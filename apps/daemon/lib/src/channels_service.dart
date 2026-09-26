import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
// The core's notifiers share the protocol's names for these lists.
import 'package:conduit_core/features/channels/providers/channel_providers.dart'
    hide ChannelMessages, ChannelTypingUsers;
import 'package:conduit_core/features/channels/providers/channel_socket_handler.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// Implements `channels.*` over the core's channel providers.
///
/// The same providers and socket handler mobile uses: a channel being
/// looked at is subscribed to over the socket, and posts, edits,
/// reactions and typing from anyone arrive through it. What the daemon
/// adds is telling the windows -- `channels.message` when a channel's
/// messages change, `channels.typing` when who is typing does -- so each
/// refetches only what it shows.
final class ChannelsService {
  ChannelsService(this._container, {EventBus? events}) : _events = events {
    if (events != null) {
      _container.listen<AsyncValue<List<Channel>>>(channelsListProvider, (
        _,
        next,
      ) {
        if (next.hasValue) events.publish(ConduitEvents.channelsChanged);
      });
      _container.listen<Map<String, String>>(channelTypingUsersProvider, (
        _,
        typing,
      ) {
        final channelId = _open;
        if (channelId == null) return;
        events.publish(
          ConduitEvents.channelsTyping,
          scope: scopeFor(channelId),
          payload: ChannelTypingUsers(
            channelId: channelId,
            names: typing.values.toList(growable: false),
          ).toJson(),
        );
      });
    }
  }

  final ProviderContainer _container;
  final EventBus? _events;

  /// The event scope a window subscribes to while it shows [channelId].
  static String scopeFor(String channelId) => 'channel:$channelId';

  /// The channel subscribed to over the socket. One at a time, as on
  /// mobile: the last one opened.
  String? _open;

  /// Channels and threads whose messages are being watched, so each change
  /// is announced once per list.
  final Map<String, ProviderSubscription<Object?>> _watched =
      <String, ProviderSubscription<Object?>>{};

  Future<ChannelList> list() async {
    final channels = await readSettled(_container, channelsListProvider.future);
    return ChannelList(
      enabled: _container.read(channelsFeatureEnabledProvider),
      channels: <ChannelSummary>[
        for (final channel in channels) _summarize(channel),
      ],
    );
  }

  Future<ChannelList> save(ChannelEdit edit) async {
    final api = _api();
    final name = edit.name.trim();
    if (name.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a channel needs a name',
      );
    }
    final description = edit.description?.trim();
    if (edit.id == null) {
      await api.createChannel(
        name: name,
        description: description,
        isPrivate: edit.private,
      );
    } else {
      await api.updateChannel(
        edit.id!,
        name: name,
        description: description,
        isPrivate: edit.private,
      );
    }
    await _container.read(channelsListProvider.notifier).refresh();
    return list();
  }

  Future<ChannelList> delete(String id) async {
    await _api().deleteChannel(id);
    _container.read(channelsListProvider.notifier).removeChannel(id);
    return list();
  }

  Future<ChannelList> leave(String id) async {
    await _api().updateMemberActiveStatus(id, isActive: false);
    _container.read(channelsListProvider.notifier).removeChannel(id);
    return list();
  }

  /// A channel's messages or a thread's, starting to listen to them.
  Future<ChannelMessages> messages(ChannelMessagesQuery query) async {
    final channelId = query.channelId;
    final parentId = query.parentId;
    if (parentId == null) {
      if (_open != channelId) {
        _open = channelId;
        _container
            .read(channelSocketHandlerProvider.notifier)
            .subscribe(channelId);
      }
      final provider = channelMessagesProvider(channelId);
      _watch(channelId, provider);
      if (query.older) {
        await _container.read(provider.notifier).loadMore();
      }
      final messages = await readSettled(_container, provider.future);
      return ChannelMessages(
        channelId: channelId,
        messages: messages.map(_message).toList(growable: false),
        hasOlder: _container.read(provider.notifier).hasMore(),
      );
    }
    final provider = threadMessagesProvider(channelId, parentId);
    _watch(channelId, provider, key: '$channelId/$parentId');
    if (query.older) {
      await _container.read(provider.notifier).loadMore();
    }
    final messages = await readSettled(_container, provider.future);
    return ChannelMessages(
      channelId: channelId,
      parentId: parentId,
      // Open WebUI answers a thread with its parent among the replies; the
      // parent is shown above them already.
      messages: <ChannelMessageDto>[
        for (final message in messages)
          if (message.id != parentId) _message(message),
      ],
      hasOlder: _container.read(provider.notifier).hasMore(),
    );
  }

  Future<ChannelMessageDto> post(ChannelPost post) async {
    final content = post.content.trim();
    if (content.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a message needs text',
      );
    }
    final json = await _api().postChannelMessage(
      post.channelId,
      content: content,
      parentId: post.parentId,
    );
    final message = ChannelMessage.fromJson(json);
    if (post.parentId == null) {
      // Shown at once rather than when the socket echoes it; the provider
      // drops the echo as a duplicate.
      _container
          .read(channelMessagesProvider(post.channelId).notifier)
          .prependMessage(message);
    } else {
      _container.invalidate(
        threadMessagesProvider(post.channelId, post.parentId!),
      );
      await _refresh(post.channelId, post.parentId!);
    }
    _announce(post.channelId);
    return _message(message);
  }

  Future<ChannelMessageDto> editMessage(ChannelMessageEdit edit) async {
    final json = await _api().updateChannelMessage(
      edit.channelId,
      edit.messageId,
      content: edit.content.trim(),
    );
    final message = ChannelMessage.fromJson(json);
    _container
        .read(channelMessagesProvider(edit.channelId).notifier)
        .updateMessage(message);
    _invalidateThreads(edit.channelId);
    _announce(edit.channelId);
    return _message(message);
  }

  Future<void> deleteMessage(ChannelMessageRef ref) async {
    await _api().deleteChannelMessage(ref.channelId, ref.messageId);
    _container
        .read(channelMessagesProvider(ref.channelId).notifier)
        .removeMessage(ref.messageId);
    _invalidateThreads(ref.channelId);
    _announce(ref.channelId);
  }

  Future<void> react(ChannelReact react) async {
    final api = _api();
    if (react.add) {
      await api.addMessageReaction(
        react.channelId,
        react.messageId,
        react.emoji,
      );
    } else {
      await api.removeMessageReaction(
        react.channelId,
        react.messageId,
        react.emoji,
      );
    }
    await _refresh(react.channelId, react.messageId);
  }

  Future<void> pin(ChannelPin pin) async {
    await _api().pinMessage(pin.channelId, pin.messageId, isPinned: pin.pinned);
    await _refresh(pin.channelId, pin.messageId);
  }

  void typing(ChannelTyping typing) => _container
      .read(channelSocketHandlerProvider.notifier)
      .emitTyping(typing.channelId, typing: typing.typing);

  Future<void> markRead(String channelId) async {
    _container
        .read(channelSocketHandlerProvider.notifier)
        .emitLastReadAt(channelId);
    _container.read(channelsListProvider.notifier).markRead(channelId);
  }

  Future<ChannelMembers> members(String channelId) async {
    final raw = await _api().getChannelMembers(channelId);
    final users = raw['users'];
    return ChannelMembers(
      users: <ChannelUser>[
        if (users is List)
          for (final user in users)
            if (user is Map && user['id'] != null)
              ChannelUser(id: '${user['id']}', name: '${user['name'] ?? ''}'),
      ],
    );
  }

  /// Reads one message again and puts it in the lists that show it: after
  /// a reaction or a pin, which the API answers without the message.
  Future<void> _refresh(String channelId, String messageId) async {
    final json = await _api().getChannelMessage(channelId, messageId);
    if (json != null) {
      _container
          .read(channelMessagesProvider(channelId).notifier)
          .updateMessage(ChannelMessage.fromJson(json));
    }
    _invalidateThreads(channelId);
    _announce(channelId);
  }

  void _invalidateThreads(String channelId) {
    for (final key in _watched.keys.toList()) {
      if (!key.startsWith('$channelId/')) continue;
      final parentId = key.substring(channelId.length + 1);
      _container.invalidate(threadMessagesProvider(channelId, parentId));
    }
  }

  void _watch(
    String channelId,
    ProviderListenable<Object?> provider, {
    String? key,
  }) {
    _watched.putIfAbsent(
      key ?? channelId,
      () =>
          _container.listen<Object?>(provider, (_, _) => _announce(channelId)),
    );
  }

  void _announce(String channelId) => _events?.publish(
    ConduitEvents.channelsMessage,
    scope: scopeFor(channelId),
    payload: ChannelMessagesChanged(channelId: channelId).toJson(),
  );

  ApiService _api() {
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'channels live on the server; sign in first',
      );
    }
    return api;
  }

  String? get _me => _container.read(currentUserProvider2)?.id;

  ChannelSummary _summarize(Channel channel) => ChannelSummary(
    id: channel.id,
    name: channel.name,
    description: channel.description,
    private: channel.isPrivate,
    unread: channel.unreadCount,
    lastMessageAtMs: _ms(channel.lastMessageAt ?? channel.updatedAt),
    manager: channel.isManager || channel.userId == _me,
    canPost: channel.writeAccess || channel.isManager || channel.userId == _me,
    userCount: channel.userCount,
  );

  ChannelMessageDto _message(ChannelMessage message) {
    final me = _me;
    final created = _ms(message.createdAt) ?? 0;
    final updated = _ms(message.updatedAt);
    // A model answering in a channel posts as the user who asked it; its
    // own name is in the message's meta, and that is who is speaking.
    final modelName =
        message.meta?['model_name'] as String? ??
        message.meta?['model_id'] as String?;
    return ChannelMessageDto(
      id: message.id,
      channelId: message.channelId ?? '',
      user: modelName != null
          ? ChannelUser(id: 'model:$modelName', name: modelName)
          : message.user == null
          ? null
          : ChannelUser(id: message.user!.id, name: message.user!.name ?? ''),
      content: message.content,
      parentId: message.parentId,
      pinned: message.isPinned,
      replyCount: message.replyCount,
      createdAtMs: created,
      // Open WebUI stamps both on creation; only a later one is an edit.
      editedAtMs: updated != null && updated > created + 1000 ? updated : null,
      reactions: <ChannelReaction>[
        for (final reaction in message.reactions)
          ChannelReaction(
            name: reaction.name,
            count: reaction.count,
            mine:
                me != null &&
                reaction.users.any(
                  (user) => '${user['id'] ?? user['user_id']}' == me,
                ),
          ),
      ],
      mine: me != null && (message.userId ?? message.user?.id) == me,
    );
  }

  /// Milliseconds from whatever Open WebUI stored: it has used seconds,
  /// milliseconds and nanoseconds in different places.
  static int? _ms(int? stamp) => switch (stamp) {
    null => null,
    final v when v > 100000000000000000 => v ~/ 1000000,
    final v when v > 100000000000000 => v ~/ 1000,
    final v when v > 100000000000 => v,
    final v => v * 1000,
  };
}

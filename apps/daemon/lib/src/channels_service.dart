import 'dart:async';
import 'dart:collection';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_members_providers.dart'
    as cm;
// The core's notifiers share the protocol's names for these lists.
import 'package:conduit_core/features/channels/providers/channel_providers.dart'
    hide ChannelMessages, ChannelTypingUsers;
import 'package:conduit_core/features/channels/providers/channel_socket_handler.dart';
import 'package:conduit_core/features/channels/utils/channel_actions.dart';
import 'package:conduit_core/features/channels/utils/channel_mentions.dart';
import 'package:conduit_core/features/channels/utils/channel_presentation.dart';
import 'package:conduit_core/features/chat/utils/file_utils.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
import 'package:conduit_core/features/notifications/services/notification_event_classifier.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_markdown/conduit_markdown.dart' as md;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'composer_wire.dart';
import 'event_bus.dart';
import 'settled.dart';

/// Implements `channels.*` over the core's channel providers.
///
/// The same providers and socket handler mobile uses: a channel being
/// looked at is subscribed to over the socket, and posts, edits,
/// reactions and typing from anyone arrive through it. What the daemon
/// adds is telling the windows:
///
/// * `channels.message` when a list a window shows changes, with what
///   changed in it (new and changed messages, removed ids), so a long
///   history is patched rather than sent again;
/// * `channels.typing` when who is typing changes;
/// * `channels.appReply` when an app answers the user alone;
/// * `channels.posted` when someone else posts in a channel that is not
///   in front of the user, after counting it unread: mobile's rules for
///   notifying (the core's classifier and Open WebUI's mentions-only
///   rule), for the window to notify with;
/// * `channels.changed` when the list changes.
final class ChannelsService {
  ChannelsService(this._container, {EventBus? events}) : _events = events {
    if (events == null) return;
    _container.listen<AsyncValue<List<Channel>>>(channelsListProvider, (
      _,
      next,
    ) {
      if (next.hasValue) events.emit(ConduitEventSpecs.channelsChanged, null);
    });
    _container.listen<Map<String, String>>(channelTypingUsersProvider, (
      _,
      typing,
    ) {
      final channelId = _open;
      if (channelId == null) return;
      events.emit(
        ConduitEventSpecs.channelsTyping,
        ChannelTypingUsers(
          channelId: channelId,
          names: typing.values.toList(growable: false),
        ),
        scope: scopeFor(channelId),
      );
    });
    _bindSocket(_container.read(socketServiceProvider));
    _container.listen<SocketService?>(
      socketServiceProvider,
      (_, next) => _bindSocket(next),
    );
  }

  final ProviderContainer _container;
  final EventBus? _events;

  static const _classifier = NotificationEventClassifier();

  /// The event scope a window subscribes to while it shows [channelId].
  static String scopeFor(String channelId) => 'channel:$channelId';

  /// The channel subscribed to over the socket. One at a time, as on
  /// mobile: the last one opened.
  String? _open;

  /// The channel in front of the user (`channels.focus`).
  String? _focused;

  /// Lists being watched, by `channelId` or `channelId/parentId`.
  final Map<String, ProviderSubscription<Object?>> _watched =
      <String, ProviderSubscription<Object?>>{};

  /// What each watched list held when last announced.
  final Map<String, List<ChannelMessage>> _snapshots =
      <String, List<ChannelMessage>>{};

  /// Lists reloaded from scratch (after a reconnect): the next change is
  /// announced whole.
  final Set<String> _reloaded = <String>{};

  SocketService? _boundSocket;
  SocketEventSubscription? _channelEvents;
  SocketEventSubscription? _appEvents;
  StreamSubscription<void>? _reconnects;

  /// Messages already counted: a socket replays some after a re-bind.
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  cm.ChannelMembersOwner? _membersOwner;
  ProviderSubscription<cm.ChannelMembersState>? _membersWatch;

  /// The account in use now, by its sign-in session.
  Object _session() => _container.read(openWebUiAuthSessionEpochProvider);

  /// Refuses an answer read under [session] once another account is in
  /// use: one account's channel is never applied to, read under or shown
  /// for the next.
  void _sameAccount(Object session) {
    if (!identical(session, _session())) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed',
      );
    }
  }

  // ── The list ──────────────────────────────────────────────────────────

  Future<ChannelList> list() async {
    final session = _session();
    final channels = await readSettled(_container, channelsListProvider.future);
    final canCreate = await _canCreate();
    // Read under another account: its channels, with the next one's flags,
    // are neither's.
    _sameAccount(session);
    return ChannelList(
      enabled: _container.read(channelsFeatureEnabledProvider),
      canCreate: canCreate,
      channels: <ChannelSummary>[
        for (final channel in channels) _summarize(channel),
      ],
    );
  }

  Future<ChannelList> save(ChannelEdit edit) async {
    final api = _api();
    final session = _session();
    final name = edit.name.trim();
    if (name.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a channel needs a name',
      );
    }
    final description = edit.description?.trim();
    final channels = _container.read(channelsListProvider.notifier);
    if (edit.id == null) {
      // As mobile's New Channel: a group, with its maker as a member.
      final channel = await createGroupChannel(
        api,
        name: name,
        description: description,
        isPrivate: edit.private,
      );
      _sameAccount(session);
      channels.addChannel(channel);
    } else {
      // Mobile's Edit Channel changes the name and the description only.
      final json = await api.updateChannel(
        edit.id!,
        name: name,
        description: description,
      );
      _sameAccount(session);
      final updated = Channel.fromJson(json);
      final listed = _listed(updated.id);
      channels.updateChannel(
        listed == null
            ? updated
            : listed.copyWith(
                name: updated.name,
                description: updated.description,
                updatedAt: updated.updatedAt,
              ),
      );
      final active = _container.read(activeChannelProvider);
      if (active?.id == updated.id) {
        _container
            .read(activeChannelProvider.notifier)
            .set(
              active!.copyWith(
                name: updated.name,
                description: updated.description,
              ),
            );
      }
    }
    return list();
  }

  Future<ChannelList> delete(String id) async {
    final session = _session();
    await _api().deleteChannel(id);
    _sameAccount(session);
    _forget(id);
    return list();
  }

  Future<ChannelList> leave(String id) async {
    final session = _session();
    await _api().updateMemberActiveStatus(id, isActive: false);
    _sameAccount(session);
    _forget(id);
    return list();
  }

  void _forget(String id) {
    _container.read(channelsListProvider.notifier).removeChannel(id);
    if (_container.read(activeChannelProvider)?.id == id) {
      _container.read(activeChannelProvider.notifier).clear();
    }
    if (_focused == id) _focused = null;
  }

  Future<ChannelList> setMuted(ChannelMute mute) async {
    await _container
        .read(channelsListProvider.notifier)
        .updateMuted(mute.id, mute.muted);
    return list();
  }

  // ── One channel ───────────────────────────────────────────────────────

  /// The channel's pane opens: it becomes the active channel (the core's
  /// member rules read it), is listened to, and is read.
  Future<ChannelDetails> open(String id) async {
    final api = _api();
    final session = _session();
    final channel = Channel.fromJson(await api.getChannel(id));
    _sameAccount(session);
    _container.read(activeChannelProvider.notifier).set(channel);
    _subscribe(id);
    await markRead(id);
    final user = _container.read(currentUserProvider2);
    final management = cm.resolveChannelMemberManagement(
      channelId: id,
      channel: channel,
      user: user,
      channelsEnabled: _container.read(channelsFeatureEnabledProvider),
      permissions: await _permissions(),
    );
    _sameAccount(session);
    final listed = _listed(id);
    return ChannelDetails(
      channel: _summarize(
        channel.copyWith(
          unreadCount: 0,
          lastMessageAt: channel.lastMessageAt ?? listed?.lastMessageAt,
        ),
      ),
      canManageMembers: management.canManage,
      moderator: user?.role == 'admin',
    );
  }

  /// The channel in front of the user now (none: [id] null). Its new
  /// messages are read as they arrive.
  Future<void> focus(String? id) async {
    _focused = id;
    if (id != null) await markRead(id);
  }

  void _subscribe(String channelId) {
    if (_open == channelId) return;
    _open = channelId;
    _container.read(channelSocketHandlerProvider.notifier).subscribe(channelId);
  }

  /// A channel's messages or a thread's, starting to listen to them.
  Future<ChannelMessages> messages(ChannelMessagesQuery query) async {
    final channelId = query.channelId;
    final parentId = query.parentId;
    if (parentId == null) {
      _subscribe(channelId);
      final provider = channelMessagesProvider(channelId);
      _watch(channelId, null, provider, () {
        return _container.read(provider.notifier).hasMore();
      });
      if (query.older) {
        await _container.read(provider.notifier).loadMore();
      }
      final messages = await readSettled(_container, provider.future);
      _snapshots[channelId] = messages;
      return ChannelMessages(
        channelId: channelId,
        messages: messages.map(_message).toList(growable: false),
        hasOlder: _container.read(provider.notifier).hasMore(),
      );
    }
    final provider = threadMessagesProvider(channelId, parentId);
    final key = '$channelId/$parentId';
    _watch(channelId, parentId, provider, () {
      return _container.read(provider.notifier).hasMore();
    });
    if (query.older) {
      await _container.read(provider.notifier).loadMore();
    }
    final messages = await readSettled(_container, provider.future);
    _snapshots[key] = messages;
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
    final content = composerWireText(post.content, post.mentions).trim();
    if (content.isEmpty && post.files.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a message needs text or a file',
      );
    }
    final session = _session();
    final json = await _api().postChannelMessage(
      post.channelId,
      content: content,
      tempId: DateTime.now().microsecondsSinceEpoch.toString(),
      parentId: post.parentId,
      replyToId: post.parentId == null ? post.replyToId : null,
      data: post.files.isEmpty
          ? null
          : <String, dynamic>{
              'files': <Map<String, dynamic>>[
                for (final file in post.files)
                  <String, dynamic>{
                    'type': file.image ? 'image' : 'file',
                    'id': file.id,
                    'url': file.id,
                    'name': file.name,
                    'size': ?file.size,
                    'status': 'uploaded',
                    'content_type': ?file.contentType,
                  },
              ],
            },
    );
    _sameAccount(session);
    var message = ChannelMessage.fromJson(json);
    // The post endpoint answers with a bare row that names only the
    // sender's id.
    final me = _container.read(currentUserProvider2);
    if (me != null) message = message.withSenderIfMissing(me);
    // Shown at once rather than when the socket echoes it; the provider
    // drops the echo as a duplicate.
    final parentId = post.parentId;
    if (parentId == null) {
      _container
          .read(channelMessagesProvider(post.channelId).notifier)
          .prependMessage(message);
    } else {
      final thread = threadMessagesProvider(post.channelId, parentId);
      if (_container.read(thread.exists)) {
        _container.read(thread.notifier).prependMessage(message);
      }
    }
    return _message(message);
  }

  Future<ChannelMessageDto> editMessage(ChannelMessageEdit edit) async {
    final content = edit.content.trim();
    if (content.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a message needs text',
      );
    }
    final session = _session();
    final json = await _api().updateChannelMessage(
      edit.channelId,
      edit.messageId,
      content: content,
    );
    _sameAccount(session);
    final response = ChannelMessage.fromJson(json);
    _container
        .read(channelMessagesProvider(edit.channelId).notifier)
        .applyEditResponse(response);
    _forThreads(edit.channelId, (thread) => thread.updateMessage(response));
    final shown = _find(edit.channelId, edit.messageId) ?? response;
    return _message(shown);
  }

  Future<void> deleteMessage(ChannelMessageRef ref) async {
    final session = _session();
    await _api().deleteChannelMessage(ref.channelId, ref.messageId);
    _sameAccount(session);
    _container
        .read(channelMessagesProvider(ref.channelId).notifier)
        .removeMessage(ref.messageId);
    _forThreads(ref.channelId, (thread) => thread.removeMessage(ref.messageId));
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
    final session = _session();
    final json = await _api().pinMessage(
      pin.channelId,
      pin.messageId,
      isPinned: pin.pinned,
    );
    _sameAccount(session);
    if (json == null) {
      await _refresh(pin.channelId, pin.messageId);
      return;
    }
    final response = ChannelMessage.fromJson(json);
    if (response.parentId == null) {
      _container
          .read(channelMessagesProvider(pin.channelId).notifier)
          .applyPinResponse(response);
    } else {
      await _refresh(pin.channelId, pin.messageId);
    }
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

  // ── People ────────────────────────────────────────────────────────────

  Future<ChannelMembers> members(String channelId) async {
    final session = _session();
    final raw = await _api().getChannelMembers(channelId);
    _sameAccount(session);
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

  /// The channel's members whose name starts what follows an `@`: the
  /// server's own search, by name. The user is left out.
  Future<MentionList> mentions(ChannelMentionQuery query) async {
    final session = _session();
    final raw = await _api().getChannelMembers(
      query.channelId,
      query: query.query.trim().isEmpty ? null : query.query.trim(),
      orderBy: 'name',
      direction: 'asc',
    );
    _sameAccount(session);
    final me = _me;
    final users = raw['users'];
    return MentionList(
      users: <MentionTarget>[
        if (users is List)
          for (final user in users)
            if (cm.ChannelMember.fromJson(user) case final member?
                when member.id != me)
              MentionTarget(
                id: member.id,
                name: member.name,
                detail: member.email,
              ),
      ],
    );
  }

  /// A page of the members sheet, from the core's member list for the
  /// owner who opened it.
  Future<ChannelMemberPage> memberPage(ChannelMemberQuery query) async {
    final owner = await _members(query.channelId);
    final controller = _container.read(
      cm.channelMembersControllerProvider(owner).notifier,
    );
    if (query.more) {
      await controller.loadMore();
    } else {
      await controller.setQuery(query.query);
    }
    await _settledMembers(owner);
    return _page(owner);
  }

  Future<ChannelMemberChange> addMembers(ChannelMembersAdd add) async {
    final owner = await _members(add.channelId);
    final result = await _container
        .read(cm.channelMembersControllerProvider(owner).notifier)
        .addMembers(userIds: add.userIds, groupIds: add.groupIds);
    await _settledMembers(owner);
    await _refreshCount(add.channelId);
    return ChannelMemberChange(result: _result(result), page: _page(owner));
  }

  Future<ChannelMemberChange> removeMember(ChannelMemberRemove remove) async {
    final owner = await _members(remove.channelId);
    final result = await _container
        .read(cm.channelMembersControllerProvider(owner).notifier)
        .removeMember(remove.userId);
    await _settledMembers(owner);
    await _refreshCount(remove.channelId);
    return ChannelMemberChange(result: _result(result), page: _page(owner));
  }

  /// The member list's owner for [channelId], captured once and kept while
  /// it stays current, as mobile's sheet holds one owner while open.
  Future<cm.ChannelMembersOwner> _members(String channelId) async {
    final held = _membersOwner;
    if (held != null &&
        held.channelId == channelId &&
        held.isCurrent(_container.read)) {
      return held;
    }
    // The core's rules read the active channel and the permissions.
    final session = _session();
    if (_container.read(activeChannelProvider)?.id != channelId) {
      final channel = Channel.fromJson(await _api().getChannel(channelId));
      _sameAccount(session);
      _container.read(activeChannelProvider.notifier).set(channel);
    }
    await _permissions();
    _sameAccount(session);
    final owner = cm.ChannelMembersOwner.capture(_container.read, channelId);
    if (owner == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'channel members live on the server; sign in first',
      );
    }
    _membersWatch?.close();
    _membersOwner = owner;
    _membersWatch = _container.listen(
      cm.channelMembersControllerProvider(owner),
      (_, _) {},
    );
    _container.listen(cm.channelMemberManagementProvider(owner), (_, _) {});
    return owner;
  }

  /// Waits while the list's first page is on its way.
  Future<void> _settledMembers(cm.ChannelMembersOwner owner) async {
    final provider = cm.channelMembersControllerProvider(owner);
    for (var i = 0; i < 200; i++) {
      final state = _container.read(provider);
      if (state.phase != cm.ChannelMembersPhase.loading &&
          !state.loadingMore &&
          !state.mutating) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  ChannelMemberPage _page(cm.ChannelMembersOwner owner) {
    final state = _container.read(cm.channelMembersControllerProvider(owner));
    final management = _container.read(
      cm.channelMemberManagementProvider(owner),
    );
    final me = _me;
    return ChannelMemberPage(
      channelId: owner.channelId,
      query: state.query,
      phase: switch (state.phase) {
        cm.ChannelMembersPhase.loading => ChannelMemberListPhase.loading,
        cm.ChannelMembersPhase.ready => ChannelMemberListPhase.ready,
        cm.ChannelMembersPhase.failed => ChannelMemberListPhase.failed,
        cm.ChannelMembersPhase.ownerChanged =>
          ChannelMemberListPhase.ownerChanged,
      },
      members: <ChannelMemberDto>[
        for (final member in state.members)
          ChannelMemberDto(
            id: member.id,
            name: member.name,
            email: member.email,
            role: member.role,
            active: member.isActive,
            me: member.id == me,
          ),
      ],
      total: state.total,
      hasMore: state.hasMore,
      loadMoreFailed: state.loadMoreFailed,
      canManage: management.canManage,
      allowUsers: management.allowUsers,
      allowGroups: management.allowGroups,
    );
  }

  static ChannelMemberChangeResult _result(
    cm.ChannelMemberMutationResult result,
  ) => switch (result) {
    cm.ChannelMemberMutationResult.done => ChannelMemberChangeResult.done,
    cm.ChannelMemberMutationResult.ownerChanged =>
      ChannelMemberChangeResult.ownerChanged,
    cm.ChannelMemberMutationResult.notPermitted =>
      ChannelMemberChangeResult.notPermitted,
    cm.ChannelMemberMutationResult.denied => ChannelMemberChangeResult.denied,
    cm.ChannelMemberMutationResult.failed => ChannelMemberChangeResult.failed,
    cm.ChannelMemberMutationResult.busy => ChannelMemberChangeResult.busy,
  };

  /// Reads the channel again after a member change, so its count is the
  /// server's (as mobile's toolbar does).
  Future<void> _refreshCount(String channelId) async {
    try {
      final session = _session();
      final channel = Channel.fromJson(await _api().getChannel(channelId));
      _sameAccount(session);
      if (_container.read(activeChannelProvider)?.id == channelId) {
        _container.read(activeChannelProvider.notifier).set(channel);
      }
      final listed = _listed(channelId);
      if (listed != null) {
        _container
            .read(channelsListProvider.notifier)
            .updateChannel(listed.copyWith(userCount: channel.userCount));
      }
    } on Object {
      // The count catches up the next time the channel opens.
    }
  }

  // ── Apps ──────────────────────────────────────────────────────────────

  /// Presses button [action] of an app's message. An answer for the asker
  /// alone comes back; one to everyone arrives as a message.
  Future<ChannelAppActionResult> appAction(ChannelAppAction action) async {
    final api = _api();
    final session = _session();
    var message = _find(action.channelId, action.messageId);
    if (message == null) {
      final json = await api.getChannelMessage(
        action.channelId,
        action.messageId,
      );
      _sameAccount(session);
      if (json != null) message = ChannelMessage.fromJson(json);
    }
    final appId = message?.appId;
    if (message == null || appId == null) {
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'that is not an app message',
      );
    }
    final Map<String, dynamic> json;
    try {
      json = await api.createAppInteraction(
        appId,
        messageId: message.id,
        actionId: action.actionId,
      );
    } on DioException catch (error) {
      final data = error.response?.data;
      final detail = data is Map ? data['detail'] : null;
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        args: <String, String>{
          if (detail is String && detail.trim().isNotEmpty)
            'detail': detail.trim(),
        },
        debugMessage: 'app interaction failed: ${error.response?.statusCode}',
      );
    }
    _sameAccount(session);
    final reply = AppChannelReply.fromJson(json);
    if (reply == null || !reply.showsToAskerOnly) {
      return const ChannelAppActionResult();
    }
    return ChannelAppActionResult(
      reply: ChannelAppReplyEvent(
        channelId: action.channelId,
        messageId: message.id,
        parentId: action.parentId,
        appId: appId,
        appName: message.user?.name,
        reply: _reply(reply),
      ),
    );
  }

  void _onAppEvent(Map<String, dynamic> event) {
    final parsed = AppChannelReplyEvent.fromJson(event);
    if (parsed == null || parsed.reply.isAck) return;
    _events?.emit(
      ConduitEventSpecs.channelsAppReply,
      ChannelAppReplyEvent(
        channelId: parsed.channelId,
        messageId: parsed.messageId,
        parentId: parsed.parentId,
        appId: parsed.appId,
        appName: parsed.appName,
        reply: _reply(parsed.reply),
      ),
      scope: scopeFor(parsed.channelId),
    );
  }

  static ChannelAppReplyDto _reply(AppChannelReply reply) => ChannelAppReplyDto(
    kind: switch (reply.type) {
      'update' => ChannelAppReplyKind.update,
      'download' => ChannelAppReplyKind.download,
      'error' => ChannelAppReplyKind.error,
      _ => ChannelAppReplyKind.message,
    },
    title: reply.title,
    content: reply.content,
    filename: reply.filename,
    embeds: reply.embeds.map(_embed).toList(growable: false),
    actions: reply.actions.map(_action).toList(growable: false),
  );

  static ChannelAppEmbedDto _embed(AppEmbed embed) => ChannelAppEmbedDto(
    title: embed.title,
    description: _display(embed.description),
    url: _web(embed.url),
    color: embed.color,
    authorName: embed.authorName,
    footerText: embed.footerText,
    thumbnailUrl: _web(embed.thumbnailUrl),
    fields: <ChannelAppFieldDto>[
      for (final field in embed.fields)
        ChannelAppFieldDto(
          name: field.name,
          value: _display(field.value),
          inline: field.inline,
        ),
    ],
  );

  static ChannelAppActionDto _action(AppAction action) => ChannelAppActionDto(
    label: action.label,
    actionId: action.actionId,
    url: _web(action.url),
  );

  /// Only http(s) links from an app reach a window.
  static String? _web(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    return url;
  }

  // ── The socket ────────────────────────────────────────────────────────

  void _bindSocket(SocketService? socket) {
    if (identical(socket, _boundSocket)) return;
    _boundSocket = socket;
    _channelEvents?.dispose();
    _channelEvents = null;
    _appEvents?.dispose();
    _appEvents = null;
    unawaited(_reconnects?.cancel());
    _reconnects = null;
    if (socket == null) return;
    // Every channel's events, open or not, as mobile's notification
    // listener hears them.
    _channelEvents = socket.addChannelEventHandler(
      requireFocus: false,
      handler: (event, _) => _onChannelEvent(event),
    );
    _appEvents = socket.addAppEventHandler(_onAppEvent);
    _reconnects = socket.onReconnect.listen((_) {
      // Unread counts drift while disconnected, and Socket.IO replays no
      // channel history: read the list again, and every list a window
      // shows from its newest page.
      unawaited(_container.read(channelsListProvider.notifier).refresh());
      for (final key in _watched.keys) {
        _reloaded.add(key);
      }
      _container.invalidate(channelMessagesProvider);
      _container.invalidate(threadMessagesProvider);
    });
  }

  /// The notification scope of the account the socket belongs to: the
  /// active Open WebUI account. Null before an account settles, when
  /// nothing can be attributed to one.
  String? get _notificationScope {
    final accountId = _container.read(settledActiveAccountIdProvider);
    if (accountId == null || accountId.isEmpty) return null;
    return NotificationScope.openWebUi(accountId).value;
  }

  void _onChannelEvent(Map<String, dynamic> event) {
    try {
      // A mute set here or in another session reaches the list.
      if (parseChannelMuteEvent(event) case final mute?) {
        _container
            .read(channelsListProvider.notifier)
            .setMuted(mute.channelId, mute.isChannelMuted);
        return;
      }
      final envelope = event['data'];
      final type = envelope is Map ? envelope['type'] : null;
      // A direct message someone started, or a channel the user was added
      // to: the list learns of it.
      if (type == 'channel:created') {
        unawaited(_container.read(channelsListProvider.notifier).refresh());
        return;
      }
      final me = _me;
      // Until the user is known, the user's own messages cannot be told
      // apart: count nothing.
      if (me == null || me.isEmpty) return;
      final scope = _notificationScope;
      if (scope == null) return;
      final notification = _classifier.classifyChannelEvent(
        event,
        currentUserId: me,
        scope: scope,
      );
      if (notification == null || !_fresh(notification.dedupKey)) return;
      final channelId = notification.sourceId;
      if (channelId == _focused) {
        // In front of the user: read as it arrives.
        _container
            .read(channelSocketHandlerProvider.notifier)
            .emitLastReadAt(channelId);
        return;
      }
      if (_listed(channelId) == null) {
        unawaited(_container.read(channelsListProvider.notifier).refresh());
      } else {
        _container.read(channelsListProvider.notifier).bumpUnread(channelId);
      }
      final data = envelope is Map ? envelope['data'] : null;
      final author = data is Map ? data['user'] : null;
      unawaited(
        _announcePost(
          channelId: channelId,
          messageId: data is Map ? '${data['id'] ?? ''}' : '',
          author: author is Map ? '${author['name'] ?? ''}' : '',
          content: notification.body,
          me: me,
          session: _session(),
        ),
      );
    } on Object {
      // A malformed envelope is no message: nothing to count.
    }
  }

  /// Tells the windows someone else posted in [channelId], with whether
  /// it alerts. Like Open WebUI, the channel's setting comes from the list,
  /// or from the channel itself when the list does not hold it yet, and a
  /// message whose channel cannot be read does not notify.
  Future<void> _announcePost({
    required String channelId,
    required String messageId,
    required String author,
    required String content,
    required String me,
    required Object session,
  }) async {
    var channel = _listed(channelId);
    if (channel == null) {
      try {
        channel = Channel.fromJson(await _api().getChannel(channelId));
      } on Object {
        return;
      }
    }
    // Read under another account: its notice is not the next one's.
    if (_me != me || !identical(session, _session())) return;
    final summary = _summarize(channel);
    _events?.emit(
      ConduitEventSpecs.channelsPosted,
      ChannelPosted(
        channelId: channelId,
        messageId: messageId,
        author: author,
        channelTitle: channel.isDm ? '' : summary.title,
        kind: summary.kind,
        alert: shouldNotifyChannelMessage(
          isMuted: channel.isChannelMuted,
          content: content,
          userId: me,
        ),
        mention: shouldNotifyChannelMessage(
          isMuted: true,
          content: content,
          userId: me,
        ),
      ),
    );
  }

  bool _fresh(String key) {
    if (!_seen.add(key)) return false;
    if (_seen.length > 256) _seen.remove(_seen.first);
    return true;
  }

  // ── Watching lists ────────────────────────────────────────────────────

  void _watch(
    String channelId,
    String? parentId,
    ProviderListenable<AsyncValue<List<ChannelMessage>>> provider,
    bool Function() hasOlder,
  ) {
    final key = parentId == null ? channelId : '$channelId/$parentId';
    _watched.putIfAbsent(
      key,
      () => _container.listen<AsyncValue<List<ChannelMessage>>>(provider, (
        _,
        next,
      ) {
        if (next.isLoading || !next.hasValue) return;
        _announce(key, channelId, parentId, next.requireValue, hasOlder);
      }),
    );
  }

  /// Tells a window what changed in the list [key] since it was last told.
  void _announce(
    String key,
    String channelId,
    String? parentId,
    List<ChannelMessage> next,
    bool Function() hasOlder,
  ) {
    final events = _events;
    final before = _snapshots[key];
    _snapshots[key] = next;
    if (events == null) return;
    bool? older;
    try {
      older = hasOlder();
    } on Object {
      older = null;
    }
    if (before == null || _reloaded.remove(key)) {
      events.emit(
        ConduitEventSpecs.channelsMessage,
        ChannelMessagesChanged(
          channelId: channelId,
          parentId: parentId,
          full: true,
          hasOlder: older,
        ),
        scope: scopeFor(channelId),
      );
      return;
    }
    final previous = <String, ChannelMessage>{
      for (final message in before) message.id: message,
    };
    final upserts = <ChannelMessageDto>[];
    final present = <String>{};
    for (final message in next) {
      present.add(message.id);
      if (parentId != null && message.id == parentId) continue;
      final old = previous[message.id];
      if (old == null || (!identical(old, message) && old != message)) {
        upserts.add(_message(message));
      }
    }
    final removed = <String>[
      for (final id in previous.keys)
        if (!present.contains(id)) id,
    ];
    if (upserts.isEmpty && removed.isEmpty) return;
    events.emit(
      ConduitEventSpecs.channelsMessage,
      ChannelMessagesChanged(
        channelId: channelId,
        parentId: parentId,
        upserts: upserts,
        removed: removed,
        hasOlder: older,
      ),
      scope: scopeFor(channelId),
    );
  }

  /// Reads one message again and puts it in the list that shows it: after
  /// a reaction or a pin, which the API answers without the message.
  Future<void> _refresh(String channelId, String messageId) async {
    final session = _session();
    final json = await _api().getChannelMessage(channelId, messageId);
    _sameAccount(session);
    if (json == null) return;
    final message = ChannelMessage.fromJson(json);
    final parentId = message.parentId;
    if (parentId == null || parentId.isEmpty) {
      _container
          .read(channelMessagesProvider(channelId).notifier)
          .updateMessage(message);
      return;
    }
    final thread = threadMessagesProvider(channelId, parentId);
    if (_container.read(thread.exists)) {
      _container.read(thread.notifier).updateMessage(message);
    }
  }

  /// Runs [apply] on every loaded thread of [channelId].
  void _forThreads(String channelId, void Function(ThreadMessages) apply) {
    for (final key in _watched.keys) {
      if (!key.startsWith('$channelId/')) continue;
      final thread = threadMessagesProvider(
        channelId,
        key.substring(channelId.length + 1),
      );
      if (_container.read(thread.exists)) {
        apply(_container.read(thread.notifier));
      }
    }
  }

  /// A message a loaded list holds.
  ChannelMessage? _find(String channelId, String messageId) {
    for (final entry in _snapshots.entries) {
      if (entry.key != channelId && !entry.key.startsWith('$channelId/')) {
        continue;
      }
      for (final message in entry.value) {
        if (message.id == messageId) return message;
      }
    }
    return null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────

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

  bool get _admin => _container.read(currentUserProvider2)?.role == 'admin';

  Channel? _listed(String id) {
    for (final channel
        in _container.read(channelsListProvider).value ?? const <Channel>[]) {
      if (channel.id == id) return channel;
    }
    return null;
  }

  /// The account's permissions, for a non-admin; null when unreadable.
  Future<Map<String, dynamic>?> _permissions() async {
    if (_admin) return null;
    try {
      return await _container
          .read(userPermissionsProvider.future)
          .timeout(const Duration(seconds: 5));
    } on Object {
      return null;
    }
  }

  /// New Channel: channels on, and an admin or a user the server's
  /// `features.channels` permission lets (Open WebUI's create route).
  Future<bool> _canCreate() async {
    if (!_container.read(channelsFeatureEnabledProvider)) return false;
    if (_container.read(currentUserProvider2) == null) return false;
    if (_admin) return true;
    final permissions = await _permissions();
    final features = permissions?['features'];
    return !(features is Map && features['channels'] == false);
  }

  ChannelSummary _summarize(Channel channel) {
    final me = _me;
    // Open WebUI lets the owner or an admin change and delete a channel.
    final owns = _admin || (me != null && channel.userId == me);
    return ChannelSummary(
      id: channel.id,
      name: channel.name,
      description: channel.description,
      private: channel.isPrivate,
      unread: channel.unreadCount,
      lastMessageAtMs: _ms(channel.lastMessageAt ?? channel.updatedAt),
      manager: owns,
      canPost: channel.writeAccess || channel.isManager || owns,
      userCount: channel.userCount,
      kind: channel.isDm
          ? ChannelKind.dm
          : channel.isGroup
          ? ChannelKind.group
          : ChannelKind.standard,
      title: channelDisplayName(channel, fallback: '', excludingUserId: me),
      muted: channel.isChannelMuted,
      canDelete: owns && !channel.isDm,
      canLeave: channel.isDm || channel.isGroup,
    );
  }

  ChannelMessageDto _message(ChannelMessage message) {
    final me = _me;
    final created = _ms(message.createdAt) ?? 0;
    final updated = _ms(message.updatedAt);
    final model = isModelMessage(message);
    final app = message.isAppMessage;
    final senderId = channelMessageSender(message) ?? '';
    final name = messageDisplayName(message);
    final reply = message.replyToMessage;
    return ChannelMessageDto(
      id: message.id,
      channelId: message.channelId ?? '',
      // A model answering in a channel posts as the user who asked it; its
      // own name is in the message's meta, and that is who is speaking.
      user: model
          ? ChannelUser(id: 'model:$senderId', name: name)
          : message.user == null && !app
          ? null
          : ChannelUser(
              id: app ? 'app:${message.appId}' : message.user!.id,
              name: message.user?.name ?? name,
            ),
      content: message.content,
      display: _display(message.content),
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
            names: <String>[
              for (final user in reaction.users)
                if (user['name'] case final String name when name.isNotEmpty)
                  name,
            ],
          ),
      ],
      mine: !app && me != null && (message.userId ?? message.user?.id) == me,
      senderKey: model
          ? 'model:$senderId'
          : app
          ? 'app:$senderId'
          : senderId,
      senderKind: model
          ? ChannelSenderKind.model
          : app
          ? ChannelSenderKind.app
          : ChannelSenderKind.user,
      files: _files(message.data?['files']),
      app: app
          ? ChannelAppContentDto(
              appId: message.appId!,
              embeds: message.appEmbeds.map(_embed).toList(growable: false),
              actions: message.appActions.map(_action).toList(growable: false),
            )
          : null,
      replyToId: message.replyToId,
      replyTo: reply == null
          ? null
          : ChannelReplyPreview(
              name: messageDisplayName(reply),
              text: stripMentions(reply.previewText),
            ),
      latestReplyAtMs: _ms(message.latestReplyAt),
    );
  }

  static List<ChannelFileDto> _files(Object? files) {
    if (files is! List) return const <ChannelFileDto>[];
    final out = <ChannelFileDto>[];
    for (final file in files) {
      if (file is! Map) continue;
      final id = chatFileShownId(file);
      if (id == null || id.isEmpty) continue;
      final size = file['size'];
      final type = file['content_type'];
      out.add(
        ChannelFileDto(
          id: id,
          name: '${file['name'] ?? ''}',
          image: isImageFile(file),
          size: size is num ? size.toInt() : null,
          contentType: type is String ? type : null,
        ),
      );
    }
    return out;
  }

  /// [content] as a window draws it: mentions as bold `@Name`, then the
  /// shared plain-markdown rules (math, escaped HTML and dollars).
  static String _display(String content) {
    if (content.isEmpty) return content;
    final mentions = content.replaceAllMapped(
      mentionRegex,
      (m) => '**@${m.group(2)}**',
    );
    return md.normalizeTextForPlainMarkdown(
      md.ConduitMarkdownPreprocessor.normalize(mentions),
      hasSources: false,
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

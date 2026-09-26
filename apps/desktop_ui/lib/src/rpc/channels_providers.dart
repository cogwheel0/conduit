import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'chat_providers.dart';
import 'rpc_providers.dart';

/// Ticks on `channels.changed`: a channel added, renamed, deleted, or an
/// unread count moved.
final _channelsChangedProvider = StreamProvider<int>((ref) {
  var tick = 0;
  return ref
      .watch(rpcClientProvider)
      .events
      .where((envelope) => envelope.event == ConduitEvents.channelsChanged)
      .map((_) => ++tick);
});

/// Every channel the user can see.
final channelListProvider = FutureProvider<ChannelList>((ref) async {
  ref.watch(coreConnectionProvider);
  ref.watch(_channelsChangedProvider);
  return ref
      .read(rpcClientProvider)
      .call(ConduitMethods.channelsList, decode: ChannelList.fromJson);
});

/// Ticks on `channels.message` for one channel.
final _channelMessagesChangedProvider = StreamProvider.family<int, String>((
  ref,
  channelId,
) {
  var tick = 0;
  return ref
      .watch(rpcClientProvider)
      .events
      .where(
        (envelope) =>
            envelope.event == ConduitEvents.channelsMessage &&
            envelope.payload['channelId'] == channelId,
      )
      .map((_) => ++tick);
});

/// A channel's messages, or with a parent id one thread's; newest first.
/// Refetched whenever the daemon says that channel changed.
final channelMessagesProvider =
    FutureProvider.family<
      ChannelMessages,
      ({String channelId, String? parentId})
    >((ref, key) async {
      ref.watch(coreConnectionProvider);
      // Keeps this window subscribed to the channel's scope.
      ref.watch(eventSubscriptionProvider);
      ref.watch(_channelMessagesChangedProvider(key.channelId));
      return ref
          .read(rpcClientProvider)
          .call(
            ConduitMethods.channelsMessages,
            params: ChannelMessagesQuery(
              channelId: key.channelId,
              parentId: key.parentId,
            ).toJson(),
            decode: ChannelMessages.fromJson,
          );
    });

/// Who is typing in [channelId], by name. Emptied when they stop.
final channelTypingProvider = StreamProvider.family<List<String>, String>((
  ref,
  channelId,
) {
  return ref
      .watch(rpcClientProvider)
      .events
      .where((envelope) => envelope.event == ConduitEvents.channelsTyping)
      .map((envelope) => ChannelTypingUsers.fromJson(envelope.payload))
      .where((typing) => typing.channelId == channelId)
      .map((typing) => typing.names);
});

/// Who can be mentioned in [channelId].
final channelMembersProvider = FutureProvider.family<ChannelMembers, String>((
  ref,
  channelId,
) async {
  return ref
      .read(rpcClientProvider)
      .call(
        ConduitMethods.channelsMembers,
        params: ChannelRef(id: channelId).toJson(),
        decode: ChannelMembers.fromJson,
      );
});

final channelActionsProvider = Provider<ChannelActions>(ChannelActions.new);

class ChannelActions {
  ChannelActions(this._ref);

  final Ref _ref;

  Future<T> _call<T>(
    String method,
    Map<String, dynamic> params,
    T Function(Map<String, dynamic>) decode,
  ) =>
      _ref.read(rpcClientProvider).call(method, params: params, decode: decode);

  Future<ChannelList> save(ChannelEdit edit) async {
    final list = await _call(
      ConduitMethods.channelsSave,
      edit.toJson(),
      ChannelList.fromJson,
    );
    _ref.invalidate(channelListProvider);
    return list;
  }

  Future<void> delete(String id) async {
    await _call(
      ConduitMethods.channelsDelete,
      ChannelRef(id: id).toJson(),
      ChannelList.fromJson,
    );
    _ref.invalidate(channelListProvider);
  }

  Future<void> leave(String id) async {
    await _call(
      ConduitMethods.channelsLeave,
      ChannelRef(id: id).toJson(),
      ChannelList.fromJson,
    );
    _ref.invalidate(channelListProvider);
  }

  /// Older messages: the next page back, merged by the daemon.
  Future<void> loadOlder(String channelId, {String? parentId}) async {
    await _call(
      ConduitMethods.channelsMessages,
      ChannelMessagesQuery(
        channelId: channelId,
        parentId: parentId,
        older: true,
      ).toJson(),
      ChannelMessages.fromJson,
    );
    _ref.invalidate(
      channelMessagesProvider((channelId: channelId, parentId: parentId)),
    );
  }

  Future<void> post(ChannelPost post) => _call(
    ConduitMethods.channelsPost,
    post.toJson(),
    ChannelMessageDto.fromJson,
  );

  Future<void> edit(ChannelMessageEdit edit) => _call(
    ConduitMethods.channelsEditMessage,
    edit.toJson(),
    ChannelMessageDto.fromJson,
  );

  Future<void> deleteMessage(String channelId, String messageId) => _call(
    ConduitMethods.channelsDeleteMessage,
    ChannelMessageRef(channelId: channelId, messageId: messageId).toJson(),
    (json) => json,
  );

  Future<void> react(ChannelReact react) =>
      _call(ConduitMethods.channelsReact, react.toJson(), (json) => json);

  Future<void> pin(ChannelPin pin) =>
      _call(ConduitMethods.channelsPin, pin.toJson(), (json) => json);

  Future<void> typing(String channelId, {required bool typing}) => _call(
    ConduitMethods.channelsTyping,
    ChannelTyping(channelId: channelId, typing: typing).toJson(),
    (json) => json,
  );

  Future<void> markRead(String channelId) => _call(
    ConduitMethods.channelsMarkRead,
    ChannelRef(id: channelId).toJson(),
    (json) => json,
  );
}

/// OpenWebUI's mention markup: `<@U:user_id|Name>`, `<@M:model_id|Name>`.
final RegExp channelMentionPattern = RegExp(r'<@[A-Z]:([^|>]+)\|([^>]+)>');

/// [content] with mentions shown as `@Name`, in bold, for the markdown
/// renderer.
String channelMarkdown(String content) => content.replaceAllMapped(
  channelMentionPattern,
  (match) => '**@${match.group(2)}**',
);

/// The mention markup for [user].
String channelMention(ChannelUser user) => '<@U:${user.id}|${user.name}>';

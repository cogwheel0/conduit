import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/models/channel.dart';
import '../../../core/models/channel_message.dart';
import '../../../core/providers/app_providers.dart';

part 'channel_providers.g.dart';

/// Fetches and manages the list of all channels.
@Riverpod(keepAlive: true)
class ChannelsList extends _$ChannelsList {
  @override
  Future<List<Channel>> build() async {
    final api = ref.watch(apiServiceProvider);
    if (api == null) return [];
    final (rawChannels, featureEnabled) = await api.getChannels();
    ref
        .read(channelsFeatureEnabledProvider.notifier)
        .setEnabled(featureEnabled);
    return rawChannels.map((json) => Channel.fromJson(json)).toList()
      ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    final result = await AsyncValue.guard(() => build());
    if (!ref.mounted) return;
    state = result;
  }

  void addChannel(Channel channel) {
    final current = state.value ?? [];
    state = AsyncValue.data([channel, ...current]);
  }

  void removeChannel(String channelId) {
    final current = state.value ?? [];
    state = AsyncValue.data(current.where((c) => c.id != channelId).toList());
  }

  void updateChannel(Channel updated) {
    final current = state.value ?? [];
    state = AsyncValue.data(
      current.map((c) => c.id == updated.id ? updated : c).toList(),
    );
  }
}

/// Tracks the currently active/viewed channel.
@Riverpod(keepAlive: true)
class ActiveChannel extends _$ActiveChannel {
  @override
  Channel? build() => null;

  void set(Channel? channel) => state = channel;

  void clear() => state = null;
}

/// Fetches paginated messages for a channel using skip/limit
/// pagination.
@Riverpod(keepAlive: true)
class ChannelMessages extends _$ChannelMessages {
  static const int _pageSize = 50;
  bool _hasMore = true;

  @override
  Future<List<ChannelMessage>> build(String channelId) async {
    _hasMore = true;
    final api = ref.watch(apiServiceProvider);
    if (api == null) return [];
    final rawMessages = await api.getChannelMessages(
      channelId,
      limit: _pageSize,
    );
    final messages = rawMessages
        .map((json) => ChannelMessage.fromJson(json))
        .toList();
    if (messages.length < _pageSize) _hasMore = false;
    return messages;
  }

  bool hasMore() => _hasMore;

  /// Loads older messages using skip/limit pagination.
  Future<void> loadMore() async {
    if (!_hasMore) return;
    final current = state.value ?? [];
    if (current.isEmpty) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    final rawMessages = await api.getChannelMessages(
      channelId,
      skip: current.length,
      limit: _pageSize,
    );
    final older = rawMessages
        .map((json) => ChannelMessage.fromJson(json))
        .toList();
    if (older.length < _pageSize) _hasMore = false;
    if (!ref.mounted) return;
    state = AsyncValue.data([...current, ...older]);
  }

  /// Prepends a new message (from send or socket event).
  ///
  /// Deduplicates by ID to prevent double-insertion when the
  /// local send response and the socket event both arrive.
  void prependMessage(ChannelMessage message) {
    final current = state.value ?? [];
    if (current.any((m) => m.id == message.id)) return;
    state = AsyncValue.data([message, ...current]);
  }

  /// Updates a message in the list (edit, reaction change).
  void updateMessage(ChannelMessage updated) {
    final current = state.value ?? [];
    state = AsyncValue.data(
      current.map((m) => m.id == updated.id ? updated : m).toList(),
    );
  }

  /// Removes a message from the list.
  void removeMessage(String messageId) {
    final current = state.value ?? [];
    state = AsyncValue.data(current.where((m) => m.id != messageId).toList());
  }
}

/// Tracks users currently typing in the active channel.
///
/// Maps user ID to display name. Entries are added when a
/// `typing` socket event arrives and removed after a timeout.
@Riverpod(keepAlive: true)
class ChannelTypingUsers extends _$ChannelTypingUsers {
  @override
  Map<String, String> build() => {};

  /// Marks a user as typing.
  void setTyping(String userId, String userName) {
    state = {...state, userId: userName};
  }

  /// Clears typing status for a user.
  void clearTyping(String userId) {
    final copy = Map<String, String>.from(state);
    copy.remove(userId);
    state = copy;
  }

  /// Clears all typing users (e.g., on channel switch).
  void clear() => state = {};
}

/// Fetches thread replies for a parent message.
@Riverpod(keepAlive: true)
class ThreadMessages extends _$ThreadMessages {
  static const int _pageSize = 50;
  bool _hasMore = true;

  @override
  Future<List<ChannelMessage>> build(
    String channelId,
    String parentMessageId,
  ) async {
    _hasMore = true;
    final api = ref.watch(apiServiceProvider);
    if (api == null) return [];
    final raw = await api.getMessageThread(
      channelId,
      parentMessageId,
      limit: _pageSize,
    );
    final messages = raw.map((json) => ChannelMessage.fromJson(json)).toList();
    if (messages.length < _pageSize) {
      _hasMore = false;
    }
    return messages;
  }

  /// Whether more thread replies are available.
  bool hasMore() => _hasMore;

  /// Loads older thread replies.
  Future<void> loadMore() async {
    if (!_hasMore) return;
    final current = state.value ?? [];
    if (current.isEmpty) return;
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final raw = await api.getMessageThread(
      channelId,
      parentMessageId,
      skip: current.length,
      limit: _pageSize,
    );
    final older = raw.map((json) => ChannelMessage.fromJson(json)).toList();
    if (older.length < _pageSize) _hasMore = false;
    if (!ref.mounted) return;
    state = AsyncValue.data([...current, ...older]);
  }

  /// Prepends a new reply to the thread.
  void prependMessage(ChannelMessage message) {
    final current = state.value ?? [];
    if (current.any((m) => m.id == message.id)) return;
    state = AsyncValue.data([message, ...current]);
  }
}

/// Fetches member list for a channel (first page).
@riverpod
Future<Map<String, dynamic>> channelMembers(Ref ref, String channelId) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) {
    return {'users': <dynamic>[], 'total': 0};
  }
  return api.getChannelMembers(channelId);
}

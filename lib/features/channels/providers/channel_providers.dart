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
    final rawChannels = await api.getChannels();
    return rawChannels
        .map((json) => Channel.fromJson(json))
        .toList()
      ..sort((a, b) =>
          (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => build());
  }

  void addChannel(Channel channel) {
    final current = state.value ?? [];
    state = AsyncValue.data([channel, ...current]);
  }

  void removeChannel(String channelId) {
    final current = state.value ?? [];
    state = AsyncValue.data(
      current.where((c) => c.id != channelId).toList(),
    );
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

/// Fetches paginated messages for a channel using cursor-based
/// pagination (the [before] timestamp of the oldest loaded message).
@riverpod
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

  bool get hasMore => _hasMore;

  /// Loads older messages before the oldest currently loaded message.
  Future<void> loadMore() async {
    if (!_hasMore) return;
    final current = state.value ?? [];
    if (current.isEmpty) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;

    final oldest = current.last;
    final before = oldest.createdDateTime;
    final rawMessages = await api.getChannelMessages(
      channelId,
      limit: _pageSize,
      before: before,
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
    state = AsyncValue.data(
      current.where((m) => m.id != messageId).toList(),
    );
  }
}

/// Fetches member list for a channel.
@riverpod
Future<List<Map<String, dynamic>>> channelMembers(
  Ref ref,
  String channelId,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return [];
  return api.getChannelMembers(channelId);
}

/// Fetches unread count for a channel.
@riverpod
Future<int> channelUnreadCount(
  Ref ref,
  String channelId,
) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return 0;
  final result = await api.getChannelUnreadCount(channelId);
  return (result['count'] as int?) ?? 0;
}

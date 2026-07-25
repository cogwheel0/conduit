import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/models/channel.dart';
import '../../../core/models/channel_message.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/api_service.dart';
import '../../auth/providers/unified_auth_providers.dart';

part 'channel_providers.g.dart';

/// Fetches and manages the list of all channels.
@Riverpod(keepAlive: true)
class ChannelsList extends _$ChannelsList {
  int _requestGeneration = 0;
  int _requestsInFlight = 0;
  bool _refreshAfterMutation = false;

  @override
  Future<List<Channel>> build() async {
    final api = ref.watch(apiServiceProvider);
    final token = ref.watch(authTokenProvider3);
    final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
    if (api == null) return [];
    final generation = _beginRequest();
    try {
      return await _fetch(api, token, authSessionEpoch, generation);
    } finally {
      _finishRequest(generation);
    }
  }

  int _beginRequest() {
    _refreshAfterMutation = false;
    _requestsInFlight += 1;
    return ++_requestGeneration;
  }

  void _finishRequest(int generation) {
    _requestsInFlight -= 1;
    if (!ref.mounted ||
        !_refreshAfterMutation ||
        generation == _requestGeneration ||
        _requestsInFlight != 0) {
      return;
    }
    _refreshAfterMutation = false;
    unawaited(Future<void>.microtask(ref.invalidateSelf));
  }

  void _invalidatePendingRequestForMutation() {
    if (_requestsInFlight == 0) return;
    _requestGeneration += 1;
    _refreshAfterMutation = true;
  }

  Future<List<Channel>> _fetch(
    ApiService api,
    String? token,
    Object authSessionEpoch,
    int generation,
  ) async {
    final (rawChannels, featureEnabled) = await api.getChannels();
    if (!ref.mounted ||
        generation != _requestGeneration ||
        !identical(ref.read(apiServiceProvider), api) ||
        ref.read(authTokenProvider3) != token ||
        !identical(
          ref.read(openWebUiAuthSessionEpochProvider),
          authSessionEpoch,
        )) {
      return state.value ?? const <Channel>[];
    }
    ref
        .read(channelsFeatureEnabledProvider.notifier)
        .setEnabled(featureEnabled);
    return rawChannels.map((json) => Channel.fromJson(json)).toList()
      ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
  }

  Future<void> refresh() async {
    final api = ref.read(apiServiceProvider);
    final token = ref.read(authTokenProvider3);
    final authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    if (api == null) {
      _requestGeneration += 1;
      state = const AsyncValue.data(<Channel>[]);
      return;
    }
    final generation = _beginRequest();
    // Preserve the current list while refreshing so socket/local mutations can
    // still be applied. Any such mutation invalidates this request below.
    if (state.value == null) {
      state = const AsyncValue.loading();
    }
    try {
      final result = await AsyncValue.guard(
        () => _fetch(api, token, authSessionEpoch, generation),
      );
      if (!ref.mounted || generation != _requestGeneration) return;
      state = result;
    } finally {
      _finishRequest(generation);
    }
  }

  void addChannel(Channel channel) {
    final current = state.value ?? [];
    _invalidatePendingRequestForMutation();
    state = AsyncValue.data([
      channel,
      ...current.where((item) => item.id != channel.id),
    ]);
  }

  void removeChannel(String channelId) {
    final current = state.value ?? [];
    if (!current.any((channel) => channel.id == channelId)) return;
    _invalidatePendingRequestForMutation();
    state = AsyncValue.data(current.where((c) => c.id != channelId).toList());
  }

  void updateChannel(Channel updated) {
    final current = state.value ?? [];
    final index = current.indexWhere((channel) => channel.id == updated.id);
    if (index < 0 || current[index] == updated) return;
    _invalidatePendingRequestForMutation();
    final next = List<Channel>.of(current);
    next[index] = updated;
    state = AsyncValue.data(next);
  }

  /// Clears the unread badge for [channelId] when the user opens it
  /// (reset-on-visit), pairing with the server-side `emitLastReadAt`. No-ops if
  /// the channel is unknown or already read so it never triggers a rebuild
  /// without a real change.
  void markRead(String channelId) {
    final current = state.value;
    if (current == null) return;
    var changed = false;
    final updated = current.map((c) {
      if (c.id == channelId && c.unreadCount != 0) {
        changed = true;
        return c.copyWith(unreadCount: 0);
      }
      return c;
    }).toList();
    if (changed) {
      _invalidatePendingRequestForMutation();
      state = AsyncValue.data(updated);
    }
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
  bool _loadMoreInFlight = false;
  int _buildRequestsInFlight = 0;
  bool _refreshAfterMutation = false;
  int _requestGeneration = 0;

  @override
  Future<List<ChannelMessage>> build(String channelId) async {
    _hasMore = true;
    _loadMoreInFlight = false;
    _refreshAfterMutation = false;
    _buildRequestsInFlight += 1;
    final generation = ++_requestGeneration;
    final api = ref.watch(apiServiceProvider);
    final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
    if (api == null) {
      _buildRequestsInFlight -= 1;
      return [];
    }
    try {
      final rawMessages = await api.getChannelMessages(
        channelId,
        limit: _pageSize,
      );
      if (!_ownsRequest(api, authSessionEpoch, generation)) {
        return state.value ?? const <ChannelMessage>[];
      }
      final messages = rawMessages
          .map((json) => ChannelMessage.fromJson(json))
          .toList();
      if (messages.length < _pageSize) _hasMore = false;
      return messages;
    } finally {
      _buildRequestsInFlight -= 1;
      _scheduleReplacementFetchIfNeeded(generation);
    }
  }

  void _invalidatePendingFetchForMutation({bool includePagination = false}) {
    if (_buildRequestsInFlight == 0 &&
        (!includePagination || !_loadMoreInFlight)) {
      return;
    }
    _requestGeneration += 1;
    _refreshAfterMutation = true;
    if (includePagination) {
      _loadMoreInFlight = false;
    }
  }

  void _scheduleReplacementFetchIfNeeded(int generation) {
    if (!ref.mounted ||
        !_refreshAfterMutation ||
        generation == _requestGeneration ||
        _buildRequestsInFlight != 0 ||
        _loadMoreInFlight) {
      return;
    }
    _refreshAfterMutation = false;
    unawaited(Future<void>.microtask(ref.invalidateSelf));
  }

  bool hasMore() => _hasMore;

  bool _ownsRequest(Object api, Object authSessionEpoch, int generation) =>
      ref.mounted &&
      generation == _requestGeneration &&
      identical(ref.read(apiServiceProvider), api) &&
      identical(ref.read(openWebUiAuthSessionEpochProvider), authSessionEpoch);

  /// Loads older messages using skip/limit pagination.
  Future<void> loadMore() async {
    if (!_hasMore || _loadMoreInFlight) return;
    final current = state.value ?? [];
    if (current.isEmpty) return;

    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    final generation = _requestGeneration;
    _loadMoreInFlight = true;

    try {
      final rawMessages = await api.getChannelMessages(
        channelId,
        skip: current.length,
        limit: _pageSize,
      );
      if (!_ownsRequest(api, authSessionEpoch, generation)) return;
      final older = rawMessages
          .map((json) => ChannelMessage.fromJson(json))
          .toList();
      if (older.length < _pageSize) _hasMore = false;
      final latest = state.value ?? const <ChannelMessage>[];
      state = AsyncValue.data(_appendUniqueOlder(latest, older));
    } finally {
      if (generation == _requestGeneration) {
        _loadMoreInFlight = false;
      }
      _scheduleReplacementFetchIfNeeded(generation);
    }
  }

  /// Adds a new message (from send or socket event).
  ///
  /// Deduplicates by ID to prevent double-insertion when the
  /// local send response and the socket event both arrive. Keeps
  /// the list newest-first so async socket hydration cannot reorder
  /// delayed attachment messages ahead of newer messages.
  void prependMessage(ChannelMessage message) {
    final current = state.value ?? [];
    if (current.any((m) => m.id == message.id)) return;
    _invalidatePendingFetchForMutation();
    state = AsyncValue.data(_insertNewestFirst(current, message));
  }

  /// Updates a message in the list (edit, reaction change).
  void updateMessage(ChannelMessage updated) {
    final current = state.value ?? [];
    final index = current.indexWhere((message) => message.id == updated.id);
    if (index < 0 || current[index] == updated) return;
    _invalidatePendingFetchForMutation();
    final next = List<ChannelMessage>.of(current);
    next[index] = updated;
    state = AsyncValue.data(next);
  }

  /// Removes a message from the list.
  void removeMessage(String messageId) {
    final current = state.value ?? [];
    if (!current.any((message) => message.id == messageId)) return;
    _invalidatePendingFetchForMutation(includePagination: true);
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
  bool _loadMoreInFlight = false;
  int _buildRequestsInFlight = 0;
  bool _refreshAfterMutation = false;
  int _requestGeneration = 0;

  @override
  Future<List<ChannelMessage>> build(
    String channelId,
    String parentMessageId,
  ) async {
    _hasMore = true;
    _loadMoreInFlight = false;
    _refreshAfterMutation = false;
    _buildRequestsInFlight += 1;
    final generation = ++_requestGeneration;
    final api = ref.watch(apiServiceProvider);
    final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
    if (api == null) {
      _buildRequestsInFlight -= 1;
      return [];
    }
    try {
      final raw = await api.getMessageThread(
        channelId,
        parentMessageId,
        limit: _pageSize,
      );
      if (!_ownsRequest(api, authSessionEpoch, generation)) {
        return state.value ?? const <ChannelMessage>[];
      }
      final messages = raw
          .map((json) => ChannelMessage.fromJson(json))
          .toList();
      if (messages.length < _pageSize) {
        _hasMore = false;
      }
      return messages;
    } finally {
      _buildRequestsInFlight -= 1;
      _scheduleReplacementFetchIfNeeded(generation);
    }
  }

  void _invalidatePendingFetchForMutation() {
    if (_buildRequestsInFlight == 0) return;
    _requestGeneration += 1;
    _refreshAfterMutation = true;
  }

  void _scheduleReplacementFetchIfNeeded(int generation) {
    if (!ref.mounted ||
        !_refreshAfterMutation ||
        generation == _requestGeneration ||
        _buildRequestsInFlight != 0 ||
        _loadMoreInFlight) {
      return;
    }
    _refreshAfterMutation = false;
    unawaited(Future<void>.microtask(ref.invalidateSelf));
  }

  /// Whether more thread replies are available.
  bool hasMore() => _hasMore;

  bool _ownsRequest(Object api, Object authSessionEpoch, int generation) =>
      ref.mounted &&
      generation == _requestGeneration &&
      identical(ref.read(apiServiceProvider), api) &&
      identical(ref.read(openWebUiAuthSessionEpochProvider), authSessionEpoch);

  /// Loads older thread replies.
  Future<void> loadMore() async {
    if (!_hasMore || _loadMoreInFlight) return;
    final current = state.value ?? [];
    if (current.isEmpty) return;
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    final generation = _requestGeneration;
    _loadMoreInFlight = true;
    try {
      final raw = await api.getMessageThread(
        channelId,
        parentMessageId,
        skip: current.length,
        limit: _pageSize,
      );
      if (!_ownsRequest(api, authSessionEpoch, generation)) return;
      final older = raw.map((json) => ChannelMessage.fromJson(json)).toList();
      if (older.length < _pageSize) _hasMore = false;
      final latest = state.value ?? const <ChannelMessage>[];
      state = AsyncValue.data(_appendUniqueOlder(latest, older));
    } finally {
      if (generation == _requestGeneration) {
        _loadMoreInFlight = false;
      }
      _scheduleReplacementFetchIfNeeded(generation);
    }
  }

  /// Prepends a new reply to the thread.
  void prependMessage(ChannelMessage message) {
    final current = state.value ?? [];
    if (current.any((m) => m.id == message.id)) return;
    _invalidatePendingFetchForMutation();
    state = AsyncValue.data(_insertNewestFirst(current, message));
  }
}

List<ChannelMessage> _insertNewestFirst(
  List<ChannelMessage> messages,
  ChannelMessage message,
) {
  final insertIndex = _newestFirstInsertIndex(messages, message);
  return [
    ...messages.take(insertIndex),
    message,
    ...messages.skip(insertIndex),
  ];
}

List<ChannelMessage> _appendUniqueOlder(
  List<ChannelMessage> current,
  List<ChannelMessage> older,
) {
  final seen = <String>{for (final message in current) message.id};
  return <ChannelMessage>[
    ...current,
    for (final message in older)
      if (seen.add(message.id)) message,
  ];
}

int _newestFirstInsertIndex(
  List<ChannelMessage> messages,
  ChannelMessage message,
) {
  final createdAt = message.createdAt;
  if (createdAt == null) {
    return 0;
  }

  for (var index = 0; index < messages.length; index++) {
    final existingCreatedAt = messages[index].createdAt;
    if (existingCreatedAt == null) {
      continue;
    }
    if (existingCreatedAt < createdAt) {
      return index;
    }
  }
  return messages.length;
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

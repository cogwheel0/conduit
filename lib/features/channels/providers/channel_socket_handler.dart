import 'dart:async';
import 'dart:developer' as developer;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/models/channel_message.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/socket_service.dart';
import 'channel_providers.dart';

part 'channel_socket_handler.g.dart';

/// Manages socket event subscriptions for real-time channel updates.
///
/// Call [subscribe] when entering a channel view and [unsubscribe]
/// when leaving. Incoming events are dispatched to the appropriate
/// [ChannelMessages] notifier.
@Riverpod(keepAlive: true)
class ChannelSocketHandler extends _$ChannelSocketHandler {
  String? _activeChannelId;
  SocketEventSubscription? _subscription;
  SocketService? _subscriptionSocket;
  Object? _subscriptionAuthSessionEpoch;
  final Map<String, Timer> _typingTimers = {};
  int _subscriptionGeneration = 0;

  @override
  void build() {
    final socket = ref.watch(socketServiceProvider);
    final authSessionEpoch = ref.watch(openWebUiAuthSessionEpochProvider);
    final activeChannelId = _activeChannelId;
    final replacingOwner = _subscriptionSocket != null;
    _disposeSubscription(clearActiveChannel: false);
    if (activeChannelId != null && socket != null) {
      _bindSubscription(activeChannelId, socket, authSessionEpoch);
    }
    if (replacingOwner) {
      Future<void>.microtask(() {
        if (ref.mounted) {
          ref.read(channelTypingUsersProvider.notifier).clear();
        }
      });
    }
    ref.onDispose(() {
      _disposeSubscription(clearActiveChannel: false);
    });
  }

  /// Subscribes to socket events for the given [channelId].
  ///
  /// Any previous subscription is cleaned up before registering the new one.
  void subscribe(String channelId) {
    unsubscribe();
    _activeChannelId = channelId;

    final socket = ref.read(socketServiceProvider);
    if (socket == null) return;
    _bindSubscription(
      channelId,
      socket,
      ref.read(openWebUiAuthSessionEpochProvider),
    );
  }

  void _bindSubscription(
    String channelId,
    SocketService socket,
    Object authSessionEpoch,
  ) {
    final generation = _subscriptionGeneration;
    _subscriptionSocket = socket;
    _subscriptionAuthSessionEpoch = authSessionEpoch;

    _subscription = socket.addChannelEventHandler(
      conversationId: channelId,
      requireFocus: false,
      handler: (event, ack) {
        _handleEvent(event, generation);
      },
    );

    developer.log(
      'Subscribed to channel events: $channelId',
      name: 'channel_socket',
    );
  }

  /// Unsubscribes from the current channel's socket events.
  void unsubscribe() {
    _disposeSubscription(clearActiveChannel: true);
    ref.read(channelTypingUsersProvider.notifier).clear();
  }

  void _disposeSubscription({required bool clearActiveChannel}) {
    _subscriptionGeneration += 1;
    _subscription?.dispose();
    _subscription = null;
    _subscriptionSocket = null;
    _subscriptionAuthSessionEpoch = null;
    if (clearActiveChannel) {
      _activeChannelId = null;
    }

    // Clear typing indicators.
    for (final timer in _typingTimers.values) {
      timer.cancel();
    }
    _typingTimers.clear();
  }

  /// Emits a read-status update to the server via socket.
  void emitLastReadAt(String channelId) {
    final socket = ref.read(socketServiceProvider);
    if (socket == null) return;
    socket.emit('events:channel', {
      'channel_id': channelId,
      'data': {'type': 'last_read_at'},
    });
  }

  /// Emits a typing indicator to the server.
  void emitTyping(String channelId, {bool typing = true}) {
    final socket = ref.read(socketServiceProvider);
    if (socket == null) return;
    socket.emit('events:channel', {
      'channel_id': channelId,
      'data': {'type': 'typing', 'typing': typing},
    });
  }

  // -- Private helpers ------------------------------------------------

  bool _ownsSubscription(String channelId, int generation) {
    final socket = _subscriptionSocket;
    final authSessionEpoch = _subscriptionAuthSessionEpoch;
    return ref.mounted &&
        generation == _subscriptionGeneration &&
        _activeChannelId == channelId &&
        socket != null &&
        authSessionEpoch != null &&
        identical(ref.read(socketServiceProvider), socket) &&
        identical(
          ref.read(openWebUiAuthSessionEpochProvider),
          authSessionEpoch,
        );
  }

  /// Handles an incoming channel socket event.
  ///
  /// OpenWebUI wraps the payload in a nested envelope:
  /// ```json
  /// {
  ///   "channel_id": "...",
  ///   "data": {
  ///     "type": "message",
  ///     "data": { ...message fields... }
  ///   }
  /// }
  /// ```
  void _handleEvent(Map<String, dynamic> event, int generation) {
    final channelId = _activeChannelId;
    if (channelId == null || !_ownsSubscription(channelId, generation)) return;

    try {
      final envelope = event['data'];
      if (envelope is! Map<String, dynamic>) {
        developer.log(
          'Missing data envelope in channel event',
          name: 'channel_socket',
        );
        return;
      }

      final type = envelope['type'] as String?;
      final data = envelope['data'];
      final notifier = ref.read(channelMessagesProvider(channelId).notifier);

      switch (type) {
        case 'message':
          if (data is Map<String, dynamic>) {
            unawaited(_prependHydratedMessage(channelId, data, generation));
          }
        case 'message:update':
          if (data is Map<String, dynamic>) {
            unawaited(_updateHydratedMessage(channelId, data, generation));
          }
        case 'message:delete':
          final messageId = data is Map
              ? data['id'] as String?
              : data as String?;
          if (messageId != null) {
            notifier.removeMessage(messageId);
          }
        case 'message:reply':
          if (data is Map<String, dynamic>) {
            final parentId = data['parent_id'] as String?;
            if (parentId != null) {
              unawaited(_refreshMessage(channelId, parentId, generation));
            }
          }
        case 'message:reaction:add' || 'message:reaction:remove':
          final messageId = data is Map
              ? data['message_id'] as String? ?? data['id'] as String?
              : null;
          if (messageId != null) {
            unawaited(_refreshMessage(channelId, messageId, generation));
          }
        case 'channel:delete':
          ref.read(channelsListProvider.notifier).removeChannel(channelId);
        case 'typing':
          _handleTyping(event, channelId, generation);
        default:
          developer.log(
            'Unhandled channel event: $type',
            name: 'channel_socket',
          );
      }
    } catch (e, st) {
      developer.log(
        'Error handling channel event',
        name: 'channel_socket',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _prependHydratedMessage(
    String channelId,
    Map<String, dynamic> data,
    int generation,
  ) async {
    try {
      final message = await _parseHydratedMessage(channelId, data, generation);
      if (message == null || !_ownsSubscription(channelId, generation)) {
        return;
      }
      ref
          .read(channelMessagesProvider(channelId).notifier)
          .prependMessage(message);
    } catch (e, st) {
      _logHydratedMessageError('prepend', channelId, data, e, st);
    }
  }

  Future<void> _updateHydratedMessage(
    String channelId,
    Map<String, dynamic> data,
    int generation,
  ) async {
    try {
      final message = await _parseHydratedMessage(channelId, data, generation);
      if (message == null || !_ownsSubscription(channelId, generation)) {
        return;
      }
      ref
          .read(channelMessagesProvider(channelId).notifier)
          .updateMessage(message);
    } catch (e, st) {
      _logHydratedMessageError('update', channelId, data, e, st);
    }
  }

  Future<ChannelMessage?> _parseHydratedMessage(
    String channelId,
    Map<String, dynamic> data,
    int generation,
  ) async {
    var messageJson = data;
    if (data['data'] == true) {
      final messageId = data['id'];
      if (messageId is String && messageId.isNotEmpty) {
        try {
          final api = ref.read(apiServiceProvider);
          final hydratedData = await api?.getMessageData(channelId, messageId);
          if (!_ownsSubscription(channelId, generation) ||
              !identical(ref.read(apiServiceProvider), api)) {
            return null;
          }
          if (hydratedData != null) {
            messageJson = {...data, 'data': hydratedData};
          }
        } catch (e, st) {
          developer.log(
            'Failed to hydrate socket message data $messageId',
            name: 'channel_socket',
            error: e,
            stackTrace: st,
          );
        }
      }
    }

    return ChannelMessage.fromJson(messageJson);
  }

  void _logHydratedMessageError(
    String action,
    String channelId,
    Map<String, dynamic> data,
    Object error,
    StackTrace stackTrace,
  ) {
    developer.log(
      'Failed to $action socket channel message '
      '${data['id']} in channel $channelId',
      name: 'channel_socket',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Fetches a single message from the API and updates
  /// the local message list.
  Future<void> _refreshMessage(
    String channelId,
    String messageId,
    int generation,
  ) async {
    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;

      final json = await api.getChannelMessage(channelId, messageId);
      if (json == null ||
          !_ownsSubscription(channelId, generation) ||
          !identical(ref.read(apiServiceProvider), api)) {
        return;
      }

      final message = ChannelMessage.fromJson(json);
      ref
          .read(channelMessagesProvider(channelId).notifier)
          .updateMessage(message);
    } catch (e, st) {
      developer.log(
        'Failed to refresh message $messageId',
        name: 'channel_socket',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Handles a typing indicator event.
  ///
  /// Adds the user to [ChannelTypingUsers] and sets a
  /// 5-second auto-clear timer. Ignores events from the
  /// current user.
  void _handleTyping(
    Map<String, dynamic> event,
    String channelId,
    int generation,
  ) {
    final userData = event['user'];
    if (userData is! Map<String, dynamic>) return;

    final userId = userData['id'] as String?;
    final userName = userData['name'] as String? ?? '';
    if (userId == null) return;

    // Don't show typing for self.
    final currentUserId = ref.read(currentUserProvider).value?.id;
    if (userId == currentUserId) return;

    final envelope = event['data'];
    final isTyping = envelope is Map && envelope['typing'] == true;

    final typingNotifier = ref.read(channelTypingUsersProvider.notifier);

    if (isTyping) {
      typingNotifier.setTyping(userId, userName);
      _typingTimers[userId]?.cancel();
      _typingTimers[userId] = Timer(const Duration(seconds: 5), () {
        _typingTimers.remove(userId);
        if (!_ownsSubscription(channelId, generation)) return;
        typingNotifier.clearTyping(userId);
      });
    } else {
      typingNotifier.clearTyping(userId);
      _typingTimers[userId]?.cancel();
      _typingTimers.remove(userId);
    }
  }
}

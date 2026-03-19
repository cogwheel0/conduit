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

  @override
  void build() {
    ref.onDispose(() {
      unsubscribe();
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

    _subscription = socket.addChannelEventHandler(
      conversationId: channelId,
      requireFocus: false,
      handler: (event, ack) {
        _handleEvent(event);
      },
    );

    developer.log(
      'Subscribed to channel events: $channelId',
      name: 'channel_socket',
    );
  }

  /// Unsubscribes from the current channel's socket events.
  void unsubscribe() {
    _subscription?.dispose();
    _subscription = null;
    _activeChannelId = null;
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
  void emitTyping(
    String channelId, {
    bool typing = true,
  }) {
    final socket = ref.read(socketServiceProvider);
    if (socket == null) return;
    socket.emit('events:channel', {
      'channel_id': channelId,
      'data': {
        'type': 'typing',
        'typing': typing,
      },
    });
  }

  // -- Private helpers ------------------------------------------------

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
  void _handleEvent(Map<String, dynamic> event) {
    if (_activeChannelId == null) return;

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
      final notifier = ref.read(
        channelMessagesProvider(_activeChannelId!)
            .notifier,
      );

      switch (type) {
        case 'message':
          if (data is Map<String, dynamic>) {
            final message =
                ChannelMessage.fromJson(data);
            notifier.prependMessage(message);
          }
        case 'message:update':
          if (data is Map<String, dynamic>) {
            final message =
                ChannelMessage.fromJson(data);
            notifier.updateMessage(message);
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
            final parentId =
                data['parent_id'] as String?;
            if (parentId != null) {
              _refreshMessage(
                _activeChannelId!,
                parentId,
              );
            }
          }
        case 'message:reaction:add' ||
              'message:reaction:remove':
          final messageId = data is Map
              ? data['message_id'] as String? ??
                  data['id'] as String?
              : null;
          if (messageId != null) {
            _refreshMessage(
              _activeChannelId!,
              messageId,
            );
          }
        case 'channel:delete':
          ref
              .read(channelsListProvider.notifier)
              .removeChannel(_activeChannelId!);
        case 'typing':
          _handleTyping(event);
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

  /// Fetches a single message from the API and updates
  /// the local message list.
  Future<void> _refreshMessage(
    String channelId,
    String messageId,
  ) async {
    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) return;

      final json = await api.getChannelMessage(
        channelId,
        messageId,
      );
      if (json == null || !ref.mounted) return;

      final message = ChannelMessage.fromJson(json);
      ref
          .read(
            channelMessagesProvider(channelId)
                .notifier,
          )
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
  /// Will be connected to a ChannelTypingUsers
  /// provider in Task 11.
  void _handleTyping(Map<String, dynamic> event) {
    final userData = event['user'];
    if (userData is Map<String, dynamic>) {
      developer.log(
        'Typing: ${userData['name']}',
        name: 'channel_socket',
      );
    }
  }
}

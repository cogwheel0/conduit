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

  void _handleEvent(Map<String, dynamic> event) {
    if (_activeChannelId == null) return;

    try {
      final type = event['type'] as String?;
      final data = event['data'];

      switch (type) {
        case 'message':
          if (data is Map<String, dynamic>) {
            final message = ChannelMessage.fromJson(data);
            ref
                .read(
                  channelMessagesProvider(_activeChannelId!).notifier,
                )
                .prependMessage(message);
          }
        case 'message:update':
          if (data is Map<String, dynamic>) {
            final message = ChannelMessage.fromJson(data);
            ref
                .read(
                  channelMessagesProvider(_activeChannelId!).notifier,
                )
                .updateMessage(message);
          }
        case 'message:delete':
          final messageId = data is Map
              ? data['id'] as String?
              : data as String?;
          if (messageId != null) {
            ref
                .read(
                  channelMessagesProvider(_activeChannelId!).notifier,
                )
                .removeMessage(messageId);
          }
        case 'channel:delete':
          ref
              .read(channelsListProvider.notifier)
              .removeChannel(_activeChannelId!);
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
}

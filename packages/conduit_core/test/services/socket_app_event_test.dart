// Open WebUI sends a channel app's private reply to the asking user's sessions
// only (routers/channels.py, app_channel_reply_handler), not on the channel
// streams: as `events:app` up to 0.13.3, and as a `channel:app` event on
// `events` from 0.13.4.
import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:test/test.dart';

const _reply = <String, dynamic>{
  'app_id': 'app-1',
  'app_name': 'Deploy Bot',
  'channel_id': 'c1',
  'message_id': 'm1',
  'parent_id': null,
  'reply': {'type': 'error', 'content': 'App is inactive'},
};

void main() {
  for (final (sent, event, payload) in <(String, String, Object)>[
    ('events:app', 'events:app', _reply),
    (
      'channel:app on events',
      'events',
      <String, dynamic>{
        'data': <String, dynamic>{'type': 'channel:app', 'data': _reply},
      },
    ),
  ]) {
    test('an app reply sent as $sent reaches app handlers, and only '
        'them', () async {
      final sockets = <io.Socket>[];
      final service = SocketService(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        socketFactory: (base, builder, config) {
          final socket = io.io('http://localhost:19500', <String, dynamic>{
            'autoConnect': false,
            'forceNew': true,
            'reconnection': false,
          });
          sockets.add(socket);
          return socket;
        },
      );
      addTearDown(service.dispose);

      final appEvents = <Map<String, dynamic>>[];
      final chatEvents = <Map<String, dynamic>>[];
      final channelEvents = <Map<String, dynamic>>[];
      final subscription = service.addAppEventHandler(appEvents.add);
      service
        ..addChatEventHandler(
          requireFocus: false,
          handler: (event, _) => chatEvents.add(event),
        )
        ..addChannelEventHandler(
          requireFocus: false,
          handler: (event, _) => channelEvents.add(event),
        );
      await service.connect();

      sockets.single.emitReserved(event, payload);

      check(appEvents).length.equals(1);
      check(appEvents.single['message_id']).equals('m1');
      check(chatEvents).isEmpty();
      check(channelEvents).isEmpty();

      subscription.dispose();
      sockets.single.emitReserved(event, payload);
      check(appEvents).length.equals(1);
    });
  }
}

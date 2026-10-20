// Open WebUI 0.12.1 sends a private app reply as `events:app` to the asking
// user's sessions (routers/channels.py, app_channel_reply_handler), not on the
// channel streams.
import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('events:app reaches app handlers, and only them', () async {
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
    final channelEvents = <Map<String, dynamic>>[];
    final subscription = service.addAppEventHandler(appEvents.add);
    service.addChannelEventHandler(
      requireFocus: false,
      handler: (event, _) => channelEvents.add(event),
    );
    await service.connect();

    final payload = <String, dynamic>{
      'app_id': 'app-1',
      'app_name': 'Deploy Bot',
      'channel_id': 'c1',
      'message_id': 'm1',
      'parent_id': null,
      'reply': {'type': 'error', 'content': 'App is inactive'},
    };
    sockets.single.emitReserved('events:app', payload);

    check(appEvents).length.equals(1);
    check(appEvents.single['message_id']).equals('m1');
    check(channelEvents).isEmpty();

    subscription.dispose();
    sockets.single.emitReserved('events:app', payload);
    check(appEvents).length.equals(1);
  });
}

// Opt-in check against an unmodified, disposable Open WebUI installation.
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/features/terminal/services/computer_socket_relay.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Open WebUI proxy: discovery, saved-chat scope, desktop auth and browser tickets',
    () async {
      final config = jsonDecode(
        File(Platform.environment['COMPUTER_WEBUI_REVIEW_CONFIG']!)
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final api = ApiService(
        serverConfig: ServerConfig(
          id: 'synthetic-proxy',
          name: 'Synthetic proxy',
          url: config['url'] as String,
        ),
        authToken: config['token'] as String,
        workerManager: WorkerManager(),
      );
      final terminal = TerminalService(api);
      final server = (await terminal.getAvailableServers()).singleWhere(
        (server) => server.systemServerId == config['server_id'],
      );
      final chat = await api.dio.post<Map<String, dynamic>>(
        '/api/v1/chats/new',
        data: {
          'chat': {
            'title': 'Computer proxy verification',
            'models': <String>[],
            'history': {'messages': <String, dynamic>{}, 'currentId': null},
          },
        },
      );
      final chatId = chat.data!['id'] as String;
      final service = ComputerService(terminal, server, chatId);
      final ownedTabs = <String>[];
      final relays = <ComputerSocketRelay>[];
      try {
        final capabilities = await service.capabilities();
        expect(capabilities.desktop, isTrue);
        expect(capabilities.browser, isTrue);
        final desktop = (await service.open(ComputerSurface.desktop))!;
        expect(desktop.streamUri.query, isEmpty);
        expect(desktop.chatId, chatId);
        final desktopRelay = await ComputerSocketRelay.start(desktop);
        relays.add(desktopRelay);
        final socket = await WebSocket.connect(
          desktopRelay.streamUri.toString(),
          headers: {'Origin': ComputerSocketRelay.viewerOrigin},
        );
        socket.add(
          jsonEncode({
            'type': 'auth',
            'token': desktop.token,
            'chat_id': desktop.chatId,
          }),
        );
        final banner = await socket.first.timeout(const Duration(seconds: 15));
        expect(ascii.decode(banner as List<int>), startsWith('RFB '));
        await socket.close();

        final proxyResponse = await terminal.requestComputer(
          server,
          'browser/sessions',
          sessionScopeId: chatId,
          method: 'POST',
          data: {'url': ''},
        );
        final proxyId = (proxyResponse.data as Map)['id'] as String;
        ownedTabs.add(proxyId);
        final pending = (await service.open(ComputerSurface.browser))!;
        expect(pending.requiresBrowserActivation, isTrue);
        final unchanged = await terminal.requestComputer(
          server,
          'browser/sessions/$proxyId',
          sessionScopeId: chatId,
        );
        expect((unchanged.data as Map)['mode'], 'proxy');
        final activated = await service.selectBrowserTab(proxyId);
        expect(activated.requiresBrowserActivation, isFalse);
        await service.closeBrowserTab(ownedTabs.removeLast());

        // Never-activated tabs tie on active/last_used. Renewing an older
        // watched tab must not win that tie by changing its touched time.
        final watchedResponse = await terminal.requestComputer(
          server,
          'browser/sessions',
          sessionScopeId: chatId,
          method: 'POST',
          data: {'url': ''},
        );
        ownedTabs.add((watchedResponse.data as Map)['id'] as String);
        await terminal.requestComputer(
          server,
          'browser/sessions/${ownedTabs.single}',
          sessionScopeId: chatId,
          method: 'PATCH',
          data: {'mode': 'chrome'},
        );
        final watched = (await service.open(ComputerSurface.browser))!;
        final nextResponse = await terminal.requestComputer(
          server,
          'browser/sessions',
          sessionScopeId: chatId,
          method: 'POST',
          data: {'url': ''},
        );
        ownedTabs.add((nextResponse.data as Map)['id'] as String);
        expect(
          (await service.browserTabs()).singleWhere((tab) => tab.selected).id,
          ownedTabs.last,
        );
        await service.keepAlive(watched);
        expect(
          (await service.browserTabs()).singleWhere((tab) => tab.selected).id,
          ownedTabs.last,
        );
        while (ownedTabs.isNotEmpty) {
          await service.closeBrowserTab(ownedTabs.removeLast());
        }

        for (var i = 0; i < 2; i++) {
          final connection = await service.createBrowserTab();
          ownedTabs.add(connection.browserSession!.id);
          expect(connection.token, isNull);
          expect(connection.streamUri.path, contains('/api/v1/terminals/'));
          expect(
            connection.streamUri.toString(),
            isNot(contains(config['token'])),
          );
        }
        expect(await service.browserTabs(), hasLength(2));
        final browser = await service.selectBrowserTab(ownedTabs.first);
        await service.sendShortcut(browser, 'Ctrl+A');
        final browserRelay = await ComputerSocketRelay.start(browser);
        relays.add(browserRelay);
        final stream = await WebSocket.connect(
          browserRelay.streamUri.toString(),
          headers: {'Origin': ComputerSocketRelay.viewerOrigin},
        );
        stream.add(jsonEncode({'type': 'frames'}));
        final state = await stream
            .firstWhere(
              (frame) =>
                  frame is String &&
                  (jsonDecode(frame) as Map)['type'] == 'state',
            )
            .timeout(const Duration(seconds: 15));
        expect((jsonDecode(state as String) as Map)['transport'], isNotNull);
        await stream.close();
        await service.keepAlive(browser);
        expect(
          (await service.browserTabs()).singleWhere((tab) => tab.selected).id,
          ownedTabs.first,
        );
        await service.closeBrowserTab(ownedTabs.removeLast());
        await service.closeBrowserTab(ownedTabs.removeLast());
        expect(await service.browserTabs(), isEmpty);
        expect(await service.open(ComputerSurface.browser), isNull);
      } finally {
        for (final relay in relays) {
          await relay.close();
        }
        for (final id in ownedTabs) {
          await service.closeBrowserTab(id);
        }
        await api.dio.delete('/api/v1/chats/$chatId');
        api.dio.close(force: true);
      }
    },
    skip: Platform.environment['COMPUTER_WEBUI_REVIEW'] != 'true',
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

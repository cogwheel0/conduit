// Opt-in checks against disposable, synthetic Open Terminal instances only.
import 'dart:io';

import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:test/test.dart';

void main() {
  for (final port in [8766, 18769]) {
    test(
      'real browser on $port: create, switch, shortcut, close and scope isolation',
      () async {
        final url = 'http://127.0.0.1:$port';
        final terminal = TerminalService(
          ApiService(
            serverConfig: ServerConfig(
              id: 'synthetic',
              name: 'Synthetic',
              url: url,
            ),
            authToken: 'computer-review-only',
            workerManager: WorkerManager(),
          ),
        );
        final server = TerminalServerInfo(
          kind: TerminalServerKind.direct,
          selectionId: 'synthetic',
          baseUrl: Uri.parse(url),
          apiKey: 'computer-review-only',
        );
        final scope =
            'tab-integration-${DateTime.now().microsecondsSinceEpoch}';
        final service = ComputerService(terminal, server, scope);
        final owned = <String>[];
        try {
          expect(await service.browserTabs(), isEmpty);
          final first = await service.createBrowserTab();
          owned.add(first.browserSession!.id);
          final second = await service.createBrowserTab();
          owned.add(second.browserSession!.id);
          expect(
            (await service.browserTabs()).singleWhere((tab) => tab.selected).id,
            owned.last,
          );
          final selected = await service.selectBrowserTab(owned.first);
          expect(
            (await service.browserTabs()).singleWhere((tab) => tab.selected).id,
            owned.first,
          );
          await service.sendShortcut(selected, 'Ctrl+A');
          expect((await service.screenshot(selected)).take(4), [
            137,
            80,
            78,
            71,
          ]);
          final unrelated = ComputerService(
            terminal,
            server,
            '$scope-unrelated',
          );
          expect(await unrelated.browserTabs(), isEmpty);
          await expectLater(
            unrelated.selectBrowserTab(owned.first),
            throwsException,
          );
          await expectLater(
            unrelated.closeBrowserTab(owned.first),
            throwsException,
          );
          expect(await service.browserTabs(), hasLength(2));
          await service.closeBrowserTab(owned.removeAt(0));
          expect((await service.browserTabs()).single.id, owned.single);
          await service.closeBrowserTab(owned.removeLast());
          expect(await service.browserTabs(), isEmpty);
        } finally {
          for (final id in owned) {
            await service.closeBrowserTab(id);
          }
        }
      },
      skip: Platform.environment['COMPUTER_REVIEW'] != 'true',
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/mcp_apps_service.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// `mcpApps.*` without an Open WebUI account: what is refused, and what
/// answers that nothing was there. Running an app against a server is
/// the desktop's `--e2e rendering` pass.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late McpAppsService apps;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('mcp-apps-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    apps = McpAppsService(runtime.container, EventBus());
  });

  tearDownAll(() async {
    apps.dispose();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('an app needs an Open WebUI account to open', () async {
    await expectLater(
      apps.open(
        const McpAppOpen(
          chatId: 'chat-1',
          app: McpAppDto(
            serverId: 'harbour',
            toolName: 'show_tides',
            binding: 'b',
          ),
        ),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.unauthenticated,
        ),
      ),
    );
  });

  test('messages, context and close for no app answer that none ran', () async {
    expect(
      (await apps.message(const McpAppMessage(appId: 'gone', payload: '{}')))
          .ok,
      isFalse,
    );
    expect(
      apps.context(const McpAppContext(appId: 'gone', theme: 'dark')).ok,
      isFalse,
    );
    expect(apps.close(const McpAppRef(appId: 'gone')).ok, isFalse);
  });
}

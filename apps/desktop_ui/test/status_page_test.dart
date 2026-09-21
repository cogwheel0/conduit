@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/status_page.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_client.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/shell_bridge.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

const ShellBridge _bridge = ShellBridge(
  rpcPort: 4242,
  token: 'test-token',
  platform: 'linux',
  windowKind: WindowKind.main,
  isElectron: true,
);

const HandshakeResponse _handshake = HandshakeResponse(
  protocolVersion: kConduitProtocolVersion,
  daemonVersion: '9.9.9-test',
  sessionId: 'session-abc',
  capabilities: Capabilities.none,
  paths: DaemonPaths(
    userData: '/home/u/.config/Conduit',
    database: '/home/u/.config/Conduit/db',
    cache: '/home/u/.config/Conduit/cache',
    logs: '/home/u/.config/Conduit/logs',
    staging: '/home/u/.config/Conduit/staging',
  ),
  platform: 'linux',
  needsOnboarding: true,
);

/// Renders [StatusPage] against a fixed connection state, with no socket and
/// no daemon. This is the layer the plan's testing table calls "UI logic
/// without Electron".
Component _scoped(CoreConnection connection) => ProviderScope(
  overrides: [
    shellBridgeProvider.overrideWithValue(_bridge),
    coreConnectionProvider.overrideWith(
      (ref) => Stream<CoreConnection>.value(connection),
    ),
  ],
  child: const StatusPage(),
);

void main() {
  testComponents('shows the connected state with handshake details', (
    tester,
  ) async {
    tester.pumpComponent(
      _scoped(
        const CoreConnection(
          state: CoreConnectionState.connected,
          handshake: _handshake,
        ),
      ),
    );
    // The provider is a stream, so the first frame is still loading.
    await pumpEventQueue();

    expect(find.text(t.desktop.desktopCoreConnected), findsOneComponent);
    expect(find.text('9.9.9-test'), findsOneComponent);
    expect(find.text('session-abc'), findsOneComponent);
  });

  testComponents('names the attempt while reconnecting', (tester) async {
    tester.pumpComponent(
      _scoped(
        const CoreConnection(
          state: CoreConnectionState.reconnecting,
          handshake: _handshake,
          attempt: 3,
        ),
      ),
    );
    await pumpEventQueue();

    expect(
      find.text(t.desktop.desktopCoreReconnecting(attempt: 3)),
      findsOneComponent,
    );
  });

  testComponents('tells a version mismatch apart from a dead daemon', (
    tester,
  ) async {
    // These need different copy: one is "wait", the other is "reinstall".
    tester.pumpComponent(
      _scoped(
        const CoreConnection(
          state: CoreConnectionState.failed,
          error: RpcError(code: ConduitErrorCodes.protocolVersionMismatch),
          attempt: 1,
        ),
      ),
    );
    await pumpEventQueue();
    expect(
      find.text(t.desktop.desktopCoreVersionMismatch),
      findsOneComponent,
    );
  });

  testComponents('falls back to the generic failure copy', (tester) async {
    tester.pumpComponent(
      _scoped(
        const CoreConnection(
          state: CoreConnectionState.failed,
          error: RpcError(code: ConduitErrorCodes.daemonUnavailable),
          attempt: 8,
        ),
      ),
    );
    await pumpEventQueue();
    expect(find.text(t.desktop.desktopCoreUnavailable), findsOneComponent);
  });
}

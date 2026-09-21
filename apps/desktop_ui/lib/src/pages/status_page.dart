import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/rpc_client.dart';
import '../rpc/rpc_providers.dart';

/// The M0 "connected to core" screen.
///
/// Deliberately plain: its job is to prove the whole chain works end to end —
/// Electron spawned the daemon, the preload bridge handed over a port and a
/// token, the socket passed the origin and token checks, and the handshake
/// agreed on a protocol version. Every later milestone replaces a piece of
/// this page with the real thing.
class StatusPage extends StatelessComponent {
  const StatusPage({super.key});

  @override
  Component build(BuildContext context) {
    final connection = context.watch(coreConnectionProvider);
    final bridge = context.read(shellBridgeProvider);

    return div(
      classes: 'mx-auto flex min-h-screen max-w-2xl flex-col justify-center '
          'gap-6 px-8 text-foreground',
      [
        h1(classes: 'text-2xl font-semibold', [Component.text('Conduit Desktop')]),
        connection.when(
          loading: () => _statusCard(
            tone: 'muted',
            title: t.desktop.desktopCoreConnecting,
            detail: 'Waiting for conduitd to accept a connection.',
          ),
          error: (error, _) => _statusCard(
            tone: 'destructive',
            title: 'Could not reach the core',
            detail: '$error',
          ),
          data: (state) => _connectionCard(state),
        ),
        _detailRow('Window', bridge.windowKind.name),
        _detailRow('Shell', bridge.isElectron ? 'Electron' : 'dev browser'),
        _detailRow('RPC', bridge.rpcUri.toString()),
      ],
    );
  }

  Component _connectionCard(CoreConnection state) => switch (state.state) {
    CoreConnectionState.connecting => _statusCard(
      tone: 'muted',
      title: t.desktop.desktopCoreConnecting,
      detail: 'Opening the loopback channel.',
    ),
    CoreConnectionState.reconnecting => _statusCard(
      tone: 'warning',
      title: t.desktop.desktopCoreReconnecting(attempt: state.attempt),
      detail: 'Your work is safe; the daemon keeps running with the window '
          'closed.',
    ),
    CoreConnectionState.failed => _statusCard(
      tone: 'destructive',
      // The daemon has no locale, so it sends a code and the UI resolves it.
      // This is the pattern every RpcError follows (WP-1.6).
      title:
          state.error?.code == ConduitErrorCodes.protocolVersionMismatch
          ? t.desktop.desktopCoreVersionMismatch
          : t.desktop.desktopCoreUnavailable,
      detail: state.error?.code ?? ConduitErrorCodes.daemonUnavailable,
    ),
    CoreConnectionState.connected => _connectedCard(state),
  };

  Component _connectedCard(CoreConnection state) {
    final handshake = state.handshake!;
    return div(
      classes: 'rounded-[--radius] border border-border bg-card p-6',
      [
        div(classes: 'flex items-center gap-2', [
          span(
            classes: 'inline-block size-2 rounded-full bg-success',
            const [],
          ),
          span(classes: 'font-medium text-card-foreground', [
            Component.text(t.desktop.desktopCoreConnected),
          ]),
        ]),
        dl(classes: 'mt-4 grid grid-cols-2 gap-y-1 text-sm', [
          ..._definition('Protocol', handshake.protocolVersion),
          ..._definition('Daemon', handshake.daemonVersion),
          ..._definition('Platform', handshake.platform),
          ..._definition('Session', handshake.sessionId),
          ..._definition('User data', handshake.paths.userData),
          ..._definition(
            'Capabilities',
            _describeCapabilities(handshake.capabilities),
          ),
        ]),
      ],
    );
  }

  /// M0 reports no capabilities at all; saying so plainly is more useful than
  /// an empty row that reads like a bug.
  String _describeCapabilities(Capabilities capabilities) =>
      capabilities == Capabilities.none
      ? 'none yet — a server is configured in M2'
      : 'reported by the daemon';

  List<Component> _definition(String term, String value) => <Component>[
    dt(classes: 'text-muted-foreground', [Component.text(term)]),
    dd(classes: 'truncate font-mono text-card-foreground', [Component.text(value)]),
  ];

  Component _detailRow(String label, String value) => div(
    classes: 'flex justify-between text-sm text-muted-foreground',
    [span([Component.text(label)]), span(classes: 'font-mono', [Component.text(value)])],
  );

  Component _statusCard({
    required String tone,
    required String title,
    required String detail,
  }) => div(
    classes: 'rounded-[--radius] border border-border bg-card p-6',
    [
      div(classes: 'font-medium text-$tone', [Component.text(title)]),
      p(classes: 'mt-2 text-sm text-muted-foreground', [Component.text(detail)]),
    ],
  );
}

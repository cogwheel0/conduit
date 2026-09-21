import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../shell_bridge.dart';
import 'rpc_client.dart';

/// The preload bridge, overridden at the root scope in `main.dart`.
///
/// Declared without a default so a component that reads it outside the scope
/// fails loudly at startup instead of silently talking to nothing.
final shellBridgeProvider = Provider<ShellBridge>(
  (ref) => throw UnimplementedError(
    'shellBridgeProvider must be overridden in the root ProviderScope',
  ),
);

/// The live connection to `conduitd`.
final rpcClientProvider = Provider<RpcClient>((ref) {
  final client = RpcClient(
    bridge: ref.watch(shellBridgeProvider),
    clientVersion: kDesktopUiVersion,
  );
  ref.onDispose(client.dispose);
  return client;
});

/// Connection state for banners and route guards.
///
/// Seeded with the client's current value so a component mounted mid-stream
/// renders the real state on its first frame rather than a spurious
/// "connecting".
final coreConnectionProvider = StreamProvider<CoreConnection>((ref) {
  final client = ref.watch(rpcClientProvider);
  return client.connection;
});

/// Convenience view of the capabilities the daemon reported.
final capabilitiesProvider = Provider<Capabilities>((ref) {
  return ref
      .watch(coreConnectionProvider)
      .maybeWhen(
        data: (connection) => connection.capabilities,
        orElse: () => Capabilities.none,
      );
});

/// Kept in step with the Electron app version by scripts/release.sh.
const String kDesktopUiVersion = '0.1.0';

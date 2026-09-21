import 'package:conduit_protocol/conduit_protocol.dart';

/// Connection details for this renderer window.
///
/// Plain Dart with no `package:web`, so the RPC client and its tests can use
/// it on the VM. Reading the value out of Electron's preload bridge lives in
/// `bridge.dart`, which is browser-only.
class ShellBridge {
  const ShellBridge({
    required this.rpcPort,
    required this.token,
    required this.platform,
    required this.windowKind,
    required this.isElectron,
  });

  final int rpcPort;
  final String token;
  final String platform;
  final WindowKind windowKind;

  /// False when running under a plain browser during development.
  final bool isElectron;

  Uri get rpcUri =>
      Uri.parse('ws://127.0.0.1:$rpcPort${ConduitHttpRoutes.rpc}');

  /// Base for proxied files, TTS audio and uploads.
  Uri get httpBase => Uri.parse('http://127.0.0.1:$rpcPort');

  static WindowKind parseWindowKind(String? raw) => switch (raw) {
    'quickAsk' => WindowKind.quickAsk,
    'headless' => WindowKind.headless,
    _ => WindowKind.main,
  };
}

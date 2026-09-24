import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../desktop_shell.dart';
import '../external_sign_in.dart';
import '../file_picker.dart';
import '../file_saver.dart';
import '../attachments.dart';
import '../sandbox_port.dart';
import '../shell_bridge.dart';
import '../window_commands.dart';
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

/// Opens external sign-in windows, overridden in `main.dart` when the
/// Electron shell is present.
///
/// Defaults to the unavailable implementation rather than throwing at read
/// time, because the dev browser legitimately has no shell -- and a button
/// that explains why beats one that silently does nothing.
final externalSignInProvider = Provider<ExternalSignInPort>(
  (ref) => const UnavailableExternalSignIn(),
);

/// Picks PEM files for mutual TLS, overridden in `main.dart`.
final filePickerProvider = Provider<FilePickerPort>(
  (ref) => const UnavailableFilePicker(),
);

/// Saves exports as downloads, overridden in `main.dart`.
final fileSaverProvider = Provider<FileSaverPort>(
  (ref) => RecordingFileSaver(),
);

/// Focus and clipboard for the keyboard layer, overridden in `main.dart`.
final windowCommandsProvider = Provider<WindowCommandsPort>(
  (ref) => RecordingWindowCommands(),
);

/// The window's network events, overridden in `main.dart`.
final networkEventsProvider = Provider<NetworkEventsPort>(
  (ref) => const SteadyNetwork(),
);

/// The document keydown listener, overridden in `main.dart`.
final shortcutBindingProvider = Provider<ShortcutBindingPort>(
  (ref) => NoShortcutBinding(),
);

/// Picks and uploads attachments, overridden in `main.dart`.
final attachmentsProvider = Provider<AttachmentPort>(
  (ref) => RecordingAttachments(),
);

/// The desktop around the window, overridden in `main.dart` under
/// Electron.
final desktopShellProvider = Provider<DesktopShellPort>(
  (ref) => RecordingDesktopShell(),
);

/// The render sandbox, overridden in `main.dart`.
final sandboxProvider = Provider<SandboxPort>((ref) => RecordingSandbox());

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

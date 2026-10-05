import 'package:riverpod/misc.dart';
import 'package:riverpod/riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:conduit_core/features/tools/providers/tools_providers.dart';

import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
import '../services/terminal_service.dart';

/// Reads a provider: `WidgetRef.read` in either app, `Ref.read` in tests.
typedef TerminalProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Listens to a provider until the subscription is closed:
/// `WidgetRef.listenManual` in either app, `ProviderContainer.listen` in
/// tests.
typedef TerminalProviderListen = ProviderSubscription<T> Function<T>(
  ProviderListenable<T> provider,
  void Function(T? previous, T next) listener,
);

abstract interface class TerminalBrowserGateway {
  TerminalService? get service;
  TerminalServerInfo? get selectedServer;
  String get sessionScopeId;
  String get currentPath;

  void setCurrentPath(String path);
  void setEntries(List<TerminalFileEntry> entries);
  void setListeningPorts(List<TerminalListeningPort> ports);
  void requestRefresh();
}

abstract interface class TerminalSessionGateway {
  TerminalConnectionState get connectionState;

  WebSocketChannel openChannel(Uri uri, {required TerminalServerKind kind});
  void setActiveSession(TerminalSessionInfo? session);
  void setConnectionState(TerminalConnectionState state);
}

abstract interface class TerminalContextGateway {
  bool get isActive;
  TerminalService? get service;
  List<TerminalServerInfo> get availableServers;
  String? get selectedTerminalId;
  TerminalServerInfo? get selectedServer;
  String get sessionScopeId;
  bool get autoConnect;

  Future<void> selectServer(TerminalServerInfo server);
  void setCurrentPath(String path);
  void setConnectionState(TerminalConnectionState state);
}

/// The sole Riverpod adapter used by the terminal controllers.
///
/// Controllers depend on the typed gateway contracts above, keeping provider
/// lookup and mutation out of their orchestration and platform logic.
final class RiverpodTerminalControllerGateway
    implements
        TerminalBrowserGateway,
        TerminalSessionGateway,
        TerminalContextGateway {
  RiverpodTerminalControllerGateway({
    required TerminalProviderRead read,
    required bool Function() isActive,
  }) : _read = read,
       _isActive = isActive;

  final TerminalProviderRead _read;
  final bool Function() _isActive;

  @override
  bool get isActive => _isActive();

  @override
  TerminalService? get service => _read(terminalServiceProvider);

  @override
  List<TerminalServerInfo> get availableServers =>
      _read(terminalAvailableServersProvider).asData?.value ??
      const <TerminalServerInfo>[];

  @override
  String? get selectedTerminalId => _read(selectedTerminalIdProvider);

  @override
  TerminalServerInfo? get selectedServer =>
      _read(terminalSelectedServerProvider).asData?.value;

  @override
  String get sessionScopeId => _read(terminalSessionScopeIdProvider);

  @override
  String get currentPath => _read(terminalCurrentPathProvider);

  @override
  bool get autoConnect => _read(terminalAutoConnectProvider);

  @override
  TerminalConnectionState get connectionState =>
      _read(terminalConnectionStateProvider);

  @override
  Future<void> selectServer(TerminalServerInfo server) =>
      _read(terminalSelectionControllerProvider).select(server);

  @override
  void setCurrentPath(String path) =>
      _read(terminalCurrentPathProvider.notifier).set(path);

  @override
  void setEntries(List<TerminalFileEntry> entries) =>
      _read(terminalEntriesProvider.notifier).set(entries);

  @override
  void setListeningPorts(List<TerminalListeningPort> ports) =>
      _read(terminalListeningPortsProvider.notifier).set(ports);

  @override
  void requestRefresh() =>
      _read(terminalSelectionControllerProvider).requestTerminalRefresh();

  @override
  WebSocketChannel openChannel(Uri uri, {required TerminalServerKind kind}) =>
      _read(terminalChannelConnectorProvider)(uri, kind: kind);

  @override
  void setActiveSession(TerminalSessionInfo? session) =>
      _read(terminalActiveSessionProvider.notifier).set(session);

  @override
  void setConnectionState(TerminalConnectionState state) =>
      _read(terminalConnectionStateProvider.notifier).set(state);
}

final class TerminalUploadFile {
  const TerminalUploadFile({required this.name, required this.path});

  final String name;
  final String path;
}

/// File picking, saving and URL launching: plugin work the app supplies.
abstract interface class TerminalBrowserPlatformGateway {
  Future<TerminalUploadFile?> pickUploadFile();
  Future<void> saveDownload(TerminalDownloadedFile downloaded);
  Future<bool> openPort(Uri uri, {String? bearerToken});
}

/// A file name from the server's `Content-Disposition` header, made safe to
/// save: separators and traversal cannot steer the save location.
String safeTerminalFileName(String fileName, {DateTime? now}) {
  // Only what can steer or break a path, or disguise a name, is replaced:
  // separators, reserved characters, control characters and bidirectional
  // controls (U+202E would make `gnp.exe` read as `exe.png` in a save
  // dialog). Other characters, including non-ASCII letters, stay so two
  // different names do not collapse into one.
  final sanitized = fileName
      .replaceAll(
        RegExp(
          r'[/\\:*?"<>|\x00-\x1F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
        ),
        '_',
      )
      .trim();
  // `.` and `..` survive character sanitization but name a directory rather
  // than a file, so writing them throws instead of producing a download.
  if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
    final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return 'terminal_file_$stamp';
  }
  return sanitized;
}

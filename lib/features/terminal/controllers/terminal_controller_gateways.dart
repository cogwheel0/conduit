import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../tools/providers/tools_providers.dart';
import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
import '../services/terminal_service.dart';

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
    required WidgetRef ref,
    required bool Function() isActive,
  }) : _ref = ref,
       _isActive = isActive;

  final WidgetRef _ref;
  final bool Function() _isActive;

  @override
  bool get isActive => _isActive();

  @override
  TerminalService? get service => _ref.read(terminalServiceProvider);

  @override
  List<TerminalServerInfo> get availableServers =>
      _ref.read(terminalAvailableServersProvider).asData?.value ??
      const <TerminalServerInfo>[];

  @override
  String? get selectedTerminalId => _ref.read(selectedTerminalIdProvider);

  @override
  TerminalServerInfo? get selectedServer =>
      _ref.read(terminalSelectedServerProvider).asData?.value;

  @override
  String get sessionScopeId => _ref.read(terminalSessionScopeIdProvider);

  @override
  String get currentPath => _ref.read(terminalCurrentPathProvider);

  @override
  bool get autoConnect => _ref.read(terminalAutoConnectProvider);

  @override
  TerminalConnectionState get connectionState =>
      _ref.read(terminalConnectionStateProvider);

  @override
  Future<void> selectServer(TerminalServerInfo server) =>
      _ref.read(terminalSelectionControllerProvider).select(server);

  @override
  void setCurrentPath(String path) =>
      _ref.read(terminalCurrentPathProvider.notifier).set(path);

  @override
  void setEntries(List<TerminalFileEntry> entries) =>
      _ref.read(terminalEntriesProvider.notifier).set(entries);

  @override
  void setListeningPorts(List<TerminalListeningPort> ports) =>
      _ref.read(terminalListeningPortsProvider.notifier).set(ports);

  @override
  void requestRefresh() =>
      _ref.read(terminalSelectionControllerProvider).requestTerminalRefresh();

  @override
  WebSocketChannel openChannel(Uri uri, {required TerminalServerKind kind}) =>
      _ref.read(terminalChannelConnectorProvider)(uri, kind: kind);

  @override
  void setActiveSession(TerminalSessionInfo? session) =>
      _ref.read(terminalActiveSessionProvider.notifier).set(session);

  @override
  void setConnectionState(TerminalConnectionState state) =>
      _ref.read(terminalConnectionStateProvider.notifier).set(state);
}

final class TerminalUploadFile {
  const TerminalUploadFile({required this.name, required this.path});

  final String name;
  final String path;
}

abstract interface class TerminalBrowserPlatformGateway {
  Future<TerminalUploadFile?> pickUploadFile();
  Future<void> saveDownload(TerminalDownloadedFile downloaded);
  Future<bool> openPort(Uri uri, {String? bearerToken});
}

/// Platform plugin adapter for file picking, saving, and URL launching.
final class DefaultTerminalBrowserPlatformGateway
    implements TerminalBrowserPlatformGateway {
  const DefaultTerminalBrowserPlatformGateway();

  @override
  Future<TerminalUploadFile?> pickUploadFile() async {
    final pickedFile = await FilePicker.pickFile();
    if (pickedFile == null) return null;

    final existingPath = pickedFile.path;
    if (existingPath != null && existingPath.isNotEmpty) {
      return TerminalUploadFile(name: pickedFile.name, path: existingPath);
    }

    final bytes = await pickedFile.readAsBytes();
    final file = await _materializeTempFile(pickedFile.name, bytes);
    return TerminalUploadFile(name: pickedFile.name, path: file.path);
  }

  @override
  Future<void> saveDownload(TerminalDownloadedFile downloaded) async {
    // The name comes from the server's Content-Disposition header, so it must
    // not be able to steer the save location with separators or traversal.
    await FilePicker.saveFile(
      fileName: _safeFileName(downloaded.fileName),
      bytes: downloaded.bytes,
    );
  }

  @override
  Future<bool> openPort(Uri uri, {String? bearerToken}) {
    final token = bearerToken?.trim();
    return launchUrl(
      uri,
      mode: token == null || token.isEmpty
          ? LaunchMode.inAppBrowserView
          : LaunchMode.inAppWebView,
      browserConfiguration: const BrowserConfiguration(showTitle: true),
      webViewConfiguration: WebViewConfiguration(
        headers: token == null || token.isEmpty
            ? const <String, String>{}
            : <String, String>{'Authorization': 'Bearer $token'},
      ),
    );
  }

  static String _safeFileName(String fileName) => fileName.isEmpty
      ? 'terminal_file_${DateTime.now().millisecondsSinceEpoch}'
      : fileName.replaceAll(RegExp(r'[^\w\.\-]'), '_');

  Future<File> _materializeTempFile(String fileName, List<int> bytes) async {
    final tempDir = await getTemporaryDirectory();
    final safeName = _safeFileName(fileName);
    final file = File(p.join(tempDir.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}

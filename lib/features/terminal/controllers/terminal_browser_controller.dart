import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
import '../services/terminal_service.dart';
import 'terminal_session_controller.dart';

enum TerminalBrowserFailure {
  loadFiles,
  loadPorts,
  download,
  rename,
  delete,
  upload,
  createFolder,
  openPort,
}

/// Coordinates terminal file-browser queries and mutations.
///
/// The controller keeps network and filesystem work out of the tab widget and
/// rejects results that no longer belong to the selected terminal context.
class TerminalBrowserController extends ChangeNotifier {
  TerminalBrowserController({
    required WidgetRef ref,
    required TerminalContextValidator isCurrentContext,
    required void Function(TerminalBrowserFailure failure) onFailure,
  }) : _ref = ref,
       _isCurrentContext = isCurrentContext,
       _onFailure = onFailure;

  final WidgetRef _ref;
  final TerminalContextValidator _isCurrentContext;
  final void Function(TerminalBrowserFailure failure) _onFailure;

  bool _loadingFiles = false;
  bool _loadingPorts = false;
  bool _disposed = false;

  bool get loadingFiles => _loadingFiles;

  bool get loadingPorts => _loadingPorts;

  Future<void> reload() async {
    if (_disposed) {
      return;
    }
    final service = _ref.read(terminalServiceProvider);
    final server = _selectedServer;
    if (service == null || server == null || !_isCurrentServer(server)) {
      return;
    }

    await loadDirectory(
      service,
      server,
      path: _ref.read(terminalCurrentPathProvider),
      updateServerCwd: false,
    );
    await loadPorts(service, server);
  }

  Future<void> loadDirectory(
    TerminalService service,
    TerminalServerInfo server, {
    required String path,
    required bool updateServerCwd,
  }) async {
    final sessionScopeId = _ref.read(terminalSessionScopeIdProvider);
    final normalizedPath = ensureTerminalDirectoryPath(path);

    _setLoadingFiles(true);
    try {
      final entries = await service.listFiles(
        server,
        normalizedPath,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentContext(server, sessionScopeId)) {
        return;
      }

      _ref.read(terminalCurrentPathProvider.notifier).set(normalizedPath);
      _ref.read(terminalEntriesProvider.notifier).set(entries);

      if (updateServerCwd) {
        unawaited(
          service.setCwd(
            server,
            normalizedPath,
            sessionScopeId: sessionScopeId,
          ),
        );
      }
    } catch (_) {
      if (_isCurrentContext(server, sessionScopeId)) {
        _onFailure(TerminalBrowserFailure.loadFiles);
      }
    } finally {
      if (_isCurrentContext(server, sessionScopeId)) {
        _setLoadingFiles(false);
      }
    }
  }

  Future<void> loadPorts(
    TerminalService service,
    TerminalServerInfo server,
  ) async {
    final sessionScopeId = _ref.read(terminalSessionScopeIdProvider);
    _setLoadingPorts(true);
    try {
      final ports = await service.getListeningPorts(
        server,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentContext(server, sessionScopeId)) {
        return;
      }
      _ref.read(terminalListeningPortsProvider.notifier).set(ports);
    } catch (_) {
      if (_isCurrentContext(server, sessionScopeId)) {
        _onFailure(TerminalBrowserFailure.loadPorts);
      }
    } finally {
      if (_isCurrentContext(server, sessionScopeId)) {
        _setLoadingPorts(false);
      }
    }
  }

  Future<void> navigateTo(String path) async {
    if (_disposed) {
      return;
    }
    final service = _ref.read(terminalServiceProvider);
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }
    await loadDirectory(service, server, path: path, updateServerCwd: true);
  }

  Future<TerminalFileReadResult?> readEntry(TerminalFileEntry entry) async {
    if (_disposed) {
      return null;
    }
    final service = _ref.read(terminalServiceProvider);
    final server = _selectedServer;
    if (service == null || server == null) {
      return null;
    }

    final sessionScopeId = _ref.read(terminalSessionScopeIdProvider);
    try {
      final preview = await service.readFile(
        server,
        entry.path,
        sessionScopeId: sessionScopeId,
      );
      return _isCurrentContext(server, sessionScopeId) ? preview : null;
    } catch (_) {
      if (_isCurrentContext(server, sessionScopeId)) {
        _onFailure(TerminalBrowserFailure.loadFiles);
      }
      return null;
    }
  }

  Future<void> downloadEntry(TerminalFileEntry entry) async {
    if (_disposed) {
      return;
    }
    final service = _ref.read(terminalServiceProvider);
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }

    try {
      final downloaded = await service.downloadFile(
        server,
        entry.path,
        sessionScopeId: _ref.read(terminalSessionScopeIdProvider),
      );
      final file = await _materializeTempFile(
        downloaded.fileName,
        downloaded.bytes,
      );
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, name: downloaded.fileName)],
        ),
      );
    } catch (_) {
      _onFailure(TerminalBrowserFailure.download);
    }
  }

  Future<void> renameEntry(TerminalFileEntry entry, String newName) async {
    if (_disposed) {
      return;
    }
    final service = _ref.read(terminalServiceProvider);
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }

    try {
      await service.moveEntry(
        server,
        _pathWithoutTrailingSlash(entry.path),
        _pathWithoutTrailingSlash(
          joinTerminalPath(
            _ref.read(terminalCurrentPathProvider),
            newName,
            directoryResult: entry.isDirectory,
          ),
        ),
        sessionScopeId: _ref.read(terminalSessionScopeIdProvider),
      );
      if (!_disposed) {
        await reload();
      }
    } catch (_) {
      _onFailure(TerminalBrowserFailure.rename);
    }
  }

  Future<void> deleteEntry(TerminalFileEntry entry) async {
    if (_disposed) {
      return;
    }
    final service = _ref.read(terminalServiceProvider);
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }

    try {
      await service.deleteEntry(
        server,
        _pathWithoutTrailingSlash(entry.path),
        sessionScopeId: _ref.read(terminalSessionScopeIdProvider),
      );
      if (!_disposed) {
        await reload();
      }
    } catch (_) {
      _onFailure(TerminalBrowserFailure.delete);
    }
  }

  Future<void> pickAndUploadFile() async {
    if (_disposed) {
      return;
    }
    final service = _ref.read(terminalServiceProvider);
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }

    try {
      final pickedFile = await FilePicker.pickFile();
      if (pickedFile == null) {
        return;
      }
      final localFile = await _materializePickedFile(pickedFile);
      if (localFile == null) {
        return;
      }

      await service.uploadFile(
        server,
        _ref.read(terminalCurrentPathProvider),
        localFile.path,
        pickedFile.name,
        sessionScopeId: _ref.read(terminalSessionScopeIdProvider),
      );
      if (!_disposed) {
        await reload();
      }
    } catch (_) {
      _onFailure(TerminalBrowserFailure.upload);
    }
  }

  Future<void> createFolder(String folderName) async {
    if (_disposed) {
      return;
    }
    final service = _ref.read(terminalServiceProvider);
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }

    try {
      await service.createDirectory(
        server,
        joinTerminalPath(_ref.read(terminalCurrentPathProvider), folderName),
        sessionScopeId: _ref.read(terminalSessionScopeIdProvider),
      );
      if (_disposed) {
        return;
      }
      _ref.read(terminalSelectionControllerProvider).requestTerminalRefresh();
      await reload();
    } catch (_) {
      _onFailure(TerminalBrowserFailure.createFolder);
    }
  }

  Future<void> openPort(TerminalListeningPort port) async {
    if (_disposed) {
      return;
    }
    final service = _ref.read(terminalServiceProvider);
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }

    final url = service.buildPortProxyUri(server, port.port);
    final authToken = server.isSystem
        ? service.authTokenForServer(server)
        : null;
    final launched = await launchUrl(
      url,
      mode: authToken == null || authToken.isEmpty
          ? LaunchMode.inAppBrowserView
          : LaunchMode.inAppWebView,
      browserConfiguration: const BrowserConfiguration(showTitle: true),
      webViewConfiguration: WebViewConfiguration(
        headers: authToken == null || authToken.isEmpty
            ? const <String, String>{}
            : <String, String>{'Authorization': 'Bearer $authToken'},
      ),
    );
    if (!launched) {
      _onFailure(TerminalBrowserFailure.openPort);
    }
  }

  void resetLoading() {
    if (!_loadingFiles && !_loadingPorts) {
      return;
    }
    _loadingFiles = false;
    _loadingPorts = false;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  TerminalServerInfo? get _selectedServer =>
      _ref.read(terminalSelectedServerProvider).asData?.value;

  bool _isCurrentServer(TerminalServerInfo server) =>
      _isCurrentContext(server, _ref.read(terminalSessionScopeIdProvider));

  void _setLoadingFiles(bool value) {
    if (_loadingFiles == value) {
      return;
    }
    _loadingFiles = value;
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _setLoadingPorts(bool value) {
    if (_loadingPorts == value) {
      return;
    }
    _loadingPorts = value;
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<File?> _materializePickedFile(PlatformFile pickedFile) async {
    if (pickedFile.path != null && pickedFile.path!.isNotEmpty) {
      return File(pickedFile.path!);
    }

    try {
      final bytes = await pickedFile.readAsBytes();
      return _materializeTempFile(pickedFile.name, bytes);
    } catch (_) {
      return null;
    }
  }

  Future<File> _materializeTempFile(String fileName, List<int> bytes) async {
    final tempDir = await getTemporaryDirectory();
    final safeName = fileName.isEmpty
        ? 'terminal_file_${DateTime.now().millisecondsSinceEpoch}'
        : fileName.replaceAll(RegExp(r'[^\w\.\-]'), '_');
    final file = File(p.join(tempDir.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _pathWithoutTrailingSlash(String path) {
    if (path == '/' || RegExp(r'^[A-Za-z]:/$').hasMatch(path)) {
      return path;
    }
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }
}

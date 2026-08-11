import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/terminal_models.dart';
import '../services/terminal_service.dart';
import 'terminal_controller_gateways.dart';
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

@immutable
final class TerminalBrowserOperationContext {
  const TerminalBrowserOperationContext({
    required this.service,
    required this.server,
    required this.sessionScopeId,
    required this.currentPath,
  });

  final TerminalService service;
  final TerminalServerInfo server;
  final String sessionScopeId;
  final String currentPath;
}

/// Coordinates terminal file-browser queries and mutations.
///
/// The controller keeps network and filesystem work out of the tab widget and
/// rejects results that no longer belong to the selected terminal context.
class TerminalBrowserController extends ChangeNotifier {
  TerminalBrowserController({
    required TerminalBrowserGateway gateway,
    required TerminalBrowserPlatformGateway platformGateway,
    required TerminalContextValidator isCurrentContext,
    required void Function(TerminalBrowserFailure failure) onFailure,
  }) : _gateway = gateway,
       _platformGateway = platformGateway,
       _isCurrentContext = isCurrentContext,
       _onFailure = onFailure;

  final TerminalBrowserGateway _gateway;
  final TerminalBrowserPlatformGateway _platformGateway;
  final TerminalContextValidator _isCurrentContext;
  final void Function(TerminalBrowserFailure failure) _onFailure;

  bool _loadingFiles = false;
  bool _loadingPorts = false;
  bool _disposed = false;

  bool get loadingFiles => _loadingFiles;

  bool get loadingPorts => _loadingPorts;

  TerminalBrowserOperationContext? captureOperationContext() {
    if (_disposed) return null;
    final service = _gateway.service;
    final server = _selectedServer;
    if (service == null || server == null || !_isCurrentServer(server)) {
      return null;
    }
    return TerminalBrowserOperationContext(
      service: service,
      server: server,
      sessionScopeId: _gateway.sessionScopeId,
      currentPath: _gateway.currentPath,
    );
  }

  Future<void> reload() async {
    if (_disposed) {
      return;
    }
    final service = _gateway.service;
    final server = _selectedServer;
    if (service == null || server == null || !_isCurrentServer(server)) {
      return;
    }

    await loadDirectory(
      service,
      server,
      path: _gateway.currentPath,
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
    final sessionScopeId = _gateway.sessionScopeId;
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

      _gateway.setCurrentPath(normalizedPath);
      _gateway.setEntries(entries);

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
    final sessionScopeId = _gateway.sessionScopeId;
    _setLoadingPorts(true);
    try {
      final ports = await service.getListeningPorts(
        server,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentContext(server, sessionScopeId)) {
        return;
      }
      _gateway.setListeningPorts(ports);
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
    final service = _gateway.service;
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }
    await loadDirectory(service, server, path: path, updateServerCwd: true);
  }

  Future<TerminalFileReadResult?> readEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
  ) async {
    if (!_isCurrentOperationContext(operationContext)) {
      return null;
    }
    try {
      final preview = await operationContext.service.readFile(
        operationContext.server,
        entry.path,
        sessionScopeId: operationContext.sessionScopeId,
      );
      return _isCurrentOperationContext(operationContext) ? preview : null;
    } catch (_) {
      if (_isCurrentOperationContext(operationContext)) {
        _onFailure(TerminalBrowserFailure.loadFiles);
      }
      return null;
    }
  }

  Future<void> downloadEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
  ) async {
    if (!_isCurrentOperationContext(operationContext)) return;
    try {
      final downloaded = await operationContext.service.downloadFile(
        operationContext.server,
        entry.path,
        sessionScopeId: operationContext.sessionScopeId,
      );
      if (!_isCurrentOperationContext(operationContext)) return;
      await _platformGateway.shareDownload(downloaded);
    } catch (_) {
      if (_isCurrentOperationContext(operationContext)) {
        _onFailure(TerminalBrowserFailure.download);
      }
    }
  }

  Future<void> renameEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
    String newName,
  ) async {
    if (!_isCurrentOperationContext(operationContext)) return;
    try {
      await operationContext.service.moveEntry(
        operationContext.server,
        _pathWithoutTrailingSlash(entry.path),
        _pathWithoutTrailingSlash(
          joinTerminalPath(
            operationContext.currentPath,
            newName,
            directoryResult: entry.isDirectory,
          ),
        ),
        sessionScopeId: operationContext.sessionScopeId,
      );
      if (_isCurrentOperationContext(operationContext)) {
        await reload();
      }
    } catch (_) {
      if (_isCurrentOperationContext(operationContext)) {
        _onFailure(TerminalBrowserFailure.rename);
      }
    }
  }

  Future<void> deleteEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
  ) async {
    if (!_isCurrentOperationContext(operationContext)) return;
    try {
      await operationContext.service.deleteEntry(
        operationContext.server,
        _pathWithoutTrailingSlash(entry.path),
        sessionScopeId: operationContext.sessionScopeId,
      );
      if (_isCurrentOperationContext(operationContext)) {
        await reload();
      }
    } catch (_) {
      if (_isCurrentOperationContext(operationContext)) {
        _onFailure(TerminalBrowserFailure.delete);
      }
    }
  }

  Future<void> pickAndUploadFile(
    TerminalBrowserOperationContext operationContext,
  ) async {
    if (!_isCurrentOperationContext(operationContext)) return;
    try {
      final pickedFile = await _platformGateway.pickUploadFile();
      if (pickedFile == null || !_isCurrentOperationContext(operationContext)) {
        return;
      }

      await operationContext.service.uploadFile(
        operationContext.server,
        operationContext.currentPath,
        pickedFile.path,
        pickedFile.name,
        sessionScopeId: operationContext.sessionScopeId,
      );
      if (_isCurrentOperationContext(operationContext)) {
        await reload();
      }
    } catch (_) {
      if (_isCurrentOperationContext(operationContext)) {
        _onFailure(TerminalBrowserFailure.upload);
      }
    }
  }

  Future<void> createFolder(
    TerminalBrowserOperationContext operationContext,
    String folderName,
  ) async {
    if (!_isCurrentOperationContext(operationContext)) return;
    try {
      await operationContext.service.createDirectory(
        operationContext.server,
        joinTerminalPath(operationContext.currentPath, folderName),
        sessionScopeId: operationContext.sessionScopeId,
      );
      if (!_isCurrentOperationContext(operationContext)) return;
      _gateway.requestRefresh();
      await reload();
    } catch (_) {
      if (_isCurrentOperationContext(operationContext)) {
        _onFailure(TerminalBrowserFailure.createFolder);
      }
    }
  }

  Future<void> openPort(TerminalListeningPort port) async {
    if (_disposed) {
      return;
    }
    final service = _gateway.service;
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }

    final url = service.buildPortProxyUri(server, port.port);
    final authToken = server.isSystem
        ? service.authTokenForServer(server)
        : null;
    final launched = await _platformGateway.openPort(
      url,
      bearerToken: authToken,
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

  TerminalServerInfo? get _selectedServer => _gateway.selectedServer;

  bool _isCurrentServer(TerminalServerInfo server) =>
      _isCurrentContext(server, _gateway.sessionScopeId);

  bool _isCurrentOperationContext(
    TerminalBrowserOperationContext operationContext,
  ) =>
      !_disposed &&
      identical(_gateway.service, operationContext.service) &&
      _gateway.currentPath == operationContext.currentPath &&
      _isCurrentContext(
        operationContext.server,
        operationContext.sessionScopeId,
      );

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

  String _pathWithoutTrailingSlash(String path) {
    if (path == '/' || RegExp(r'^[A-Za-z]:/$').hasMatch(path)) {
      return path;
    }
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }
}

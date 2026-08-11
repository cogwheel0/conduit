import 'package:flutter/foundation.dart';

import '../models/terminal_models.dart';
import '../services/terminal_service.dart';
import 'terminal_browser_controller.dart';
import 'terminal_controller_gateways.dart';
import 'terminal_session_controller.dart';

enum TerminalContextFailure { load, connect }

/// Owns terminal selection, context synchronization, and reload ordering.
final class TerminalContextController extends ChangeNotifier {
  TerminalContextController({
    required TerminalContextGateway gateway,
    required TerminalSessionController sessionController,
    required TerminalBrowserController browserController,
    required String Function() disconnectedLabel,
    required void Function(TerminalContextFailure failure) onFailure,
  }) : _gateway = gateway,
       _sessionController = sessionController,
       _browserController = browserController,
       _disconnectedLabel = disconnectedLabel,
       _onFailure = onFailure;

  final TerminalContextGateway _gateway;
  final TerminalSessionController _sessionController;
  final TerminalBrowserController _browserController;
  final String Function() _disconnectedLabel;
  final void Function(TerminalContextFailure failure) _onFailure;

  bool _didAutoSelectFallback = false;
  bool _terminalSupported = true;
  bool _disposed = false;
  String? _syncKey;
  int _syncGeneration = 0;

  bool get terminalSupported => _terminalSupported;

  bool isCurrentContext(TerminalServerInfo server, String sessionScopeId) =>
      !_disposed &&
      _gateway.isActive &&
      _gateway.selectedServer?.selectionId == server.selectionId &&
      _gateway.sessionScopeId == sessionScopeId;

  Future<void> reloadBrowser() async {
    if (_disposed || !_gateway.isActive) return;
    await _browserController.reload();
  }

  Future<void> sync({required bool force}) async {
    if (_disposed) return;
    if (!_gateway.isActive) {
      await deactivate();
      return;
    }

    final service = _gateway.service;
    if (service == null) return;

    final selectedTerminalId = _gateway.selectedTerminalId;
    final selectedServer = _gateway.selectedServer;
    if (!_didAutoSelectFallback &&
        selectedTerminalId == null &&
        selectedServer != null) {
      _didAutoSelectFallback = true;
      await _gateway.selectServer(selectedServer);
      return;
    }
    if (selectedServer == null) {
      final availableServers = _gateway.availableServers;
      if (!_didAutoSelectFallback &&
          selectedTerminalId == null &&
          availableServers.isNotEmpty) {
        _didAutoSelectFallback = true;
        await _gateway.selectServer(availableServers.first);
      } else {
        await _sessionController.disconnect(showClosedBanner: false);
        _browserController.resetLoading();
      }
      return;
    }

    final sessionScopeId = _gateway.sessionScopeId;
    final nextSyncKey = '${selectedServer.selectionId}::$sessionScopeId';
    if (!force && _syncKey == nextSyncKey) return;
    _syncKey = nextSyncKey;
    final syncGeneration = ++_syncGeneration;

    await _sessionController.disconnect(showClosedBanner: false);
    if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
      return;
    }
    _sessionController.clear();
    _gateway.setConnectionState(const TerminalConnectionState.disconnected());

    try {
      final terminalEnabled = await service.isTerminalFeatureEnabled(
        selectedServer,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }
      _setTerminalSupported(terminalEnabled);

      final cwd = await service.getCwd(
        selectedServer,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }
      final initialPath = ensureTerminalDirectoryPath(cwd ?? '/');
      _gateway.setCurrentPath(initialPath);

      await _browserController.loadDirectory(
        service,
        selectedServer,
        path: initialPath,
        updateServerCwd: false,
      );
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }
      await _browserController.loadPorts(service, selectedServer);
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }

      if (_gateway.autoConnect && terminalSupported) {
        await _connect(service, selectedServer, sessionScopeId);
      }
    } catch (_) {
      if (_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        _onFailure(TerminalContextFailure.load);
      }
    }
  }

  Future<void> connect() async {
    if (_disposed || !_gateway.isActive) return;
    final service = _gateway.service;
    final server = _gateway.selectedServer;
    if (service == null || server == null) return;
    await _connect(service, server, _gateway.sessionScopeId);
  }

  Future<void> deactivate() async {
    if (_disposed) return;
    _syncKey = null;
    _syncGeneration++;
    await _sessionController.disconnect(showClosedBanner: false);
    _browserController.resetLoading();
  }

  Future<void> _connect(
    TerminalService service,
    TerminalServerInfo server,
    String sessionScopeId,
  ) => _sessionController.connect(
    service,
    server,
    sessionScopeId: sessionScopeId,
    disconnectedLabel: _disconnectedLabel(),
    onFailure: () => _onFailure(TerminalContextFailure.connect),
  );

  bool _isCurrentSync(
    int syncGeneration,
    TerminalServerInfo server,
    String sessionScopeId,
  ) =>
      syncGeneration == _syncGeneration &&
      isCurrentContext(server, sessionScopeId);

  void _setTerminalSupported(bool value) {
    if (_terminalSupported == value) return;
    _terminalSupported = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncGeneration++;
    super.dispose();
  }
}

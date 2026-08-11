import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
import 'terminal_browser_controller.dart';
import 'terminal_context_controller.dart';
import 'terminal_controller_gateways.dart';
import 'terminal_session_controller.dart';

/// Composition root for the terminal tab.
///
/// The coordinator owns provider synchronization, controller lifetimes, context
/// validation, and the command surface consumed by terminal widgets. Internal
/// controllers remain focused on their respective protocols without forming a
/// cyclic ownership graph.
final class TerminalCoordinator extends ChangeNotifier {
  TerminalCoordinator({
    required WidgetRef ref,
    required bool Function() isActive,
    required String Function() disconnectedLabel,
    required void Function(TerminalBrowserFailure failure) onBrowserFailure,
    required void Function(TerminalContextFailure failure) onContextFailure,
    TerminalBrowserPlatformGateway platformGateway =
        const DefaultTerminalBrowserPlatformGateway(),
  }) : _ref = ref,
       _gateway = RiverpodTerminalControllerGateway(
         ref: ref,
         isActive: isActive,
       ) {
    _sessionController = TerminalSessionController(
      gateway: _gateway,
      isCurrentContext: _isCurrentContext,
    );
    _browserController = TerminalBrowserController(
      gateway: _gateway,
      platformGateway: platformGateway,
      isCurrentContext: _isCurrentContext,
      onFailure: onBrowserFailure,
    );
    _contextController = TerminalContextController(
      gateway: _gateway,
      sessionController: _sessionController,
      browserController: _browserController,
      isCurrentContext: _isCurrentContext,
      disconnectedLabel: disconnectedLabel,
      onFailure: onContextFailure,
    );

    _browserController.addListener(_relayChange);
    _contextController.addListener(_relayChange);
    _refreshSubscription = ref.listenManual<int>(
      terminalBrowserRefreshTokenProvider,
      (previous, next) {
        if (previous != next && _gateway.isActive) {
          unawaited(_contextController.reloadBrowser());
        }
      },
    );
    _sessionScopeSubscription = ref.listenManual<String>(
      terminalSessionScopeIdProvider,
      (_, _) {
        if (_gateway.isActive) {
          unawaited(_contextController.sync(force: true));
        }
      },
    );
    _selectedServerSubscription = ref
        .listenManual<AsyncValue<TerminalServerInfo?>>(
          terminalSelectedServerProvider,
          (_, next) => next.whenData((_) {
            if (_gateway.isActive) {
              unawaited(_contextController.sync(force: true));
            }
          }),
        );
    _singleServerDefaultPanelSubscription = ref.listenManual(
      terminalAvailableServersProvider,
      (_, next) => _handleInitialServerList(next),
    );
  }

  final WidgetRef _ref;
  final RiverpodTerminalControllerGateway _gateway;

  late final TerminalSessionController _sessionController;
  late final TerminalBrowserController _browserController;
  late final TerminalContextController _contextController;
  late final ProviderSubscription<int> _refreshSubscription;
  late final ProviderSubscription<String> _sessionScopeSubscription;
  late final ProviderSubscription<AsyncValue<TerminalServerInfo?>>
  _selectedServerSubscription;
  ProviderSubscription<AsyncValue<List<TerminalServerInfo>>>?
  _singleServerDefaultPanelSubscription;

  bool _started = false;
  bool _disposed = false;

  Terminal get terminal => _sessionController.terminal;
  TerminalController get terminalController =>
      _sessionController.terminalController;
  bool get loadingFiles => _browserController.loadingFiles;
  bool get loadingPorts => _browserController.loadingPorts;
  bool get terminalSupported => _contextController.terminalSupported;

  /// Starts initial synchronization after the widget's first frame.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _handleInitialServerList(_ref.read(terminalAvailableServersProvider));
    if (_gateway.isActive) {
      unawaited(_contextController.sync(force: true));
    }
  }

  void activate() {
    if (!_disposed) unawaited(_contextController.sync(force: true));
  }

  void deactivate() {
    if (!_disposed) unawaited(_contextController.deactivate());
  }

  Future<void> connect() => _contextController.connect();

  Future<void> disconnect() =>
      _sessionController.disconnect(showClosedBanner: false);

  Future<void> reloadBrowser() => _contextController.reloadBrowser();

  Future<void> navigateTo(String path) => _browserController.navigateTo(path);

  TerminalBrowserOperationContext? captureOperationContext() =>
      _browserController.captureOperationContext();

  Future<TerminalFileReadResult?> readEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
  ) => _browserController.readEntry(operationContext, entry);

  Future<void> downloadEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
  ) => _browserController.downloadEntry(operationContext, entry);

  Future<void> renameEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
    String newName,
  ) => _browserController.renameEntry(operationContext, entry, newName);

  Future<void> deleteEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
  ) => _browserController.deleteEntry(operationContext, entry);

  Future<void> pickAndUploadFile(
    TerminalBrowserOperationContext operationContext,
  ) => _browserController.pickAndUploadFile(operationContext);

  Future<void> createFolder(
    TerminalBrowserOperationContext operationContext,
    String folderName,
  ) => _browserController.createFolder(operationContext, folderName);

  Future<void> openPort(TerminalListeningPort port) =>
      _browserController.openPort(port);

  bool _isCurrentContext(TerminalServerInfo server, String sessionScopeId) =>
      !_disposed &&
      _gateway.isActive &&
      _gateway.selectedServer?.selectionId == server.selectionId &&
      _gateway.sessionScopeId == sessionScopeId;

  void _handleInitialServerList(AsyncValue<List<TerminalServerInfo>> state) {
    if (!state.hasValue || _disposed) return;
    final shouldShowFiles = state.requireValue.length == 1;
    _singleServerDefaultPanelSubscription?.close();
    _singleServerDefaultPanelSubscription = null;
    if (!shouldShowFiles) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) {
        _ref
            .read(terminalSidebarPanelProvider.notifier)
            .setPanel(TerminalSidebarPanel.files);
      }
    });
  }

  void _relayChange() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _refreshSubscription.close();
    _sessionScopeSubscription.close();
    _selectedServerSubscription.close();
    _singleServerDefaultPanelSubscription?.close();
    _contextController
      ..removeListener(_relayChange)
      ..dispose();
    _browserController
      ..removeListener(_relayChange)
      ..dispose();
    _sessionController.dispose();
    super.dispose();
  }
}

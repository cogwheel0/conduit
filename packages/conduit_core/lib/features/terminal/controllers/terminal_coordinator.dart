import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
import 'terminal_browser_controller.dart';
import 'terminal_change_notifier.dart';
import 'terminal_context_controller.dart';
import 'terminal_controller_gateways.dart';
import 'terminal_screen.dart';
import 'terminal_session_controller.dart';

/// Composition root for the terminal tab.
///
/// The coordinator owns provider synchronization, controller lifetimes,
/// context validation, and the command surface consumed by terminal widgets.
/// Internal controllers remain focused on their respective protocols without
/// forming a cyclic ownership graph. [S] is the app's emulator adapter, which
/// the widgets render.
final class TerminalCoordinator<S extends TerminalScreen>
    with TerminalChangeNotifier {
  TerminalCoordinator({
    required TerminalProviderRead read,
    required TerminalProviderListen listen,
    required this.screen,
    required bool Function() isActive,
    required String Function() disconnectedLabel,
    required void Function(TerminalBrowserFailure failure) onBrowserFailure,
    required void Function(TerminalContextFailure failure) onContextFailure,
    required TerminalBrowserPlatformGateway platformGateway,
    void Function(void Function() callback)? schedulePostFrame,
  }) : _read = read,
       _schedulePostFrame = schedulePostFrame ?? scheduleMicrotask,
       _gateway = RiverpodTerminalControllerGateway(
         read: read,
         isActive: isActive,
       ) {
    _sessionController = TerminalSessionController(
      gateway: _gateway,
      isCurrentContext: _isCurrentContext,
      screen: screen,
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
    _refreshSubscription = listen<int>(terminalBrowserRefreshTokenProvider, (
      previous,
      next,
    ) {
      if (previous != next && _gateway.isActive) {
        unawaited(_contextController.reloadBrowser());
      }
    });
    _sessionScopeSubscription = listen<String>(terminalSessionScopeIdProvider, (
      _,
      _,
    ) {
      if (_gateway.isActive) {
        unawaited(_contextController.sync(force: true));
      }
    });
    _selectedServerSubscription = listen<AsyncValue<TerminalServerInfo?>>(
      terminalSelectedServerProvider,
      (_, next) => next.whenData((_) {
        if (_gateway.isActive) {
          unawaited(_contextController.sync(force: true));
        }
      }),
    );
    // The shell writes files while the console is shown; list the
    // directory again when the Files panel comes back.
    _panelSubscription = listen<TerminalSidebarPanel>(
      terminalSidebarPanelProvider,
      (previous, next) {
        if (previous != next &&
            next == TerminalSidebarPanel.files &&
            _gateway.isActive) {
          unawaited(_contextController.reloadBrowser());
        }
      },
    );
    _singleServerDefaultPanelSubscription =
        listen<AsyncValue<List<TerminalServerInfo>>>(
          terminalAvailableServersProvider,
          (_, next) => _handleInitialServerList(next),
        );
  }

  final TerminalProviderRead _read;
  final void Function(void Function() callback) _schedulePostFrame;
  final RiverpodTerminalControllerGateway _gateway;

  /// The emulator adapter the widgets render and type into.
  final S screen;

  late final TerminalSessionController _sessionController;
  late final TerminalBrowserController _browserController;
  late final TerminalContextController _contextController;
  late final ProviderSubscription<int> _refreshSubscription;
  late final ProviderSubscription<String> _sessionScopeSubscription;
  late final ProviderSubscription<TerminalSidebarPanel> _panelSubscription;
  late final ProviderSubscription<AsyncValue<TerminalServerInfo?>>
  _selectedServerSubscription;
  ProviderSubscription<AsyncValue<List<TerminalServerInfo>>>?
  _singleServerDefaultPanelSubscription;

  bool _started = false;
  bool _disposed = false;

  bool get loadingFiles => _browserController.loadingFiles;
  bool get loadingPorts => _browserController.loadingPorts;
  bool get terminalSupported => _contextController.terminalSupported;

  /// Starts initial synchronization after the widget's first frame.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _handleInitialServerList(_read(terminalAvailableServersProvider));
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

    _schedulePostFrame(() {
      if (!_disposed) {
        _read(terminalSidebarPanelProvider.notifier)
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
    _panelSubscription.close();
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

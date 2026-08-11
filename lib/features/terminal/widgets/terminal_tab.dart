import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_page_route.dart';
import '../../../shared/utils/utf16_sanitizer.dart';
import '../../navigation/models/sidebar_navigation_model.dart';
import '../../navigation/providers/sidebar_search_providers.dart';
import '../../navigation/providers/sidebar_tab_scroll_registry.dart';
import '../../tools/providers/tools_providers.dart';
import '../controllers/terminal_browser_controller.dart';
import '../controllers/terminal_session_controller.dart';
import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
import '../services/terminal_service.dart';
import 'terminal_console_section.dart';
import 'terminal_files_section.dart';
import 'terminal_fullscreen_page.dart';

class TerminalTab extends ConsumerStatefulWidget {
  const TerminalTab({super.key, this.isActive = true});

  final bool isActive;

  @override
  ConsumerState<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends ConsumerState<TerminalTab>
    with
        AutomaticKeepAliveClientMixin,
        SidebarTabScrollRegistration<TerminalTab> {
  final ScrollController _filesScrollController = ScrollController();
  final ScrollController _portsScrollController = ScrollController();

  late final TerminalSessionController _sessionController;
  late final TerminalBrowserController _browserController;

  ProviderSubscription<int>? _refreshSubscription;
  ProviderSubscription<String>? _sessionScopeSubscription;
  ProviderSubscription<AsyncValue<TerminalServerInfo?>>?
  _selectedServerSubscription;
  ProviderSubscription<AsyncValue<List<TerminalServerInfo>>>?
  _singleServerDefaultPanelSubscription;

  bool _didAutoSelectFallback = false;
  bool _terminalSupported = true;
  bool _fullscreen = false;
  String? _syncKey;
  int _syncGeneration = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sessionController = TerminalSessionController(
      ref: ref,
      isCurrentContext: _isCurrentTerminalContext,
    );
    _browserController = TerminalBrowserController(
      ref: ref,
      isCurrentContext: _isCurrentTerminalContext,
      onFailure: _handleBrowserFailure,
    )..addListener(_handleBrowserChanged);

    _refreshSubscription = ref.listenManual<int>(
      terminalBrowserRefreshTokenProvider,
      (previous, next) {
        if (previous != next && widget.isActive) {
          unawaited(_browserController.reload());
        }
      },
    );
    _sessionScopeSubscription = ref.listenManual<String>(
      terminalSessionScopeIdProvider,
      (previous, next) {
        if (widget.isActive) {
          unawaited(_syncTerminalState(force: true));
        }
      },
    );
    _selectedServerSubscription = ref
        .listenManual<AsyncValue<TerminalServerInfo?>>(
          terminalSelectedServerProvider,
          (_, next) => next.whenData((_) {
            if (widget.isActive) {
              unawaited(_syncTerminalState(force: true));
            }
          }),
        );
    _singleServerDefaultPanelSubscription = ref.listenManual(
      terminalAvailableServersProvider,
      (previous, next) => _handleSingleServerDefaultPanel(next),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _handleSingleServerDefaultPanel(
        ref.read(terminalAvailableServersProvider),
      );
      if (widget.isActive) {
        unawaited(_syncTerminalState(force: true));
      }
    });
  }

  @override
  void didUpdateWidget(covariant TerminalTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) {
      return;
    }

    if (widget.isActive) {
      unawaited(_syncTerminalState(force: true));
      return;
    }

    _syncKey = null;
    _syncGeneration++;
    unawaited(_sessionController.disconnect(showClosedBanner: false));
    _browserController.resetLoading();
  }

  @override
  void dispose() {
    _refreshSubscription?.close();
    _sessionScopeSubscription?.close();
    _selectedServerSubscription?.close();
    _singleServerDefaultPanelSubscription?.close();
    _browserController
      ..removeListener(_handleBrowserChanged)
      ..dispose();
    _sessionController.dispose();
    _filesScrollController.dispose();
    _portsScrollController.dispose();
    super.dispose();
  }

  @override
  SidebarTabId get sidebarTabId => SidebarTabId.terminal;

  @override
  ScrollController get sidebarScrollController =>
      _filesScrollController.hasClients
      ? _filesScrollController
      : _portsScrollController;

  void _handleBrowserChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _handleSingleServerDefaultPanel(
    AsyncValue<List<TerminalServerInfo>> next,
  ) {
    if (!next.hasValue) {
      return;
    }

    final shouldShowFiles = next.requireValue.length == 1;
    _singleServerDefaultPanelSubscription?.close();
    _singleServerDefaultPanelSubscription = null;
    if (!shouldShowFiles) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref
            .read(terminalSidebarPanelProvider.notifier)
            .setPanel(TerminalSidebarPanel.files);
      }
    });
  }

  bool _isCurrentTerminalContext(
    TerminalServerInfo server,
    String sessionScopeId,
  ) {
    if (!mounted || !widget.isActive) {
      return false;
    }
    final currentServer = ref
        .read(terminalSelectedServerProvider)
        .asData
        ?.value;
    return currentServer?.selectionId == server.selectionId &&
        ref.read(terminalSessionScopeIdProvider) == sessionScopeId;
  }

  bool _isCurrentSync(
    int syncGeneration,
    TerminalServerInfo server,
    String sessionScopeId,
  ) {
    return syncGeneration == _syncGeneration &&
        _isCurrentTerminalContext(server, sessionScopeId);
  }

  Future<void> _syncTerminalState({required bool force}) async {
    final service = ref.read(terminalServiceProvider);
    if (service == null) {
      return;
    }

    if (!widget.isActive) {
      _syncKey = null;
      await _sessionController.disconnect(showClosedBanner: false);
      _browserController.resetLoading();
      return;
    }

    final availableServers =
        ref.read(terminalAvailableServersProvider).asData?.value ??
        const <TerminalServerInfo>[];
    final selectedTerminalId = ref.read(selectedTerminalIdProvider);
    final selectedServer = ref
        .read(terminalSelectedServerProvider)
        .asData
        ?.value;
    if (!_didAutoSelectFallback &&
        selectedTerminalId == null &&
        selectedServer != null) {
      _didAutoSelectFallback = true;
      await ref
          .read(terminalSelectionControllerProvider)
          .select(selectedServer);
      return;
    }
    if (selectedServer == null) {
      if (!_didAutoSelectFallback &&
          selectedTerminalId == null &&
          availableServers.isNotEmpty) {
        _didAutoSelectFallback = true;
        await ref
            .read(terminalSelectionControllerProvider)
            .select(availableServers.first);
      } else {
        await _sessionController.disconnect(showClosedBanner: false);
        _browserController.resetLoading();
      }
      return;
    }

    final sessionScopeId = ref.read(terminalSessionScopeIdProvider);
    final nextSyncKey = '${selectedServer.selectionId}::$sessionScopeId';
    if (!force && _syncKey == nextSyncKey) {
      return;
    }
    _syncKey = nextSyncKey;
    final syncGeneration = ++_syncGeneration;

    await _sessionController.disconnect(showClosedBanner: false);
    if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
      return;
    }
    _sessionController.clear();
    ref
        .read(terminalConnectionStateProvider.notifier)
        .set(const TerminalConnectionState.disconnected());

    try {
      final terminalEnabled = await service.isTerminalFeatureEnabled(
        selectedServer,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }
      setState(() => _terminalSupported = terminalEnabled);

      final cwd = await service.getCwd(
        selectedServer,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }
      final initialPath = ensureTerminalDirectoryPath(cwd ?? '/');
      ref.read(terminalCurrentPathProvider.notifier).set(initialPath);

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

      if (ref.read(terminalAutoConnectProvider) && _terminalSupported) {
        await _connect(service, selectedServer, sessionScopeId);
      }
    } catch (_) {
      if (mounted) {
        _showSnackBar(AppLocalizations.of(context)!.terminalFailedToLoadFiles);
      }
    }
  }

  Future<void> _connect(
    TerminalService service,
    TerminalServerInfo server,
    String sessionScopeId,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    await _sessionController.connect(
      service,
      server,
      sessionScopeId: sessionScopeId,
      disconnectedLabel: l10n.terminalDisconnectedStatus,
      onFailure: () {
        if (mounted) {
          _showSnackBar(l10n.terminalFailedToConnect);
        }
      },
    );
  }

  Future<void> _openFullscreen() async {
    if (_fullscreen) {
      return;
    }
    setState(() => _fullscreen = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return;
      }
      await Navigator.of(context, rootNavigator: true).push(
        buildPlatformPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => TerminalFullscreenPage(
            terminal: _sessionController.terminal,
            controller: _sessionController.terminalController,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _fullscreen = false);
      }
    }
  }

  void _handleBrowserFailure(TerminalBrowserFailure failure) {
    if (!mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final message = switch (failure) {
      TerminalBrowserFailure.loadFiles => l10n.terminalFailedToLoadFiles,
      TerminalBrowserFailure.loadPorts => l10n.terminalFailedToLoadPorts,
      TerminalBrowserFailure.download => l10n.terminalDownloadFailed,
      TerminalBrowserFailure.rename => l10n.terminalRenameFailed,
      TerminalBrowserFailure.delete => l10n.terminalDeleteFailed,
      TerminalBrowserFailure.upload => l10n.terminalUploadFailed,
      TerminalBrowserFailure.createFolder => l10n.terminalFolderCreateFailed,
      TerminalBrowserFailure.openPort => l10n.errorMessage,
    };
    _showSnackBar(message);
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(sanitizeUtf16(message))));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final selectedServerAsync = ref.watch(terminalSelectedServerProvider);
    final serversAsync = ref.watch(terminalAvailableServersProvider);
    final connectionState = ref.watch(terminalConnectionStateProvider);
    final currentPath = ref.watch(terminalCurrentPathProvider);
    final entries = ref.watch(terminalEntriesProvider);
    final ports = ref.watch(terminalListeningPortsProvider);
    final searchController = ref.watch(sidebarSearchFieldControllerProvider);

    final selectedServer = selectedServerAsync.asData?.value;
    final noServersConfigured =
        !serversAsync.isLoading &&
        !serversAsync.hasError &&
        (serversAsync.asData?.value.isEmpty ?? false);

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: searchController,
      builder: (context, value, _) {
        final query = value.text.trim().toLowerCase();
        final filteredEntries = query.isEmpty
            ? entries
            : entries
                  .where(
                    (entry) => sanitizeUtf16(
                      entry.displayName,
                    ).toLowerCase().contains(query),
                  )
                  .toList(growable: false);
        final sidebarPanel = ref.watch(terminalSidebarPanelProvider);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: sidebarPanel == TerminalSidebarPanel.console
              ? TerminalConsoleSection(
                  terminal: _sessionController.terminal,
                  terminalController: _sessionController.terminalController,
                  portsScrollController: _portsScrollController,
                  selectedServer: selectedServer,
                  connectionState: connectionState,
                  ports: ports,
                  noServersConfigured: noServersConfigured,
                  loadingPorts: _browserController.loadingPorts,
                  terminalSupported: _terminalSupported,
                  fullscreen: _fullscreen,
                  onConnect:
                      selectedServer == null ||
                          ref.read(terminalServiceProvider) == null
                      ? null
                      : () => unawaited(
                          _connect(
                            ref.read(terminalServiceProvider)!,
                            selectedServer,
                            ref.read(terminalSessionScopeIdProvider),
                          ),
                        ),
                  onDisconnect: () => unawaited(
                    _sessionController.disconnect(showClosedBanner: false),
                  ),
                  onOpenFullscreen: () => unawaited(_openFullscreen()),
                  onOpenPort: (port) =>
                      unawaited(_browserController.openPort(port)),
                )
              : TerminalFilesSection(
                  browserController: _browserController,
                  scrollController: _filesScrollController,
                  selectedServer: selectedServer,
                  currentPath: currentPath,
                  entries: filteredEntries,
                  noServersConfigured: noServersConfigured,
                  loading: _browserController.loadingFiles,
                ),
        );
      },
    );
  }
}

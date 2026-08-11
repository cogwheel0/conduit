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
import '../controllers/terminal_browser_controller.dart';
import '../controllers/terminal_context_controller.dart';
import '../controllers/terminal_controller_gateways.dart';
import '../controllers/terminal_session_controller.dart';
import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
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
  late final TerminalContextController _contextController;

  ProviderSubscription<int>? _refreshSubscription;
  ProviderSubscription<String>? _sessionScopeSubscription;
  ProviderSubscription<AsyncValue<TerminalServerInfo?>>?
  _selectedServerSubscription;
  ProviderSubscription<AsyncValue<List<TerminalServerInfo>>>?
  _singleServerDefaultPanelSubscription;

  bool _fullscreen = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final gateway = RiverpodTerminalControllerGateway(
      ref: ref,
      isActive: () => mounted && widget.isActive,
    );
    _sessionController = TerminalSessionController(
      gateway: gateway,
      isCurrentContext: (server, sessionScopeId) =>
          _contextController.isCurrentContext(server, sessionScopeId),
    );
    _browserController = TerminalBrowserController(
      gateway: gateway,
      platformGateway: const DefaultTerminalBrowserPlatformGateway(),
      isCurrentContext: (server, sessionScopeId) =>
          _contextController.isCurrentContext(server, sessionScopeId),
      onFailure: _handleBrowserFailure,
    );
    _contextController = TerminalContextController(
      gateway: gateway,
      sessionController: _sessionController,
      browserController: _browserController,
      disconnectedLabel: () =>
          AppLocalizations.of(context)!.terminalDisconnectedStatus,
      onFailure: _handleContextFailure,
    );
    _browserController.addListener(_handleControllerChanged);
    _contextController.addListener(_handleControllerChanged);

    _refreshSubscription = ref.listenManual<int>(
      terminalBrowserRefreshTokenProvider,
      (previous, next) {
        if (previous != next && widget.isActive) {
          unawaited(_contextController.reloadBrowser());
        }
      },
    );
    _sessionScopeSubscription = ref.listenManual<String>(
      terminalSessionScopeIdProvider,
      (previous, next) {
        if (widget.isActive) {
          unawaited(_contextController.sync(force: true));
        }
      },
    );
    _selectedServerSubscription = ref
        .listenManual<AsyncValue<TerminalServerInfo?>>(
          terminalSelectedServerProvider,
          (_, next) => next.whenData((_) {
            if (widget.isActive) {
              unawaited(_contextController.sync(force: true));
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
        unawaited(_contextController.sync(force: true));
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
      unawaited(_contextController.sync(force: true));
      return;
    }

    unawaited(_contextController.deactivate());
  }

  @override
  void dispose() {
    _refreshSubscription?.close();
    _sessionScopeSubscription?.close();
    _selectedServerSubscription?.close();
    _singleServerDefaultPanelSubscription?.close();
    _browserController
      ..removeListener(_handleControllerChanged)
      ..dispose();
    _contextController
      ..removeListener(_handleControllerChanged)
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

  void _handleControllerChanged() {
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

  void _handleContextFailure(TerminalContextFailure failure) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    _showSnackBar(switch (failure) {
      TerminalContextFailure.load => l10n.terminalFailedToLoadFiles,
      TerminalContextFailure.connect => l10n.terminalFailedToConnect,
    });
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
                  terminalSupported: _contextController.terminalSupported,
                  fullscreen: _fullscreen,
                  onConnect: selectedServer == null
                      ? null
                      : () => unawaited(_contextController.connect()),
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

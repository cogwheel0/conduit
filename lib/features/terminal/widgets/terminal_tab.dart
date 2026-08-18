import 'dart:async';

import 'package:material_ui/material_ui.dart';
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
import '../controllers/terminal_coordinator.dart';
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

  late final TerminalCoordinator _coordinator;

  bool _fullscreen = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _coordinator = TerminalCoordinator(
      ref: ref,
      isActive: () => mounted && widget.isActive,
      disconnectedLabel: () =>
          AppLocalizations.of(context)!.terminalDisconnectedStatus,
      onBrowserFailure: _handleBrowserFailure,
      onContextFailure: _handleContextFailure,
    );
    _coordinator.addListener(_handleControllerChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _coordinator.start();
    });
    ref.listenManual<String?>(terminalDisplayFileProvider, (_, path) {
      if (path == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_displayFile(path));
      });
    }, fireImmediately: true);
  }

  @override
  void didUpdateWidget(covariant TerminalTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) {
      return;
    }

    if (widget.isActive) {
      _coordinator.activate();
      return;
    }

    _coordinator.deactivate();
  }

  @override
  void dispose() {
    _coordinator
      ..removeListener(_handleControllerChanged)
      ..dispose();
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
            terminal: _coordinator.terminal,
            controller: _coordinator.terminalController,
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
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(sanitizeUtf16(message))));
  }

  Future<void> _displayFile(String requestedPath) async {
    ref.read(terminalDisplayFileProvider.notifier).clear();
    final path = normalizeTerminalPath(requestedPath);
    await _coordinator.navigateTo(parentTerminalPath(path));
    if (!mounted) return;

    final entries = ref.read(terminalEntriesProvider);
    TerminalFileEntry? entry;
    for (final candidate in entries) {
      if (normalizeTerminalPath(candidate.path) == path) {
        entry = candidate;
        break;
      }
    }
    final pathParts = path.split('/').where((part) => part.isNotEmpty).toList();
    entry ??= TerminalFileEntry(
      name: pathParts.isEmpty ? path : pathParts.last,
      path: path,
      isDirectory: false,
    );
    await showTerminalFilePreview(context, _coordinator, entry);
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
                    (entry) =>
                        sanitizeUtf16(entry.displayName)
                            .toLowerCase()
                            .contains(query),
                  )
                  .toList(growable: false);
        final sidebarPanel = ref.watch(terminalSidebarPanelProvider);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: sidebarPanel == TerminalSidebarPanel.console
              ? TerminalConsoleSection(
                  terminal: _coordinator.terminal,
                  terminalController: _coordinator.terminalController,
                  portsScrollController: _portsScrollController,
                  selectedServer: selectedServer,
                  connectionState: connectionState,
                  ports: ports,
                  noServersConfigured: noServersConfigured,
                  loadingPorts: _coordinator.loadingPorts,
                  terminalSupported: _coordinator.terminalSupported,
                  fullscreen: _fullscreen,
                  onConnect: selectedServer == null
                      ? null
                      : () => unawaited(_coordinator.connect()),
                  onDisconnect: () => unawaited(_coordinator.disconnect()),
                  onOpenFullscreen: () => unawaited(_openFullscreen()),
                  onOpenPort: (port) => unawaited(_coordinator.openPort(port)),
                )
              : TerminalFilesSection(
                  coordinator: _coordinator,
                  scrollController: _filesScrollController,
                  selectedServer: selectedServer,
                  currentPath: currentPath,
                  entries: filteredEntries,
                  noServersConfigured: noServersConfigured,
                  loading: _coordinator.loadingFiles,
                ),
        );
      },
    );
  }
}

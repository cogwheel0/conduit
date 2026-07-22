import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/utf16_sanitizer.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';

const _nativeServerActionPrefix = 'server:';

/// Max height of the Material fallback sheet (server picker + Terminal / Files).
const _kTerminalSidebarControlsSheetMaxHeightFraction = 0.46;

/// Sidebar Terminal tab: view (console vs files) + optional server picker,
/// opened from the app bar overflow action.
///
/// On iOS uses [NativeSheetBridge] when server data is ready; otherwise falls
/// back to a Material bottom sheet. The Material sheet closes after each
/// selection.
Future<void> showTerminalSidebarControlsSheet(BuildContext context) async {
  if (Platform.isIOS) {
    try {
      final usedNative = await _tryPresentNativeTerminalSidebarControlsSheet(
        context,
      );
      if (usedNative) {
        return;
      }
    } catch (_) {
      if (!context.mounted) {
        return;
      }
    }
  }

  if (!context.mounted) {
    return;
  }

  final viewSize = MediaQuery.sizeOf(context);
  final maxSheetHeight =
      viewSize.height * _kTerminalSidebarControlsSheetMaxHeightFraction;

  await ThemedSheets.showSurface<void>(
    context: context,
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: maxSheetHeight),
    padding: EdgeInsets.zero,
    builder: (_) => const TerminalSidebarControlsSheet(),
  );
}

Future<bool> _tryPresentNativeTerminalSidebarControlsSheet(
  BuildContext context,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final l10n = AppLocalizations.of(context)!;
  final serversAsync = container.read(terminalAvailableServersProvider);

  if (serversAsync.isLoading) {
    return false;
  }

  if (serversAsync.hasError) {
    await NativeSheetBridge.instance.presentSheet(
      root: NativeSheetDetailConfig(
        id: 'terminal-sidebar-controls',
        title: l10n.sidebarTerminalTab,
        maxHeightFraction: _kTerminalSidebarControlsSheetMaxHeightFraction,
        items: [
          NativeSheetItemConfig(
            id: 'terminal-servers-error',
            title: l10n.errorMessage,
            sfSymbol: 'exclamationmark.triangle',
            kind: NativeSheetItemKind.info,
          ),
        ],
      ),
      rethrowErrors: true,
    );
    return true;
  }

  final servers = serversAsync.requireValue;
  if (servers.isEmpty) {
    await NativeSheetBridge.instance.presentSheet(
      root: NativeSheetDetailConfig(
        id: 'terminal-sidebar-controls',
        title: l10n.sidebarTerminalTab,
        maxHeightFraction: _kTerminalSidebarControlsSheetMaxHeightFraction,
        items: [
          NativeSheetItemConfig(
            id: 'terminal-no-servers',
            title: l10n.terminalNoServersConfigured,
            sfSymbol: 'exclamationmark.triangle',
            kind: NativeSheetItemKind.info,
          ),
        ],
      ),
      rethrowErrors: true,
    );
    return true;
  }

  final sections = <NativeSheetSectionConfig>[
    if (servers.length > 1)
      NativeSheetSectionConfig(
        title: l10n.terminalSelectServer,
        items: [
          for (final s in servers)
            NativeSheetItemConfig(
              id: '$_nativeServerActionPrefix${Uri.encodeComponent(s.selectionId)}',
              title: sanitizeUtf16(s.displayName),
              sfSymbol: s.isSystem
                  ? 'server.rack'
                  : 'chevron.left.forwardslash.chevron.right',
            ),
        ],
      ),
    NativeSheetSectionConfig(
      items: [
        NativeSheetItemConfig(
          id: 'panel-console',
          title: l10n.terminal,
          sfSymbol: 'terminal',
        ),
        NativeSheetItemConfig(
          id: 'panel-files',
          title: l10n.files,
          sfSymbol: 'folder',
        ),
      ],
    ),
  ];

  final result = await NativeSheetBridge.instance.presentSheet(
    root: NativeSheetDetailConfig(
      id: 'terminal-sidebar-controls',
      title: l10n.sidebarTerminalTab,
      maxHeightFraction: _kTerminalSidebarControlsSheetMaxHeightFraction,
      sections: sections,
    ),
    rethrowErrors: true,
  );

  if (!context.mounted) {
    return true;
  }

  _applyNativeTerminalControlsResult(container, result?.actionId);
  return true;
}

void _applyNativeTerminalControlsResult(
  ProviderContainer container,
  String? actionId,
) {
  if (actionId == null || actionId.isEmpty) {
    return;
  }
  if (actionId.startsWith(_nativeServerActionPrefix)) {
    final encoded = actionId.substring(_nativeServerActionPrefix.length);
    final selectionId = Uri.decodeComponent(encoded);
    final servers = container
        .read(terminalAvailableServersProvider)
        .asData
        ?.value;
    if (servers == null) {
      return;
    }
    for (final s in servers) {
      if (s.selectionId == selectionId) {
        unawaited(
          container.read(terminalSelectionControllerProvider).select(s),
        );
        return;
      }
    }
    return;
  }
  if (actionId == 'panel-console') {
    container
        .read(terminalSidebarPanelProvider.notifier)
        .setPanel(TerminalSidebarPanel.console);
    return;
  }
  if (actionId == 'panel-files') {
    container
        .read(terminalSidebarPanelProvider.notifier)
        .setPanel(TerminalSidebarPanel.files);
  }
}

class TerminalSidebarControlsSheet extends ConsumerWidget {
  const TerminalSidebarControlsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final panel = ref.watch(terminalSidebarPanelProvider);
    final serversAsync = ref.watch(terminalAvailableServersProvider);
    final selectedAsync = ref.watch(terminalSelectedServerProvider);
    final selectedServer = selectedAsync.asData?.value;
    final controller = ref.read(terminalSelectionControllerProvider);

    final servers = serversAsync.asData?.value ?? const <TerminalServerInfo>[];
    final showServerPicker =
        serversAsync.isLoading ||
        serversAsync.hasError ||
        servers.isEmpty ||
        servers.length > 1;

    void closeSheet() {
      if (context.mounted) {
        Navigator.of(context).maybePop();
      }
    }

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.only(bottom: Spacing.sm),
        children: [
          if (showServerPicker) ...[
            Padding(
              padding: const EdgeInsets.only(
                top: Spacing.md,
                bottom: Spacing.lg,
                left: Spacing.lg,
                right: Spacing.lg,
              ),
              child: Center(
                child: _ServerDropdownBlock(
                  l10n: l10n,
                  theme: theme,
                  serversAsync: serversAsync,
                  servers: servers,
                  selectedServer: selectedServer,
                  onChanged: (id) {
                    final server = servers.firstWhere(
                      (s) => s.selectionId == id,
                    );
                    unawaited(controller.select(server));
                    closeSheet();
                  },
                ),
              ),
            ),
            const Divider(height: 1),
          ],
          ListTile(
            leading: const Icon(Icons.terminal_rounded),
            title: Text(l10n.terminal),
            trailing: panel == TerminalSidebarPanel.console
                ? Icon(Icons.check_rounded, color: theme.buttonPrimary)
                : null,
            onTap: () {
              ref
                  .read(terminalSidebarPanelProvider.notifier)
                  .setPanel(TerminalSidebarPanel.console);
              closeSheet();
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(l10n.files),
            trailing: panel == TerminalSidebarPanel.files
                ? Icon(Icons.check_rounded, color: theme.buttonPrimary)
                : null,
            onTap: () {
              ref
                  .read(terminalSidebarPanelProvider.notifier)
                  .setPanel(TerminalSidebarPanel.files);
              closeSheet();
            },
          ),
        ],
      ),
    );
  }
}

class _ServerDropdownBlock extends StatelessWidget {
  const _ServerDropdownBlock({
    required this.l10n,
    required this.theme,
    required this.serversAsync,
    required this.servers,
    required this.selectedServer,
    required this.onChanged,
  });

  final AppLocalizations l10n;
  final ConduitThemeExtension theme;
  final AsyncValue<List<TerminalServerInfo>> serversAsync;
  final List<TerminalServerInfo> servers;
  final TerminalServerInfo? selectedServer;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (serversAsync.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.md),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (serversAsync.hasError) {
      return Text(
        l10n.errorMessage,
        textAlign: TextAlign.center,
        style: AppTypography.bodySmallStyle.copyWith(
          color: theme.textSecondary,
        ),
      );
    }

    if (servers.isEmpty) {
      return Text(
        l10n.terminalNoServersConfigured,
        textAlign: TextAlign.center,
        style: AppTypography.bodySmallStyle.copyWith(
          color: theme.textSecondary,
        ),
      );
    }

    final textStyle = AppTypography.titleSmallStyle.copyWith(
      color: theme.textPrimary,
    );

    final items = servers
        .map(
          (s) => DropdownMenuItem<String>(
            value: s.selectionId,
            child: Text(
              sanitizeUtf16(s.displayName),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        )
        .toList(growable: false);

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: selectedServer?.selectionId,
        hint: Text(
          l10n.terminalSelectServer,
          style: textStyle,
          overflow: TextOverflow.ellipsis,
        ),
        style: textStyle,
        icon: Icon(Icons.expand_more_rounded, color: theme.textPrimary),
        dropdownColor: theme.surfaceBackground,
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(AppBorderRadius.standard),
        items: items,
        onChanged: (next) {
          if (next != null) {
            onChanged(next);
          }
        },
      ),
    );
  }
}

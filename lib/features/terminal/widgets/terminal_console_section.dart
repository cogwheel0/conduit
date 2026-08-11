import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/utils/locale_display_formatters.dart';
import '../../../shared/utils/platform_scroll_physics.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/utils/utf16_sanitizer.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../../shared/widgets/utility_components.dart';
import '../models/terminal_models.dart';
import 'terminal_connection_badge.dart';
import 'terminal_console_surface.dart';

class TerminalConsoleSection extends StatefulWidget {
  const TerminalConsoleSection({
    required this.terminal,
    required this.terminalController,
    required this.portsScrollController,
    required this.selectedServer,
    required this.connectionState,
    required this.ports,
    required this.noServersConfigured,
    required this.loadingPorts,
    required this.terminalSupported,
    required this.fullscreen,
    required this.onConnect,
    required this.onDisconnect,
    required this.onOpenFullscreen,
    required this.onOpenPort,
    super.key,
  });

  final Terminal terminal;
  final TerminalController terminalController;
  final ScrollController portsScrollController;
  final TerminalServerInfo? selectedServer;
  final TerminalConnectionState connectionState;
  final List<TerminalListeningPort> ports;
  final bool noServersConfigured;
  final bool loadingPorts;
  final bool terminalSupported;
  final bool fullscreen;
  final VoidCallback? onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onOpenFullscreen;
  final ValueChanged<TerminalListeningPort> onOpenPort;

  @override
  State<TerminalConsoleSection> createState() => _TerminalConsoleSectionState();
}

class _TerminalConsoleSectionState extends State<TerminalConsoleSection> {
  bool _portsCollapsed = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: EdgeInsets.only(
        top: sidebarTabContentTopPadding(context),
        bottom: sidebarTabContentBottomPadding(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _buildTerminalPane(l10n)),
          const SizedBox(height: Spacing.md),
          _buildPortsToggleHeader(l10n),
          if (!_portsCollapsed) ...[
            const SizedBox(height: Spacing.xs),
            _buildPortsSection(l10n),
          ],
        ],
      ),
    );
  }

  Widget _buildTerminalPane(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    final connectionState = widget.connectionState;
    final selectedServer = widget.selectedServer;

    return ConduitCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.sm,
              Spacing.md,
              Spacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.terminal,
                    style: AppTypography.labelStyle.copyWith(
                      color: theme.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TerminalConnectionBadge(state: connectionState),
                if (selectedServer != null) ...[
                  const SizedBox(width: Spacing.xs),
                  if (connectionState.isConnected ||
                      connectionState.isConnecting)
                    _TerminalIconActionButton(
                      tooltip: l10n.terminalDisconnectAction,
                      iosIcon: Icons.link_off_rounded,
                      materialIcon: Icons.link_off_rounded,
                      compact: true,
                      onPressed: widget.onDisconnect,
                    )
                  else
                    _TerminalIconActionButton(
                      tooltip: l10n.terminalConnectAction,
                      iosIcon: CupertinoIcons.link,
                      materialIcon: Icons.link_rounded,
                      compact: true,
                      onPressed: widget.onConnect,
                    ),
                  const SizedBox(width: Spacing.xs),
                  _TerminalIconActionButton(
                    tooltip: l10n.terminalExpandAction,
                    iosIcon: CupertinoIcons.fullscreen,
                    materialIcon: Icons.fullscreen_rounded,
                    compact: true,
                    onPressed: widget.terminalSupported
                        ? widget.onOpenFullscreen
                        : null,
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: widget.fullscreen
                ? _buildFullscreenPlaceholder(l10n)
                : TerminalConsoleSurface(
                    terminal: widget.terminal,
                    controller: widget.terminalController,
                    connected: connectionState.isConnected,
                    overlayMessage: widget.noServersConfigured
                        ? l10n.terminalNoServersConfigured
                        : selectedServer == null
                        ? l10n.terminalSelectServer
                        : !widget.terminalSupported
                        ? l10n.terminalFeatureDisabled
                        : null,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFullscreenPlaceholder(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(AppBorderRadius.standard),
      ),
      child: SizedBox.expand(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onOpenFullscreen,
          child: ColoredBox(
            color: theme.codeBackground,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      UiUtils.platformIcon(
                        ios: CupertinoIcons.fullscreen,
                        android: Icons.fullscreen_rounded,
                      ),
                      color: theme.codeText,
                      size: IconSize.medium,
                    ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      l10n.terminalReopenFullscreen,
                      textAlign: TextAlign.center,
                      style: AppTypography.bodyMediumStyle.copyWith(
                        color: theme.codeText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPortsToggleHeader(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    final labelStyle = AppTypography.labelStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w700,
    );

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _portsCollapsed = !_portsCollapsed),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
          child: Row(
            children: [
              Icon(
                _portsCollapsed
                    ? Icons.chevron_right_rounded
                    : Icons.expand_more_rounded,
                size: IconSize.medium,
                color: theme.iconSecondary,
              ),
              const SizedBox(width: Spacing.xs),
              Text(l10n.terminalPortsToggle, style: labelStyle),
              if (widget.ports.isNotEmpty) ...[
                const SizedBox(width: Spacing.xs),
                Text(
                  '(${LocaleDisplayFormatters.integer(context, widget.ports.length)})',
                  style: labelStyle.copyWith(
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortsSection(AppLocalizations l10n) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
      child: CustomScrollView(
        key: const PageStorageKey<String>('terminal_tab_ports_scroll'),
        controller: widget.portsScrollController,
        primary: false,
        shrinkWrap: true,
        physics: platformAlwaysScrollablePhysics(context),
        slivers: [
          if (widget.loadingPorts)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            )
          else if (widget.ports.isEmpty)
            SliverToBoxAdapter(child: _TerminalInfoCard(l10n.terminalNoPorts))
          else
            DecoratedSliver(
              decoration: BoxDecoration(
                color: context.conduitTheme.surfaceContainer.withValues(
                  alpha: 0.68,
                ),
                borderRadius: BorderRadius.circular(AppBorderRadius.card),
                border: Border.all(color: context.conduitTheme.cardBorder),
              ),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildPortTile(
                    l10n,
                    widget.ports[index],
                    showDivider: index != widget.ports.length - 1,
                  ),
                  childCount: widget.ports.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPortTile(
    AppLocalizations l10n,
    TerminalListeningPort port, {
    required bool showDivider,
  }) {
    final subtitleParts = <String>[
      if (port.process != null && port.process!.trim().isNotEmpty)
        port.process!,
      if (port.pid != null) 'PID ${port.pid}',
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                bottom: BorderSide(
                  color: context.conduitTheme.dividerColor,
                  width: BorderWidth.thin,
                ),
              )
            : null,
      ),
      child: UtilityRow(
        preserveTrailingSemantics: true,
        padding: const EdgeInsets.all(Spacing.md),
        onTap: () => widget.onOpenPort(port),
        leading: Icon(
          UiUtils.platformIcon(
            ios: CupertinoIcons.globe,
            android: Icons.lan_outlined,
          ),
        ),
        title: 'localhost:${port.port}',
        subtitle: subtitleParts.isEmpty
            ? null
            : sanitizeUtf16(subtitleParts.join(' • ')),
        trailing: _TerminalIconActionButton(
          tooltip: l10n.terminalOpenInBrowserAction,
          iosIcon: CupertinoIcons.arrow_up_right,
          materialIcon: Icons.open_in_new_rounded,
          onPressed: () => widget.onOpenPort(port),
        ),
      ),
    );
  }
}

class _TerminalIconActionButton extends StatelessWidget {
  const _TerminalIconActionButton({
    required this.tooltip,
    required this.iosIcon,
    required this.materialIcon,
    required this.onPressed,
    this.compact = false,
  });

  final String tooltip;
  final IconData iosIcon;
  final IconData materialIcon;
  final VoidCallback? onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final iconSize = compact ? IconSize.sm : IconSize.medium;
    final minSide = compact ? TouchTarget.micro : TouchTarget.medium;
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    return AdaptiveTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        child: AdaptiveButton.child(
          onPressed: onPressed,
          enabled: onPressed != null,
          style: usesOpaqueFallback
              ? AdaptiveButtonStyle.filled
              : AdaptiveButtonStyle.glass,
          color: usesOpaqueFallback ? theme.surfaceContainerHighest : null,
          size: compact ? AdaptiveButtonSize.small : AdaptiveButtonSize.medium,
          minSize: Size(minSide, minSide),
          padding: compact
              ? const EdgeInsets.all(Spacing.xxs)
              : EdgeInsets.zero,
          borderRadius: BorderRadius.circular(AppBorderRadius.circular),
          useSmoothRectangleBorder: false,
          child: Icon(
            UiUtils.platformIcon(ios: iosIcon, android: materialIcon),
            size: iconSize,
            color: onPressed != null ? theme.iconSecondary : theme.iconDisabled,
          ),
        ),
      ),
    );
  }
}

class _TerminalInfoCard extends StatelessWidget {
  const _TerminalInfoCard(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return InsetGroupedSection(
      padding: const EdgeInsets.all(Spacing.md),
      child: Text(
        sanitizeUtf16(message),
        style: AppTypography.bodyMediumStyle.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
    );
  }
}

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../core/services/raster_media_policy.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/utils/locale_display_formatters.dart';
import '../../../shared/utils/platform_scroll_physics.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/utils/utf16_sanitizer.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../controllers/terminal_browser_controller.dart';
import '../models/terminal_models.dart';
import '../services/terminal_service.dart';

class TerminalFilesSection extends StatelessWidget {
  const TerminalFilesSection({
    required this.browserController,
    required this.scrollController,
    required this.selectedServer,
    required this.currentPath,
    required this.entries,
    required this.noServersConfigured,
    required this.loading,
    super.key,
  });

  final TerminalBrowserController browserController;
  final ScrollController scrollController;
  final TerminalServerInfo? selectedServer;
  final String currentPath;
  final List<TerminalFileEntry> entries;
  final bool noServersConfigured;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final filesLabelStyle = AppTypography.labelStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w700,
    );

    return CustomScrollView(
      key: const PageStorageKey<String>('terminal_tab_files_scroll'),
      controller: scrollController,
      primary: false,
      physics: platformAlwaysScrollablePhysics(context),
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(height: sidebarTabContentTopPadding(context)),
        ),
        SliverToBoxAdapter(child: _buildPathCard(context, l10n)),
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
        SliverToBoxAdapter(child: Text(l10n.files, style: filesLabelStyle)),
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
        if (loading)
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
        else if (selectedServer == null)
          SliverToBoxAdapter(
            child: _TerminalInfoCard(
              noServersConfigured
                  ? l10n.terminalNoServersConfigured
                  : l10n.terminalSelectServer,
            ),
          )
        else if (entries.isEmpty)
          SliverToBoxAdapter(child: _TerminalInfoCard(l10n.terminalNoFiles))
        else
          DecoratedSliver(
            decoration: BoxDecoration(
              color: theme.surfaceContainer.withValues(alpha: 0.68),
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              border: Border.all(color: theme.cardBorder),
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildEntryTile(
                  context,
                  l10n,
                  entries[index],
                  showDivider: index != entries.length - 1,
                ),
                childCount: entries.length,
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(height: sidebarTabContentBottomPadding(context)),
        ),
      ],
    );
  }

  Widget _buildPathCard(BuildContext context, AppLocalizations l10n) {
    final theme = context.conduitTheme;
    final canInteract = selectedServer != null;
    final parentPath = parentTerminalPath(currentPath);
    final canGoUp = canInteract && parentPath != currentPath;

    return InsetGroupedSection(
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _TerminalIconActionButton(
            tooltip: l10n.back,
            iosIcon: CupertinoIcons.arrow_up,
            materialIcon: Icons.arrow_upward_rounded,
            onPressed: canGoUp
                ? () => browserController.navigateTo(parentPath)
                : null,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.terminalCurrentPathLabel,
                  style: AppTypography.labelStyle.copyWith(
                    color: theme.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                SelectableText(
                  sanitizeUtf16(currentPath),
                  style: AppTypography.codeStyle.copyWith(
                    color: theme.codeText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.xs),
          if (canInteract)
            AdaptiveTooltip(
              message: l10n.more,
              child: AdaptivePopupMenuButton.icon<String>(
                icon: conduitAdaptivePopupMenuIcon(
                  iosSymbol: 'ellipsis',
                  materialIcon: Icons.more_horiz_rounded,
                ),
                items: _buildPathDirectoryMenuItems(l10n),
                onSelected: (_, selected) =>
                    _handlePathAction(context, l10n, selected.value),
                buttonStyle: conduitSupportsNativeGlass()
                    ? PopupButtonStyle.glass
                    : PopupButtonStyle.plain,
                tint: theme.iconSecondary,
                size: TouchTarget.medium,
              ),
            )
          else
            SizedBox(width: TouchTarget.medium, height: TouchTarget.medium),
        ],
      ),
    );
  }

  Future<void> _handlePathAction(
    BuildContext context,
    AppLocalizations l10n,
    String? action,
  ) async {
    switch (action) {
      case 'upload':
        await browserController.pickAndUploadFile();
      case 'new-folder':
        final folderName = await ThemedDialogs.promptTextInput(
          context,
          title: l10n.newFolder,
          hintText: l10n.terminalFolderNameHint,
        );
        if (folderName != null && context.mounted) {
          await browserController.createFolder(folderName);
        }
      case 'home':
        await browserController.navigateTo('/');
      case 'refresh':
        await browserController.reload();
      case null:
        return;
    }
  }

  Widget _buildEntryTile(
    BuildContext context,
    AppLocalizations l10n,
    TerminalFileEntry entry, {
    required bool showDivider,
  }) {
    final subtitle = entry.isDirectory
        ? entry.path
        : [
            if (entry.size != null)
              LocaleDisplayFormatters.bytes(context, entry.size!),
            if (entry.modifiedAt != null)
              MaterialLocalizations.of(
                context,
              ).formatShortDate(entry.modifiedAt!),
          ].join(' • ');

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
        onTap: () => _openEntry(context, l10n, entry),
        leading: Icon(
          entry.isDirectory
              ? UiUtils.folderIcon
              : UiUtils.platformIcon(
                  ios: CupertinoIcons.doc,
                  android: Icons.insert_drive_file_outlined,
                ),
        ),
        title: sanitizeUtf16(entry.displayName),
        subtitle: subtitle.isEmpty ? null : sanitizeUtf16(subtitle),
        trailing: AdaptiveTooltip(
          message: l10n.more,
          child: AdaptivePopupMenuButton.icon<String>(
            icon: conduitAdaptivePopupMenuIcon(
              iosSymbol: 'ellipsis',
              materialIcon: Icons.more_horiz_rounded,
            ),
            items: _buildEntryMenuItems(l10n, entry),
            onSelected: (_, selected) =>
                _handleEntryAction(context, l10n, entry, selected.value),
            buttonStyle: conduitSupportsNativeGlass()
                ? PopupButtonStyle.glass
                : PopupButtonStyle.plain,
            size: TouchTarget.medium,
          ),
        ),
      ),
    );
  }

  Future<void> _openEntry(
    BuildContext context,
    AppLocalizations l10n,
    TerminalFileEntry entry,
  ) async {
    if (entry.isDirectory) {
      await browserController.navigateTo(entry.path);
      return;
    }

    final preview = await browserController.readEntry(entry);
    if (preview == null || !context.mounted) {
      return;
    }
    await ThemedDialogs.show<void>(
      context,
      title: sanitizeUtf16(entry.displayName),
      content: _buildPreviewContent(context, l10n, preview),
      actions: [
        ConduitTextButton(
          text: l10n.close,
          onPressed: () => Navigator.of(context).pop(),
        ),
        ConduitTextButton(
          text: l10n.download,
          onPressed: () {
            Navigator.of(context).pop();
            browserController.downloadEntry(entry);
          },
          isPrimary: true,
        ),
      ],
    );
  }

  Future<void> _handleEntryAction(
    BuildContext context,
    AppLocalizations l10n,
    TerminalFileEntry entry,
    String? action,
  ) async {
    switch (action) {
      case 'download':
        await browserController.downloadEntry(entry);
      case 'rename':
        final newName = await ThemedDialogs.promptTextInput(
          context,
          title: l10n.rename,
          hintText: l10n.rename,
          initialValue: sanitizeUtf16(entry.name),
        );
        if (newName != null && context.mounted) {
          await browserController.renameEntry(entry, newName);
        }
      case 'delete':
        final confirmed = await ThemedDialogs.confirm(
          context,
          title: l10n.delete,
          message: sanitizeUtf16(entry.displayName),
          isDestructive: true,
        );
        if (confirmed && context.mounted) {
          await browserController.deleteEntry(entry);
        }
      case null:
        return;
    }
  }

  Widget _buildPreviewContent(
    BuildContext context,
    AppLocalizations l10n,
    TerminalFileReadResult preview,
  ) {
    final theme = context.conduitTheme;
    if (preview.isText) {
      return SizedBox(
        width: 520,
        height: 360,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.codeBackground,
            borderRadius: BorderRadius.circular(AppBorderRadius.standard),
            border: Border.all(color: theme.codeBorder),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.md),
            child: SelectableText(
              sanitizeUtf16(preview.text ?? ''),
              style: AppTypography.codeStyle.copyWith(color: theme.codeText),
            ),
          ),
        ),
      );
    }

    if (preview.isImage && preview.bytes != null) {
      final decodeTarget = RasterMediaPolicy.forBox(
        context,
        profile: RasterDecodeProfile.inline,
        logicalWidth: 520,
        logicalHeight: 360,
      );
      return SizedBox(
        width: 520,
        height: 360,
        child: InteractiveViewer(
          child: Image(
            image: RasterMediaPolicy.resizeProvider(
              MemoryImage(preview.bytes!),
              decodeTarget,
            ),
            fit: BoxFit.contain,
          ),
        ),
      );
    }

    return SizedBox(
      width: 420,
      child: Text(
        l10n.terminalPreviewUnavailable,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
    );
  }

  List<AdaptivePopupMenuEntry> _buildPathDirectoryMenuItems(
    AppLocalizations l10n,
  ) {
    return [
      AdaptivePopupMenuItem<String>(
        value: 'upload',
        label: l10n.terminalUploadAction,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'arrow.up.doc',
          materialIcon: Icons.upload_file_rounded,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'new-folder',
        label: l10n.newFolder,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'folder.badge.plus',
          materialIcon: Icons.create_new_folder_outlined,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'home',
        label: l10n.terminalHomeAction,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'house',
          materialIcon: Icons.home_outlined,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'refresh',
        label: l10n.retry,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'arrow.clockwise',
          materialIcon: Icons.refresh_rounded,
        ),
      ),
    ];
  }

  List<AdaptivePopupMenuEntry> _buildEntryMenuItems(
    AppLocalizations l10n,
    TerminalFileEntry entry,
  ) {
    return [
      if (!entry.isDirectory)
        AdaptivePopupMenuItem<String>(
          value: 'download',
          label: l10n.download,
          icon: conduitAdaptivePopupMenuIcon(
            iosSymbol: 'square.and.arrow.down',
            materialIcon: Icons.download_outlined,
          ),
        ),
      AdaptivePopupMenuItem<String>(
        value: 'rename',
        label: l10n.rename,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'pencil',
          materialIcon: Icons.edit_outlined,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'delete',
        label: l10n.delete,
        isDestructive: true,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'trash',
          materialIcon: Icons.delete_outline,
        ),
      ),
    ];
  }
}

class _TerminalIconActionButton extends StatelessWidget {
  const _TerminalIconActionButton({
    required this.tooltip,
    required this.iosIcon,
    required this.materialIcon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData iosIcon;
  final IconData materialIcon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
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
          size: AdaptiveButtonSize.medium,
          minSize: const Size(TouchTarget.medium, TouchTarget.medium),
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(AppBorderRadius.circular),
          useSmoothRectangleBorder: false,
          child: Icon(
            UiUtils.platformIcon(ios: iosIcon, android: materialIcon),
            size: IconSize.medium,
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

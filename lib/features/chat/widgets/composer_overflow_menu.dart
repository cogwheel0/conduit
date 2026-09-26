import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/horizontal_gesture_ownership.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../../shared/widgets/horizontal_overflow_fade.dart';

import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';

import '../../terminal/providers/terminal_providers.dart';

import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';

import '../providers/chat_providers.dart';
import 'composer_overflow_items.dart';

import 'package:conduit/l10n/app_localizations.dart';

/// A reusable toggle tile widget used in the composer overflow sheet.
class ToggleTile extends StatelessWidget {
  const ToggleTile({
    super.key,
    required this.glyph,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onToggle,
    required this.theme,
  });

  final Widget glyph;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onToggle;
  final ConduitThemeExtension theme;

  @override
  Widget build(BuildContext context) {
    // A flat menu row: plain glyph, regular-weight title, and a
    // checkmark only while the option is on.
    void handleTap() {
      ConduitHaptics.selectionClick();
      onToggle();
    }

    // The labelled node replaces the InkWell's, so it must carry the tap.
    return Semantics(
      button: true,
      toggled: selected,
      label: title,
      hint: (subtitle?.isEmpty ?? true) ? null : subtitle,
      excludeSemantics: true,
      onTap: handleTap,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: handleTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xs,
              vertical: Spacing.xs + Spacing.xxs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                glyph,
                const SizedBox(width: Spacing.sm + Spacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppTypography.bodyMediumStyle.copyWith(
                          color: theme.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.labelSmallStyle.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                SizedBox(
                  width: IconSize.small,
                  child: selected
                      ? Icon(
                          Platform.isIOS
                              ? CupertinoIcons.checkmark_alt
                              : Icons.check_rounded,
                          color: theme.textPrimary,
                          size: IconSize.small,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Inserts [SizedBox] spacers of [gap] height between [children].
List<Widget> withVerticalSpacing(List<Widget> children, double gap) {
  if (children.length <= 1) return List<Widget>.from(children);
  final spaced = <Widget>[];
  for (var i = 0; i < children.length; i++) {
    spaced.add(children[i]);
    if (i != children.length - 1) spaced.add(SizedBox(height: gap));
  }
  return spaced;
}

/// Inserts [SizedBox] spacers of [gap] width between [children].
List<Widget> withHorizontalSpacing(List<Widget> children, double gap) {
  if (children.length <= 1) return List<Widget>.from(children);
  final spaced = <Widget>[];
  for (var i = 0; i < children.length; i++) {
    spaced.add(children[i]);
    if (i != children.length - 1) spaced.add(SizedBox(width: gap));
  }
  return spaced;
}

/// Keyboard-height attachment and overflow panel for the chat composer.
///
/// The panel intentionally follows the compact interaction used by messaging
/// apps: attachment actions stay in a horizontally scrolling strip while
/// secondary toggles and tools scroll vertically below it.
class ComposerAttachmentKeyboard extends ConsumerStatefulWidget {
  const ComposerAttachmentKeyboard({
    super.key,
    this.localAttachmentsOnly = false,
    this.height = 300,
    this.onDismiss,
    this.onFileAttachment,
    this.onServerFileAttachment,
    this.onImageAttachment,
    this.onCameraCapture,
    this.onWebAttachment,
    this.onMcpContent,
  });

  /// Restricts the sheet to device-local attachment actions supplied by the
  /// caller. Used by backends such as Hermes that cannot resolve OpenWebUI
  /// server files, web pages, feature toggles, tools, integrations, or filters.
  final bool localAttachmentsOnly;
  final double height;
  final VoidCallback? onDismiss;
  final VoidCallback? onFileAttachment;
  final VoidCallback? onServerFileAttachment;
  final VoidCallback? onImageAttachment;
  final VoidCallback? onCameraCapture;
  final VoidCallback? onWebAttachment;
  final VoidCallback? onMcpContent;

  @override
  ConsumerState<ComposerAttachmentKeyboard> createState() =>
      _ComposerAttachmentKeyboardState();
}

class _ComposerAttachmentKeyboardState
    extends ConsumerState<ComposerAttachmentKeyboard> {
  Future<Map<String, dynamic>?>? _userSettingsFuture;

  Future<Map<String, dynamic>?> _loadUserSettings() async {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return null;
    }

    try {
      return await api.getUserSettings();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final selectedModel = ref.watch(selectedModelProvider);
    final directBinding = selectedModel == null
        ? null
        : ref.watch(directModelRegistryProvider).resolve(selectedModel);
    final directMode = directBinding != null;
    final directToolsAvailable = directBindingSupportsLocalMcp(directBinding);
    final restrictedMode = directMode || widget.localAttachmentsOnly;
    // Direct and local-only backends have no OpenWebUI integrations to
    // discover. Resolve the request lazily because direct provenance is only
    // available once providers can be read during build.
    final userSettingsFuture = restrictedMode
        ? null
        : (_userSettingsFuture ??= _loadUserSettings());
    final attachmentItems =
        buildComposerOverflowAttachmentItems(
          l10n: l10n,
          attachmentAvailability: ComposerOverflowAttachmentAvailability(
            file: widget.onFileAttachment != null,
            serverFile:
                !restrictedMode && widget.onServerFileAttachment != null,
            photo: widget.onImageAttachment != null,
            camera: widget.onCameraCapture != null,
            web: !restrictedMode && widget.onWebAttachment != null,
            mcpContent: directMode && widget.onMcpContent != null,
          ),
        ).where((item) {
          if (widget.localAttachmentsOnly) {
            return item.enabled &&
                (item.id == ComposerOverflowActionIds.file ||
                    item.id == ComposerOverflowActionIds.photo ||
                    item.id == ComposerOverflowActionIds.camera);
          }
          if (!directMode) {
            return true;
          }
          return item.enabled &&
              (item.id == ComposerOverflowActionIds.file ||
                  item.id == ComposerOverflowActionIds.photo ||
                  item.id == ComposerOverflowActionIds.camera ||
                  item.id == ComposerOverflowActionIds.mcpContent);
        });

    final attachments = attachmentItems
        .map(
          (item) =>
              _buildAction(item: item, onTap: _attachmentHandlerFor(item.id)),
        )
        .toList();

    // Trusted direct providers can expose Conduit-managed server tools even
    // though they cannot use OpenWebUI-managed tools.
    final webSearchAvailable =
        !widget.localAttachmentsOnly && ref.watch(webSearchAvailableProvider);
    final webSearchEnabled =
        !widget.localAttachmentsOnly && ref.watch(webSearchEnabledProvider);
    final imageGenAvailable =
        !widget.localAttachmentsOnly &&
        ref.watch(imageGenerationAvailableProvider);
    final imageGenEnabled =
        !widget.localAttachmentsOnly &&
        ref.watch(imageGenerationEnabledProvider);
    final featureTiles =
        buildComposerOverflowFeatureItems(
          l10n: l10n,
          webSearchAvailable: webSearchAvailable,
          webSearchEnabled: webSearchEnabled,
          imageGenerationAvailable: imageGenAvailable,
          imageGenerationEnabled: imageGenEnabled,
        ).map((item) {
          return _buildOverflowItemTile(
            item: item,
            onChanged: (selected) {
              setComposerOverflowSelection(
                ref,
                actionId: item.id,
                selected: selected,
              );
            },
          );
        }).toList();

    final selectedToolIds = widget.localAttachmentsOnly
        ? const <String>[]
        : ref.watch(selectedToolIdsProvider);
    final selectedTerminalId = restrictedMode
        ? null
        : ref.watch(selectedTerminalIdProvider);
    final availableTerminalServersAsync = restrictedMode
        ? null
        : ref.watch(terminalAvailableServersProvider);
    final toolsAsync = widget.localAttachmentsOnly
        ? null
        : directMode
        ? directToolsAvailable
              ? ref.watch(directMcpToolsProvider)
              : const AsyncData<List<Tool>>([])
        : ref.watch(toolsListProvider);
    final toolsSection = widget.localAttachmentsOnly
        ? const SizedBox.shrink()
        : toolsAsync!.when(
            data: (tools) {
              final toolItems = buildComposerOverflowToolItems(
                availableTools: tools,
                selectedToolIds: selectedToolIds,
              );
              if (toolItems.isEmpty) {
                return _buildInfoCard(l10n.noToolsAvailable);
              }
              final tiles = toolItems.map((item) {
                return _buildOverflowItemTile(
                  item: item,
                  onChanged: (selected) {
                    setComposerOverflowSelection(
                      ref,
                      actionId: item.id,
                      selected: selected,
                    );
                  },
                );
              }).toList();
              return Column(children: withVerticalSpacing(tiles, Spacing.xxs));
            },
            loading: () => directMode
                ? const SizedBox.shrink()
                : Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: BorderWidth.thin,
                      ),
                    ),
                  ),
            error: (_, _) => _buildInfoCard(l10n.failedToLoadTools),
          );
    final integrationsSection = restrictedMode
        ? const SizedBox.shrink()
        : FutureBuilder<Map<String, dynamic>?>(
            future: userSettingsFuture,
            builder: (context, snapshot) {
              final settings = snapshot.data;
              final directToolServers = _extractConfiguredServers(
                settings,
                'toolServers',
              );
              final directToolTiles = <Widget>[];
              for (var index = 0; index < directToolServers.length; index++) {
                final server = directToolServers[index];
                if (!_isServerEnabled(server)) {
                  continue;
                }

                final selectionId = _directServerSelectionId(server, index);
                final isSelected = selectedToolIds.contains(selectionId);
                directToolTiles.add(
                  _buildToggleTile(
                    icon: Platform.isIOS
                        ? CupertinoIcons.square_stack_3d_down_right
                        : Icons.hub_outlined,
                    title: _serverTitle(
                      server,
                      fallbackPrefix: l10n.toolServer,
                    ),
                    subtitle: _serverSubtitle(server),
                    value: isSelected,
                    onChanged: (_) {
                      final current = List<String>.from(
                        ref.read(selectedToolIdsProvider),
                      );
                      if (isSelected) {
                        current.remove(selectionId);
                      } else {
                        current.add(selectionId);
                      }
                      ref.read(selectedToolIdsProvider.notifier).set(current);
                    },
                  ),
                );
              }

              final terminalTiles = availableTerminalServersAsync!.maybeWhen(
                data: (servers) {
                  return servers
                      .map((server) {
                        final isSelected =
                            selectedTerminalId == server.selectionId;
                        return _buildToggleTile(
                          icon: Platform.isIOS
                              ? CupertinoIcons.chevron_left_slash_chevron_right
                              : Icons.terminal_rounded,
                          title: server.displayName,
                          subtitle: server.subtitle,
                          value: isSelected,
                          onChanged: (_) async {
                            await ref
                                .read(terminalSelectionControllerProvider)
                                .toggle(server);
                          },
                        );
                      })
                      .toList(growable: false);
                },
                orElse: () => const <Widget>[],
              );

              if (directToolTiles.isEmpty && terminalTiles.isEmpty) {
                return const SizedBox.shrink();
              }

              final children = <Widget>[];
              if (directToolTiles.isNotEmpty) {
                children
                  ..add(_buildSectionLabel(l10n.toolServers))
                  ..add(
                    Column(
                      children: withVerticalSpacing(
                        directToolTiles,
                        Spacing.xxs,
                      ),
                    ),
                  );
              }
              if (terminalTiles.isNotEmpty) {
                if (children.isNotEmpty) {
                  children.add(const SizedBox(height: Spacing.sm));
                }
                children
                  ..add(_buildSectionLabel(l10n.terminal))
                  ..add(
                    Column(
                      children: withVerticalSpacing(terminalTiles, Spacing.xxs),
                    ),
                  );
              }

              return Column(children: children);
            },
          );

    final listItems = <Widget>[
      SizedBox(
        height: MediaQuery.textScalerOf(context).scale(_attachmentTileHeight),
        child: HorizontalOverflowFade(
          child: HorizontalScrollGestureBoundary(
            child: ListView.separated(
              key: const ValueKey('composer-attachment-action-strip'),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              itemCount: attachments.length,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
              // Tiles widen to fit longer localized labels.
              itemBuilder: (_, index) => ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: _attachmentTileWidth,
                  maxWidth: _attachmentTileMaxWidth,
                ),
                child: IntrinsicWidth(child: attachments[index]),
              ),
            ),
          ),
        ),
      ),
      if (featureTiles.isNotEmpty) ...[
        const SizedBox(height: Spacing.sm),
        ...featureTiles,
      ],
      if (!widget.localAttachmentsOnly) ...[
        const SizedBox(height: Spacing.sm),
        _buildSectionLabel(l10n.tools),
        toolsSection,
      ],
      if (!restrictedMode) ...[integrationsSection],
    ];

    final toggleFilters = selectedModel?.filters ?? const <ToggleFilter>[];
    if (!restrictedMode && toggleFilters.isNotEmpty) {
      final selectedFilterIds = ref.watch(selectedFilterIdsProvider);
      final filterTiles = toggleFilters.map((filter) {
        final isSelected = selectedFilterIds.contains(filter.id);
        return _buildFilterTile(
          filter: filter,
          selected: isSelected,
          onToggle: () =>
              ref.read(selectedFilterIdsProvider.notifier).toggle(filter.id),
        );
      }).toList();
      listItems
        ..add(const SizedBox(height: Spacing.sm))
        ..add(_buildSectionLabel(l10n.filters))
        ..add(Column(children: withVerticalSpacing(filterTiles, Spacing.xxs)));
    }

    listItems.add(const SizedBox(height: Spacing.md));

    return Material(
      key: const ValueKey('composer-attachment-keyboard'),
      color: theme.surfaceBackground,
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.dividerColor, width: BorderWidth.thin),
          ),
          boxShadow: [
            BoxShadow(
              color: theme.cardShadow.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? 0.22
                    : 0.10,
              ),
              blurRadius: 18,
              spreadRadius: -10,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: ListView.builder(
            key: const ValueKey('composer-attachment-panel-scroll'),
            padding: const EdgeInsets.only(top: Spacing.md),
            itemCount: listItems.length,
            itemBuilder: (_, i) => Padding(
              padding: i == 0
                  ? EdgeInsets.zero
                  : const EdgeInsets.symmetric(horizontal: Spacing.md),
              child: listItems[i],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xxs),
      child: Text(
        text,
        style: AppTypography.labelSmallStyle.copyWith(
          color: context.conduitTheme.textSecondary.withValues(
            alpha: Alpha.strong,
          ),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildInfoCard(String message) {
    final theme = context.conduitTheme;
    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: Text(
        message,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: theme.sidebarForeground.withValues(alpha: 0.75),
        ),
      ),
    );
  }

  List _extractConfiguredServers(Map<String, dynamic>? settings, String key) {
    if (settings == null) {
      return const [];
    }

    final rootValue = settings[key];
    if (rootValue is List) {
      return rootValue;
    }

    final uiValue = settings['ui'];
    if (uiValue is Map && uiValue[key] is List) {
      return uiValue[key] as List;
    }

    return const [];
  }

  bool _isServerEnabled(dynamic server) {
    if (server is! Map) {
      return false;
    }

    final config = server['config'];
    if (config is Map && config.containsKey('enable')) {
      return config['enable'] == true;
    }

    final enabled = server['enabled'];
    if (enabled is bool) {
      return enabled;
    }

    return true;
  }

  String _directServerSelectionId(dynamic server, int index) {
    final serverId = server is Map ? server['id']?.toString().trim() : null;
    final suffix = serverId != null && serverId.isNotEmpty
        ? serverId
        : index.toString();
    return 'direct_server:$suffix';
  }

  String _serverTitle(dynamic server, {required String fallbackPrefix}) {
    if (server is Map) {
      final values = <dynamic>[
        server['name'],
        server['title'],
        server['info'] is Map ? (server['info'] as Map)['title'] : null,
        server['id'],
        server['url'],
      ];
      for (final value in values) {
        final text = value?.toString().trim();
        if (text != null && text.isNotEmpty) {
          return text;
        }
      }
    }

    return fallbackPrefix;
  }

  String? _serverSubtitle(dynamic server) {
    if (server is! Map) {
      return null;
    }

    final values = <dynamic>[
      server['description'],
      server['url'],
      server['path'],
    ];
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) {
        return text;
      }
    }

    return null;
  }

  VoidCallback? _attachmentHandlerFor(String actionId) {
    switch (actionId) {
      case ComposerOverflowActionIds.file:
        return widget.onFileAttachment;
      case ComposerOverflowActionIds.serverFile:
        return widget.onServerFileAttachment;
      case ComposerOverflowActionIds.photo:
        return widget.onImageAttachment;
      case ComposerOverflowActionIds.camera:
        return widget.onCameraCapture;
      case ComposerOverflowActionIds.web:
        return widget.onWebAttachment;
      case ComposerOverflowActionIds.mcpContent:
        return widget.onMcpContent;
      default:
        return null;
    }
  }

  static const double _attachmentTileWidth = 78;
  static const double _attachmentTileMaxWidth = 160;
  static const double _attachmentTileHeight = 58;

  /// Attach tile: a filled rounded square holding its icon and
  /// label, so a row of them reads as one control group.
  Widget _buildAction({
    required ComposerOverflowItem item,
    VoidCallback? onTap,
  }) {
    final theme = context.conduitTheme;
    final bool enabled = onTap != null;
    final Color foreground = enabled ? theme.textPrimary : theme.iconDisabled;
    final VoidCallback? handleTap = onTap == null
        ? null
        : () {
            ConduitHaptics.lightImpact();
            widget.onDismiss?.call();
            Future.microtask(onTap);
          };

    // The labelled node replaces the InkWell's, so it must carry the tap.
    return Semantics(
      button: true,
      enabled: enabled,
      label: item.label,
      excludeSemantics: true,
      onTap: handleTap,
      child: Opacity(
        opacity: enabled ? 1.0 : Alpha.disabled,
        child: Material(
          color: theme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBorderRadius.md + 2),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: handleTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    item.iconFor(useCupertino: Platform.isIOS),
                    color: foreground,
                    size: IconSize.message,
                  ),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppTypography.labelSmallStyle.copyWith(
                      color: foreground,
                      height: 1.1,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToggleTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? iconUrl,
  }) {
    final theme = context.conduitTheme;
    final glyph = iconUrl != null && iconUrl.isNotEmpty
        ? _buildFilterGlyph(iconUrl: iconUrl, selected: value, theme: theme)
        : _buildIconGlyph(icon: icon, selected: value, theme: theme);
    return ToggleTile(
      glyph: glyph,
      title: title,
      subtitle: subtitle,
      selected: value,
      onToggle: () => onChanged(!value),
      theme: theme,
    );
  }

  Widget _buildOverflowItemTile({
    required ComposerOverflowItem item,
    required ValueChanged<bool> onChanged,
  }) {
    return _buildToggleTile(
      icon: item.iconFor(useCupertino: Platform.isIOS),
      title: item.label,
      subtitle: item.subtitle,
      value: item.selected,
      onChanged: onChanged,
    );
  }

  Widget _buildFilterTile({
    required ToggleFilter filter,
    required bool selected,
    required VoidCallback onToggle,
  }) {
    final theme = context.conduitTheme;
    return ToggleTile(
      glyph: _buildFilterGlyph(
        iconUrl: filter.icon,
        selected: selected,
        theme: theme,
      ),
      title: filter.name,
      subtitle: filter.description,
      selected: selected,
      onToggle: onToggle,
      theme: theme,
    );
  }

  Widget _buildIconGlyph({
    required IconData icon,
    required bool selected,
    required ConduitThemeExtension theme,
  }) {
    return Icon(icon, color: theme.iconPrimary, size: IconSize.message);
  }

  Widget _buildFilterGlyph({
    String? iconUrl,
    required bool selected,
    required ConduitThemeExtension theme,
  }) {
    if (iconUrl != null && iconUrl.isNotEmpty) {
      return ModelAvatar(
        size: IconSize.message,
        imageUrl: iconUrl,
        label: null,
      );
    }
    return Icon(
      Platform.isIOS ? CupertinoIcons.sparkles : Icons.auto_awesome,
      color: theme.iconPrimary,
      size: IconSize.message,
    );
  }
}

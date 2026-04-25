import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../core/models/tool.dart';
import '../../../core/models/toggle_filter.dart';
import '../../../core/providers/app_providers.dart';
import '../../tools/providers/tools_providers.dart';
import '../providers/chat_providers.dart';
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
    return Semantics(
      button: true,
      toggled: selected,
      label: title,
      hint: (subtitle?.isEmpty ?? true) ? null : subtitle,
      child: ConduitCard(
        padding: const EdgeInsets.all(Spacing.md),
        onTap: () {
          ConduitHaptics.selectionClick();
          onToggle();
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            glyph,
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.sidebarForeground,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: Spacing.xs),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.sidebarForeground.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            IgnorePointer(
              child: Platform.isIOS
                  ? CupertinoSwitch(
                      value: selected,
                      onChanged: (_) {},
                      activeTrackColor: theme.buttonPrimary,
                    )
                  : Switch(
                      value: selected,
                      onChanged: (_) {},
                      activeThumbColor: theme.buttonPrimary,
                    ),
            ),
          ],
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

/// Bottom sheet for attachment and overflow options in the chat composer.
class ComposerOverflowSheet extends ConsumerStatefulWidget {
  const ComposerOverflowSheet({
    super.key,
    this.onFileAttachment,
    this.onServerFileAttachment,
    this.onImageAttachment,
    this.onCameraCapture,
    this.onWebAttachment,
  });

  final VoidCallback? onFileAttachment;
  final VoidCallback? onServerFileAttachment;
  final VoidCallback? onImageAttachment;
  final VoidCallback? onCameraCapture;
  final VoidCallback? onWebAttachment;

  @override
  ConsumerState<ComposerOverflowSheet> createState() =>
      _ComposerOverflowSheetState();
}

class _ComposerOverflowSheetState extends ConsumerState<ComposerOverflowSheet> {
  Future<Map<String, dynamic>?>? _userSettingsFuture;

  @override
  void initState() {
    super.initState();
    _userSettingsFuture = _loadUserSettings();
  }

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

    final attachments = <Widget>[
      _buildAction(
        icon: Platform.isIOS ? CupertinoIcons.doc : Icons.attach_file,
        label: l10n.file,
        onTap: widget.onFileAttachment == null
            ? null
            : () {
                ConduitHaptics.lightImpact();
                widget.onFileAttachment!();
              },
      ),
      _buildAction(
        icon: Platform.isIOS ? CupertinoIcons.folder : Icons.folder_rounded,
        label: l10n.files,
        onTap: widget.onServerFileAttachment == null
            ? null
            : () {
                ConduitHaptics.lightImpact();
                widget.onServerFileAttachment!();
              },
      ),
      _buildAction(
        icon: Platform.isIOS ? CupertinoIcons.photo : Icons.image,
        label: l10n.photo,
        onTap: widget.onImageAttachment == null
            ? null
            : () {
                ConduitHaptics.lightImpact();
                widget.onImageAttachment!();
              },
      ),
      _buildAction(
        icon: Platform.isIOS ? CupertinoIcons.camera : Icons.camera_alt,
        label: l10n.camera,
        onTap: widget.onCameraCapture == null
            ? null
            : () {
                ConduitHaptics.lightImpact();
                widget.onCameraCapture!();
              },
      ),
      _buildAction(
        icon: Icons.public,
        label: l10n.webPage,
        onTap: widget.onWebAttachment == null
            ? null
            : () {
                ConduitHaptics.lightImpact();
                widget.onWebAttachment!();
              },
      ),
    ];

    final featureTiles = <Widget>[];
    final webSearchAvailable = ref.watch(webSearchAvailableProvider);
    final webSearchEnabled = ref.watch(webSearchEnabledProvider);
    if (webSearchAvailable) {
      featureTiles.add(
        _buildToggleTile(
          icon: Platform.isIOS ? CupertinoIcons.search : Icons.search,
          title: l10n.webSearch,
          subtitle: l10n.webSearchDescription,
          value: webSearchEnabled,
          onChanged: (v) => ref.read(webSearchEnabledProvider.notifier).set(v),
        ),
      );
    }

    final imageGenAvailable = ref.watch(imageGenerationAvailableProvider);
    final imageGenEnabled = ref.watch(imageGenerationEnabledProvider);
    if (imageGenAvailable) {
      featureTiles.add(
        _buildToggleTile(
          icon: Platform.isIOS ? CupertinoIcons.photo : Icons.image,
          title: l10n.imageGeneration,
          subtitle: l10n.imageGenerationDescription,
          value: imageGenEnabled,
          onChanged: (v) =>
              ref.read(imageGenerationEnabledProvider.notifier).set(v),
        ),
      );
    }

    final selectedToolIds = ref.watch(selectedToolIdsProvider);
    final selectedTerminalId = ref.watch(selectedTerminalIdProvider);
    final toolsAsync = ref.watch(toolsListProvider);
    final toolsSection = toolsAsync.when(
      data: (tools) {
        if (tools.isEmpty) return _buildInfoCard('No tools available');
        final tiles = tools.map((tool) {
          final isSelected = selectedToolIds.contains(tool.id);
          return _buildToolTile(
            tool: tool,
            selected: isSelected,
            onToggle: () {
              final current = List<String>.from(
                ref.read(selectedToolIdsProvider),
              );
              isSelected ? current.remove(tool.id) : current.add(tool.id);
              ref.read(selectedToolIdsProvider.notifier).set(current);
            },
          );
        }).toList();
        return Column(children: withVerticalSpacing(tiles, Spacing.xxs));
      },
      loading: () => Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: BorderWidth.thin),
        ),
      ),
      error: (_, _) => _buildInfoCard('Failed to load tools'),
    );
    final integrationsSection = FutureBuilder<Map<String, dynamic>?>(
      future: _userSettingsFuture,
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
              title: _serverTitle(server, fallbackPrefix: l10n.toolServer),
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

        final terminalServers = _extractConfiguredServers(
          settings,
          'terminalServers',
        );
        final terminalTiles = <Widget>[];
        for (var index = 0; index < terminalServers.length; index++) {
          final server = terminalServers[index];
          if (!_isServerEnabled(server)) {
            continue;
          }

          final terminalValue = _terminalSelectionValue(server);
          if (terminalValue == null) {
            continue;
          }

          final isSelected = selectedTerminalId == terminalValue;
          terminalTiles.add(
            _buildToggleTile(
              icon: Platform.isIOS
                  ? CupertinoIcons.chevron_left_slash_chevron_right
                  : Icons.terminal_rounded,
              title: _serverTitle(server, fallbackPrefix: l10n.terminal),
              subtitle: _serverSubtitle(server),
              value: isSelected,
              onChanged: (_) {
                ref
                    .read(selectedTerminalIdProvider.notifier)
                    .set(isSelected ? null : terminalValue);
              },
            ),
          );
        }

        if (directToolTiles.isEmpty && terminalTiles.isEmpty) {
          return const SizedBox.shrink();
        }

        final children = <Widget>[];
        if (directToolTiles.isNotEmpty) {
          children
            ..add(_buildSectionLabel(l10n.toolServers))
            ..add(
              Column(
                children: withVerticalSpacing(directToolTiles, Spacing.xxs),
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
              Column(children: withVerticalSpacing(terminalTiles, Spacing.xxs)),
            );
        }

        return Column(children: children);
      },
    );

    final listItems = <Widget>[
      const SheetHandle(),
      const SizedBox(height: Spacing.sm),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: withHorizontalSpacing(
                attachments
                    .map((attachment) => Expanded(child: attachment))
                    .toList(),
                Spacing.sm,
              ),
            ),
          ),
        ],
      ),
      if (featureTiles.isNotEmpty) ...[
        const SizedBox(height: Spacing.sm),
        ...withVerticalSpacing(featureTiles, Spacing.xxs),
      ],
      const SizedBox(height: Spacing.sm),
      _buildSectionLabel(l10n.tools),
      toolsSection,
      integrationsSection,
    ];

    final selectedModel = ref.watch(selectedModelProvider);
    final toggleFilters = selectedModel?.filters ?? const <ToggleFilter>[];
    if (toggleFilters.isNotEmpty) {
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

    listItems.add(const SizedBox(height: Spacing.sm));

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.shrink(),
          ),
        ),
        DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.28,
          minChildSize: 0.28,
          maxChildSize: 0.92,
          snap: true,
          snapSizes: const [0.28, 0.92],
          builder: (_, scrollController) => Container(
            decoration: BoxDecoration(
              color: theme.surfaceBackground,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppBorderRadius.bottomSheet),
              ),
              border: Border.all(
                color: theme.dividerColor,
                width: BorderWidth.thin,
              ),
              boxShadow: ConduitShadows.modal(context),
            ),
            child: ModalSheetSafeArea(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.xs,
                Spacing.md,
                0,
              ),
              child: ListView.builder(
                controller: scrollController,
                itemCount: listItems.length,
                itemBuilder: (_, i) => listItems[i],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xxs),
      child: Text(
        text,
        style: AppTypography.labelStyle.copyWith(
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

  String? _terminalSelectionValue(dynamic server) {
    if (server is! Map) {
      return null;
    }

    final id = server['id']?.toString().trim();
    if (id != null && id.isNotEmpty) {
      return id;
    }

    final url = server['url']?.toString().trim();
    if (url != null && url.isNotEmpty) {
      return url;
    }

    return null;
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

  Widget _buildAction({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final theme = context.conduitTheme;
    final bool enabled = onTap != null;
    final Color iconColor = enabled ? theme.buttonPrimary : theme.iconDisabled;
    final Color textColor = enabled
        ? theme.sidebarForeground
        : theme.sidebarForeground.withValues(alpha: Alpha.disabled);

    return Opacity(
      opacity: enabled ? 1.0 : Alpha.disabled,
      child: ConduitCard(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xs,
          vertical: Spacing.sm,
        ),
        onTap: onTap == null
            ? null
            : () {
                Navigator.of(context).pop();
                Future.microtask(onTap);
              },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: enabled
                    ? iconColor.withValues(alpha: 0.1)
                    : theme.surfaceContainer.withValues(alpha: 0.60),
                borderRadius: BorderRadius.circular(AppBorderRadius.small),
                border: Border.all(
                  color: enabled
                      ? iconColor.withValues(alpha: 0.2)
                      : Colors.transparent,
                  width: BorderWidth.thin,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: iconColor, size: IconSize.medium),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              label,
              textAlign: TextAlign.center,
              style: AppTypography.labelMediumStyle.copyWith(color: textColor),
            ),
          ],
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

  Widget _buildToolTile({
    required Tool tool,
    required bool selected,
    required VoidCallback onToggle,
  }) {
    final theme = context.conduitTheme;
    return ToggleTile(
      glyph: _buildIconGlyph(
        icon: _iconFor(tool),
        selected: selected,
        theme: theme,
      ),
      title: tool.name,
      subtitle: _descriptionFor(tool),
      selected: selected,
      onToggle: onToggle,
      theme: theme,
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
    final color = selected ? theme.buttonPrimary : theme.iconPrimary;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: BorderWidth.thin,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: color, size: IconSize.medium),
    );
  }

  Widget _buildFilterGlyph({
    String? iconUrl,
    required bool selected,
    required ConduitThemeExtension theme,
  }) {
    final color = selected ? theme.buttonPrimary : theme.iconPrimary;
    final fallback = Icon(
      Platform.isIOS ? CupertinoIcons.sparkles : Icons.auto_awesome,
      color: color,
      size: IconSize.medium,
    );
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: BorderWidth.thin,
        ),
      ),
      alignment: Alignment.center,
      child: iconUrl != null && iconUrl.isNotEmpty
          ? ClipRRect(
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
              child: Image.network(
                iconUrl,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                color: iconUrl.endsWith('.svg') ? color : null,
                colorBlendMode: BlendMode.srcIn,
                errorBuilder: (_, _, _) => fallback,
              ),
            )
          : fallback,
    );
  }

  IconData _iconFor(Tool tool) {
    final name = tool.name.toLowerCase();
    if (name.contains('image') || name.contains('vision')) {
      return Platform.isIOS ? CupertinoIcons.photo : Icons.image;
    }
    if (name.contains('code') || name.contains('python')) {
      return Platform.isIOS
          ? CupertinoIcons.chevron_left_slash_chevron_right
          : Icons.code;
    }
    if (name.contains('calculator') || name.contains('math')) {
      return Icons.calculate;
    }
    if (name.contains('file') || name.contains('document')) {
      return Platform.isIOS ? CupertinoIcons.doc : Icons.description;
    }
    if (name.contains('api') || name.contains('request')) return Icons.cloud;
    if (name.contains('search')) {
      return Platform.isIOS ? CupertinoIcons.search : Icons.search;
    }
    return Platform.isIOS ? CupertinoIcons.square_grid_2x2 : Icons.extension;
  }

  String _descriptionFor(Tool tool) {
    final meta = tool.meta;
    if (meta != null) {
      final v = meta['description'];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    final custom = tool.description?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    final name = tool.name.toLowerCase();
    if (name.contains('search') || name.contains('browse')) {
      return 'Search the web for fresh context to improve answers.';
    }
    if (name.contains('image') || name.contains('vision')) {
      return 'Understand or generate imagery alongside your conversation.';
    }
    if (name.contains('code') || name.contains('python')) {
      return 'Execute code snippets and return computed results inline.';
    }
    if (name.contains('calc') || name.contains('math')) {
      return 'Perform precise math and calculations on demand.';
    }
    if (name.contains('file') || name.contains('document')) {
      return 'Access and summarize your uploaded files during chat.';
    }
    if (name.contains('api') || name.contains('request')) {
      return 'Trigger API requests and bring external data into the chat.';
    }
    return 'Enhance responses with specialized capabilities from this tool.';
  }
}

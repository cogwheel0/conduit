import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/model_avatar.dart';

import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';

import '../../terminal/providers/terminal_providers.dart';

import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart'
    show isLibreChatModel;
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart'
    show libreChatComposerOptionsProvider;
import '../../librechat/widgets/librechat_composer_support.dart'
    show libreChatComposerTools;

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';

import '../../integrations/views/personal_connection_messages.dart';

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
    this.isAction = false,
    this.enabled = true,
  });

  final Widget glyph;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onToggle;
  final ConduitThemeExtension theme;

  /// A command row that opens something: announced as a button, never as a
  /// toggle, and marked with a chevron instead of a switch.
  final bool isAction;

  /// A row that only explains itself, such as an option the server cannot
  /// offer, stays visible but cannot be tapped.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // A flat menu row: plain glyph, regular-weight title, and a switch that
    // shows whether the option is on before it is tapped (as in Settings).
    void handleTap() {
      ConduitHaptics.selectionClick();
      onToggle();
    }

    // The labelled node replaces the InkWell's, so it must carry the tap.
    return Semantics(
      button: true,
      enabled: enabled,
      toggled: isAction ? null : selected,
      label: title,
      hint: (subtitle?.isEmpty ?? true) ? null : subtitle,
      excludeSemantics: true,
      onTap: enabled ? handleTap : null,
      child: Opacity(
        opacity: enabled ? 1.0 : Alpha.disabled,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? handleTap : null,
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
                            // A command or an option that is off explains
                            // itself, so it gets room to finish the sentence.
                            maxLines: isAction || !enabled ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.labelSmallStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  if (isAction)
                    SizedBox(
                      width: IconSize.small,
                      child: Icon(
                        Platform.isIOS
                            ? CupertinoIcons.chevron_forward
                            : Icons.chevron_right,
                        color: theme.textTertiary,
                        size: IconSize.small,
                      ),
                    )
                  else
                    // The row takes the tap and carries the toggled state;
                    // the switch only shows it.
                    IgnorePointer(
                      child: ExcludeSemantics(
                        child: AdaptiveSwitch(
                          key: const ValueKey<String>('toggle-tile-switch'),
                          value: selected,
                          onChanged: enabled ? (_) {} : null,
                        ),
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
    this.onToolSettings,
    this.onCompareModels,
    this.compareModelsHasMessage = true,
    this.onSaveDraftAsNote,
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

  /// Opens the personal tool settings sheet. Null hides the Advanced command.
  final VoidCallback? onToolSettings;

  /// Starts a model comparison from the composer's message. Null hides the
  /// Advanced command.
  final VoidCallback? onCompareModels;

  /// Whether the composer holds a message to compare. Until it does, the
  /// command stays visible but off and says why.
  final bool compareModelsHasMessage;

  /// Keeps the typed message as a new note instead of sending it. Null hides
  /// the command (no message, notes off, or the Chats setting turned off).
  final VoidCallback? onSaveDraftAsNote;

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
    // LibreChat takes uploads and its own tools, and none of Open WebUI's
    // integrations.
    final libreChatMode =
        selectedModel != null && isLibreChatModel(selectedModel);
    final restrictedMode =
        directMode || libreChatMode || widget.localAttachmentsOnly;
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
          if (widget.localAttachmentsOnly || libreChatMode) {
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
          // Only an Open WebUI server runs the interpreter.
          codeInterpreter: restrictedMode
              ? null
              : ref.watch(codeInterpreterOfferProvider),
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
    final clearedConnections = restrictedMode
        ? const <String>[]
        : ref.watch(personalSelectionNoticeProvider);
    final availableTerminalServersAsync = restrictedMode
        ? null
        : ref.watch(terminalAvailableServersProvider);
    final toolsAsync = widget.localAttachmentsOnly
        ? null
        : directMode
        ? directToolsAvailable
              ? ref.watch(directMcpToolsProvider)
              : const AsyncData<List<Tool>>([])
        : libreChatMode
        ? ref
              .watch(libreChatComposerOptionsProvider)
              .whenData((options) => libreChatComposerTools(l10n, options))
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
                : const Center(
                    child: ConduitLoadingIndicator(
                      size: IconSize.lg,
                      isCompact: true,
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
              final directToolServers = effectivePersonalServerList(
                settings,
                PersonalConnectionKind.toolServer.settingsKey,
              );
              final directToolTiles = <Widget>[];
              for (var index = 0; index < directToolServers.length; index++) {
                final server = directToolServers[index];
                if (!_isServerEnabled(server)) {
                  continue;
                }

                final selectionId = personalToolServerSelectionId(
                  directToolServers,
                  index,
                );
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
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The same grid as the native iOS panel: equal columns that all
            // fit, balanced rows (3 + 2 rather than 4 + 1).
            final rows = composerAttachmentGridRows(
              count: attachments.length,
              availableWidth: constraints.maxWidth,
            );
            final columns = rows.isEmpty ? 0 : rows.first;
            var index = 0;
            final rowWidgets = <Widget>[];
            for (final count in rows) {
              final tiles = attachments.sublist(index, index + count);
              index += count;
              rowWidgets.add(
                Row(
                  // A name that wraps makes only its own tile taller.
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var column = 0; column < columns; column++) ...[
                      if (column > 0)
                        const SizedBox(width: _attachmentTileSpacing),
                      Expanded(
                        child: column < tiles.length
                            ? tiles[column]
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              );
            }
            return Column(
              key: const ValueKey('composer-attachment-action-grid'),
              children: withVerticalSpacing(rowWidgets, _attachmentTileSpacing),
            );
          },
        ),
      ),
      if (featureTiles.isNotEmpty) ...[
        const SizedBox(height: Spacing.sm + Spacing.xs),
        ...featureTiles,
      ],
      if (!restrictedMode && widget.onCompareModels != null)
        ..._buildCompareModelsTiles(l10n),
      if (widget.onSaveDraftAsNote != null) ..._buildSaveDraftAsNoteTiles(l10n),
      if (!widget.localAttachmentsOnly) ...[
        const SizedBox(height: Spacing.sm),
        _buildSectionLabel(l10n.tools),
        toolsSection,
        if (!restrictedMode && widget.onToolSettings != null)
          ..._buildToolSettingsTiles(l10n),
      ],
      if (clearedConnections.isNotEmpty) ...[
        const SizedBox(height: Spacing.sm),
        _buildInfoCard(
          l10n.personalConnectionsSelectionCleared(
            personalSelectionNoticeText(l10n, clearedConnections),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            key: const Key('personal-selection-notice-dismiss'),
            onPressed: () =>
                ref.read(personalSelectionNoticeProvider.notifier).clear(),
            child: Text(l10n.ok),
          ),
        ),
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
      // As tall as its rows, up to the keyboard height it stands in for; a
      // host that reserves the keyboard's space still gets it filled.
      child: Container(
        constraints: BoxConstraints(maxHeight: widget.height),
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
            shrinkWrap: true,
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

  /// The Advanced "Tool settings" command, built from the same item the
  /// native iOS panel renders so both surfaces offer the identical action.
  List<Widget> _buildToolSettingsTiles(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return [
      for (final item in buildComposerOverflowToolSettingsItems(
        l10n: l10n,
        available: true,
      ))
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xxs),
          child: ToggleTile(
            glyph: _buildIconGlyph(
              icon: item.iconFor(useCupertino: Platform.isIOS),
              selected: false,
              theme: theme,
            ),
            title: item.label,
            subtitle: item.subtitle,
            selected: false,
            isAction: true,
            // The composer's handler captures the owner before it dismisses
            // this panel, so it runs synchronously from the tap.
            onToggle: widget.onToolSettings!,
            theme: theme,
          ),
        ),
    ];
  }

  /// The Advanced "Compare models" command, built from the same item the
  /// native iOS panel renders so both surfaces offer the identical action.
  List<Widget> _buildCompareModelsTiles(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return [
      for (final item in buildComposerOverflowComparisonItems(
        l10n: l10n,
        available: true,
        hasMessage: widget.compareModelsHasMessage,
      ))
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xxs),
          child: ToggleTile(
            glyph: _buildIconGlyph(
              icon: item.iconFor(useCupertino: Platform.isIOS),
              selected: false,
              theme: theme,
            ),
            title: item.label,
            subtitle: item.subtitle,
            selected: false,
            isAction: true,
            enabled: item.enabled,
            onToggle: widget.onCompareModels!,
            theme: theme,
          ),
        ),
    ];
  }

  /// "Save as Note", built from the same item the native iOS panel renders.
  List<Widget> _buildSaveDraftAsNoteTiles(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return [
      for (final item in buildComposerOverflowDraftNoteItems(
        l10n: l10n,
        available: true,
      ))
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xxs),
          child: ToggleTile(
            key: const ValueKey<String>('composer-save-draft-as-note'),
            glyph: _buildIconGlyph(
              icon: item.iconFor(useCupertino: Platform.isIOS),
              selected: false,
              theme: theme,
            ),
            title: item.label,
            subtitle: item.subtitle,
            selected: false,
            isAction: true,
            onToggle: widget.onSaveDraftAsNote!,
            theme: theme,
          ),
        ),
    ];
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

  static const double _attachmentTileSpacing = Spacing.sm;

  /// Attach tile: a flat rounded key holding the icon, with its name beneath
  /// it, the same as the native iOS panel.
  Widget _buildAction({
    required ComposerOverflowItem item,
    VoidCallback? onTap,
  }) {
    final VoidCallback? handleTap = onTap == null
        ? null
        : () {
            ConduitHaptics.lightImpact();
            widget.onDismiss?.call();
            Future.microtask(onTap);
          };

    return ComposerAttachmentKey(
      key: ValueKey<String>('composer-attachment-key:${item.id}'),
      icon: item.iconFor(useCupertino: Platform.isIOS),
      label: item.label,
      onTap: handleTap,
    );
  }

  Widget _buildToggleTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? iconUrl,
    bool enabled = true,
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
      enabled: enabled,
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
      enabled: item.enabled,
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

/// One attach panel tile: a flat rounded key holding [icon], with [label]
/// beneath it so a long name never crowds the key's edges. The key darkens
/// the moment a finger lands. Mirrors the native iOS panel's tiles.
class ComposerAttachmentKey extends StatefulWidget {
  const ComposerAttachmentKey({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  static const double keyHeight = 56;
  static const double cornerRadius = 14;

  /// Cupertino and Material glyphs draw a little inside their box; at 24 pt
  /// they match the native panel's 22 pt (Title 2) SF Symbols.
  static const double glyphSize = 24;

  @override
  State<ComposerAttachmentKey> createState() => _ComposerAttachmentKeyState();
}

class _ComposerAttachmentKeyState extends State<ComposerAttachmentKey> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null;

  void _setPressed(bool value) {
    if (_pressed == value || !_enabled) return;
    setState(() => _pressed = value);
  }

  @override
  void didUpdateWidget(ComposerAttachmentKey oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _pressed) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = _enabled ? theme.textPrimary : theme.iconDisabled;
    // The same quiet monochrome fill as the suggestion buttons, a step
    // stronger while pressed.
    final fill = theme.textPrimary.withValues(
      alpha: _pressed ? (isDark ? 0.20 : 0.11) : (isDark ? 0.12 : 0.05),
    );

    // The labelled node replaces the gesture's, so it must carry the tap.
    return Semantics(
      container: true,
      button: true,
      enabled: _enabled,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onTap,
        child: Opacity(
          opacity: _enabled ? 1.0 : Alpha.disabled,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                key: const ValueKey<String>('composer-attachment-key-fill'),
                // Instant on touch-down; a short ease back on release.
                duration: _pressed
                    ? Duration.zero
                    : context.motionDuration(const Duration(milliseconds: 200)),
                curve: Curves.easeOut,
                height: MediaQuery.textScalerOf(context)
                    .scale(ComposerAttachmentKey.keyHeight),
                decoration: ShapeDecoration(
                  color: fill,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(
                      ComposerAttachmentKey.cornerRadius,
                    ),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  widget.icon,
                  color: foreground,
                  size: MediaQuery.textScalerOf(
                    context,
                  ).scale(ComposerAttachmentKey.glyphSize),
                ),
              ),
              const SizedBox(height: 6),
              // A long localized name wraps instead of truncating, so every
              // tile can share one column width.
              Text(
                widget.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppTypography.labelSmallStyle.copyWith(
                  color: foreground,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How many attachment tiles each row of the attach panel holds: every tile
/// at least [minimumTileWidth] wide so none is cut off, and the rows balanced
/// so five tiles that cannot share one row split three and two. Mirrors
/// `attachmentGridRows` in the native iOS panel.
@visibleForTesting
List<int> composerAttachmentGridRows({
  required int count,
  required double availableWidth,
  double spacing = Spacing.sm,
  double minimumTileWidth = 62,
}) {
  if (count <= 0) return const <int>[];
  final fitting = ((availableWidth + spacing) / (minimumTileWidth + spacing))
      .floor();
  final maxColumns = fitting < 1 ? 1 : fitting;
  final rowCount = (count / maxColumns).ceil();
  final columns = (count / rowCount).ceil();
  final rows = <int>[];
  var remaining = count;
  while (remaining > 0) {
    final take = remaining < columns ? remaining : columns;
    rows.add(take);
    remaining -= take;
  }
  return rows;
}

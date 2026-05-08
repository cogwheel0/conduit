import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/models/model.dart';
import '../../../core/models/server_user_settings.dart';
import '../../../core/models/server_memory.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../chat/providers/chat_providers.dart' show restoreDefaultModel;
import '../widgets/customization_tile.dart';
import '../widgets/default_model_sheet.dart';
import '../widgets/expandable_card.dart';
import '../widgets/settings_page_scaffold.dart';

class PersonalizationPage extends ConsumerWidget {
  const PersonalizationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settingsAsync = ref.watch(personalizationSettingsProvider);
    final appSettings = ref.watch(appSettingsProvider);
    final memoriesAsync = ref.watch(userMemoriesProvider);
    final modelsAsync = ref.watch(modelsProvider);

    return SettingsPageScaffold(
      title: l10n.personalization,
      children: [
        _buildDefaultModelSection(
          context,
          ref,
          currentDefaultModelId: appSettings.defaultModel,
          modelsAsync: modelsAsync,
        ),
        settingsSectionGap,
        _buildSystemPromptSection(context, ref, settingsAsync),
        settingsSectionGap,
        _buildMemorySection(context, ref, settingsAsync, memoriesAsync),
        settingsSectionGap,
        _buildAdvancedPromptTile(context),
      ],
    );
  }

  Widget _buildDefaultModelSection(
    BuildContext context,
    WidgetRef ref, {
    required String? currentDefaultModelId,
    required AsyncValue<List<Model>> modelsAsync,
  }) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: l10n.defaultModel),
        const SizedBox(height: Spacing.sm),
        modelsAsync.when(
          data: (models) {
            final resolvedName = _resolveModelName(
              models,
              currentDefaultModelId,
            );
            return CustomizationTile(
              leading: SettingsIconBadge(
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.wand_stars,
                  android: Icons.auto_awesome,
                ),
                color: context.conduitTheme.buttonPrimary,
              ),
              title: l10n.defaultModel,
              subtitle: resolvedName ?? l10n.autoSelectDescription,
              onTap: () => _showDefaultModelPicker(
                context,
                ref,
                models: models,
                currentDefaultModelId: currentDefaultModelId,
              ),
            );
          },
          loading: () => _buildLoadingTile(context, title: l10n.defaultModel),
          error: (_, _) => _buildErrorTile(
            context,
            title: l10n.defaultModel,
            subtitle: l10n.failedToLoadModels,
          ),
        ),
      ],
    );
  }

  Widget _buildSystemPromptSection(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<ServerUserSettings> settingsAsync,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: l10n.yourSystemPrompt),
        const SizedBox(height: Spacing.sm),
        settingsAsync.when(
          data: (settings) {
            final prompt = settings.systemPrompt;
            return CustomizationTile(
              leading: SettingsIconBadge(
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.person_crop_circle_badge_checkmark,
                  android: Icons.person_outline,
                ),
                color: context.conduitTheme.buttonPrimary,
              ),
              title: l10n.yourSystemPrompt,
              subtitle: _previewText(context, prompt),
              onTap: () => _showTextEditorSheet(
                context,
                title: l10n.yourSystemPrompt,
                description: l10n.yourSystemPromptDescription,
                initialValue: prompt ?? '',
                hintText: l10n.enterSystemPrompt,
                onSave: (value) async {
                  await ref
                      .read(personalizationSettingsProvider.notifier)
                      .setSystemPrompt(value);
                },
              ),
            );
          },
          loading: () =>
              _buildLoadingTile(context, title: l10n.yourSystemPrompt),
          error: (_, _) => _buildErrorTile(
            context,
            title: l10n.yourSystemPrompt,
            subtitle: l10n.unableToLoadOpenWebuiSettings,
          ),
        ),
      ],
    );
  }

  Widget _buildMemorySection(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<ServerUserSettings> settingsAsync,
    AsyncValue<List<ServerMemory>> memoriesAsync,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: l10n.memoryTitle),
        const SizedBox(height: Spacing.sm),
        settingsAsync.when(
          data: (settings) {
            final enabled = settings.memoryEnabled;
            return CustomizationTile(
              leading: SettingsIconBadge(
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.bookmark,
                  android: Icons.memory,
                ),
                color: context.conduitTheme.buttonPrimary,
              ),
              title: l10n.memoryTitle,
              subtitle: enabled
                  ? l10n.memoryEnabledDescription
                  : l10n.memoryDisabledDescription,
              trailing: AdaptiveSwitch(
                value: enabled,
                onChanged: (value) async {
                  await ref
                      .read(personalizationSettingsProvider.notifier)
                      .setMemoryEnabled(value);
                },
              ),
              showChevron: false,
              onTap: () async {
                await ref
                    .read(personalizationSettingsProvider.notifier)
                    .setMemoryEnabled(!enabled);
              },
            );
          },
          loading: () => _buildLoadingTile(context, title: l10n.memoryTitle),
          error: (_, _) => _buildErrorTile(
            context,
            title: l10n.memoryTitle,
            subtitle: l10n.unableToLoadOpenWebuiSettings,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        ExpandableCard(
          title: l10n.manageMemories,
          subtitle: memoriesAsync.when(
            data: (memories) => l10n.savedMemoriesCount(memories.length),
            loading: () => l10n.loadingFromOpenWebui,
            error: (_, _) => l10n.errorMessage,
          ),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.collections,
            android: Icons.collections_bookmark_outlined,
          ),
          child: memoriesAsync.when(
            data: (memories) => _buildMemoryManager(context, ref, memories),
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(Spacing.md),
                child: ConduitLoadingIndicator(isCompact: true),
              ),
            ),
            error: (_, _) => Text(
              l10n.unableToLoadOpenWebuiSettings,
              style: context.conduitTheme.bodyMedium?.copyWith(
                color: context.conduitTheme.sidebarForeground.withValues(
                  alpha: 0.75,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMemoryManager(
    BuildContext context,
    WidgetRef ref,
    List<ServerMemory> memories,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CustomizationTile(
          leading: SettingsIconBadge(
            icon: UiUtils.platformIcon(
              ios: CupertinoIcons.add_circled,
              android: Icons.add_circle_outline,
            ),
            color: context.conduitTheme.buttonPrimary,
          ),
          title: l10n.addMemory,
          subtitle: l10n.manageMemoriesDescription,
          onTap: () => _showTextEditorSheet(
            context,
            title: l10n.addMemory,
            description: l10n.memoryEditorDescription,
            initialValue: '',
            hintText: l10n.memoryHint,
            onSave: (value) async {
              await ref.read(userMemoriesProvider.notifier).add(value);
            },
          ),
        ),
        if (memories.isEmpty) ...[
          const SizedBox(height: Spacing.md),
          Text(
            l10n.noMemoriesSaved,
            style: context.conduitTheme.bodyMedium?.copyWith(
              color: context.conduitTheme.sidebarForeground.withValues(
                alpha: 0.75,
              ),
            ),
          ),
        ] else ...[
          const SizedBox(height: Spacing.sm),
          for (var i = 0; i < memories.length; i++) ...[
            CustomizationTile(
              leading: SettingsIconBadge(
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.quote_bubble,
                  android: Icons.notes_rounded,
                ),
                color: context.conduitTheme.buttonPrimary,
              ),
              title: _truncateMemory(memories[i].content),
              subtitle: _memorySubtitle(context, memories[i]),
              trailing: ConduitIconButton(
                tooltip: l10n.deleteMemory,
                onPressed: () =>
                    _confirmDeleteMemory(context, ref, memories[i]),
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.delete_simple,
                  android: Icons.delete_outline,
                ),
                iconColor: context.conduitTheme.error,
              ),
              showChevron: false,
              onTap: () => _showTextEditorSheet(
                context,
                title: l10n.editMemory,
                description: l10n.memoryEditorDescription,
                initialValue: memories[i].content,
                hintText: l10n.memoryHint,
                onSave: (value) async {
                  await ref
                      .read(userMemoriesProvider.notifier)
                      .updateItem(memories[i].id, value);
                },
              ),
            ),
            if (i != memories.length - 1) const SizedBox(height: Spacing.xs),
          ],
          const SizedBox(height: Spacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: AdaptiveButton.child(
              onPressed: () => _confirmClearMemories(context, ref),
              style: AdaptiveButtonStyle.plain,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.clear_circled,
                      android: Icons.clear_all,
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(l10n.clearAllMemories),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAdvancedPromptTile(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return CustomizationTile(
      leading: SettingsIconBadge(
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.slider_horizontal_3,
          android: Icons.tune,
        ),
        color: context.conduitTheme.buttonPrimary,
      ),
      title: l10n.advancedPromptOverrides,
      subtitle: l10n.advancedPromptOverridesDescription,
      onTap: () => context.pushNamed(RouteNames.appCustomization),
    );
  }

  Future<void> _showDefaultModelPicker(
    BuildContext context,
    WidgetRef ref, {
    required List<Model> models,
    required String? currentDefaultModelId,
  }) async {
    final result = await showSettingsSheet<String?>(
      context: context,
      builder: (sheetContext) => DefaultModelBottomSheet(
        models: models,
        currentDefaultModelId: currentDefaultModelId,
      ),
    );

    if (result == null) {
      return;
    }

    final selectedId = result == 'auto-select' ? null : result;
    await ref.read(appSettingsProvider.notifier).setDefaultModel(selectedId);
    await restoreDefaultModel(ref);
  }

  Future<void> _showTextEditorSheet(
    BuildContext context, {
    required String title,
    required String description,
    required String initialValue,
    required String hintText,
    required Future<void> Function(String value) onSave,
  }) async {
    final l10n = AppLocalizations.of(context)!;

    await showSettingsSheet<void>(
      context: context,
      builder: (sheetContext) => _TextEditorSheet(
        title: title,
        description: description,
        initialValue: initialValue,
        hintText: hintText,
        cancelLabel: l10n.cancel,
        saveLabel: l10n.save,
        errorMessage: l10n.errorMessage,
        savedMessage: l10n.saved,
        onSave: onSave,
      ),
    );
  }

  Future<void> _confirmDeleteMemory(
    BuildContext context,
    WidgetRef ref,
    ServerMemory memory,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.deleteMemory,
      message: l10n.deleteMemoryConfirm,
      confirmText: l10n.deleteMemory,
      isDestructive: true,
    );
    if (!confirmed) {
      return;
    }

    await ref.read(userMemoriesProvider.notifier).deleteItem(memory.id);
  }

  Future<void> _confirmClearMemories(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.clearAllMemories,
      message: l10n.clearAllMemoriesDescription,
      confirmText: l10n.clearAllMemories,
      isDestructive: true,
    );
    if (!confirmed) {
      return;
    }

    await ref.read(userMemoriesProvider.notifier).clearAll();
  }

  Widget _buildLoadingTile(BuildContext context, {required String title}) {
    final l10n = AppLocalizations.of(context)!;
    return CustomizationTile(
      leading: SettingsIconBadge(
        icon: UiUtils.platformIcon(
          ios: CupertinoIcons.hourglass,
          android: Icons.hourglass_empty,
        ),
        color: context.conduitTheme.buttonPrimary,
      ),
      title: title,
      subtitle: l10n.loadingFromOpenWebui,
      showChevron: false,
    );
  }

  Widget _buildErrorTile(
    BuildContext context, {
    required String title,
    required String subtitle,
  }) {
    return CustomizationTile(
      leading: SettingsIconBadge(
        icon: Icons.warning_amber_rounded,
        color: context.conduitTheme.error,
      ),
      title: title,
      subtitle: subtitle,
      showChevron: false,
    );
  }

  String? _resolveModelName(List<Model> models, String? modelId) {
    if (modelId == null || modelId.isEmpty) {
      return null;
    }
    for (final model in models) {
      if (model.id == modelId) {
        return model.name;
      }
    }
    return modelId;
  }

  String _previewText(BuildContext context, String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.of(context)!.notSet;
    }
    return value.trim();
  }

  String _truncateMemory(String content) {
    final normalized = content.trim().replaceAll('\n', ' ');
    if (normalized.length <= 72) {
      return normalized;
    }
    return '${normalized.substring(0, 69)}...';
  }

  String _memorySubtitle(BuildContext context, ServerMemory memory) {
    final l10n = AppLocalizations.of(context)!;
    final formatted = DateFormat.yMMMd().add_jm().format(memory.updatedAt);
    return l10n.memoryUpdatedAt(formatted);
  }
}

class _TextEditorSheet extends StatefulWidget {
  const _TextEditorSheet({
    required this.title,
    required this.description,
    required this.initialValue,
    required this.hintText,
    required this.cancelLabel,
    required this.saveLabel,
    required this.errorMessage,
    required this.savedMessage,
    required this.onSave,
  });

  final String title;
  final String description;
  final String initialValue;
  final String hintText;
  final String cancelLabel;
  final String saveLabel;
  final String errorMessage;
  final String savedMessage;
  final Future<void> Function(String value) onSave;

  @override
  State<_TextEditorSheet> createState() => _TextEditorSheetState();
}

class _TextEditorSheetState extends State<_TextEditorSheet> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (_saving) {
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.onSave(_controller.text);
      if (!mounted) {
        return;
      }
      UiUtils.showMessage(context, widget.savedMessage);
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) {
        return;
      }
      UiUtils.showMessage(context, widget.errorMessage);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Container(
      decoration: BoxDecoration(
        color: theme.sidebarBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.modal),
        ),
        boxShadow: ConduitShadows.modal(context),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.lg,
            Spacing.lg,
            Spacing.lg + viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: theme.headingSmall?.copyWith(
                  color: theme.sidebarForeground,
                ),
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                widget.description,
                style: theme.bodySmall?.copyWith(
                  color: theme.sidebarForeground.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: Spacing.md),
              ConduitInput(
                controller: _controller,
                hint: widget.hintText,
                maxLines: 6,
                autofocus: true,
              ),
              const SizedBox(height: Spacing.md),
              Row(
                children: [
                  Expanded(
                    child: ConduitButton(
                      text: widget.cancelLabel,
                      isSecondary: true,
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: ConduitButton(
                      text: widget.saveLabel,
                      isLoading: _saving,
                      onPressed: _saving ? null : _handleSave,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

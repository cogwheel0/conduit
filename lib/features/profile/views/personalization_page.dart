import 'dart:io' show Platform;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/server_memory.dart';

import 'package:conduit_core/providers/app_providers.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/native_sheet_hydration_service.dart';

import 'package:conduit_core/services/settings_service.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show restoreDefaultModel;

import '../widgets/customization_tile.dart';
import '../widgets/default_model_sheet.dart';
import '../widgets/expandable_card.dart';
import '../widgets/settings_page_scaffold.dart';
import '../../../shared/widgets/utility_components.dart';

class PersonalizationPage extends ConsumerStatefulWidget {
  const PersonalizationPage({super.key});

  @override
  ConsumerState<PersonalizationPage> createState() =>
      _PersonalizationPageState();
}

class _PersonalizationPageState extends ConsumerState<PersonalizationPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(openWebUiAccountAvailableProvider)) {
        ref.invalidate(personalizationSettingsProvider);
        ref.invalidate(userMemoriesProvider);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appSettings = ref.watch(appSettingsProvider);
    final modelsAsync = ref.watch(modelsProvider);
    final hasOpenWebUiAccount = ref.watch(openWebUiAccountAvailableProvider);
    // Only an explicit denial hides memories; while the permission loads or
    // cannot be read the section stays, and the server enforces the answer.
    final memoriesPermitted = ref
        .watch(memoriesPermittedProvider)
        .maybeWhen(data: (permitted) => permitted, orElse: () => true);

    return UtilityPageScaffold.settings(
      title: l10n.personalization,
      children: [
        _buildDefaultModelSection(
          context,
          ref,
          currentDefaultModelId: appSettings.defaultModel,
          modelsAsync: modelsAsync,
          hasOpenWebUiAccount: hasOpenWebUiAccount,
        ),
        _buildOpenRouterImageGenerationModelSection(
          context,
          ref,
          currentModelId: appSettings.openRouterImageGenerationModel,
          modelsAsync: modelsAsync,
        ),
        if (hasOpenWebUiAccount) ...[
          settingsSectionGap,
          _buildSystemPromptSection(
            context,
            ref,
            ref.watch(personalizationSettingsProvider),
          ),
          if (memoriesPermitted) ...[
            settingsSectionGap,
            _buildMemorySection(
              context,
              ref,
              ref.watch(personalizationSettingsProvider),
              ref.watch(userMemoriesProvider),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildDefaultModelSection(
    BuildContext context,
    WidgetRef ref, {
    required String? currentDefaultModelId,
    required AsyncValue<List<Model>> modelsAsync,
    required bool hasOpenWebUiAccount,
  }) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
              subtitle:
                  resolvedName ??
                  (hasOpenWebUiAccount
                      ? l10n.autoSelectDescription
                      : l10n.autoSelect),
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

  Widget _buildOpenRouterImageGenerationModelSection(
    BuildContext context,
    WidgetRef ref, {
    required String? currentModelId,
    required AsyncValue<List<Model>> modelsAsync,
  }) {
    final l10n = AppLocalizations.of(context)!;

    return modelsAsync.maybeWhen(
      data: (models) {
        final hasOpenRouterImageTool = models.any(
          (model) =>
              model.capabilities?['openrouter'] == true &&
              model.capabilities?['image_generation'] == true,
        );
        if (!hasOpenRouterImageTool) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            settingsSectionGap,
            CustomizationTile(
              leading: SettingsIconBadge(
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.photo_on_rectangle,
                  android: Icons.image_outlined,
                ),
                color: context.conduitTheme.buttonPrimary,
              ),
              title: l10n.defaultImageGenerationModel,
              subtitle:
                  currentModelId ?? l10n.openRouterDefaultImageGenerationModel,
              onTap: () => _showTextEditorSheet(
                context,
                title: l10n.defaultImageGenerationModel,
                description: l10n.defaultImageGenerationModelDescription,
                initialValue: currentModelId ?? '',
                hintText: 'openai/gpt-5-image',
                onSave: (value) async {
                  await ref
                      .read(appSettingsProvider.notifier)
                      .setOpenRouterImageGenerationModel(value);
                },
              ),
            ),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
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
            loading: () => '',
            error: (_, _) => l10n.errorMessage,
          ),
          subtitleWidget: memoriesAsync.isLoading
              ? const Padding(
                  padding: EdgeInsets.only(top: Spacing.xs),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConduitLoadingIndicator(isCompact: true),
                  ),
                )
              : null,
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
          onTap: () => _openMemoryEditor(context, ref),
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
              onTap: () => _openMemoryEditor(context, ref, memory: memories[i]),
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

  Future<void> _showDefaultModelPicker(
    BuildContext context,
    WidgetRef ref, {
    required List<Model> models,
    required String? currentDefaultModelId,
  }) async {
    final l10n = AppLocalizations.of(context)!;

    if (Platform.isIOS) {
      try {
        final result = await ref
            .read(nativeSheetHydrationServiceProvider)
            .presentModelSelector(
              context,
              title: l10n.defaultModel,
              selectedModelId: currentDefaultModelId ?? 'auto-select',
              leadingOptions: [
                NativeSheetModelOption(
                  id: 'auto-select',
                  name: l10n.autoSelect,
                  subtitle: l10n.autoSelectDescription,
                  sfSymbol: 'wand.and.stars',
                ),
              ],
              models: models,
              rethrowErrors: true,
            );
        if (result == null) return;
        final selectedId = result == 'auto-select' ? null : result;
        await ref
            .read(appSettingsProvider.notifier)
            .setDefaultModel(selectedId);
        await restoreDefaultModel(ref);
        return;
      } catch (_) {
        if (!context.mounted) {
          return;
        }
      }
    }

    if (!context.mounted) {
      return;
    }

    final result = await showAdaptiveSelectionSheet<String?>(
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

  Future<void> _openMemoryEditor(
    BuildContext context,
    WidgetRef ref, {
    ServerMemory? memory,
  }) {
    final notifier = ref.read(userMemoriesProvider.notifier);
    return showMemoryEditor(
      context,
      notifier: notifier,
      owner: notifier.captureOwner(),
      advanced: ref.read(appSettingsProvider).advancedFeaturesEnabled,
      memory: memory,
    );
  }

  Future<void> _confirmDeleteMemory(
    BuildContext context,
    WidgetRef ref,
    ServerMemory memory,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(userMemoriesProvider.notifier);
    final owner = notifier.captureOwner();
    if (owner == null) {
      UiUtils.showMessage(context, l10n.errorMessage);
      return;
    }
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

    try {
      await notifier.deleteItem(memory.id, owner: owner);
    } catch (_) {
      if (context.mounted) {
        UiUtils.showMessage(context, l10n.errorMessage);
      }
    }
  }

  Future<void> _confirmClearMemories(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(userMemoriesProvider.notifier);
    final owner = notifier.captureOwner();
    if (owner == null) {
      UiUtils.showMessage(context, l10n.errorMessage);
      return;
    }
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

    try {
      await notifier.clearAll(owner: owner);
    } catch (_) {
      if (context.mounted) {
        UiUtils.showMessage(context, l10n.errorMessage);
      }
    }
  }

  Widget _buildLoadingTile(BuildContext context, {required String title}) {
    return CustomizationTile(
      leading: const SizedBox(
        width: IconSize.xl,
        height: IconSize.xl,
        child: Center(child: ConduitLoadingIndicator(isCompact: true)),
      ),
      title: title,
      subtitle: '',
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

/// Adds a memory, or edits [memory]. The ordinary editor is the content box
/// alone. With [advanced] it also offers the type and path; a change to either
/// is sent only when the user made one, so editing the text never reclassifies
/// a memory.
///
/// [owner] is the account the entry point was opened for: the Personalization
/// page captures it when it is tapped, native Settings when its list was built.
/// The form refuses to open for another account, and a Save after the account
/// changes is rejected with the typed input still in the form.
Future<void> showMemoryEditor(
  BuildContext context, {
  required UserMemories notifier,
  required MemoryOwner? owner,
  required bool advanced,
  ServerMemory? memory,
}) async {
  final l10n = AppLocalizations.of(context)!;
  if (owner == null || !notifier.isCurrentOwner(owner)) {
    UiUtils.showMessage(context, l10n.errorMessage);
    return;
  }
  final title = memory == null ? l10n.addMemory : l10n.editMemory;

  if (!advanced) {
    await _showTextEditorSheet(
      context,
      title: title,
      description: l10n.memoryEditorDescription,
      initialValue: memory?.content ?? '',
      hintText: l10n.memoryHint,
      nativeSheet: false,
      onSave: (value) async {
        if (memory == null) {
          await notifier.add(value, owner: owner);
        } else {
          await notifier.updateItem(memory.id, value, owner: owner);
        }
      },
    );
    return;
  }

  // A type this client does not know (or an old server's missing one) starts
  // unselected, which keeps whatever the server holds.
  final knownType =
      memory?.type == ServerMemory.userType ||
          memory?.type == ServerMemory.contextType
      ? memory?.type
      : null;
  // The sheet takes over these and disposes them with itself; disposing here
  // would pull them out from under the closing animation.
  final fields = _MemoryEditorFields(
    type: memory == null ? ServerMemory.userType : knownType,
    path: memory?.path ?? '',
  );
  await _showTextEditorSheet(
    context,
    title: title,
    description: l10n.memoryEditorDescription,
    initialValue: memory?.content ?? '',
    hintText: l10n.memoryHint,
    nativeSheet: false,
    extras: fields,
    onSave: (value) async {
      final path = fields.pathController.text.trim();
      if (memory == null) {
        await notifier.add(
          value,
          type: fields.type.value ?? ServerMemory.userType,
          path: path.isEmpty ? null : path,
          owner: owner,
        );
        return;
      }
      final selected = fields.type.value;
      await notifier.updateItem(
        memory.id,
        value,
        type: selected != null && selected != memory.type ? selected : null,
        path: path != (memory.path ?? '') ? path : null,
        owner: owner,
      );
    },
  );
}

Future<void> _showTextEditorSheet(
  BuildContext context, {
  required String title,
  required String description,
  required String initialValue,
  required String hintText,
  required Future<void> Function(String value) onSave,
  // The native sheet closes before [onSave] runs, so a rejected save loses the
  // typed text. Editors whose save can be refused use the Flutter sheet, which
  // stays open with the input.
  bool nativeSheet = true,
  _EditorExtras? extras,
}) async {
  final l10n = AppLocalizations.of(context)!;

  if (Platform.isIOS && nativeSheet) {
    try {
      final result = await NativeSheetBridge.instance.presentSheet(
        root: NativeSheetDetailConfig(
          id: 'text-editor-sheet',
          title: title,
          subtitle: description,
          confirmActionId: 'save',
          confirmActionLabel: AppLocalizations.of(context)!.save,
          items: [
            NativeSheetItemConfig(
              id: 'text-editor-value',
              title: title,
              subtitle: hintText,
              sfSymbol: 'text.bubble',
              kind: NativeSheetItemKind.multilineTextField,
              value: initialValue,
              placeholder: hintText,
            ),
          ],
        ),
        rethrowErrors: true,
      );
      if (result?.actionId != 'save') {
        return;
      }
      final value = result?.values['text-editor-value'] as String? ?? '';
      try {
        await onSave(value);
        if (context.mounted) {
          UiUtils.showMessage(context, l10n.saved);
        }
      } catch (_) {
        if (context.mounted) {
          UiUtils.showMessage(context, l10n.errorMessage);
        }
      }
      return;
    } catch (_) {
      if (!context.mounted) {
        return;
      }
    }
  }

  if (!context.mounted) {
    return;
  }

  await showAdaptiveSelectionSheet<void>(
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
      extras: extras,
    ),
  );
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
    this.extras,
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

  /// Fields shown under the text box. The sheet owns them from here on and
  /// disposes them with itself.
  final _EditorExtras? extras;

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
    widget.extras?.dispose();
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
              if (widget.extras case final extras?) ...[
                const SizedBox(height: Spacing.md),
                extras.build(context),
              ],
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

/// Extra fields an editor sheet shows under its text box.
abstract interface class _EditorExtras {
  Widget build(BuildContext context);

  void dispose();
}

/// Type and path controls for a memory, shown only with Advanced on.
///
/// [type] is null while no type is chosen, which leaves a memory's existing
/// classification alone.
final class _MemoryEditorFields implements _EditorExtras {
  _MemoryEditorFields({String? type, required String path})
    : type = ValueNotifier<String?>(type),
      pathController = TextEditingController(text: path);

  final ValueNotifier<String?> type;
  final TextEditingController pathController;

  @override
  void dispose() {
    type.dispose();
    pathController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.memoryTypeLabel,
          style: theme.label?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.xs),
        ValueListenableBuilder<String?>(
          valueListenable: type,
          builder: (context, selected, _) => Row(
            children: [
              Expanded(
                child: ConduitChip(
                  key: const Key('memory-type-user'),
                  label: l10n.memoryTypeUser,
                  isSelected: selected == ServerMemory.userType,
                  onTap: () => type.value = ServerMemory.userType,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: ConduitChip(
                  key: const Key('memory-type-context'),
                  label: l10n.memoryTypeContext,
                  isSelected: selected == ServerMemory.contextType,
                  onTap: () => type.value = ServerMemory.contextType,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        Text(
          l10n.memoryPathLabel,
          style: theme.label?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.xs),
        ConduitInput(
          key: const Key('memory-path'),
          controller: pathController,
          hint: l10n.memoryPathHint,
        ),
      ],
    );
  }
}

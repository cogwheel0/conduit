import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/model.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/model_list_tile.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../direct_connections/models/direct_connection_profile.dart';
import '../../direct_connections/providers/direct_connection_providers.dart';
import '../../direct_connections/services/direct_model_registry.dart';
import '../../direct_connections/views/ollama_model_actions.dart';
import '../../hermes/models/hermes_model.dart';
import '../models/model_selector_layout.dart';
import '../providers/reasoning_effort_provider.dart';

class ModelSelectorSheet extends ConsumerStatefulWidget {
  const ModelSelectorSheet({super.key, required this.models});

  final List<Model> models;

  @override
  ConsumerState<ModelSelectorSheet> createState() => ModelSelectorSheetState();
}

class ModelSelectorSheetState extends ConsumerState<ModelSelectorSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _showMore = false;

  List<Model> get _selectableModels =>
      widget.models.where((model) => !isHermesModel(model)).toList();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _togglePinnedModel(String modelId) => ref
      .read(personalizationSettingsProvider.notifier)
      .togglePinnedModel(modelId);

  Future<void> _showEffortSelector() async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(reasoningEffortProvider);
    final allowsCustom = ref.read(reasoningEffortAllowsCustomProvider);
    final options = <String>[...kReasoningEffortOptions];
    final customMarker = '__custom__';
    final selected = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: context.conduitTheme.surfaceBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.bottomSheet),
        ),
      ),
      builder: (sheetContext) => ModalSheetSafeArea(
        padding: const EdgeInsets.all(Spacing.modalPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Text(
              l10n.reasoningEffort,
              textAlign: TextAlign.center,
              style: context.conduitTheme.headingSmall,
            ),
            const SizedBox(height: Spacing.md),
            for (final option in options)
              _EffortOption(
                label: _effortLabel(l10n, option),
                selected: current == option,
                onTap: () => Navigator.of(sheetContext).pop(option),
              ),
            if (allowsCustom)
              _EffortOption(
                label: l10n.customReasoningEffort,
                selected: !kReasoningEffortOptions.contains(current),
                onTap: () => Navigator.of(sheetContext).pop(customMarker),
              ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    var effort = selected;
    if (selected == customMarker) {
      final custom = await ThemedDialogs.promptTextInput(
        context,
        title: l10n.customReasoningEffort,
        hintText: l10n.customReasoningEffortHint,
        initialValue: kReasoningEffortOptions.contains(current)
            ? null
            : current,
        maxLength: 64,
        textCapitalization: TextCapitalization.none,
      );
      if (!mounted || custom == null) return;
      final trimmed = custom.trim();
      if (trimmed.isEmpty) return;
      effort = trimmed;
    }
    try {
      await setReasoningEffort(ref.read, normalizeReasoningEffort(effort));
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.errorMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinnedModelIds = ref.watch(effectivePinnedModelIdsProvider);
    final hasOpenWebUiAccount = ref.watch(openWebUiAccountAvailableProvider);
    final localDefaultModelId = ref.watch(appSettingsProvider).defaultModel;
    final defaultModelId = hasOpenWebUiAccount
        ? ref
                  .watch(personalizationSettingsProvider)
                  .asData
                  ?.value
                  .defaultModelId ??
              localDefaultModelId
        : localDefaultModelId;
    final layout = buildModelSelectorLayout(
      models: _selectableModels,
      pinnedModelIds: pinnedModelIds,
      defaultModelId: defaultModelId,
    );
    final normalizedQuery = _searchQuery.trim().toLowerCase();
    final moreModels = layout.more
        .where((model) => modelSelectorQueryMatches(model, normalizedQuery))
        .toList(growable: false);
    final l10n = AppLocalizations.of(context)!;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.94,
      minChildSize: 0.46,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: context.conduitTheme.surfaceBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppBorderRadius.bottomSheet),
          ),
          boxShadow: ConduitShadows.modal(context),
        ),
        child: ModalSheetSafeArea(
          padding: const EdgeInsets.fromLTRB(
            Spacing.modalPadding,
            Spacing.sm,
            Spacing.modalPadding,
            Spacing.modalPadding,
          ),
          child: Column(
            children: [
              const SheetHandle(),
              _SelectorHeader(
                title: _showMore ? l10n.moreModels : l10n.chooseModel,
                isBack: _showMore,
                onPressed: () {
                  if (_showMore) {
                    setState(() {
                      _showMore = false;
                      _searchQuery = '';
                      _searchController.clear();
                    });
                  } else {
                    Navigator.of(context).pop();
                  }
                },
              ),
              const SizedBox(height: Spacing.md),
              if (_showMore) ...[
                ConduitGlassSearchField(
                  controller: _searchController,
                  hintText: l10n.searchModels,
                  query: _searchQuery,
                  onChanged: (value) => setState(() => _searchQuery = value),
                  onClear: () => setState(() {
                    _searchQuery = '';
                    _searchController.clear();
                  }),
                ),
                const SizedBox(height: Spacing.md),
              ],
              Expanded(
                child: _showMore
                    ? _ModelGroup(
                        models: moreModels,
                        onTogglePinnedModel: _togglePinnedModel,
                        scrollController: scrollController,
                      )
                    : ListView(
                        controller: scrollController,
                        children: [
                          _ModelGroup(
                            models: layout.featured,
                            onTogglePinnedModel: _togglePinnedModel,
                          ),
                          const SizedBox(height: Spacing.md),
                          _ActionCard(
                            icon: Platform.isIOS
                                ? CupertinoIcons.timer
                                : Icons.schedule_rounded,
                            title: l10n.reasoningEffort,
                            subtitle: _effortLabel(
                              l10n,
                              ref.watch(reasoningEffortProvider),
                            ),
                            onTap: _showEffortSelector,
                          ),
                          if (layout.more.isNotEmpty) ...[
                            const SizedBox(height: Spacing.md),
                            _ActionCard(
                              icon: Platform.isIOS
                                  ? CupertinoIcons.ellipsis
                                  : Icons.more_horiz_rounded,
                              title: l10n.moreModels,
                              onTap: () => setState(() => _showMore = true),
                            ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _effortLabel(AppLocalizations l10n, String effort) => switch (effort) {
  kAutomaticReasoningEffort => l10n.ollamaThinkingAutomatic,
  'low' => l10n.reasoningEffortLow,
  'medium' => l10n.reasoningEffortMedium,
  'high' => l10n.reasoningEffortHigh,
  'max' => l10n.reasoningEffortMaximum,
  _ => effort,
};

@visibleForTesting
bool modelSelectorQueryMatches(Model model, String query) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return true;
  final directSource = directModelSourceLabel(model)?.toLowerCase();
  return model.name.toLowerCase().contains(normalizedQuery) ||
      model.id.toLowerCase().contains(normalizedQuery) ||
      (directSource?.contains(normalizedQuery) ?? false) ||
      model.modelTags.any((tag) => tag.toLowerCase().contains(normalizedQuery));
}

class _SelectorHeader extends StatelessWidget {
  const _SelectorHeader({
    required this.title,
    required this.isBack,
    required this.onPressed,
  });

  final String title;
  final bool isBack;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Text(
          title,
          style: AppTypography.titleLargeStyle.copyWith(
            fontSize: 18,
            height: 1.22,
            fontWeight: FontWeight.w600,
            color: context.conduitTheme.textPrimary,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            onPressed: onPressed,
            tooltip: isBack
                ? MaterialLocalizations.of(context).backButtonTooltip
                : MaterialLocalizations.of(context).closeButtonTooltip,
            icon: Icon(
              isBack
                  ? (Platform.isIOS
                        ? CupertinoIcons.back
                        : Icons.arrow_back_rounded)
                  : (Platform.isIOS ? CupertinoIcons.xmark : Icons.close),
            ),
          ),
        ),
      ],
    ),
  );
}

class _ModelGroup extends ConsumerWidget {
  const _ModelGroup({
    required this.models,
    required this.onTogglePinnedModel,
    this.scrollController,
  });

  final List<Model> models;
  final Future<void> Function(String modelId) onTogglePinnedModel;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (models.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xxl),
        child: Center(
          child: Text(
            AppLocalizations.of(context)!.noResults,
            style: context.conduitTheme.bodyMedium?.copyWith(
              color: context.conduitTheme.textSecondary,
            ),
          ),
        ),
      );
    }
    final selectedModelId = ref.watch(selectedModelProvider)?.id;
    final pinnedModelIds = ref.watch(effectivePinnedModelIdsProvider);
    final canToggle = ref.watch(canTogglePinnedModelsProvider);
    final api = ref.watch(apiServiceProvider);
    final directRegistry = ref.watch(directModelRegistryProvider);
    final profiles =
        ref.watch(directConnectionProfilesProvider).value ??
        const <DirectConnectionProfile>[];
    final l10n = AppLocalizations.of(context)!;

    Widget buildRow(int index) => _buildModelRow(
      context: context,
      ref: ref,
      model: models[index],
      isLast: index == models.length - 1,
      selectedModelId: selectedModelId,
      pinnedModelIds: pinnedModelIds,
      canToggle: canToggle,
      api: api,
      directRegistry: directRegistry,
      profiles: profiles,
      l10n: l10n,
    );

    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.xs),
      child: scrollController == null
          ? Column(
              children: [
                for (var index = 0; index < models.length; index++)
                  buildRow(index),
              ],
            )
          : ListView.builder(
              controller: scrollController,
              itemCount: models.length,
              itemBuilder: (context, index) => buildRow(index),
            ),
    );
  }

  Widget _buildModelRow({
    required BuildContext context,
    required WidgetRef ref,
    required Model model,
    required bool isLast,
    required String? selectedModelId,
    required List<String> pinnedModelIds,
    required bool canToggle,
    required ApiService? api,
    required DirectModelRegistry directRegistry,
    required List<DirectConnectionProfile> profiles,
    required AppLocalizations l10n,
  }) {
    final binding = directRegistry.resolve(model);
    final profile = binding == null
        ? null
        : profiles.where((item) => item.id == binding.profileId).firstOrNull;
    final lifecycleEnabled =
        binding?.adapterKey == kOllamaAdapterKey &&
        binding?.source == DirectModelSource.device &&
        profile?.supportsOllamaModelLifecycle == true;
    final lifecycle = lifecycleEnabled
        ? ref.watch(ollamaModelLifecycleProvider(binding!.profileId))
        : null;
    final remoteModelId = binding?.remoteModelId ?? '';
    final isLoaded = lifecycle?.value?.isLoaded(remoteModelId) ?? false;
    final isBusy =
        lifecycle?.isLoading == true ||
        (lifecycle?.value?.isBusy(remoteModelId) ?? false);
    final isPinned = pinnedModelIds.contains(model.id);

    return Column(
      children: [
        ConduitContextMenu(
          actions: canToggle
              ? [
                  ConduitContextMenuAction(
                    cupertinoIcon: isPinned
                        ? CupertinoIcons.pin_slash
                        : CupertinoIcons.pin,
                    materialIcon: isPinned
                        ? Icons.push_pin_outlined
                        : Icons.push_pin_rounded,
                    label: isPinned ? l10n.unpin : l10n.pin,
                    onSelected: () => onTogglePinnedModel(model.id),
                  ),
                ]
              : const [],
          child: ModelListTile(
            model: model,
            isSelected: selectedModelId == model.id,
            isPinned: isPinned,
            isLoaded: isLoaded,
            iconUrl: resolveModelIconUrlForModel(api, model),
            trailing: lifecycleEnabled && profile != null
                ? OllamaModelActionsButton(
                    profileId: binding!.profileId,
                    remoteModelId: remoteModelId,
                    modelName: model.name,
                    isLoaded: isLoaded,
                    isStatusKnown: lifecycle?.hasValue ?? false,
                    isBusy: isBusy,
                    currentKeepAlive: profile.ollamaKeepAliveFor(remoteModelId),
                    supportsLifecycle: lifecycleEnabled,
                    isCloud: false,
                    currentThinking: profile.ollamaThinkingFor(remoteModelId),
                  )
                : null,
            onTap: () {
              ref.read(selectedModelProvider.notifier).set(model);
              Navigator.of(context).pop();
            },
          ),
        ),
        if (!isLast)
          Divider(
            height: 1,
            indent: 52,
            color: context.conduitTheme.dividerColor,
          ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ConduitCard(
    onTap: onTap,
    padding: const EdgeInsets.all(Spacing.md),
    child: Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: context.conduitTheme.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: context.conduitTheme.textPrimary),
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTypography.bodyLargeStyle.copyWith(
                  fontSize: 16,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                  color: context.conduitTheme.textPrimary,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: AppTypography.bodyMediumStyle.copyWith(
                    fontSize: 14,
                    height: 1.35,
                    color: context.conduitTheme.buttonPrimary,
                  ),
                ),
            ],
          ),
        ),
        Icon(
          Platform.isIOS ? CupertinoIcons.chevron_right : Icons.chevron_right,
          color: context.conduitTheme.iconSecondary,
        ),
      ],
    ),
  );
}

class _EffortOption extends StatelessWidget {
  const _EffortOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    title: Text(label),
    trailing: selected
        ? Icon(Icons.check, color: context.conduitTheme.buttonPrimary)
        : null,
  );
}

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/settings_service.dart';
import '../../../core/sherpa/sherpa_catalog.dart';
import '../../../core/sherpa/sherpa_model.dart';
import '../../../core/sherpa/sherpa_model_manager.dart';
import '../../../core/sherpa/sherpa_storage.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../widgets/settings_page_scaffold.dart';

class SherpaModelsPage extends ConsumerStatefulWidget {
  const SherpaModelsPage({super.key, this.selectionKind});

  final SherpaModelKind? selectionKind;

  @override
  ConsumerState<SherpaModelsPage> createState() => _SherpaModelsPageState();
}

class _SherpaModelsPageState extends ConsumerState<SherpaModelsPage> {
  final _searchController = TextEditingController();
  SherpaModelKind? _kind;
  SherpaRecognitionMode? _mode;
  SherpaModelTier? _tier;
  SherpaModelFamily? _family;
  String? _language;
  String? _pendingActivation;

  bool get _hasFilters =>
      (widget.selectionKind == null && _kind != null) ||
      _mode != null ||
      _tier != null ||
      _family != null ||
      _language != null;

  void _clearFilters({bool clearSearch = false}) {
    if (clearSearch) _searchController.clear();
    setState(() {
      _kind = widget.selectionKind;
      _mode = null;
      _tier = null;
      _family = null;
      _language = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _kind = widget.selectionKind;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sherpaInstallProgressProvider, (_, next) {
      final id = _pendingActivation;
      final state = id == null ? null : next.value?[id];
      final model = id == null ? null : sherpaModelById(id);
      if (state?.phase == SherpaInstallPhase.installed) {
        setState(() => _pendingActivation = null);
        if (model != null) unawaited(_activate(model));
      }
    });

    final installedAsync = ref.watch(sherpaInstalledModelsProvider);
    final l10n = AppLocalizations.of(context)!;
    final progress = ref.watch(sherpaInstallProgressProvider).value ?? const {};
    final broken = ref.watch(sherpaBrokenModelsProvider).value ?? const {};
    final installedValues =
        installedAsync.value ?? const <InstalledSherpaModel>[];
    final installedById = {
      for (final value in installedValues) value.model.id: value,
    };
    final installedBytes = installedValues.fold<int>(
      0,
      (total, model) => total + model.installedBytes,
    );
    final settings = ref.watch(appSettingsProvider);
    final models = _filteredModels();
    final activeIds = {?settings.sherpaSttModelId, ?settings.sherpaTtsModelId};
    final active = models
        .where((model) => activeIds.contains(model.id))
        .toList(growable: false);
    final installedModels = models
        .where(
          (model) =>
              installedById.containsKey(model.id) &&
              !activeIds.contains(model.id),
        )
        .toList(growable: false);
    final available = models
        .where(
          (model) =>
              !installedById.containsKey(model.id) &&
              !activeIds.contains(model.id),
        )
        .toList(growable: false);

    return SettingsPageScaffold(
      title: widget.selectionKind == null
          ? l10n.sherpaModelsTitle
          : widget.selectionKind == SherpaModelKind.stt
          ? l10n.sherpaChooseSpeechModel
          : l10n.sherpaChooseVoiceModel,
      children: [
        _LibrarySummary(
          subtitle: installedAsync.isLoading
              ? l10n.sherpaCheckingModels
              : l10n.sherpaInstalledSummary(
                  installedValues.length,
                  formatModelBytes(installedBytes),
                ),
          selectionKind: widget.selectionKind,
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          hint: l10n.sherpaSearchModels,
          semanticLabel: l10n.sherpaSearchModels,
          textInputAction: TextInputAction.search,
          prefixIcon: Icon(
            context.usesCupertinoChrome ? CupertinoIcons.search : Icons.search,
            size: IconSize.small,
          ),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : ConduitIconButton(
                  icon: context.usesCupertinoChrome
                      ? CupertinoIcons.xmark_circle_fill
                      : Icons.clear,
                  tooltip: l10n.clear,
                  isCompact: true,
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                ),
        ),
        const SizedBox(height: Spacing.sm),
        _FilterBar(
          kind: _kind,
          mode: _mode,
          tier: _tier,
          family: _family,
          language: _language,
          lockKind: widget.selectionKind != null,
          onKindChanged: (value) => setState(() => _kind = value),
          onModeChanged: (value) => setState(() => _mode = value),
          onTierChanged: (value) => setState(() => _tier = value),
          onFamilyChanged: (value) => setState(() => _family = value),
          onLanguageChanged: (value) => setState(() => _language = value),
          onClear: _hasFilters ? _clearFilters : null,
        ),
        if (installedAsync.isLoading) ...[
          const SizedBox(height: Spacing.xxl),
          Center(
            child: ConduitLoading.inline(
              context: context,
              message: l10n.sherpaCheckingModels,
            ),
          ),
        ] else if (installedAsync.hasError) ...[
          const SizedBox(height: Spacing.lg),
          ConduitEmptyState(
            icon: context.usesCupertinoChrome
                ? CupertinoIcons.exclamationmark_circle
                : Icons.error_outline,
            title: l10n.failedToLoadModels,
            message: l10n.errorMessage,
            isCompact: true,
            action: ConduitButton(
              text: l10n.retry,
              isSecondary: true,
              onPressed: () => ref.invalidate(sherpaInstalledModelsProvider),
            ),
          ),
        ] else if (models.isEmpty) ...[
          const SizedBox(height: Spacing.lg),
          ConduitEmptyState(
            icon: context.usesCupertinoChrome
                ? CupertinoIcons.search
                : Icons.search_off,
            title: l10n.sherpaNoModelsMatch,
            message: l10n.sherpaNoModelsMatchHint,
            isCompact: true,
            action: _hasFilters || _searchController.text.isNotEmpty
                ? ConduitButton(
                    text: l10n.clear,
                    isSecondary: true,
                    onPressed: () => _clearFilters(clearSearch: true),
                  )
                : null,
          ),
        ] else ...[
          _ModelSection(
            title: l10n.sherpaActive,
            models: active,
            installed: installedById,
            progress: progress,
            broken: broken,
            settings: settings,
            selectionMode: widget.selectionKind != null,
            pendingActivation: _pendingActivation,
            onAction: _handleAction,
            onDelete: _delete,
          ),
          _ModelSection(
            title: l10n.sherpaInstalled,
            models: installedModels,
            installed: installedById,
            progress: progress,
            broken: broken,
            settings: settings,
            selectionMode: widget.selectionKind != null,
            pendingActivation: _pendingActivation,
            onAction: _handleAction,
            onDelete: _delete,
          ),
          _ModelSection(
            title: l10n.sherpaAvailable,
            models: available,
            installed: installedById,
            progress: progress,
            broken: broken,
            settings: settings,
            selectionMode: widget.selectionKind != null,
            pendingActivation: _pendingActivation,
            onAction: _handleAction,
            onDelete: _delete,
          ),
        ],
      ],
    );
  }

  List<SherpaModel> _filteredModels() {
    final query = _searchController.text.trim().toLowerCase();
    return sherpaModelCatalog
        .where((model) {
          if (_kind != null && model.kind != _kind) return false;
          if (_mode != null && model.mode != _mode) return false;
          if (_tier != null && model.tier != _tier) return false;
          if (_family != null && model.family != _family) return false;
          if (_language != null && !model.supportsLanguage(_language!)) {
            return false;
          }
          if (query.isNotEmpty &&
              !model.displayName.toLowerCase().contains(query) &&
              !model.family.label.toLowerCase().contains(query)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  Future<void> _handleAction(
    SherpaModel model,
    InstalledSherpaModel? installed,
    SherpaInstallProgress? progress,
    bool broken,
  ) async {
    if (broken) {
      setState(
        () =>
            _pendingActivation = widget.selectionKind == null ? null : model.id,
      );
      await ref.read(sherpaModelManagerProvider).retry(model);
      return;
    }
    if (installed != null) {
      await _activate(model);
      return;
    }
    if (progress?.phase == SherpaInstallPhase.failed) {
      setState(
        () =>
            _pendingActivation = widget.selectionKind == null ? null : model.id,
      );
      await ref.read(sherpaModelManagerProvider).retry(model);
      return;
    }
    if (progress != null &&
        progress.phase != SherpaInstallPhase.installed &&
        progress.phase != SherpaInstallPhase.failed) {
      return;
    }
    if (!await _confirmDownload(model)) return;
    if (!mounted) return;
    setState(
      () => _pendingActivation = widget.selectionKind == null ? null : model.id,
    );
    ref.read(sherpaModelManagerProvider).enqueue(model);
  }

  Future<bool> _confirmDownload(SherpaModel model) async {
    final device = await ref.read(sherpaStorageProvider).deviceInfo();
    if (model.tier != SherpaModelTier.large && device.meteredNetwork != true) {
      return true;
    }
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context)!;
    final deviceCapacity = [
      if (device.physicalMemoryBytes case final bytes?)
        l10n.sherpaPhysicalMemory(formatModelBytes(bytes)),
      if (device.freeStorageBytes case final bytes?)
        l10n.sherpaFreeStorage(formatModelBytes(bytes)),
    ].join(', ');
    final warnings = [
      if (device.meteredNetwork == true) l10n.sherpaMeteredNetworkWarning,
      if (model.tier == SherpaModelTier.large) l10n.sherpaLargeModelWarning,
      if (deviceCapacity.isNotEmpty) l10n.sherpaDeviceCapacity(deviceCapacity),
    ];
    return ThemedDialogs.confirm(
      context,
      title: model.tier == SherpaModelTier.large
          ? l10n.sherpaLargeDownloadTitle
          : l10n.sherpaMeteredDownloadTitle,
      message: [
        l10n.sherpaDownloadSizeSummary(
          formatModelBytes(model.archiveBytes),
          formatModelBytes(model.installedBytes),
        ),
        ...warnings,
      ].join(' '),
      confirmText: l10n.download,
    );
  }

  Future<void> _activate(SherpaModel model) async {
    final notifier = ref.read(appSettingsProvider.notifier);
    final language =
        model.supportsAutomaticLanguage && model.languages.length > 1
        ? null
        : model.languages.first.tag;
    if (model.kind == SherpaModelKind.stt) {
      await notifier.activateSherpaStt(
        modelId: model.id,
        languageCode: language,
      );
    } else {
      await notifier.activateSherpaTts(
        modelId: model.id,
        languageCode: language,
        speakerId: model.speakers.isEmpty
            ? null
            : model.speakers.first.id.toString(),
      );
    }
    if (mounted && widget.selectionKind != null) Navigator.of(context).pop();
  }

  Future<void> _delete(SherpaModel model) async {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.read(appSettingsProvider);
    final active =
        model.id == settings.sherpaSttModelId ||
        model.id == settings.sherpaTtsModelId;
    if (active) {
      UiUtils.showMessage(context, l10n.sherpaDeleteActiveModel);
      return;
    }
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.sherpaDeleteModelTitle,
      message: l10n.sherpaDeleteModelMessage(model.displayName),
      confirmText: l10n.delete,
      isDestructive: true,
    );
    if (confirmed) {
      if (!mounted) return;
      await ref.read(sherpaModelManagerProvider).delete(model);
      if (!mounted) return;
      ref.invalidate(sherpaInstalledModelsProvider);
    }
  }
}

class _LibrarySummary extends StatelessWidget {
  const _LibrarySummary({required this.subtitle, required this.selectionKind});

  final String subtitle;
  final SherpaModelKind? selectionKind;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final icon = switch (selectionKind) {
      SherpaModelKind.stt =>
        context.usesCupertinoChrome
            ? CupertinoIcons.waveform
            : Icons.graphic_eq,
      SherpaModelKind.tts =>
        context.usesCupertinoChrome
            ? CupertinoIcons.speaker_2
            : Icons.record_voice_over,
      null =>
        context.usesCupertinoChrome
            ? CupertinoIcons.arrow_down_circle
            : Icons.download_for_offline_outlined,
    };
    return ConduitCard(
      isCompact: true,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.buttonPrimary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              color: theme.buttonPrimary,
              size: IconSize.medium,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.sherpaModelsSubtitle,
                  style: theme.bodyMedium?.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: Spacing.xxs),
                Text(
                  subtitle,
                  style: theme.bodySmall?.copyWith(color: theme.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.kind,
    required this.mode,
    required this.tier,
    required this.family,
    required this.language,
    required this.lockKind,
    required this.onKindChanged,
    required this.onModeChanged,
    required this.onTierChanged,
    required this.onFamilyChanged,
    required this.onLanguageChanged,
    required this.onClear,
  });

  static final List<String> _languages = List.unmodifiable(
    sherpaModelCatalog
        .expand((model) => model.languages.map((language) => language.tag))
        .toSet()
        .toList()
      ..sort(),
  );

  final SherpaModelKind? kind;
  final SherpaRecognitionMode? mode;
  final SherpaModelTier? tier;
  final SherpaModelFamily? family;
  final String? language;
  final bool lockKind;
  final ValueChanged<SherpaModelKind?> onKindChanged;
  final ValueChanged<SherpaRecognitionMode?> onModeChanged;
  final ValueChanged<SherpaModelTier?> onTierChanged;
  final ValueChanged<SherpaModelFamily?> onFamilyChanged;
  final ValueChanged<String?> onLanguageChanged;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Wrap(
      spacing: Spacing.xs,
      runSpacing: Spacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!lockKind)
          _FilterChip<SherpaModelKind>(
            title: l10n.sherpaFilterType,
            selected: kind,
            values: SherpaModelKind.values,
            labelFor: (value) => value.name.toUpperCase(),
            onChanged: onKindChanged,
          ),
        _FilterChip<SherpaRecognitionMode>(
          title: l10n.sherpaFilterMode,
          selected: mode,
          values: SherpaRecognitionMode.values,
          labelFor: (value) => _modelModeLabel(l10n, value),
          onChanged: onModeChanged,
        ),
        _FilterChip<SherpaModelTier>(
          title: l10n.sherpaFilterSize,
          selected: tier,
          values: SherpaModelTier.values,
          labelFor: (value) => value.label,
          onChanged: onTierChanged,
        ),
        _FilterChip<SherpaModelFamily>(
          title: l10n.sherpaFilterFamily,
          selected: family,
          values: SherpaModelFamily.values,
          labelFor: (value) => value.label,
          onChanged: onFamilyChanged,
        ),
        _FilterChip<String>(
          title: l10n.language,
          selected: language,
          values: _languages,
          labelFor: (value) => value.toUpperCase(),
          onChanged: onLanguageChanged,
        ),
        if (onClear != null)
          ConduitTextButton(text: l10n.clear, onPressed: onClear),
      ],
    );
  }
}

class _FilterChip<T> extends StatelessWidget {
  const _FilterChip({
    required this.title,
    required this.selected,
    required this.values,
    required this.labelFor,
    required this.onChanged,
  });

  final String title;
  final T? selected;
  final List<T> values;
  final String Function(T value) labelFor;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return ConduitChip(
      label: selected == null ? title : labelFor(selected as T),
      icon: selected == null
          ? (context.usesCupertinoChrome
                ? CupertinoIcons.chevron_down
                : Icons.arrow_drop_down)
          : (context.usesCupertinoChrome
                ? CupertinoIcons.slider_horizontal_3
                : Icons.tune),
      isSelected: selected != null,
      isCompact: true,
      onTap: () => _showOptions(context),
    );
  }

  Future<void> _showOptions(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final contentFraction = (120 + ((values.length + 1) * 52)) / height;
    final initialSize = contentFraction.clamp(0.34, 0.78).toDouble();
    return showSettingsSheet<void>(
      context: context,
      builder: (sheetContext) => SettingsSelectorSheet(
        title: title,
        itemCount: values.length + 1,
        initialChildSize: initialSize,
        minChildSize: 0.3,
        maxChildSize: 0.84,
        itemBuilder: (context, index) {
          final value = index == 0 ? null : values[index - 1];
          return SettingsSelectorTile(
            title: value == null
                ? AppLocalizations.of(context)!.sherpaFilterAny
                : labelFor(value),
            selected: selected == value,
            onTap: () {
              onChanged(value);
              Navigator.of(sheetContext).pop();
            },
          );
        },
      ),
    );
  }
}

class _ModelSection extends StatelessWidget {
  const _ModelSection({
    required this.title,
    required this.models,
    required this.installed,
    required this.progress,
    required this.broken,
    required this.settings,
    required this.selectionMode,
    required this.pendingActivation,
    required this.onAction,
    required this.onDelete,
  });

  final String title;
  final List<SherpaModel> models;
  final Map<String, InstalledSherpaModel> installed;
  final Map<String, SherpaInstallProgress> progress;
  final Set<String> broken;
  final AppSettings settings;
  final bool selectionMode;
  final String? pendingActivation;
  final void Function(
    SherpaModel,
    InstalledSherpaModel?,
    SherpaInstallProgress?,
    bool,
  )
  onAction;
  final ValueChanged<SherpaModel> onDelete;

  @override
  Widget build(BuildContext context) {
    if (models.isEmpty) return const SizedBox.shrink();
    final grouped = <SherpaModelFamily, List<SherpaModel>>{};
    for (final model in models) {
      grouped.putIfAbsent(model.family, () => []).add(model);
    }
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Spacing.xl),
        Row(
          children: [
            Expanded(child: SettingsSectionHeader(title: title)),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: Spacing.xxs,
              ),
              decoration: BoxDecoration(
                color: theme.surfaceContainer,
                borderRadius: BorderRadius.circular(AppBorderRadius.badge),
              ),
              child: Text(
                models.length.toString(),
                style: theme.bodySmall?.copyWith(color: theme.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        for (final entry in grouped.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs, bottom: Spacing.xs),
            child: Text(
              entry.key.label,
              style: theme.bodySmall?.copyWith(
                color: theme.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
          for (final model in entry.value)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: _ModelCard(
                model: model,
                installed: installed[model.id],
                progress: progress[model.id],
                broken: broken.contains(model.id),
                active:
                    model.id == settings.sherpaSttModelId ||
                    model.id == settings.sherpaTtsModelId,
                downloadAndUse:
                    selectionMode && !installed.containsKey(model.id),
                pendingActivation: pendingActivation == model.id,
                onAction: () => onAction(
                  model,
                  installed[model.id],
                  progress[model.id],
                  broken.contains(model.id),
                ),
                onDelete: () => onDelete(model),
              ),
            ),
        ],
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.installed,
    required this.progress,
    required this.broken,
    required this.active,
    required this.downloadAndUse,
    required this.pendingActivation,
    required this.onAction,
    required this.onDelete,
  });

  final SherpaModel model;
  final InstalledSherpaModel? installed;
  final SherpaInstallProgress? progress;
  final bool broken;
  final bool active;
  final bool downloadAndUse;
  final bool pendingActivation;
  final VoidCallback onAction;
  final VoidCallback onDelete;

  String _actionLabel(AppLocalizations l10n, {required bool busy}) {
    if (broken) return l10n.sherpaRepair;
    if (pendingActivation) {
      return busy ? _phaseLabel(l10n, progress!.phase) : l10n.sherpaPreparing;
    }
    if (progress?.phase == SherpaInstallPhase.failed) return l10n.retry;
    if (busy) return _phaseLabel(l10n, progress!.phase);
    if (installed != null) return l10n.sherpaUse;
    return downloadAndUse ? l10n.sherpaDownloadAndUse : l10n.download;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final busy =
        progress != null &&
        progress!.phase != SherpaInstallPhase.failed &&
        progress!.phase != SherpaInstallPhase.installed;
    final languages = model.languages
        .map((language) => language.tag.toUpperCase())
        .join(', ');
    final installedSize = installed?.installedBytes ?? model.installedBytes;
    final showAction = !(active && installed != null && !broken);

    return ConduitCard(
      isSelected: active,
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.displayName,
                      style: theme.bodyMedium?.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      model.family.label,
                      style: theme.bodySmall?.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (active)
                _Badge(
                  l10n.sherpaActive,
                  emphasized: true,
                  icon: context.usesCupertinoChrome
                      ? CupertinoIcons.check_mark_circled_solid
                      : Icons.check_circle,
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              _Badge(model.tier.label),
              _Badge(_modelModeLabel(l10n, model.mode)),
              if (model.recommended)
                _Badge(l10n.sherpaRecommended, emphasized: true),
              if (model.speakers.isNotEmpty)
                _Badge(l10n.sherpaVoices(model.speakers.length)),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.xs,
            children: [
              _ModelDetail(
                icon: context.usesCupertinoChrome
                    ? CupertinoIcons.globe
                    : Icons.language,
                label: languages,
              ),
              _ModelDetail(
                icon: context.usesCupertinoChrome
                    ? CupertinoIcons.arrow_down_circle
                    : Icons.download_outlined,
                label: formatModelBytes(model.archiveBytes),
              ),
              _ModelDetail(
                icon: context.usesCupertinoChrome
                    ? CupertinoIcons.archivebox
                    : Icons.storage_outlined,
                label: formatModelBytes(installedSize),
              ),
            ],
          ),
          if (busy) ...[
            const SizedBox(height: Spacing.md),
            _InstallProgress(fraction: progress!.fraction),
            const SizedBox(height: Spacing.xs),
            Text(
              _phaseLabel(l10n, progress!.phase),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
          if (progress?.phase == SherpaInstallPhase.failed) ...[
            const SizedBox(height: Spacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: theme.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppBorderRadius.small),
              ),
              child: Text(
                _phaseLabel(l10n, SherpaInstallPhase.failed),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.bodySmall?.copyWith(color: theme.error),
              ),
            ),
          ],
          if (showAction || (installed != null && !active)) ...[
            const SizedBox(height: Spacing.md),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.end,
                children: [
                  if (installed != null && !active)
                    ConduitTextButton(
                      text: l10n.delete,
                      isDestructive: true,
                      onPressed: onDelete,
                    ),
                  if (showAction)
                    ConduitButton(
                      text: _actionLabel(l10n, busy: busy),
                      isCompact: true,
                      isSecondary: installed != null || broken,
                      isLoading: busy,
                      onPressed: busy ? null : onAction,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InstallProgress extends StatelessWidget {
  const _InstallProgress({required this.fraction});

  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      value: fraction == null ? null : '${(fraction! * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppBorderRadius.circular),
        child: SizedBox(
          height: 4,
          child: LinearProgressIndicator(
            value: fraction,
            backgroundColor: theme.surfaceContainer,
            valueColor: AlwaysStoppedAnimation(theme.buttonPrimary),
          ),
        ),
      ),
    );
  }
}

class _ModelDetail extends StatelessWidget {
  const _ModelDetail({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: IconSize.xs, color: theme.iconSecondary),
            const SizedBox(width: Spacing.xxs),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.bodySmall?.copyWith(color: theme.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, {this.emphasized = false, this.icon});

  final String label;
  final bool emphasized;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final foreground = emphasized ? theme.buttonPrimary : theme.textSecondary;
    final background = emphasized
        ? theme.buttonPrimary.withValues(alpha: 0.1)
        : theme.surfaceContainer;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppBorderRadius.badge),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xxs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: IconSize.xs, color: foreground),
              const SizedBox(width: Spacing.xxs),
            ],
            Text(
              label,
              style: theme.bodySmall?.copyWith(
                color: foreground,
                fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _modelModeLabel(AppLocalizations l10n, SherpaRecognitionMode mode) =>
    switch (mode) {
      SherpaRecognitionMode.streaming => l10n.sherpaStreaming,
      SherpaRecognitionMode.offline => l10n.sherpaOffline,
    };

String _phaseLabel(AppLocalizations l10n, SherpaInstallPhase phase) =>
    l10n.sherpaInstallPhase(phase.name);

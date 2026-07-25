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
import '../../../shared/widgets/conduit_components.dart';
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
      if (state?.phase == SherpaInstallPhase.installed) {
        _pendingActivation = null;
        unawaited(_activate(sherpaModelById(id)!));
      }
    });
    final installed = ref.watch(sherpaInstalledModelsProvider);
    final l10n = AppLocalizations.of(context)!;
    final progress = ref.watch(sherpaInstallProgressProvider).value ?? const {};
    final broken = ref.watch(sherpaBrokenModelsProvider).value ?? const {};
    final installedById = {
      for (final value in installed.value ?? const <InstalledSherpaModel>[])
        value.model.id: value,
    };
    final settings = ref.watch(appSettingsProvider);
    final models = _filteredModels();
    final active = models.where(
      (model) =>
          model.id == settings.sherpaSttModelId ||
          model.id == settings.sherpaTtsModelId,
    );
    final installedModels = models.where(
      (model) =>
          installedById.containsKey(model.id) &&
          !active.any((activeModel) => activeModel.id == model.id),
    );
    final available = models.where(
      (model) => !installedById.containsKey(model.id),
    );

    return SettingsPageScaffold(
      title: widget.selectionKind == null
          ? l10n.sherpaModelsTitle
          : widget.selectionKind == SherpaModelKind.stt
          ? l10n.sherpaChooseSpeechModel
          : l10n.sherpaChooseVoiceModel,
      children: [
        TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: l10n.sherpaSearchModels,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
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
        ),
        if (models.isEmpty) ...[
          const SizedBox(height: 32),
          Center(child: Text(l10n.sherpaNoModelsMatch)),
        ],
        _ModelSection(
          title: l10n.sherpaActive,
          models: active.toList(),
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
          models: installedModels.toList(),
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
          models: available.toList(),
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
  ) async {
    if (installed != null) {
      await _activate(model);
      return;
    }
    if (progress?.phase == SherpaInstallPhase.failed) {
      _pendingActivation = widget.selectionKind == null ? null : model.id;
      await ref.read(sherpaModelManagerProvider).retry(model);
      return;
    }
    if (progress != null &&
        progress.phase != SherpaInstallPhase.installed &&
        progress.phase != SherpaInstallPhase.failed) {
      return;
    }
    if (!await _confirmDownload(model)) return;
    _pendingActivation = widget.selectionKind == null ? null : model.id;
    ref.read(sherpaModelManagerProvider).enqueue(model);
  }

  Future<bool> _confirmDownload(SherpaModel model) async {
    final device = await ref.read(sherpaStorageProvider).deviceInfo();
    if (model.tier != SherpaModelTier.large && device.meteredNetwork != true) {
      return true;
    }
    if (!mounted) return false;
    final largeWarning = model.tier == SherpaModelTier.large
        ? ' Large models require a 64-bit device and can increase memory '
              'use, latency, battery drain, and heat.'
        : '';
    final meteredWarning = device.meteredNetwork == true
        ? ' Your current network is metered.'
        : '';
    final deviceCapacity = [
      if (device.physicalMemoryBytes case final bytes?)
        '${formatModelBytes(bytes)} physical memory',
      if (device.freeStorageBytes case final bytes?)
        '${formatModelBytes(bytes)} free storage',
    ].join(' and ');
    final capacityWarning = deviceCapacity.isEmpty
        ? ''
        : ' This device reports $deviceCapacity.';
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              model.tier == SherpaModelTier.large
                  ? 'Download a Large model?'
                  : 'Use metered data?',
            ),
            content: Text(
              '${formatModelBytes(model.archiveBytes)} download and '
              '${formatModelBytes(model.installedBytes)} installed.'
              '$meteredWarning$largeWarning$capacityWarning',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Download'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _activate(SherpaModel model) async {
    final notifier = ref.read(appSettingsProvider.notifier);
    final language =
        model.family == SherpaModelFamily.nemotron && model.languages.length > 1
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
    final settings = ref.read(appSettingsProvider);
    final active =
        model.id == settings.sherpaSttModelId ||
        model.id == settings.sherpaTtsModelId;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete model?'),
            content: Text(
              active
                  ? 'This model is active. Choose another model before deleting it.'
                  : '${model.displayName} will be removed from this device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              if (!active)
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Delete'),
                ),
            ],
          ),
        ) ??
        false;
    if (confirmed) {
      await ref.read(sherpaModelManagerProvider).delete(model);
      ref.invalidate(sherpaInstalledModelsProvider);
    }
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
  });

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

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (!lockKind)
            _FilterMenu<SherpaModelKind>(
              label: kind?.name.toUpperCase() ?? 'STT / TTS',
              values: SherpaModelKind.values,
              onChanged: onKindChanged,
            ),
          _FilterMenu<SherpaRecognitionMode>(
            label: mode == null
                ? 'Streaming / Offline'
                : mode == SherpaRecognitionMode.streaming
                ? 'Streaming'
                : 'Offline',
            values: SherpaRecognitionMode.values,
            onChanged: onModeChanged,
          ),
          _FilterMenu<SherpaModelTier>(
            label: tier?.label ?? 'Size',
            values: SherpaModelTier.values,
            onChanged: onTierChanged,
          ),
          _FilterMenu<SherpaModelFamily>(
            label: family?.label ?? 'Family',
            values: SherpaModelFamily.values,
            onChanged: onFamilyChanged,
          ),
          _FilterMenu<String>(
            label: language?.toUpperCase() ?? 'Language',
            values: const [
              'ar',
              'cs',
              'de',
              'en',
              'es',
              'fr',
              'id',
              'it',
              'ja',
              'ko',
              'nl',
              'ru',
              'sk',
              'th',
              'vi',
              'yue',
              'zh',
            ],
            onChanged: onLanguageChanged,
          ),
        ],
      ),
    );
  }
}

class _FilterMenu<T> extends StatelessWidget {
  const _FilterMenu({
    required this.label,
    required this.values,
    required this.onChanged,
  });

  final String label;
  final List<T> values;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PopupMenuButton<T?>(
        onSelected: onChanged,
        itemBuilder: (context) => [
          const PopupMenuItem(value: null, child: Text('Any')),
          for (final value in values)
            PopupMenuItem(value: value, child: Text(_label(value))),
        ],
        child: Chip(
          label: Text(label),
          avatar: const Icon(Icons.tune, size: 16),
        ),
      ),
    );
  }

  String _label(Object? value) => switch (value) {
    SherpaModelTier value => value.label,
    SherpaRecognitionMode.streaming => 'Streaming',
    SherpaRecognitionMode.offline => 'Offline',
    SherpaModelKind.stt => 'STT',
    SherpaModelKind.tts => 'TTS',
    SherpaModelFamily value => value.label,
    _ => value.toString().toUpperCase(),
  };
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        for (final entry in grouped.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              entry.key.label,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          for (final model in entry.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
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
                onAction: () =>
                    onAction(model, installed[model.id], progress[model.id]),
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

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final busy =
        progress != null &&
        progress!.phase != SherpaInstallPhase.failed &&
        progress!.phase != SherpaInstallPhase.installed;
    final languages = model.languages
        .map((language) => language.tag.toUpperCase())
        .join(', ');
    return ConduitCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  model.displayName,
                  style: theme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (active)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(CupertinoIcons.checkmark_circle_fill, size: 20),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Badge(model.tier.label),
              _Badge(
                model.mode == SherpaRecognitionMode.streaming
                    ? 'Streaming'
                    : 'Offline',
              ),
              if (model.recommended) const _Badge('Recommended'),
              if (model.speakers.isNotEmpty)
                _Badge('${model.speakers.length} voices'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$languages  •  ${formatModelBytes(model.archiveBytes)} download'
            '  •  ${installed == null ? '${formatModelBytes(model.installedBytes)} installed' : '${formatModelBytes(installed!.installedBytes)} installed'}',
            style: theme.bodySmall?.copyWith(
              color: theme.sidebarForeground.withValues(alpha: 0.72),
            ),
          ),
          if (busy) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress!.fraction),
            const SizedBox(height: 4),
            Text(_phaseLabel(progress!.phase), style: theme.bodySmall),
          ],
          if (progress?.phase == SherpaInstallPhase.failed) ...[
            const SizedBox(height: 8),
            Text(
              progress!.error.toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (installed != null && !active)
                TextButton(onPressed: onDelete, child: const Text('Delete')),
              FilledButton.tonal(
                onPressed: (active && !broken) || busy ? null : onAction,
                child: Text(
                  broken
                      ? 'Repair'
                      : active
                      ? 'Active'
                      : pendingActivation && busy
                      ? 'Preparing…'
                      : progress?.phase == SherpaInstallPhase.failed
                      ? 'Retry'
                      : installed != null
                      ? 'Use'
                      : downloadAndUse
                      ? 'Download & use'
                      : 'Download',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _phaseLabel(SherpaInstallPhase phase) => switch (phase) {
    SherpaInstallPhase.queued => 'Queued',
    SherpaInstallPhase.downloading => 'Downloading',
    SherpaInstallPhase.verifying => 'Verifying',
    SherpaInstallPhase.extracting => 'Extracting',
    SherpaInstallPhase.validating => 'Validating model',
    SherpaInstallPhase.installed => 'Installed',
    SherpaInstallPhase.failed => 'Download failed',
  };
}

class _Badge extends StatelessWidget {
  const _Badge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = context.conduitTheme.buttonPrimary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

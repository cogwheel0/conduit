import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:conduit_core/features/hermes/models/hermes_agent_settings.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_setting_guidance.dart';
import 'package:conduit_core/navigation/routes.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../providers/hermes_agent_settings_provider.dart';
import 'hermes_agent_settings_labels.dart';
import 'hermes_setting_guidance.dart';
import 'hermes_settings_sections.dart';
import '../widgets/hermes_section_icon.dart';
import '../widgets/hermes_visual_model_selector.dart';

/// Profile settings are separate from transport/account configuration.
class HermesAgentSettingsPage extends ConsumerWidget {
  const HermesAgentSettingsPage({super.key, this.section});
  final String? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(hermesAgentSettingsProvider);
    final group = section == 'ensembles'
        ? const HermesSettingGroup('Model ensembles', '', {})
        : hermesMobileSettingGroups
              .where((g) => g.title == section)
              .firstOrNull;
    final title = group == null
        ? l10n.mobileHermesSettings
        : agentGroupLabel(l10n, group.title);
    return UtilityPageScaffold.settings(
      title: section == 'tools'
          ? l10n.mobileAgentTools
          : section == 'ensembles'
          ? l10n.mobileAgentEnsembles
          : title,
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      trailing: CompactIconAction(
        icon: const Icon(Icons.refresh_rounded),
        tooltip: l10n.mobileAgentRefresh,
        onPressed: () => ref.invalidate(hermesAgentSettingsProvider),
      ),
      children: [
        if (section == null) ...[
          _SettingsGroup(
            children: [
              UtilityRow(
                title: l10n.mobileAgentConnection,
                leading: const HermesSectionIcon('Connection'),
                showChevron: true,
                onTap: () => context.pushNamed(RouteNames.hermesConnections),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Hint(l10n.mobileAgentProfileNote),
          const SizedBox(height: 12),
        ],
        if (section == 'tools') ...[
          const HermesToolsetsSection(),
          const SizedBox(height: 16),
          _SettingsGroup(
            children: [
              UtilityRow(
                title: l10n.mobileIntegrations,
                leading: const HermesSectionIcon('Tools'),
                showChevron: true,
                onTap: () => context.pushNamed(RouteNames.hermesMcp),
              ),
            ],
          ),
        ] else
          settings.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: AdaptiveProgressIndicator()),
            ),
            error: (_, _) => _SettingsGroup(
              children: [
                UtilityRow(
                  title: l10n.mobileAgentLoadFailed,
                  subtitle: l10n.mobileAgentRefresh,
                  onTap: () => ref.invalidate(hermesAgentSettingsProvider),
                ),
              ],
            ),
            data: (data) {
              if (data == null) return _Hint(l10n.mobileAgentNoSettings);
              if (group != null) {
                return _AgentSection(settings: data, group: group);
              }
              return _SettingsGroup(
                children: [
                  for (final group in hermesMobileSettingGroups)
                    if (data.fields(group).isNotEmpty ||
                        group.title == 'Models')
                      UtilityRow(
                        title: agentGroupLabel(l10n, group.title),
                        leading: HermesSectionIcon(group.title),
                        showChevron: true,
                        onTap: () => context.pushNamed(
                          RouteNames.hermesAgentSection,
                          pathParameters: {'section': group.title},
                        ),
                      ),
                  UtilityRow(
                    title: l10n.mobileAgentTools,
                    leading: const HermesSectionIcon('Tools'),
                    showChevron: true,
                    onTap: () => context.pushNamed(
                      RouteNames.hermesAgentSection,
                      pathParameters: {'section': 'tools'},
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      text,
      style: TextStyle(fontSize: 14, color: context.conduitTheme.textSecondary),
    ),
  );
}

/// The same title/description hierarchy surrounds rows and picker choices.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children, this.title, this.footer});
  final List<Widget> children;
  final String? title;
  final String? footer;
  @override
  Widget build(BuildContext context) => InsetGroupedList(
    title: title,
    titleStyle: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: context.conduitTheme.textPrimary,
    ),
    footer: footer,
    children: children,
  );
}

class _SettingsSheetHeader extends StatelessWidget {
  const _SettingsSheetHeader({
    required this.title,
    this.description,
    this.padded = true,
  });
  final String title;
  final String? description;
  final bool padded;
  @override
  Widget build(BuildContext context) => Padding(
    padding: padded
        ? const EdgeInsets.fromLTRB(16, 0, 16, 16)
        : const EdgeInsets.only(bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: context.conduitTheme.textPrimary,
                  ),
                ),
              ),
            ),
            CompactIconAction(
              icon: const Icon(Icons.close_rounded),
              tooltip: AppLocalizations.of(context)!.close,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        if (description?.isNotEmpty ?? false) ...[
          const SizedBox(height: 4),
          Text(
            description!,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: context.conduitTheme.textSecondary,
            ),
          ),
        ],
      ],
    ),
  );
}

class _AgentSection extends ConsumerStatefulWidget {
  const _AgentSection({required this.settings, required this.group});
  final HermesAgentSettings settings;
  final HermesSettingGroup group;
  @override
  ConsumerState<_AgentSection> createState() => _AgentSectionState();
}

class _AgentSectionState extends ConsumerState<_AgentSection> {
  bool _busy = false;
  String? _selectedPreset;
  bool _current(HermesAgentSettingsAccess service) =>
      mounted &&
      identical(ref.read(hermesAgentSettingsAccessProvider), service);

  Future<void> _run(
    Future<void> Function(HermesAgentSettingsAccess) action,
  ) async {
    final service = ref.read(hermesAgentSettingsAccessProvider);
    if (_busy || service == null) return;
    setState(() => _busy = true);
    try {
      await action(service);
    } on _SettingsEditCanceled {
      // A canceled picker does not save or produce an error.
    } catch (_) {
      if (mounted && _current(service)) {
        UiUtils.showMessage(
          context,
          AppLocalizations.of(context)!.mobileAgentSaveFailed,
        );
      }
    } finally {
      if (_current(service)) ref.invalidate(hermesAgentSettingsProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(HermesSettingField field) => _run((service) async {
    Object? next;
    final l10n = AppLocalizations.of(context)!;
    if (field.path == 'agent.reasoning_effort' ||
        field.path == 'delegation.reasoning_effort') {
      final main = widget.settings.config['model'];
      final currentModel = field.path.startsWith('delegation')
          ? hermesSettingValue(
              widget.settings.config,
              'delegation.model',
            )?.toString()
          : main is Map
          ? (main['default'] ?? main['model'])?.toString()
          : null;
      next = await _reasoning(
        service,
        currentModel: currentModel,
        current: field.value?.toString(),
      );
    } else if (field.type == 'boolean') {
      next = field.value != true;
    } else if (field.type == 'select') {
      next = await _choices<String>(
        agentSettingLabel(l10n, field.path),
        [
          for (final option in field.options)
            (value: option, label: _valueLabel(option, l10n)),
        ],
        current: field.value,
        description: settingExplanation(l10n, field),
      );
    } else {
      next = await showCompactConfigurationSheet<Object>(
        context,
        (_) => _SettingEditor(
          field,
          choices: settingVoiceChoices(field, widget.settings),
        ),
      );
    }
    if (!_current(service) || next == null || next == field.value) return;
    await service.setAgentSetting(field, next);
  });

  Future<T?> _choices<T>(
    String title,
    List<({T value, String label})> choices, {
    Object? current,
    String? description,
  }) => showCompactConfigurationSheet<T>(
    context,
    (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * .65,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsSheetHeader(title: title, description: description),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                _SettingsGroup(
                  children: [
                    for (final choice in choices)
                      UtilityRow(
                        title: choice.label,
                        titleFontWeight: FontWeight.w400,
                        selected: choice.value == current,
                        trailing: choice.value == current
                            ? const Icon(Icons.check_rounded)
                            : null,
                        onTap: () =>
                            Navigator.of(sheetContext).pop(choice.value),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Future<HermesDesktopModelOption?> _pickModel(
    HermesAgentSettingsAccess service, {
    bool excludeEnsembles = false,
    Map<dynamic, dynamic>? current,
  }) async {
    final options = (await service.configuredModels())
        .where((model) => !excludeEnsembles || model.provider != 'moa')
        .toList();
    if (!mounted || !_current(service)) return null;
    final l10n = AppLocalizations.of(context)!;
    if (options.isEmpty) {
      UiUtils.showMessage(context, l10n.mobileNoModels);
      return null;
    }
    final providers = options.map((model) => model.provider).toSet().toList()
      ..sort();
    final provider = await showCompactSelectionGrid<String>(
      context,
      title: l10n.mobileChooseProvider,
      choices: [
        for (final provider in providers)
          CompactMenuChoice(
            provider,
            _providerLabel(provider),
            selected: provider == current?['provider'],
          ),
      ],
    );
    if (!mounted || !_current(service) || provider == null) return null;
    final models = options.where((m) => m.provider == provider).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return _choices(
      l10n.mobileChooseModel,
      [for (final model in models) (value: model, label: model.name)],
      current: models
          .where(
            (model) => model.id == (current?['model'] ?? current?['default']),
          )
          .firstOrNull,
    );
  }

  Future<String?> _reasoning(
    HermesAgentSettingsAccess service, {
    String? currentModel,
    String? current,
  }) async {
    final options = await service.configuredModels();
    if (!mounted || !_current(service)) return null;
    final model = options.where((m) => m.id == currentModel).firstOrNull;
    final settings = HermesSessionReasoningSettings(
      reasoningAvailable: model?.reasoningAvailable,
      canDisableReasoning: model?.canDisableReasoning,
    );
    return _choices(
      AppLocalizations.of(context)!.mobileAgentAuxiliaryReasoning,
      [
        (value: '', label: AppLocalizations.of(context)!.mobileAgentDefault),
        for (final level in settings.levels)
          (value: level, label: level[0].toUpperCase() + level.substring(1)),
      ],
      current: current ?? '',
    );
  }

  List<Map<String, dynamic>> get _fallbacks {
    final raw = widget.settings.config['fallback_providers'];
    if (raw is! List) return [];
    return [
      for (final row in raw)
        if (row is Map)
          Map<String, dynamic>.from(row)
        else if (row is String && row.contains('/'))
          {
            'provider': row.split('/').first,
            'model': row.substring(row.indexOf('/') + 1),
          },
    ];
  }

  Future<void> _fallback({int? remove, int? move, int? change}) =>
      _run((service) async {
        final rows = _fallbacks;
        if (remove != null) {
          rows.removeAt(remove);
        } else if (move != null && move > 0) {
          final row = rows.removeAt(move);
          rows.insert(move - 1, row);
        } else {
          final model = await _pickModel(
            service,
            current: change == null ? null : rows[change],
          );
          if (!_current(service) || model == null) return;
          final row = <String, dynamic>{
            'provider': model.provider,
            'model': model.id,
            if (model.baseUrl != null) 'base_url': model.baseUrl,
          };
          if (change == null) {
            rows.add(row);
          } else {
            rows[change] = {
              if (rows[change]['provider'] == model.provider) ...rows[change],
              ...row,
            };
          }
        }
        if (_current(service)) {
          await service.setFallbackModels(
            rows,
            widget.settings.config['fallback_providers'],
          );
        }
      });

  Future<void> _auxiliary(Map<String, dynamic> row) => _run((service) async {
    final task = row['task']?.toString();
    if (task == null) return;
    final followsGlobal = row['provider'] == 'global';
    final l10n = AppLocalizations.of(context)!;
    final choice = await showCompactConfigurationSheet<String>(
      context,
      (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * .7,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsSheetHeader(
                  title: _auxiliaryLabel(row),
                  description: _auxiliaryDescription(
                    l10n,
                    task,
                    row['hint']?.toString(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _SettingsGroup(
                    children: [
                      UtilityRow(
                        key: const ValueKey('auxiliary-model-setting'),
                        title: l10n.mobileAgentModelLabel,
                        value: _taskModelSummary(row, l10n),
                        showChevron: true,
                        onTap: () => Navigator.of(sheetContext).pop('model'),
                      ),
                      UtilityRow(
                        key: const ValueKey('auxiliary-reasoning-setting'),
                        title: l10n.mobileAgentAuxiliaryReasoning,
                        value: _effortLabel(
                          followsGlobal
                              ? hermesSettingValue(
                                  widget.settings.config,
                                  'agent.reasoning_effort',
                                )
                              : row['reasoning_effort'],
                          l10n,
                        ),
                        subtitle: followsGlobal
                            ? l10n.mobileAgentGlobalReasoningHint
                            : null,
                        showChevron: !followsGlobal,
                        onTap: followsGlobal
                            ? null
                            : () => Navigator.of(sheetContext).pop('reasoning'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!_current(service)) return;
    if (choice == 'reasoning') {
      final effective = row['effective'];
      final effort = await _reasoning(
        service,
        currentModel: effective is Map
            ? effective['model']?.toString()
            : row['model']?.toString(),
        current: row['reasoning_effort']?.toString(),
      );
      if (_current(service) && effort != null) {
        await service.setAuxiliaryReasoning(
          task: task,
          provider: row['provider']?.toString() ?? 'auto',
          model: row['model']?.toString() ?? '',
          effort: effort.isEmpty ? null : effort,
          baseUrl: row['base_url'] is String ? row['base_url'] as String : null,
        );
      }
    } else if (choice == 'model') {
      final mode = await _modelModes(row, l10n);
      if (!_current(service) || mode == null) return;
      if (mode == 'global') {
        if (!followsGlobal) await service.useGlobalModel(task);
        return;
      }
      if (mode == 'automatic') {
        if (!_isAutomaticAuxiliary(row)) {
          // Reset model routing without resetting this task's reasoning choice.
          await service.setAuxiliaryReasoning(
            task: task,
            provider: 'auto',
            model: '',
            effort: (row['reasoning_effort']?.toString().isEmpty ?? true)
                ? null
                : row['reasoning_effort'].toString(),
          );
        }
        return;
      }
      final model = await _pickModel(service, current: row);
      if (_current(service) && model != null) {
        await service.setDefaultModel(model, task: task);
      }
    }
  });

  String _taskModelSummary(Map<String, dynamic> row, AppLocalizations l10n) {
    if (row['provider'] == 'global') {
      final model = widget.settings.config['model'];
      return '${l10n.mobileAgentUseGlobalModel} · ${_modelLabel(model is Map ? model : widget.settings.model, l10n)}';
    }
    return _auxiliaryModelSummary(row, l10n);
  }

  Future<String?> _modelModes(Map<String, dynamic> row, AppLocalizations l10n) {
    final current = row['provider'] == 'global'
        ? 'global'
        : _isAutomaticAuxiliary(row)
        ? 'automatic'
        : 'custom';
    final pinnedAuto =
        row['provider'] == 'auto' &&
        (row['base_url']?.toString().isNotEmpty ?? false);
    final choices = [
      (
        value: 'global',
        label: l10n.mobileAgentUseGlobalModel,
        description: widget.settings.supportsGlobalModel
            ? l10n.mobileAgentUseGlobalHint
            : l10n.mobileAgentGlobalUnavailable,
        enabled: widget.settings.supportsGlobalModel,
      ),
      (
        value: 'automatic',
        label: l10n.mobileAgentAutomatic,
        description: pinnedAuto
            ? l10n.mobileAgentPinnedEndpointHint
            : l10n.mobileAgentAutomaticModeHint,
        enabled: !pinnedAuto,
      ),
      (
        value: 'custom',
        label: l10n.mobileAgentCustomModel,
        description: l10n.mobileAgentCustomModelHint,
        enabled: true,
      ),
    ];
    return showCompactConfigurationSheet<String>(
      context,
      (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * .7,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SettingsSheetHeader(title: l10n.mobileAgentTaskModel),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: _SettingsGroup(
                  children: [
                    for (final choice in choices)
                      UtilityRow(
                        title: choice.label,
                        subtitle: choice.description,
                        titleFontWeight: FontWeight.w500,
                        subtitleMaxLines: 5,
                        enabled: choice.enabled,
                        selected: current == choice.value,
                        trailing: current == choice.value
                            ? const Icon(Icons.check_rounded)
                            : null,
                        onTap: () =>
                            Navigator.of(sheetContext).pop(choice.value),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fieldRow(HermesSettingField field, AppLocalizations l10n) =>
      UtilityRow(
        key: ValueKey(field.path),
        title: agentSettingLabel(l10n, field.path),
        value: _fieldValueLabel(field, l10n),
        subtitle: field.path == 'tts.xai.auto_speech_tags'
            ? settingExplanation(l10n, field)
            : null,
        subtitleMaxLines: 5,
        showChevron: field.type != 'boolean',
        enabled: !_busy,
        preserveTrailingSemantics: field.type == 'boolean',
        trailing: field.type == 'boolean'
            ? AdaptiveSwitch(
                value: field.value == true,
                semanticLabel: agentSettingLabel(l10n, field.path),
                onChanged: _busy ? null : (_) => _edit(field),
              )
            : null,
        onTap: field.type == 'boolean' ? null : () => _edit(field),
      );

  Future<void> _editEnsemble(
    Future<void> Function(HermesAgentSettingsAccess, Map<String, dynamic>) edit,
  ) => _run((service) async {
    final draft = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(widget.settings.ensembles)) as Map,
    );
    await edit(service, draft);
    if (_current(service)) {
      await service.setModelEnsembles(draft, widget.settings.ensembles);
    }
  });

  Future<void> _ensembleModel(String name, {int? index, bool remove = false}) =>
      _editEnsemble((service, draft) async {
        final preset = (draft['presets'] as Map)[name] as Map;
        final rows = preset['reference_models'] as List;
        if (remove && index != null) {
          rows.removeAt(index);
          return;
        }
        final model = await _pickModel(
          service,
          excludeEnsembles: true,
          current: index == -1
              ? preset['aggregator'] as Map
              : index == null
              ? null
              : rows[index] as Map,
        );
        if (!_current(service) || model == null) {
          throw const _SettingsEditCanceled();
        }
        final row = {
          'provider': model.provider,
          'model': model.id,
          if (model.baseUrl != null) 'base_url': model.baseUrl,
        };
        if (index == -1) {
          preset['aggregator'] = row;
        } else if (index == null) {
          rows.add(row);
        } else {
          rows[index] = row;
        }
      });

  Future<void> _newPreset(String name) => _editEnsemble((service, draft) async {
    final l10n = AppLocalizations.of(context)!;
    final next = await ThemedDialogs.promptTextInput(
      context,
      title: l10n.mobileAgentAddPreset,
      hintText: l10n.mobileAgentPresetNameHint,
      maxLength: 64,
    );
    if (!_current(service) || next == null) throw const _SettingsEditCanceled();
    final presets = draft['presets'] as Map;
    if (presets.containsKey(next)) {
      throw const FormatException('Preset already exists.');
    }
    presets[next] = jsonDecode(jsonEncode(presets[name]));
    _selectedPreset = next;
  });

  Future<void> _deletePreset(String name) => _editEnsemble((
    service,
    draft,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.mobileAgentDeletePreset,
      message: l10n.mobileAgentDeletePresetHint,
    );
    if (!_current(service) || !confirmed) throw const _SettingsEditCanceled();
    final presets = draft['presets'] as Map;
    presets.remove(name);
    if (draft['default_preset'] == name) {
      draft['default_preset'] = presets.keys.first;
    }
    if (draft['active_preset'] == name) draft['active_preset'] = '';
    _selectedPreset = null;
  });

  Widget _buildEnsembles(AppLocalizations l10n) {
    final ensembles = widget.settings.ensembles;
    final presets = ensembles['presets'];
    if (presets is! Map || presets.isEmpty) {
      return _Hint(l10n.mobileAgentNoSettings);
    }
    final name = presets.containsKey(_selectedPreset)
        ? _selectedPreset!
        : ensembles['default_preset']?.toString() ??
              presets.keys.first.toString();
    final preset = presets[name];
    if (preset is! Map ||
        preset['reference_models'] is! List ||
        preset['aggregator'] is! Map) {
      return _Hint(l10n.mobileAgentNoSettings);
    }
    final rows = (preset['reference_models'] as List).whereType<Map>().toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hint(l10n.mobileAgentEnsemblesHint),
        const SizedBox(height: 12),
        _SettingsGroup(
          children: [
            UtilityRow(
              title: l10n.mobileAgentPreset,
              value: name,
              showChevron: true,
              enabled: !_busy,
              onTap: () async {
                final selected = await _choices(l10n.mobileAgentPreset, [
                  for (final key in presets.keys)
                    (value: key.toString(), label: key.toString()),
                ], current: name);
                if (mounted && selected != null) {
                  setState(() => _selectedPreset = selected);
                }
              },
            ),
            UtilityRow(
              title: l10n.mobileAgentDefaultPreset,
              value: ensembles['default_preset']?.toString(),
              showChevron: true,
              enabled: !_busy,
              onTap: () => _editEnsemble((service, draft) async {
                final selected = await _choices(l10n.mobileAgentDefaultPreset, [
                  for (final key in presets.keys)
                    (value: key.toString(), label: key.toString()),
                ], current: ensembles['default_preset']);
                if (!_current(service) || selected == null) {
                  throw const _SettingsEditCanceled();
                }
                draft['default_preset'] = selected;
              }),
            ),
            UtilityRow(
              title: l10n.mobileAgentEnabledPreset,
              value: preset['enabled'] == true ? l10n.enabled : l10n.disabled,
              preserveTrailingSemantics: true,
              trailing: AdaptiveSwitch(
                value: preset['enabled'] == true,
                semanticLabel: l10n.mobileAgentEnabledPreset,
                onChanged: _busy
                    ? null
                    : (enabled) => _editEnsemble((_, draft) async {
                        ((draft['presets'] as Map)[name] as Map)['enabled'] =
                            enabled;
                      }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsGroup(
          title: l10n.mobileAgentReferenceModels,
          children: [
            for (var i = 0; i < rows.length; i++)
              UtilityRow(
                title: rows[i]['model']?.toString() ?? '',
                subtitle: _providerLabel(rows[i]['provider']?.toString() ?? ''),
                enabled: !_busy,
                onTap: () => _ensembleModel(name, index: i),
                preserveTrailingSemantics: true,
                trailing: rows.length > 1
                    ? CompactIconAction(
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                        tooltip: l10n.mobileAgentRemoveReference,
                        onPressed: _busy
                            ? null
                            : () =>
                                  _ensembleModel(name, index: i, remove: true),
                      )
                    : null,
              ),
            UtilityRow(
              title: l10n.mobileAgentAddReference,
              leading: const Icon(Icons.add_rounded),
              enabled: !_busy && rows.length < 32,
              onTap: () => _ensembleModel(name),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsGroup(
          children: [
            UtilityRow(
              title: l10n.mobileAgentAggregator,
              value: _modelLabel(preset['aggregator'] as Map, l10n),
              leading: const HermesSectionIcon('Models'),
              enabled: !_busy,
              showChevron: true,
              onTap: () => _ensembleModel(name, index: -1),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SettingsGroup(
          children: [
            UtilityRow(
              title: l10n.mobileAgentAddPreset,
              leading: const Icon(Icons.add_rounded),
              enabled: !_busy && presets.length < 32,
              onTap: () => _newPreset(name),
            ),
            if (presets.length > 1)
              UtilityRow(
                title: l10n.mobileAgentDeletePreset,
                leading: const Icon(Icons.delete_outline_rounded),
                destructive: true,
                enabled: !_busy,
                onTap: () => _deletePreset(name),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.group.title == 'Model ensembles') return _buildEnsembles(l10n);
    final fields = widget.settings.fields(widget.group);
    final models = widget.group.title == 'Models';
    final fallbacks = _fallbacks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hint(agentGroupDescription(l10n, widget.group.title)),
        const SizedBox(height: 12),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _Hint(l10n.loadingShort),
          ),
        if (models) ...[
          _SettingsGroup(
            title: l10n.mobileAgentGlobalSettings,
            children: [
              HermesGlobalModelSelector(settings: widget.settings),
              for (final field in fields)
                if (!const {
                  'agent.reasoning_effort',
                  'agent.service_tier',
                }.contains(field.path))
                  _fieldRow(field, l10n),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (models && widget.settings.ensembles['presets'] is Map) ...[
          _SettingsGroup(
            children: [
              UtilityRow(
                title: l10n.mobileAgentEnsembles,
                leading: const HermesSectionIcon('Delegation'),
                showChevron: true,
                onTap: () => context.pushNamed(
                  RouteNames.hermesAgentSection,
                  pathParameters: {'section': 'ensembles'},
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (!models && fields.isNotEmpty)
          _SettingsGroup(
            children: [for (final field in fields) _fieldRow(field, l10n)],
          ),
        if (models &&
            (widget.settings.schema.containsKey('fallback_providers') ||
                widget.settings.config.containsKey('fallback_providers'))) ...[
          const SizedBox(height: 20),
          _SettingsGroup(
            title: l10n.mobileAgentFallbackModels,
            footer: l10n.mobileAgentFallbackHint,
            children: [
              for (var i = 0; i < fallbacks.length; i++)
                UtilityRow(
                  title: '${i + 1}. ${fallbacks[i]['model'] ?? ''}',
                  subtitle: _providerLabel(
                    fallbacks[i]['provider']?.toString() ?? '',
                  ),
                  enabled: !_busy,
                  onTap: () => _fallback(change: i),
                  preserveTrailingSemantics: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (i > 0)
                        CompactIconAction(
                          icon: const Icon(Icons.arrow_upward_rounded),
                          tooltip: l10n.mobileAgentMoveEarlier,
                          onPressed: _busy ? null : () => _fallback(move: i),
                        ),
                      CompactIconAction(
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                        tooltip: l10n.mobileAgentRemoveFallback,
                        onPressed: _busy ? null : () => _fallback(remove: i),
                      ),
                    ],
                  ),
                ),
              UtilityRow(
                title: l10n.mobileAgentAddFallback,
                leading: const Icon(Icons.add_rounded),
                enabled: !_busy && fallbacks.length < 32,
                onTap: () => _fallback(),
              ),
            ],
          ),
        ],
        if (models && widget.settings.auxiliary.isNotEmpty) ...[
          const SizedBox(height: 20),
          CompactDisclosureSection(
            key: const ValueKey('customize-hermes'),
            title: l10n.mobileAgentCustomizeHermes,
            icon: Icons.tune_rounded,
            iconWidget: const HermesSectionIcon('Models'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Hint(l10n.mobileAgentCustomizeHint),
                const SizedBox(height: 12),
                _SettingsGroup(
                  children: [
                    for (final row in widget.settings.auxiliary)
                      UtilityRow(
                        title: _auxiliaryLabel(row),
                        subtitle: _auxiliaryDescription(
                          l10n,
                          row['task']?.toString() ?? '',
                          row['hint']?.toString(),
                        ),
                        value: _taskModelSummary(row, l10n),
                        enabled: !_busy,
                        showChevron: true,
                        onTap: () => _auxiliary(row),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

bool _isAutomaticAuxiliary(Map<String, dynamic> row) =>
    (row['base_url']?.toString().trim().isEmpty ?? true) &&
    (row['model']?.toString().trim().isEmpty ?? true) &&
    (row['provider'] == null ||
        row['provider'] == '' ||
        row['provider'] == 'auto');

String _auxiliaryModelSummary(Map<String, dynamic> row, AppLocalizations l10n) {
  final effective = row['effective'];
  final resolved =
      effective is Map &&
          (effective['model'] ?? effective['default']) is String &&
          (effective['model'] ?? effective['default'])
              .toString()
              .trim()
              .isNotEmpty
      ? _modelLabel(effective, l10n)
      : null;
  if (_isAutomaticAuxiliary(row)) {
    return resolved == null
        ? l10n.mobileAgentAutomatic
        : '${l10n.mobileAgentAutomatic} · $resolved';
  }
  if ((row['base_url']?.toString().trim().isNotEmpty ?? false) &&
      (row['model']?.toString().trim().isEmpty ?? true) &&
      resolved == null) {
    return l10n.mobileAgentCustomEndpoint;
  }
  return (row['model']?.toString().trim().isNotEmpty ?? false)
      ? _modelLabel(row, l10n)
      : resolved ??
            '${l10n.mobileAgentDefault} · ${_providerLabel(row['provider']?.toString() ?? '')}';
}

String _effortLabel(Object? value, AppLocalizations l10n) =>
    value == null || value == ''
    ? l10n.mobileAgentDefault
    : _sentenceValue(value.toString());
String _sentenceValue(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
String _fieldValueLabel(HermesSettingField field, AppLocalizations l10n) {
  if (field.path == 'tts.provider' || field.path == 'stt.provider') {
    return switch (field.value) {
      'openai' => 'OpenAI',
      'xai' => 'xAI',
      'edge' => 'Edge',
      'elevenlabs' => 'ElevenLabs',
      'minimax' => 'MiniMax',
      'mistral' => 'Mistral',
      'gemini' => 'Gemini',
      'neutts' => 'NeuTTS',
      'kittentts' => 'KittenTTS',
      'piper' => 'Piper',
      'deepinfra' => 'DeepInfra',
      _ => _valueLabel(field.value, l10n),
    };
  }
  if (field.path == 'agent.max_turns' &&
      (field.value == null ||
          const {
            'none',
            'unlimited',
            'inf',
          }.contains(field.value?.toString().toLowerCase()))) {
    return l10n.mobileAgentUnlimited;
  }
  if (field.value is num) {
    return settingNumberLabel(field.path, field.value as num, l10n);
  }
  if (field.type == 'number' && field.value is String) {
    final number = num.tryParse(field.value as String);
    if (number != null) return settingNumberLabel(field.path, number, l10n);
  }
  if (field.path == 'model_context_length' &&
      (field.value == null || field.value == 0)) {
    return l10n.mobileAgentAutomatic;
  }
  if (field.path.endsWith('reasoning_effort')) {
    return _effortLabel(field.value, l10n);
  }
  if (field.value == 'auto') return l10n.mobileAgentAutomatic;
  return _valueLabel(field.value, l10n);
}

String _auxiliaryDescription(
  AppLocalizations l10n,
  String task, [
  String? hint,
]) => switch (task) {
  'vision' => l10n.mobileAgentTaskVisionHint,
  'compression' => l10n.mobileAgentTaskCompressionHint,
  'skills_hub' => l10n.mobileAgentTaskSkillsHint,
  'approval' => l10n.mobileAgentTaskApprovalHint,
  'mcp' => l10n.mobileAgentTaskMcpHint,
  'title_generation' => l10n.mobileAgentTaskTitlesHint,
  'review' => l10n.mobileAgentTaskReviewHint,
  'voice_chat' => l10n.mobileAgentTaskVoiceHint,
  'triage_specifier' => l10n.mobileAgentTaskPlanningHint,
  'kanban_decomposer' => l10n.mobileAgentTaskBreakdownHint,
  'profile_describer' => l10n.mobileAgentTaskProfilesHint,
  'curator' => l10n.mobileAgentTaskCuratorHint,
  _ => hint?.trim().isNotEmpty == true ? hint! : l10n.mobileAgentTaskOtherHint,
};

String _providerLabel(String value) =>
    value == 'openai-codex' ? 'ChatGPT / Codex' : value.replaceAll('-', ' ');
String _modelLabel(Map<dynamic, dynamic> model, AppLocalizations l10n) =>
    [
          model['model'] ?? model['default'] ?? model['id'],
          if (model['provider'] is String)
            _providerLabel(model['provider'] as String),
        ]
        .where((value) => value is String && value.trim().isNotEmpty)
        .join(' · ')
        .emptyOr(l10n.mobileAgentDefault);
String _auxiliaryLabel(Map<String, dynamic> row) =>
    row['label']?.toString() ??
    switch (row['task']) {
      'vision' => 'Image analysis',
      'compression' => 'Context compression',
      'skills_hub' => 'Skill search',
      'approval' => 'Smart approvals',
      'mcp' => 'Tool routing',
      'title_generation' => 'Conversation titles',
      'review' => 'Review',
      'voice_chat' => 'Voice chat',
      'triage_specifier' => 'Task planning',
      'kanban_decomposer' => 'Task breakdown',
      'profile_describer' => 'Profile descriptions',
      'curator' => 'Skill review',
      _ => row['task']?.toString().replaceAll('_', ' ') ?? '',
    };
String _valueLabel(Object? value, AppLocalizations l10n) => switch (value) {
  null || '' => l10n.mobileAgentDefault,
  'auto' => l10n.mobileAgentAutomatic,
  true => l10n.enabled,
  false => l10n.disabled,
  List() => value.isEmpty ? l10n.mobileAgentEmptyList : value.join(', '),
  _ => value.toString(),
};

extension on String {
  String emptyOr(String other) => isEmpty ? other : this;
}

/// An explicit save allows empty strings/lists and preserves multiline input.
class _SettingEditor extends StatefulWidget {
  const _SettingEditor(this.field, {this.choices = const []});
  final HermesSettingField field;
  final List<String> choices;
  @override
  State<_SettingEditor> createState() => _SettingEditorState();
}

class _SettingEditorState extends State<_SettingEditor> {
  HermesNumericGuidance? get _guidance => widget.field.type == 'number'
      ? hermesNumericGuidance[widget.field.path]
      : null;
  bool get _percent => _guidance?.unit == HermesSettingUnit.percent;
  bool get _guided => _guidance != null || widget.choices.isNotEmpty;
  late bool _custom = !_guided;
  late Object? _pending = widget.field.value;
  late final TextEditingController _text = TextEditingController(
    text: widget.field.value is List
        ? (widget.field.value as List).join('\n')
        : _percent && widget.field.value is num
        ? ((widget.field.value as num) * 100).toString()
        : widget.field.value?.toString() ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final field = widget.field;
    if (!_custom && _pending == field.value) {
      Navigator.of(context).pop();
      return;
    }
    final numeric = num.tryParse(_text.text.trim().replaceAll(',', '.'));
    final Object? next = !_custom
        ? _pending
        : field.type == 'number'
        ? (numeric == null
              ? null
              : _percent
              ? numeric / 100
              : numeric)
        : field.type == 'list'
        ? _text.text
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList()
        : _text.text;
    try {
      field.validate(next);
      Navigator.of(context).pop(next);
    } on FormatException {
      setState(
        () => _error = AppLocalizations.of(context)!.mobileAgentInvalidValue,
      );
    }
  }

  bool _accepts(num value) {
    try {
      widget.field.validate(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  String _limits(AppLocalizations l, HermesNumericGuidance g) {
    final field = widget.field;
    if (field.path == 'compression.threshold') {
      return l.mobileAgentThresholdRange;
    }
    if (field.path == 'agent.max_turns') {
      return l.mobileAgentTurnLimitRange;
    }
    if (field.path == 'delegation.child_timeout_seconds') {
      return l.mobileAgentIdleTimeoutRange;
    }
    if (g.allowedValues != null) {
      return l.mobileAgentAllowedValues(
        g.allowedValues!
            .where(_accepts)
            .map((v) => settingNumberLabel(field.path, v, l))
            .join(', '),
      );
    }
    final minimum = field.minimum != null && field.minimum! > g.minimum
        ? field.minimum!
        : g.minimum;
    final maximum = field.maximum == null
        ? g.maximum
        : g.maximum == null || field.maximum! < g.maximum!
        ? field.maximum
        : g.maximum;
    final lower = settingNumberLabel(
      field.path,
      minimum,
      l,
      describeSpecial: false,
    );
    return maximum == null
        ? l.mobileAgentMinimum(lower)
        : l.mobileAgentRange(lower, settingNumberLabel(field.path, maximum, l));
  }

  void _pick(Object? value) => setState(() {
    _custom = false;
    _pending = value;
    _error = null;
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final field = widget.field;
    final guidance = _guidance;
    final options = <Object>[
      ...?guidance?.presets.where(_accepts),
      ...widget.choices,
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SettingsSheetHeader(
                      title: agentSettingLabel(l, field.path),
                      description: settingExplanation(l, field),
                      padded: false,
                    ),
                    const SizedBox(height: 8),
                    _Hint(
                      '${l.mobileAgentCurrentValue}: ${_fieldValueLabel(field, l)}',
                    ),
                    if (_guided) ...[
                      const SizedBox(height: 12),
                      _Hint(
                        guidance == null || guidance.allowedValues != null
                            ? l.mobileAgentAvailableChoices
                            : l.mobileAgentStartingPoints,
                      ),
                      const SizedBox(height: 6),
                      _SettingsGroup(
                        children: [
                          for (final value in options)
                            UtilityRow(
                              key: ValueKey('setting-preset-$value'),
                              title: value is num
                                  ? settingNumberLabel(field.path, value, l)
                                  : _sentenceValue(value.toString()),
                              subtitle: guidance?.defaultValue == value
                                  ? l.mobileAgentHermesDefault
                                  : null,
                              selected: !_custom && _pending == value,
                              trailing: !_custom && _pending == value
                                  ? const Icon(Icons.check_rounded)
                                  : null,
                              onTap: () => _pick(value),
                            ),
                          if (field.value != null &&
                              !options.contains(field.value))
                            UtilityRow(
                              title: _fieldValueLabel(field, l),
                              subtitle: l.mobileAgentCurrentCustom,
                              selected: !_custom && _pending == field.value,
                              onTap: () => _pick(field.value),
                            ),
                          UtilityRow(
                            key: const ValueKey('setting-custom'),
                            title: l.mobileAgentCustomValue,
                            selected: _custom,
                            showChevron: !_custom,
                            onTap: () => setState(() {
                              _custom = true;
                              _error = null;
                            }),
                          ),
                        ],
                      ),
                      if (guidance != null &&
                          guidance.allowedValues == null) ...[
                        const SizedBox(height: 8),
                        _Hint(l.mobileAgentStartingPointsHint),
                      ],
                    ],
                    if (_custom) ...[
                      const SizedBox(height: 12),
                      _Hint(
                        _percent
                            ? l.mobileAgentPercentInput
                            : l.mobileAgentNewValue,
                      ),
                      if (guidance != null) ...[
                        const SizedBox(height: 4),
                        _Hint(_limits(l, guidance)),
                        if (guidance.integerOnly)
                          _Hint(l.mobileAgentWholeNumbers),
                      ],
                      const SizedBox(height: 6),
                      Semantics(
                        label:
                            '${agentSettingLabel(l, field.path)}. ${l.mobileAgentNewValue}',
                        textField: true,
                        child: AdaptiveTextField(
                          controller: _text,
                          autofocus: !_guided,
                          maxLines: field.type == 'list' ? 5 : 1,
                          maxLength: field.type == 'number'
                              ? null
                              : field.type == 'list'
                              ? 65536
                              : 16384,
                          placeholder: field.type == 'list'
                              ? l.mobileAgentListHint
                              : l.mobileAgentDefault,
                          keyboardType: field.type == 'number'
                              ? const TextInputType.numberWithOptions(
                                  decimal: true,
                                  signed: true,
                                )
                              : TextInputType.text,
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: TextStyle(color: context.conduitTheme.error),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                AdaptiveButton(
                  label: l.cancel,
                  style: AdaptiveButtonStyle.plain,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                AdaptiveButton(
                  label: l.save,
                  color: context.conduitTheme.buttonPrimary,
                  textColor: context.conduitTheme.buttonPrimaryText,
                  onPressed: _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsEditCanceled implements Exception {
  const _SettingsEditCanceled();
}

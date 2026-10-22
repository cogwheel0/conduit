import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/hermes_messages.dart';
import '../providers/hermes_workspace.dart';
import '../widgets/hermes_visual_model_selector.dart';
import '../widgets/hermes_capability_picker.dart';

import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/models/hermes_toolset.dart';

import '../widgets/hermes_message_icon.dart';

class HermesBotSetupPage extends ConsumerStatefulWidget {
  const HermesBotSetupPage({super.key, this.cloneFrom});
  final String? cloneFrom;
  @override
  ConsumerState<HermesBotSetupPage> createState() => _HermesBotSetupPageState();
}

class _HermesBotSetupPageState extends ConsumerState<HermesBotSetupPage> {
  final _name = TextEditingController(),
      _profile = TextEditingController(),
      _title = TextEditingController(),
      _description = TextEditingController(),
      _instructions = TextEditingController(),
      _aboutUser = TextEditingController();
  int _step = 1;
  String _base = 'fresh';
  final _fallbackProfile = 'bot-${const Uuid().v4().substring(0, 8)}';
  bool _shareAuth = false,
      _saving = false,
      _failed = false,
      _profileEdited = false;
  HermesDesktopModelOption? _model;
  List<HermesDesktopModelOption> _models = [];
  final Set<String> _disabledSkills = {},
      _disabledTools = {},
      _disabledIntegrations = {};
  String? _catalogSource, _createdProfile;
  bool _unsupported = false;
  bool get _editable => !_saving && _createdProfile == null;
  bool _catalogInitialized = false,
      _skillsChanged = false,
      _toolsChanged = false,
      _integrationsChanged = false;
  Object? _service;
  @override
  void initState() {
    super.initState();
    _service = ref.read(hermesApiServiceProvider);
    _base = widget.cloneFrom ?? 'fresh';
    _name.addListener(_nameChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadModels();
    });
  }

  Future<void> _loadModels() async {
    final service = _service;
    if (service is HermesDesktopApiService) {
      try {
        final models = await service.configuredModels();
        if (mounted && identical(service, ref.read(hermesApiServiceProvider))) {
          setState(() => _models = models);
        }
      } catch (_) {
        /* Hermes default remains a valid model choice. */
      }
    }
  }

  void _nameChanged() {
    if (!_profileEdited) {
      _profile.text = _name.text
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-|-$'), '');
      if (_profile.text.length > 64) {
        _profile.text = _profile.text
            .substring(0, 64)
            .replaceFirst(RegExp(r'-$'), '');
      }
    }
    if (!_profileEdited &&
        _name.text.trim().isNotEmpty &&
        _profile.text.isEmpty) {
      _profile.text = _fallbackProfile;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.removeListener(_nameChanged);
    for (final c in [
      _name,
      _profile,
      _title,
      _description,
      _instructions,
      _aboutUser,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      HermesConfig.isValidDesktopProfile(_profile.text.trim()) &&
      _profile.text.trim() != 'default';
  Future<void> _save() async {
    final backend = ref.read(hermesMessagesBackendProvider);
    if (backend == null || _saving || !_valid) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      final create = _createdProfile == null
          ? backend.createBot
          : backend.finishBotSetup;
      final bot = await create(
        HermesBotDraft(
          profile: _profile.text.trim(),
          title: _title.text.trim().isEmpty
              ? _name.text.trim()
              : _title.text.trim(),
          role: _title.text.trim(),
          description: _description.text.trim(),
          instructions: _instructions.text.trim(),
          cloneFrom: _base == 'fresh'
              ? null
              : _base == 'hermes'
              ? 'default'
              : _base,
          shareAuth: _shareAuth,
          model: _model?.id,
          provider: _model?.provider,
          disabledSkills: (_base == 'fresh' || _skillsChanged)
              ? _disabledSkills.toList()
              : null,
          toolsets:
              _toolsChanged ||
                  _base == 'fresh' &&
                      (ref
                              .read(
                                hermesBotSetupCatalogProvider(_catalogSource!),
                              )
                              .asData
                              ?.value
                              .tools
                              .isNotEmpty ??
                          false)
              ? [
                  for (final row
                      in ref
                          .read(hermesBotSetupCatalogProvider(_catalogSource!))
                          .asData!
                          .value
                          .tools)
                    if (HermesToolset.fromJson(row) case final tool?)
                      if (!_disabledTools.contains(tool.name)) tool.name,
                ]
              : null,
          mcpServers:
              (_base == 'fresh' || _integrationsChanged) &&
                  ref
                          .read(hermesBotSetupCatalogProvider(_catalogSource!))
                          .asData
                          ?.value
                          .integrations !=
                      null
              ? [
                  for (final row
                      in ref
                          .read(hermesBotSetupCatalogProvider(_catalogSource!))
                          .asData!
                          .value
                          .integrations!)
                    if (validateHermesOpaqueIdentifier(row['name'])
                        case final name?)
                      if (!_disabledIntegrations.contains(name)) name,
                ]
              : null,
        ),
      );
      _createdProfile = bot.name;
      if (!mounted ||
          !identical(_service, ref.read(hermesApiServiceProvider))) {
        return;
      }
      final workspace = ref.read(hermesWorkspaceServiceProvider);
      if (workspace != null) {
        await workspace.initializeBotWorkspace(bot.name);
        if (_aboutUser.text.trim().isNotEmpty) {
          final existing = await workspace.readBotMemory(
            bot.name,
            aboutUser: true,
          );
          await workspace.writeBotMemory(
            bot.name,
            _aboutUser.text.trim(),
            expected: existing,
            aboutUser: true,
          );
        }
      }
      if (!mounted ||
          !identical(_service, ref.read(hermesApiServiceProvider))) {
        return;
      }
      ref.invalidate(hermesBotsProvider);
      ref.invalidate(hermesMessagesBotsProvider);
      ref.invalidate(hermesBotConversationsProvider);
      Navigator.of(context).pop(bot);
    } on HermesBotSetupIncomplete catch (error) {
      if (mounted) {
        setState(() {
          _createdProfile = error.profile;
          _failed = true;
        });
      }
    } on UnsupportedError {
      if (mounted) setState(() => _unsupported = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _capabilityRow(
    String title,
    String kind,
    IconData icon,
    List<Map<String, dynamic>> entries,
    Set<String> disabled,
  ) {
    final valid = entries
        .where((row) => validateHermesOpaqueIdentifier(row['name']) != null)
        .toList();
    final selected = valid
        .where((row) => !disabled.contains(row['name']))
        .length;
    return ListTile(
      key: ValueKey('bot-setup-$kind'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(
        valid.isEmpty
            ? 'None configured'
            : '$selected of ${valid.length} enabled',
      ),
      trailing: const Icon(HermesMessageIcons.next, size: 20),
      enabled: _editable && valid.isNotEmpty,
      onTap: () async {
        final source = _catalogSource;
        final result = await showCompactConfigurationSheet<Set<String>>(
          context,
          (_) => HermesCapabilityPicker(
            title: title,
            requireSelection: kind == 'tools',
            entries: [
              for (final row in valid)
                {...row, 'enabled': !disabled.contains(row['name'])},
            ],
          ),
        );
        if (result == null ||
            !mounted ||
            !_editable ||
            source != _catalogSource ||
            !identical(_service, ref.read(hermesApiServiceProvider))) {
          return;
        }
        setState(() {
          disabled
            ..clear()
            ..addAll(
              valid
                  .where((row) => !result.contains(row['name']))
                  .map((row) => row['name'] as String),
            );
          if (kind == 'skills') _skillsChanged = true;
          if (kind == 'tools') _toolsChanged = true;
          if (kind == 'integrations') _integrationsChanged = true;
        });
      },
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int lines = 1,
    int? length,
    String? key,
    bool profile = false,
    String? help,
  }) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: TextField(
      key: key == null ? null : ValueKey(key),
      controller: controller,
      enabled: _editable,
      minLines: lines,
      maxLines: lines > 1 ? 6 : 1,
      maxLength: length,
      textCapitalization: profile
          ? TextCapitalization.none
          : TextCapitalization.sentences,
      onChanged: (_) {
        if (profile) _profileEdited = true;
        setState(() {});
      },
      decoration: InputDecoration(
        labelText: label,
        counterText: '',
        helperText: help,
        helperMaxLines: 10,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!,
        bots =
            ref.watch(hermesMessagesBotsProvider).asData?.value ??
            <HermesBot>[];
    final same = identical(_service, ref.watch(hermesApiServiceProvider));
    final source = _base == 'fresh'
        ? (ref.read(hermesApiServiceProvider)?.config.desktopProfile ??
              'default')
        : _base == 'hermes'
        ? 'default'
        : _base;
    if (_catalogSource != source) {
      _catalogSource = source;
      _catalogInitialized = false;
      _skillsChanged = false;
      _toolsChanged = false;
      _integrationsChanged = false;
      _disabledIntegrations.clear();
      _disabledSkills.clear();
      _disabledTools.clear();
    }
    final catalog = ref.watch(hermesBotSetupCatalogProvider(source));
    final skills = catalog.asData?.value.skills ?? <Map<String, dynamic>>[];
    final tools = [
      for (final row in catalog.asData?.value.tools ?? <Map<String, dynamic>>[])
        ?HermesToolset.fromJson(row),
    ];
    if (!_catalogInitialized && catalog.hasValue) {
      _disabledSkills.addAll(
        skills
            .where((row) => row['enabled'] == false)
            .map((row) => row['name'].toString()),
      );
      _disabledTools.addAll(
        tools.where((tool) => !tool.enabled).map((tool) => tool.name),
      );
      _disabledIntegrations.addAll(
        (catalog.asData!.value.integrations ?? const <Map<String, dynamic>>[])
            .where((row) => row['enabled'] == false)
            .map((row) => row['name'].toString()),
      );
      _catalogInitialized = true;
    }
    return PopScope(
      canPop: !_saving,
      child: AdaptiveScaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
                child: Row(
                  children: [
                    CompactIconAction(
                      key: const ValueKey('bot-setup-back'),
                      tooltip: l10n.back,
                      onPressed: _saving
                          ? null
                          : () => _step == 2
                                ? setState(() => _step = 1)
                                : Navigator.of(context).pop(),
                      icon: const Icon(HermesMessageIcons.back),
                    ),
                    Expanded(
                      child: Text(
                        l10n.messagesNewBot,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    Text(
                      _step == 1
                          ? l10n.messagesNewBotIdentity
                          : l10n.messagesSetUpBot(
                              _title.text.trim().isEmpty
                                  ? _name.text
                                  : _title.text.trim(),
                            ),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (!same) Text(l10n.messagesLoadFailed),
                    if (_step == 1) ...[
                      _field(
                        l10n.messagesName,
                        _name,
                        length: 256,
                        key: 'bot-setup-name',
                      ),
                      _field(
                        '${l10n.calendarFieldTitle} (optional)',
                        _title,
                        length: 256,
                        key: 'bot-setup-title',
                      ),
                      _field(
                        '${l10n.calendarFieldDescription} (optional)',
                        _description,
                        lines: 3,
                        length: 5000,
                        key: 'bot-setup-role',
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const ValueKey('bot-setup-continue'),
                        onPressed: _valid && same && !_saving
                            ? () => setState(() => _step = 2)
                            : null,
                        child: Text(l10n.messagesContinue),
                      ),
                    ] else ...[
                      const SizedBox(height: 20),
                      Text(
                        l10n.hermesCapabilitiesTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      catalog.when(
                        loading: () =>
                            const Center(child: AdaptiveProgressIndicator()),
                        error: (_, _) => TextButton(
                          onPressed: () => ref.invalidate(
                            hermesBotSetupCatalogProvider(source),
                          ),
                          child: Text(l10n.messagesSkillsUnavailable),
                        ),
                        data: (data) => Column(
                          children: [
                            _capabilityRow(
                              l10n.mobileSkills,
                              'skills',
                              Icons.extension_outlined,
                              skills,
                              _disabledSkills,
                            ),
                            _capabilityRow(
                              l10n.mobileTools,
                              'tools',
                              Icons.handyman_outlined,
                              [
                                for (final tool in tools)
                                  {
                                    'name': tool.name,
                                    'label': tool.label,
                                    'description': tool.description,
                                  },
                              ],
                              _disabledTools,
                            ),
                            if (data.integrations != null)
                              _capabilityRow(
                                l10n.mobileIntegrations,
                                'integrations',
                                Icons.hub_outlined,
                                data.integrations!,
                                _disabledIntegrations,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                        key: const ValueKey('bot-setup-advanced'),
                        title: Text(l10n.advancedFeatures),
                        children: [
                          CompactModelSelector(
                            model: _model?.name ?? l10n.messagesDefaultModel,
                            provider: _model?.provider ?? '',
                            choices: hermesModelCatalogChoices(_models),
                            selectedModelId: _model?.id,
                            currentProviderId: _model?.provider,
                            enableRecommendations: true,
                            efforts: const [],
                            effort: '',
                            fast: false,
                            fastAvailable: false,
                            busy: !_editable,
                            onModel: (choice) => setState(
                              () => _model = _models.firstWhere(
                                (m) =>
                                    m.id == choice.id &&
                                    m.provider == choice.provider,
                              ),
                            ),
                            onEffort: (_) {},
                            onFast: null,
                            onReset: () => setState(() => _model = null),
                            resetLabel: l10n.messagesDefaultModel,
                          ),
                          _field(
                            'Custom SOUL.md',
                            _instructions,
                            lines: 4,
                            length: 16000,
                            key: 'bot-setup-instructions',
                            help: 'Blank uses the name, title, and description. Custom text replaces the generated personality.',
                          ),
                          _field(
                            'About you',
                            _aboutUser,
                            lines: 1,
                            length: 64000,
                            key: 'bot-setup-user-memory',
                            help: 'Your preferences and facts, separate from this bot’s personality.',
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            initialValue: _base,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: l10n.messagesStartFrom,
                            ),
                            items: [
                              DropdownMenuItem(
                                value: 'fresh',
                                child: Text(l10n.messagesFresh),
                              ),
                              DropdownMenuItem(
                                value: 'hermes',
                                child: Text(l10n.messagesCloneHermes),
                              ),
                              for (final bot in bots.where(
                                (b) => b.name != 'default',
                              ))
                                DropdownMenuItem(
                                  value: bot.name,
                                  child: Text(
                                    l10n.messagesCloneBot(bot.title),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: !_editable
                                ? null
                                : (value) => setState(() => _base = value!),
                          ),
                          if (_base != 'fresh')
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                l10n.messagesCloneHelp,
                                style: TextStyle(
                                  color: context.conduitTheme.textSecondary,
                                ),
                              ),
                            ),

                          _field(
                            l10n.messagesProfile,
                            _profile,
                            length: 64,
                            key: 'bot-setup-profile',
                            profile: true,
                          ),
                          CheckboxListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            value: _shareAuth,
                            title: const Text(
                              'Share keys and accounts with Hermes',
                            ),
                            onChanged: !_editable
                                ? null
                                : (value) =>
                                      setState(() => _shareAuth = value!),
                          ),
                          Text(
                            _shareAuth
                                ? 'Uses the main profile’s sign-in and API keys.'
                                : l10n.messagesSeparateAuth,
                            style: TextStyle(
                              color: context.conduitTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      if (_unsupported)
                        Text(
                          l10n.messagesUpdateHermes,
                          style: TextStyle(color: context.conduitTheme.error),
                        ),
                      if (_failed)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            l10n.messagesCreateFailed,
                            style: TextStyle(color: context.conduitTheme.error),
                          ),
                        ),
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const ValueKey('bot-setup-create'),
                        onPressed:
                            _valid &&
                                same &&
                                !_saving &&
                                !catalog.isLoading &&
                                !catalog.hasError &&
                                (tools.isEmpty ||
                                    tools.any(
                                      (tool) =>
                                          !_disabledTools.contains(tool.name),
                                    ))
                            ? _save
                            : null,
                        child: _saving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: AdaptiveProgressIndicator(),
                              )
                            : Text(
                                _createdProfile == null
                                    ? l10n.messagesCreateBot
                                    : l10n.retry,
                              ),
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

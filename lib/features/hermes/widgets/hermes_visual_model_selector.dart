import '../providers/hermes_workspace.dart';

import 'package:conduit_core/utils/continuity_probe.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_agent_settings.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_model_catalog.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/hermes/services/hermes_visual_model_store.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/utils/ui_utils.dart';
import '../providers/hermes_agent_settings_provider.dart';
import '../providers/hermes_mobile_navigation.dart';

import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart'
    show sanitizeHermesProviderErrorMessage;

String _effortValue(Object? value) {
  if (value == false) {
    return 'none';
  }
  if (value is Map) {
    return value['enabled'] == false
        ? 'none'
        : value['effort']?.toString() ?? '';
  }
  return value?.toString() ?? '';
}

String _providerName(String id) => switch (id) {
  'openai-codex' => 'OpenAI Codex',
  'openai' || 'openai-api' => 'OpenAI',
  'anthropic' => 'Anthropic',
  'openrouter' => 'OpenRouter',
  'google' || 'gemini' => 'Google',
  'xai' => 'xAI',
  _ =>
    id
        .split(RegExp('[-_]'))
        .map((s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}')
        .join(' '),
};

String _modelName(String name) {
  final gpt = RegExp(r'^gpt-(\d+(?:\.\d+)?)(?:-(.+))?$').firstMatch(name);
  if (gpt == null) {
    return name;
  }
  final suffix = gpt
      .group(2)
      ?.split('-')
      .map(
        (part) => part.isEmpty
            ? part
            : '${part[0].toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
  return 'GPT-${gpt.group(1)}${suffix == null ? '' : ' $suffix'}';
}

List<CompactModelChoice> hermesModelCatalogChoices(
  List<HermesDesktopModelOption> options,
) {
  final recommended = hermesRecommendedModels(options);
  final identities = {
    for (final model in recommended) (model.provider, model.id),
  };
  return [
    for (final option in [
      ...recommended,
      ...options.where((o) => !identities.contains((o.provider, o.id))),
    ])
      CompactModelChoice(
        option.id,
        _modelName(option.name),
        option.provider,
        _providerName(option.provider),
        recommended: identities.contains((option.provider, option.id)),
      ),
  ];
}

// Hermes can return a legacy string, a config map, or a resolved model summary.
// Read both sources so drafts and global settings show the same active route.
({String id, String provider}) _globalRoute(HermesAgentSettings settings) {
  final raw = settings.config['model'];
  final config = raw is Map ? raw : const {};
  String first(List<Object?> values) =>
      values
          .whereType<String>()
          .where((value) => value.trim().isNotEmpty)
          .firstOrNull ??
      '';
  return (
    id: first([
      config['default'],
      config['model'],
      config['id'],
      raw is String ? raw : null,
      settings.model['model'],
      settings.model['default'],
      settings.model['id'],
    ]),
    provider: first([config['provider'], settings.model['provider']]),
  );
}

final _configuredModels =
    FutureProvider.autoDispose<List<HermesDesktopModelOption>>((ref) {
      final service = ref.watch(hermesApiServiceProvider);
      if (service is HermesDesktopApiService) {
        return service.cachedDefaultModelContext?.models ??
            service.modelContext().then((value) => value.models);
      }
      return ref.watch(hermesAgentSettingsAccessProvider)?.configuredModels() ??
          <HermesDesktopModelOption>[];
    });

final _configuredRecommendations = FutureProvider.autoDispose((ref) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service is! HermesDesktopApiService) {
    return ref.watch(_configuredModels.future);
  }
  return service.modelRecommendations(await service.modelContext());
});

class HermesGlobalModelSelector extends ConsumerStatefulWidget {
  const HermesGlobalModelSelector({super.key, required this.settings});
  final HermesAgentSettings settings;
  @override
  ConsumerState<HermesGlobalModelSelector> createState() =>
      _GlobalSelectorState();
}

class _GlobalSelectorState extends ConsumerState<HermesGlobalModelSelector> {
  bool _busy = false;
  Future<void> _run(
    Future<void> Function(HermesAgentSettingsAccess) action,
  ) async {
    final access = ref.read(hermesAgentSettingsAccessProvider);
    if (_busy || access == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action(access);
      if (!mounted ||
          !identical(access, ref.read(hermesAgentSettingsAccessProvider))) {
        return;
      }
      ref.invalidate(hermesAgentSettingsProvider);
    } catch (_) {
      if (mounted &&
          identical(access, ref.read(hermesAgentSettingsAccessProvider))) {
        UiUtils.showMessage(context, 'Could not update global model settings.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(_configuredModels);
    final recommendations = ref.watch(_configuredRecommendations);
    final options =
        recommendations.asData?.value ??
        inventory.asData?.value ??
        <HermesDesktopModelOption>[];
    final route = _globalRoute(widget.settings);
    final id = route.id;
    final provider = route.provider;
    final current = options
        .where((o) => o.id == id && o.provider == provider)
        .firstOrNull;
    final reasoning = widget.settings.field(
      'agent.reasoning_effort',
      'Reasoning effort',
    );
    final speed = widget.settings.field('agent.service_tier', 'Speed mode');
    final effort = _effortValue(reasoning?.value);
    final fast = const {'fast', 'priority', 'ultrafast'}.contains(speed?.value);
    return CompactModelSelector(
      model: _modelName(current?.name ?? (id.isEmpty ? 'Global model' : id)),
      provider: _providerName(provider),
      choices: hermesModelCatalogChoices(options),
      enableRecommendations: true,
      recommendationsLoading: recommendations.isLoading,
      selectedModelId: id,
      currentProviderId: provider,
      efforts: reasoning == null ? const [] : current?.effortLevels ?? const [],
      effort: effort,
      fast: fast,
      fastAvailable: current?.supportsFast == true && speed != null,
      busy: _busy || inventory.isLoading,
      status: _busy
          ? 'Saving…'
          : inventory.hasError
          ? 'Models unavailable'
          : inventory.isLoading
          ? 'Loading models…'
          : null,
      onRetry: inventory.hasError
          ? () {
              final service = ref.read(hermesApiServiceProvider);
              if (service is HermesDesktopApiService) {
                service.invalidateModelContext();
              }
              ref.invalidate(_configuredModels);
              ref.invalidate(_configuredRecommendations);
            }
          : null,
      onModel: (choice) => _run(
        (access) => access.setDefaultModel(
          options.firstWhere(
            (o) => o.id == choice.id && o.provider == choice.provider,
          ),
        ),
      ),
      onEffort: (value) {
        if (reasoning != null) {
          _run((access) => access.setAgentSetting(reasoning, value));
        }
      },
      onFast: current?.supportsFast == true && speed != null
          ? () => _run(
              (access) =>
                  access.setAgentSetting(speed, fast ? 'normal' : 'fast'),
            )
          : null,
      resetLabel: 'Reload global settings',
      onReset: () {
        final service = ref.read(hermesApiServiceProvider);
        if (service is HermesDesktopApiService) {
          service.invalidateModelContext();
        }
        ref.invalidate(_configuredModels);
        ref.invalidate(_configuredRecommendations);
        ref.invalidate(hermesAgentSettingsProvider);
      },
    );
  }
}

class HermesChatModelSelector extends ConsumerStatefulWidget {
  const HermesChatModelSelector({super.key, this.visible = true});
  final bool visible;
  @override
  ConsumerState<HermesChatModelSelector> createState() => _ChatSelectorState();
}

class _ChatSelectorState extends ConsumerState<HermesChatModelSelector> {
  bool _busy = false, _loaded = false;
  bool _loading = false, _recommendationsLoading = false;
  int _loadEpoch = 0;
  String? _error;
  List<HermesDesktopModelOption> _models = [];
  HermesSessionReasoningSettings? _settings;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  String? _identity(HermesDesktopApiService service) {
    final endpoint = HermesConfigController.connectionEndpoint(
      service.config.baseUrl,
    );
    return endpoint == null
        ? null
        : HermesLocalDocumentTrustStore.connectionIdentity(
            endpointIdentity: endpoint,
            principalId: ref
                .read(hermesConfigProvider.notifier)
                .documentTrustPrincipalId(),
          );
  }

  int _profileRevision = 0;
  bool _current(
    HermesDesktopApiService service,
    String? conversationId,
    String session,
    String identity,
  ) {
    final conversation = ref.read(activeConversationProvider);
    final activeId = conversation?.metadata['hermesSessionId'];
    if (conversationId == null) {
      return mounted &&
          conversation == null &&
          identical(ref.read(hermesApiServiceProvider), service) &&
          _identity(service) == identity;
    }
    return mounted &&
        identical(ref.read(hermesApiServiceProvider), service) &&
        isNativeHermesConversation(conversation) &&
        conversation?.id == conversationId &&
        conversation?.metadata[kHermesConnectionIdentityMetadataKey] ==
            identity &&
        activeId is String &&
        service.sessionIdsReferToSameBinding(activeId, session);
  }

  Future<void> _run(
    Future<void> Function(
      HermesDesktopApiService,
      String,
      String,
      bool Function(),
    )
    action,
  ) async {
    final service = ref.read(hermesApiServiceProvider);
    final conversation = ref.read(activeConversationProvider);
    final session = conversation == null
        ? ''
        : validateHermesOpaqueIdentifier(
            conversation.metadata['hermesSessionId'],
          );
    if (_busy || service is! HermesDesktopApiService || session == null) {
      return;
    }
    if (ref.read(isChatStreamingProvider)) return;
    final identity = _identity(service);
    final controller = ref.read(hermesConfigProvider.notifier);
    final admission = controller.captureSessionActionAdmission();
    if (admission == null || identity == null) {
      return;
    }
    final draft = ref.read(hermesMobileNavigationProvider).draft;
    bool current() =>
        mounted &&
        !ref.read(isChatStreamingProvider) &&
        (conversation != null ||
            ref.read(hermesMobileNavigationProvider).draft == draft) &&
        controller.sessionActionAdmissionIsCurrent(admission) &&
        _current(service, conversation?.id, session, identity);
    if (!current()) {
      return;
    }
    setState(() {
      _loadEpoch++;
      _recommendationsLoading = false;
      _busy = true;
      _error = null;
    });
    try {
      await action(service, session, identity, current);
    } catch (_) {
      if (current()) {
        setState(() => _error = 'Model update failed');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _load({bool refresh = false}) async {
    final service = ref.read(hermesApiServiceProvider);
    final conversation = ref.read(activeConversationProvider);
    final session = conversation == null
        ? ''
        : validateHermesOpaqueIdentifier(
            conversation.metadata['hermesSessionId'],
          );
    if (_busy || service is! HermesDesktopApiService || session == null) return;
    final identity = _identity(service);
    final controller = ref.read(hermesConfigProvider.notifier);
    final admission = controller.captureSessionActionAdmission();
    if (identity == null || admission == null) return;
    final draftId = ref.read(hermesMobileNavigationProvider).draft;
    final epoch = ++_loadEpoch;
    bool current() =>
        mounted &&
        epoch == _loadEpoch &&
        (conversation != null ||
            ref.read(hermesMobileNavigationProvider).draft == draftId) &&
        controller.sessionActionAdmissionIsCurrent(admission) &&
        _current(service, conversation?.id, session, identity);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stored = session.isEmpty
          ? null
          : HermesVisualModelStore.read(identity, session);
      final snapshot = await service.modelContext(
        sessionId: session.isEmpty ? null : session,
        followGlobal: stored?.followGlobal == true,
        refresh: refresh,
      );
      if (!current()) return;
      var settings = snapshot.settings;
      if (session.isEmpty) {
        final draft = ref.read(hermesVisualDraftOptionsProvider);
        final id = draft?.model ?? settings.modelId;
        final provider = draft?.provider ?? settings.provider;
        final picked = snapshot.models
            .where((o) => o.id == id && o.provider == provider)
            .firstOrNull;
        settings = HermesSessionReasoningSettings(
          modelId: id,
          provider: provider,
          model: picked?.name ?? id,
          effort: draft?.reasoningEffort ?? settings.effort,
          fast: draft?.fast ?? settings.fast,
          supportsFast: picked?.supportsFast ?? settings.supportsFast,
          reasoningAvailable:
              picked?.reasoningAvailable ?? settings.reasoningAvailable,
          canDisableReasoning:
              picked?.canDisableReasoning ?? settings.canDisableReasoning,
          supportedEfforts:
              picked?.supportedEfforts ?? settings.supportedEfforts,
        );
        if (draft == null) {
          ref
              .read(hermesVisualDraftOptionsProvider.notifier)
              .set(const HermesDesktopSessionOptions(followGlobal: true));
        }
      } else if (stored == null) {
        await HermesVisualModelStore.write(
          identity,
          session,
          const HermesDesktopSessionOptions(preserveSession: true),
        );
        if (!current()) return;
      }
      setState(() {
        _models = snapshot.models;
        _settings = settings;
        _loaded = true;
        _loading = false;
        _recommendationsLoading = true;
      });
      ContinuityProbe.mark('model-context-ready');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current()) ContinuityProbe.mark('model-context-frame');
      });
      // The real catalog is already usable. Optional recommendation hints
      // cannot hold the current model, provider browsing, or composer hostage.
      final enriched = await service.modelRecommendations(snapshot);
      if (!current()) return;
      setState(() {
        _models = enriched;
        _recommendationsLoading = false;
      });
    } catch (_) {
      if (current()) {
        setState(() {
          _error = 'Models unavailable';
          _recommendationsLoading = false;
        });
      }
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  Future<void> _save(
    HermesDesktopApiService service,
    String session,
    String identity,
    bool Function() current, {
    bool global = false,
  }) async {
    final settings = (await service.modelContext(
      sessionId: session,
      refresh: true,
    )).settings;
    if (!current()) {
      return;
    }
    await HermesVisualModelStore.write(
      identity,
      session,
      global
          ? const HermesDesktopSessionOptions(followGlobal: true)
          : const HermesDesktopSessionOptions(preserveSession: true),
    );
    if (!current()) {
      return;
    }
    setState(() {
      _settings = settings;
    });
  }

  Future<bool> _switchModel(
    HermesDesktopApiService service,
    String session,
    String model,
    String provider,
    bool Function() current,
  ) async {
    var result = await service.configureSession(
      session,
      model: model,
      provider: provider,
    );
    if (!mounted || !current()) {
      return false;
    }
    if (result['confirm_required'] == true) {
      final confirmed = await ThemedDialogs.confirm(
        context,
        title: 'Change model',
        message: sanitizeHermesProviderErrorMessage(
          validateHermesBoundedString(
                result['confirm_message'],
                maxCharacters: 1000,
              ) ??
              'This model may cost more. Continue?',
          sensitiveValues: service.config.sensitiveValues,
        ),
      );
      if (confirmed != true || !current()) {
        return false;
      }
      result = await service.configureSession(
        session,
        model: model,
        provider: provider,
        confirmExpensiveModel: true,
      );
      if (!current() || result['confirm_required'] == true) {
        return false;
      }
    }
    return true;
  }

  Future<void> _model(CompactModelChoice choice) =>
      _run((service, session, identity, current) async {
        if (session.isEmpty) {
          final picked = _models.firstWhere(
            (o) => o.id == choice.id && o.provider == choice.provider,
          );
          _draft(picked: picked);
          return;
        }
        if (!await _switchModel(
              service,
              session,
              choice.id,
              choice.provider,
              current,
            ) ||
            !current()) {
          return;
        }
        await _save(service, session, identity, current);
      });
  void _draft({HermesDesktopModelOption? picked, String? effort, bool? fast}) {
    final old = _settings;
    if (old == null) {
      return;
    }
    final levels = picked?.effortLevels;
    final nextEffort =
        effort ??
        (levels != null && levels.isNotEmpty && !levels.contains(old.effort)
            ? (levels.contains('medium') ? 'medium' : levels.first)
            : old.effort);
    final settings = HermesSessionReasoningSettings(
      modelId: picked?.id ?? old.modelId,
      provider: picked?.provider ?? old.provider,
      model: picked?.name ?? old.model,
      effort: nextEffort,
      fast: fast ?? (picked == null ? old.fast : false),
      supportsFast: picked?.supportsFast ?? old.supportsFast,
      reasoningAvailable: picked?.reasoningAvailable ?? old.reasoningAvailable,
      canDisableReasoning:
          picked?.canDisableReasoning ?? old.canDisableReasoning,
      supportedEfforts: picked?.supportedEfforts ?? old.supportedEfforts,
    );
    ref
        .read(hermesVisualDraftOptionsProvider.notifier)
        .set(
          HermesDesktopSessionOptions(
            model: settings.modelId,
            provider: settings.provider,
            reasoningEffort: settings.effort,
            fast: settings.supportsFast ? settings.fast : null,
          ),
        );
    setState(() {
      _settings = settings;
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(hermesApiServiceProvider);
    final conversation = ref.watch(activeConversationProvider);
    final session = conversation == null
        ? ''
        : validateHermesOpaqueIdentifier(
            conversation.metadata['hermesSessionId'],
          );
    if (service is! HermesDesktopApiService || session == null) {
      return const SizedBox.shrink();
    }
    final identity = _identity(service);
    if (identity == null ||
        !_current(service, conversation?.id, session, identity)) {
      return const SizedBox.shrink();
    }
    final profile = conversation?.metadata['hermesBotProfile']?.toString();
    final revision = profile == null
        ? 0
        : ref.watch(
            hermesProfileRevisionsProvider.select(
              (values) => values[profile] ?? 0,
            ),
          );
    if (revision != _profileRevision) {
      _profileRevision = revision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(refresh: true);
      });
    }
    final settings = _settings;
    final effort = settings?.effort ?? '';
    final panel = ref.watch(hermesMobileModelPanelProvider);
    return CompactModelReveal(
      visible: widget.visible,
      child: Align(
        alignment: Alignment.centerLeft,
        child: CompactModelPopover(
          enabled: widget.visible,
          onDismissChanged: (dismiss) {
            if (dismiss == null) {
              panel.clear(this);
            } else {
              panel.register(this, dismiss);
            }
          },
          label: !_loaded
              ? (_loading ? 'Loading model…' : 'Model')
              : [
                  _modelName(settings?.model ?? 'Model'),
                  if (effort.isNotEmpty)
                    '${effort[0].toUpperCase()}${effort.substring(1)}',
                ].join(' · '),
          onOpen: _load,
          child: CompactModelSelector(
            model: _modelName(settings?.model ?? 'Model'),
            provider: _providerName(settings?.provider ?? ''),
            choices: hermesModelCatalogChoices(_models),
            enableRecommendations: true,
            selectedModelId: settings?.modelId,
            currentProviderId: settings?.provider,
            efforts: settings?.levels ?? const [],
            effort: settings?.effort ?? '',
            fast: settings?.fast == true,
            fastAvailable: settings?.supportsFast == true,
            busy: _busy || !_loaded || ref.watch(isChatStreamingProvider),
            recommendationsLoading: _recommendationsLoading,
            status:
                _error ??
                (_busy
                    ? 'Saving…'
                    : ref.watch(isChatStreamingProvider)
                    ? 'Changes after reply'
                    : _loading || !_loaded
                    ? 'Loading models…'
                    : null),
            onRetry: _error == null ? null : () => _load(refresh: true),
            onModel: _model,
            onEffort: (value) =>
                _run((service, session, identity, current) async {
                  if (session.isEmpty) {
                    _draft(effort: value);
                    return;
                  }
                  await service.configureSession(session, reasoning: value);
                  if (current()) {
                    await _save(service, session, identity, current);
                  }
                }),
            onFast: settings?.supportsFast == true
                ? () => _run((service, session, identity, current) async {
                    if (session.isEmpty) {
                      _draft(fast: settings?.fast != true);
                      return;
                    }
                    await service.configureSession(
                      session,
                      fast: settings?.fast != true,
                    );
                    if (current()) {
                      await _save(service, session, identity, current);
                    }
                  })
                : null,
            onReset: () async {
              await _run((service, session, identity, current) async {
                if (session.isEmpty) {
                  ref.read(hermesVisualDraftOptionsProvider.notifier).set(null);
                  _loaded = false;
                  return;
                }
                final global = await service.globalSessionOptions(session);
                if (!current()) return;
                if (!await _switchModel(
                      service,
                      session,
                      global.model!,
                      global.provider!,
                      current,
                    ) ||
                    !current()) {
                  return;
                }
                await service.applyGlobalSessionOptions(session);
                if (current()) {
                  await _save(
                    service,
                    session,
                    identity,
                    current,
                    global: true,
                  );
                }
              });
              if (mounted && ref.read(activeConversationProvider) == null) {
                await _load();
              }
            },
            resetLabel: 'Use global model and reasoning',
          ),
        ),
      ),
    );
  }
}

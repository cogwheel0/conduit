import 'dart:async';

import 'package:conduit_core/features/chat/models/model_selector_layout.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        captureOpenWebUiReasoningPickTargetFor,
        modelControlChoicesProvider,
        modelControlStates,
        selectReasoningEffortForModel,
        terminalAgentModelsIn,
        terminalAgentScopeFor,
        terminalAgentSelectionGuardProvider;
import 'package:conduit_core/features/chat/providers/reasoning_effort_provider.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart'
    show kOllamaAdapterKey;
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show directModelRegistryProvider;
import 'package:conduit_core/features/direct_connections/services/model_logo_catalog.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesFastTierSelectionProvider;
import 'package:conduit_core/features/librechat/models/librechat_model.dart'
    show libreChatModelSection;
import 'package:conduit_core/features/terminal/models/terminal_agent_model.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart'
    show selectedTerminalIdProvider;
import 'package:conduit_core/models/model_controls.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart'
    show currentPreferenceAccountId;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart'
    show appSettingsProvider;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'account_scope.dart';
import 'event_bus.dart';
import 'settled.dart';

/// How long [currentModel] waits for the account's default to resolve.
///
/// Resolving reads the user's settings from the server. A server out of
/// reach is retried for much longer than a window should wait for its model
/// list, so past this the answer is "nothing chosen yet".
const _defaultModelWait = Duration(seconds: 5);

/// How long `models.list` waits for the account's pins to load.
const _listSettingsWait = Duration(milliseconds: 1500);

/// The section the picker's layout files coding agents under; the window
/// draws them from [ModelList.agents] under its own heading.
const _agentsSection = (label: '\u0000agents', order: 1 << 20);

/// A coding agent's place on the wire, from its model id; null when [id] is
/// not an agent's.
TerminalAgentDto? terminalAgentDto(String? id, {String? terminalName}) {
  final agent = parseTerminalAgentModelId(id);
  if (agent == null) return null;
  final name = terminalName?.trim();
  return TerminalAgentDto(
    terminalId: agent.terminalId,
    terminalName: name == null || name.isEmpty ? null : name,
    agent: agent.provider,
    agentName: terminalAgentName(agent.provider),
    model: agent.model,
  );
}

/// The model a turn that names none runs with: the account's selection, or
/// else its default.
///
/// The default is the one the server's user settings name, or the one last
/// used on this device. Resolving it also selects it, as the mobile chat
/// screen does when it opens. Nothing in the daemon resolved it before, so a
/// fresh sign-in reported no selection, and the first turn ran on whichever
/// model the server happened to list first.
Future<core.Model?> currentModel(ProviderContainer container) async {
  final selected = container.read(selectedModelProvider);
  if (selected != null) return selected;
  core.Model? resolved;
  try {
    resolved = await readSettled(
      container,
      defaultModelProvider.future,
    ).timeout(_defaultModelWait);
  } on Object catch (error) {
    DebugLogger.warning(
      'default-model-unresolved',
      scope: 'daemon/models',
      data: <String, Object?>{'error': '$error'},
    );
    return null;
  }
  return container.read(selectedModelProvider) ?? resolved;
}

/// Implements `models.*` over the core's model providers.
final class ModelsService {
  ModelsService(this._container, {EventBus? events}) {
    if (events != null) _announceChanges(events);
  }

  final ProviderContainer _container;

  /// Publishes `models.changed` when the ids on offer change, or the model
  /// the next turn runs with.
  ///
  /// A direct connection's models are discovered after it is saved, over
  /// the network, so the list a window fetched straight after saving did
  /// not have them yet -- and nothing told it to look again. A new Default
  /// Model in Settings changes the selection a moment after it is saved
  /// (the core's `defaultModelSettingSelectionProvider`, kept alive here as
  /// mobile keeps it), and the composers show it.
  void _announceChanges(EventBus events) {
    _container.listen<void>(defaultModelSettingSelectionProvider, (_, _) {});
    // As mobile keeps them: a coding agent goes when its terminal is turned
    // off, and a control's pick the model no longer offers is cleared.
    _container.listen<void>(terminalAgentSelectionGuardProvider, (_, _) {});
    _container.listen<AsyncValue<ModelControlChoices>>(
      modelControlChoicesProvider,
      (_, _) {},
    );
    _container.listen<core.Model?>(selectedModelProvider, (previous, next) {
      if (previous?.id == next?.id) return;
      events.emit(ConduitEventSpecs.modelsChanged, null);
    });
    List<String>? last;
    _container.listen<AsyncValue<List<core.Model>>>(modelsProvider, (_, next) {
      final models = next.value;
      if (models == null) return;
      final ids = models.map((model) => model.id).toList(growable: false);
      final previous = last;
      last = ids;
      if (previous == null || _sameIds(previous, ids)) return;
      events.emit(ConduitEventSpecs.modelsChanged, null);
    });
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The models on offer.
  ///
  /// When the server cannot be reached, the refresh behind the cached list
  /// fails, and the core keeps that list beside the error, as mobile shows
  /// it. The composer offers that list too, instead of no models at all.
  /// The failure is the answer only when there is no list.
  Future<List<core.Model>> _models() async {
    try {
      return await readSettled(_container, modelsProvider.future);
    } on Object catch (error) {
      final last = _container.read(modelsProvider).value;
      if (last == null) rethrow;
      DebugLogger.warning(
        'models-stale',
        scope: 'daemon/models',
        data: <String, Object?>{'count': last.length, 'error': '$error'},
      );
      return last;
    }
  }

  /// The chat a list last reopened its coding agent for: a chat started
  /// with one reopens with it once, as on mobile, and the user may pick
  /// another model there afterwards.
  String? _reopenedFor;

  /// One account's list: started again once if the account (or its
  /// signed-in user) changes while it is put together, and refused if it
  /// changes again, so no list mixes one account's models with the next's
  /// selection and pins.
  Future<ModelList> list([
    ModelListQuery query = const ModelListQuery(),
  ]) async {
    for (var attempt = 0; ; attempt++) {
      final session = _container.read(openWebUiAuthSessionEpochProvider);
      final accountId = currentPreferenceAccountId();
      final list = await _list(query);
      if (identical(
            session,
            _container.read(openWebUiAuthSessionEpochProvider),
          ) &&
          accountId == currentPreferenceAccountId()) {
        return list;
      }
      if (attempt > 0) {
        throw const RpcError(
          code: ConduitErrorCodes.sessionExpired,
          debugMessage: 'the account changed while its models were listed',
        );
      }
    }
  }

  Future<ModelList> _list(ModelListQuery query) async {
    final models = await _models();
    await _accountSettings(wait: _listSettingsWait);
    final chatId = query.chatId;
    final conversation = chatId == null ? null : await _conversation(chatId);
    final agents = await _agents(conversation, temporary: query.temporary);
    if (chatId != null && chatId != _reopenedFor) {
      _reopenedFor = chatId;
      await _reopenAgent(conversation, agents);
    }
    // The model the next turn runs with, not the first in the list: the
    // composer shows this, and showing a model the next turn would not
    // actually use is worse than showing none.
    final selectedId = (await currentModel(_container))?.id;
    final plain = ModelList(
      models: models.map(_summarize).toList(growable: false),
      selectedId: selectedId,
      agents: agents.map(_summarize).toList(growable: false),
      agentNames: _agentNames(conversation),
    );
    try {
      return _arranged([...models, ...agents], plain);
    } on Object catch (error) {
      // The pins and the default come from the account's settings; a list
      // without them still lets the user pick.
      DebugLogger.warning(
        'models-unarranged',
        scope: 'daemon/models',
        data: <String, Object?>{'error': error.runtimeType.toString()},
      );
      return plain;
    }
  }

  /// [plain] with mobile's picker layout: the pinned models, the default,
  /// and what goes under "More Models".
  ModelList _arranged(List<core.Model> models, ModelList plain) {
    final pinned = _container.read(effectivePinnedModelIdsProvider);
    final defaultId = _defaultModelId();
    final layout = buildModelSelectorLayout(
      models: models,
      pinnedModelIds: pinned,
      defaultModelId: defaultId,
      selectedModelId: plain.selectedId,
      // A terminal's coding agents come last, under their own heading, and
      // lead the list only when pinned or selected, as mobile lays them out.
      sectionOf: (model) =>
          libreChatModelSection(model) ??
          (isTerminalAgentModel(model) ? _agentsSection : null),
      fillsFallback: (model) => !isTerminalAgentModel(model),
    );
    final pinnedSet = pinned.toSet();
    return plain.copyWith(
      models: <ModelSummary>[
        for (final model in plain.models)
          model.copyWith(pinned: pinnedSet.contains(model.id)),
      ],
      agents: <ModelSummary>[
        for (final model in plain.agents)
          model.copyWith(pinned: pinnedSet.contains(model.id)),
      ],
      featuredIds: <String>[for (final model in layout.featured) model.id],
      moreSections: <ModelSection>[
        if (layout.more.isNotEmpty)
          ModelSection(ids: <String>[for (final m in layout.more) m.id]),
        for (final section in layout.sections)
          if (section.label != _agentsSection.label)
            ModelSection(
              label: section.label,
              ids: <String>[for (final m in section.models) m.id],
            ),
      ],
      canPin: _container.read(canTogglePinnedModelsProvider),
      defaultId: defaultId,
    );
  }

  /// The account's default model, as mobile's picker marks it.
  String? _defaultModelId() {
    final local = _container.read(appSettingsProvider).defaultModel;
    if (!_container.read(openWebUiAccountAvailableProvider)) return local;
    return _container
            .read(personalizationSettingsProvider)
            .value
            ?.defaultModelId ??
        local;
  }

  /// The account's settings (pins, default model), which the picker reads,
  /// once they arrive; a server out of reach leaves the device's copy.
  ///
  /// The list waits briefly ([_listSettingsWait]), and only while they are
  /// still loading: offline it must answer with what it has.
  Future<void> _accountSettings({Duration wait = _defaultModelWait}) async {
    try {
      if (_container.read(apiServiceProvider) == null) return;
      if (!_container.read(personalizationSettingsProvider).isLoading) return;
      await readSettled(
        _container,
        personalizationSettingsProvider.future,
      ).timeout(wait);
    } on Object {
      // The local pins stand in.
    }
  }

  /// `models.setPinned`: in the account's settings, as mobile's picker pins.
  Future<ModelList> setPinned(SetModelPinned request) async {
    // Pinned for the account that asked: once another is in use, its pins
    // are not changed.
    final session = _container.read(openWebUiAuthSessionEpochProvider);
    await _accountSettings();
    if (!identical(
      session,
      _container.read(openWebUiAuthSessionEpochProvider),
    )) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed',
      );
    }
    final pinned = _container.read(effectivePinnedModelIdsProvider);
    if (pinned.contains(request.id) != request.pinned) {
      if (!_container.read(canTogglePinnedModelsProvider)) {
        throw const RpcError(
          code: ConduitErrorCodes.unsupported,
          debugMessage: 'the account settings are not loaded yet',
        );
      }
      await _container
          .read(personalizationSettingsProvider.notifier)
          .togglePinnedModel(request.id);
    }
    return list();
  }

  /// `models.options`: reasoning effort (an Ollama model's thinking level)
  /// and Hermes' Fast tier for one model.
  Future<ModelOptionsDto> options(ModelOptionsQuery query) async {
    // A coding agent is found among its terminal's, and offers none: its
    // effort is a control of its own (`models.controls`).
    final model = await _controlled(query.modelId, query.chatId);
    final options = await _options(model);
    // A chat's own saved effort is what its next turn sends: shown for it
    // over the model's pick.
    final chatId = query.chatId;
    if (chatId == null || model == null || !_savedOnChat(model)) {
      return options;
    }
    final params = (await _conversation(chatId))?.chatParams;
    if (params == null || !params.containsKey(kChatParamReasoningEffort)) {
      return options;
    }
    final saved = params[kChatParamReasoningEffort];
    final current = saved is String && saved.trim().isNotEmpty
        ? saved.trim().toLowerCase()
        : kAutomaticReasoningEffort;
    return options.copyWith(
      reasoning: options.reasoning.copyWith(current: current),
    );
  }

  /// `models.setReasoningEffort`: the picker's pick, through the core's one
  /// entry point. For an Open WebUI model the pick is also the chat's saved
  /// override; a new chat's lands in the window's draft instead, as mobile's
  /// lands in its pending settings.
  Future<ModelOptionsDto> setReasoningEffort(SetReasoningEffort request) async {
    // Picked for the account in use now: the pick's key is that account's,
    // so nothing is written once another one, or another server, is.
    final session = _container.read(openWebUiAuthSessionEpochProvider);
    final accountId = currentPreferenceAccountId();
    void sameAccount() {
      if (!identical(
            session,
            _container.read(openWebUiAuthSessionEpochProvider),
          ) ||
          accountId != currentPreferenceAccountId()) {
        throw const RpcError(
          code: ConduitErrorCodes.sessionExpired,
          debugMessage: 'the account changed',
        );
      }
    }

    final model = await _model(request.modelId);
    sameAccount();
    if (model == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'id': request.modelId},
        debugMessage: 'this server does not offer ${request.modelId}',
      );
    }
    final String effort;
    try {
      effort = normalizeReasoningEffort(request.effort);
    } on FormatException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'format'},
        debugMessage: error.message,
      );
    }
    final chatId = request.chatId;
    // The named chat is read before anything changes: one that cannot be
    // read is refused, never taken for a new chat's draft.
    final conversation = chatId == null ? null : await _conversation(chatId);
    if (chatId != null && conversation == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'id': chatId},
        debugMessage: 'no chat $chatId to save the pick on',
      );
    }
    sameAccount();
    Map<String, dynamic>? draft;
    try {
      if (chatId == null) {
        await setReasoningEffortForModel(_container.read, model, effort);
        if (_savedOnChat(model)) {
          draft = <String, dynamic>{
            ...openWebUiChatParamsFrom(request.draft),
            kChatParamReasoningEffort: effort == kAutomaticReasoningEffort
                ? null
                : effort,
          };
        }
      } else {
        await selectReasoningEffortForModel(
          _container,
          model,
          effort,
          target: captureOpenWebUiReasoningPickTargetFor(
            _container,
            conversation,
          ),
        );
      }
    } on FormatException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'unsupported'},
        debugMessage: error.message,
      );
    }
    return (await _options(model)).copyWith(draft: draft);
  }

  /// `models.setFastTier`: Hermes' Fast tier for the next turns, until the
  /// model changes (the core resets it then, as on mobile). A turn's scope
  /// takes it when the turn starts.
  Future<ModelOptionsDto> setFastTier(SetFastTier request) async {
    final model = await _model(request.modelId);
    // One switch for the selected model: another model's request would
    // change it for the model in use.
    final selected = (await currentModel(_container))?.id;
    if (model == null ||
        model.metadata?['hermesFast'] != true ||
        model.id != selected) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'id': ?request.modelId},
        debugMessage: 'Fast tier belongs to the selected model that offers it',
      );
    }
    _container.read(hermesFastTierSelectionProvider.notifier).set(request.on);
    return _options(model);
  }

  bool _savedOnChat(core.Model model) =>
      !isHermesModel(model) &&
      _container.read(directModelRegistryProvider).resolve(model) == null;

  Future<ModelOptionsDto> _options(core.Model? model) async {
    final read = _container.read;
    final policy = reasoningEffortPolicyForModel(read, model);
    final binding = model == null
        ? null
        : read(directModelRegistryProvider).resolve(model);
    final selectedId = (await currentModel(_container))?.id;
    final offersFast =
        model != null &&
        model.metadata?['hermesFast'] == true &&
        model.id == selectedId;
    return ModelOptionsDto(
      modelId: model?.id,
      reasoning: ReasoningOptions(
        visible: policy.visible,
        options: policy.options,
        allowsCustom: policy.allowsCustom,
        current: reasoningEffortForModel(read, model),
        ollama: binding?.adapterKey == kOllamaAdapterKey,
      ),
      fastTier: offersFast ? read(hermesFastTierSelectionProvider) : null,
    );
  }

  Future<core.Model?> _model(String? id) async {
    if (id == null) return currentModel(_container);
    final models = await _models();
    return models.where((candidate) => candidate.id == id).firstOrNull;
  }

  Future<Conversation?> _conversation(String chatId) async {
    try {
      return await readSettled(
        _container,
        loadConversationProvider(chatId).future,
      );
    } on Object {
      return null;
    }
  }

  Future<ModelList> select(String id, {String? chatId}) async {
    if (isTerminalAgentModelId(id)) {
      final conversation = chatId == null ? null : await _conversation(chatId);
      final agent = (await _agents(conversation))
          .where((candidate) => candidate.id == id)
          .firstOrNull;
      if (agent == null) {
        throw RpcError(
          code: ConduitErrorCodes.notFound,
          args: <String, String>{'id': id},
          debugMessage: 'the selected terminal does not offer $id here',
        );
      }
      _selectAgent(agent);
      return list(ModelListQuery(chatId: chatId));
    }
    final models = await _models();
    final model = models.where((candidate) => candidate.id == id).firstOrNull;
    if (model == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'id': id},
        debugMessage: 'this server does not offer $id',
      );
    }
    _container.read(selectedModelProvider.notifier).set(model);
    return list(ModelListQuery(chatId: chatId));
  }

  /// [agent] for the next turns, on its own terminal (picking an agent
  /// selects its terminal, as on mobile).
  void _selectAgent(core.Model agent) {
    _container
        .read(selectedTerminalIdProvider.notifier)
        .set(terminalAgentTerminalId(agent));
    _container
        .read(selectedModelProvider.notifier)
        .set(agent, allowHidden: true);
  }

  /// The coding agents the selected terminal offers [conversation] (null
  /// for a new chat): none where no agent can answer, or when the terminal
  /// was not reached in time.
  Future<List<core.Model>> _agents(
    Conversation? conversation, {
    bool temporary = false,
  }) async {
    try {
      final scope = await terminalAgentScopeFor(
        _container,
        conversation,
        temporary: temporary,
      );
      return await terminalAgentModelsIn(_container, scope);
    } on Object catch (error) {
      DebugLogger.warning(
        'agents-unlisted',
        scope: 'daemon/models',
        data: <String, Object?>{'error': error.runtimeType.toString()},
      );
      return const <core.Model>[];
    }
  }

  /// A chat started with a coding agent reopens with it, as on mobile, once
  /// its terminal offers it again; until then the selection stays.
  Future<void> _reopenAgent(
    Conversation? conversation,
    List<core.Model> agents,
  ) async {
    final id = conversation?.model;
    if (!isTerminalAgentModelId(id)) return;
    if (_container.read(selectedModelProvider)?.id == id) return;
    final agent = agents.where((candidate) => candidate.id == id).firstOrNull;
    if (agent != null) _selectAgent(agent);
  }

  /// The coding agents [conversation]'s replies came from, named as the
  /// picker names them.
  static Map<String, String> _agentNames(Conversation? conversation) {
    if (conversation == null) return const <String, String>{};
    return <String, String>{
      for (final id in <String>[
        ?conversation.model,
        for (final message in conversation.messages) ?message.model,
      ])
        id: ?terminalAgentDisplayName(id),
    };
  }

  // ── Model controls ──────────────────────────────────────────────────────

  /// `models.controls`: the model's controls, each with the option that
  /// applies now (the user's pick, else the control's default).
  Future<ModelControlList> controls(ModelControlsQuery query) async {
    final model = await _controlled(query.modelId, query.chatId);
    return _controlsOf(model);
  }

  /// `models.setControl`: the pick, saved in the account's Open WebUI
  /// settings through the core (taken back if the server refuses it).
  Future<ModelControlList> setControl(SetModelControl request) async {
    // The pick is saved on the server of the account it was made under
    // ([AccountScope]), or nowhere.
    final account = AccountScope.capture(_container);
    final model = await _controlled(request.modelId, request.chatId);
    final control = modelControlsOf(model)
        .where((c) => c.key == request.key)
        .firstOrNull;
    if (model == null || control == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'control': request.key},
        debugMessage: 'the model has no control ${request.key}',
      );
    }
    final value = request.value;
    if (value != null && control.optionFor(value) == null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: const <String, String>{'reason': 'option'},
        debugMessage: '${request.key} offers no option $value',
      );
    }
    try {
      await _choices();
      account.require('the model control is saved');
      await _container
          .read(modelControlChoicesProvider.notifier)
          .choose(model, control.key, value);
    } on RpcError {
      rethrow;
    } on Object catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the control was not saved: $error',
      );
    }
    return _controlsOf(model);
  }

  Future<ModelControlList> _controlsOf(core.Model? model) async {
    if (model == null || modelControlsOf(model).isEmpty) {
      return ModelControlList(modelId: model?.id);
    }
    final choices = await _choices();
    return ModelControlList(
      modelId: model.id,
      controls: <ModelControlDto>[
        for (final state in modelControlStates(model, choices))
          ModelControlDto(
            key: state.control.key,
            label: state.control.label,
            description: state.control.description,
            options: <ModelControlOptionDto>[
              for (final option in state.control.options)
                ModelControlOptionDto(value: option.value, label: option.label),
            ],
            defaultValue: state.control.defaultValue,
            value: state.value,
          ),
      ],
    );
  }

  /// The user's picks, once read; none while the server cannot be reached.
  Future<ModelControlChoices> _choices() async {
    try {
      return await readSettled(
        _container,
        modelControlChoicesProvider.future,
      ).timeout(_defaultModelWait);
    } on Object {
      return _container.read(modelControlChoicesProvider).value ??
          const <String, Map<String, String>>{};
    }
  }

  /// The model [id] names (the selection for null), a coding agent among
  /// them: the selected one, else one the terminal offers [chatId].
  Future<core.Model?> _controlled(String? id, String? chatId) async {
    final selected = await currentModel(_container);
    if (id == null || selected?.id == id) return selected;
    if (isTerminalAgentModelId(id)) {
      final conversation = chatId == null ? null : await _conversation(chatId);
      return (await _agents(conversation))
          .where((candidate) => candidate.id == id)
          .firstOrNull;
    }
    return _model(id);
  }

  /// The capability names the server reported, as a flat list.
  ///
  /// `capabilities` is a free-form map on the server's side and gains keys
  /// without warning, so this reports the ones that are true rather than
  /// mapping them onto a fixed struct that would silently drop the rest.
  static ModelSummary _summarize(core.Model model) => ModelSummary(
    id: model.id,
    name: model.name,
    description: model.description,
    capabilities: <String>[
      for (final entry
          in (model.capabilities ?? const <String, dynamic>{}).entries)
        if (entry.value == true) entry.key,
    ]..sort(),
    connection: model.metadata?['direct'] == true
        ? (model.metadata?['directProfileName'] as String?)
        : null,
    logo: _logo(model),
    agent: terminalAgentDto(
      model.id,
      terminalName: model.metadata?[kTerminalAgentTerminalNameKey] as String?,
    ),
  );

  /// The models.dev logo the core picks for a direct model, by id; none
  /// for the server's own models, which have their own pictures.
  static String? _logo(core.Model model) {
    if (model.metadata?['direct'] != true) return null;
    final url = directModelLogoAvatarUrl(model);
    return url?.substring(kModelLogoUrlScheme.length);
  }
}

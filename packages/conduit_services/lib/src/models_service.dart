import 'dart:async';

import 'package:conduit_core/features/chat/models/model_selector_layout.dart';
import 'package:conduit_core/features/chat/providers/chat_model_choice.dart'
    show modelForId, modelSavedWithChat;
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        agentTerminalGone,
        captureOpenWebUiReasoningPickTargetFor,
        modelControlChoicesProvider,
        modelControlStates,
        resolveTerminalAgentModel,
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
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart'
    show
        terminalAvailableServersProvider,
        terminalServiceProvider,
        terminalSessionScopeIdProvider;
import 'package:conduit_core/features/tools/providers/tools_providers.dart'
    show selectedTerminalIdProvider;
import 'package:conduit_core/models/model_controls.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart'
    show currentPreferenceAccountId;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show primaryAccountKindProvider;
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountKind;
import 'package:conduit_core/services/settings_service.dart'
    show appSettingsProvider;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/features/tether/tether_devices.dart';
import 'package:conduit_core/features/tether/tether_offers.dart';
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
/// not an agent's. [model] is the agent's own model as the server listed it;
/// without it, the id names the model (Open WebUI 0.13.4's id holds only a
/// slug of it).
TerminalAgentDto? terminalAgentDto(
  String? id, {
  String? terminalName,
  String? model,
}) {
  final agent = parseTerminalAgentModelId(id);
  if (agent == null) return null;
  final name = terminalName?.trim();
  return TerminalAgentDto(
    terminalId: agent.terminalId,
    terminalName: name == null || name.isEmpty ? null : name,
    agent: agent.provider,
    agentName: terminalAgentName(agent.provider),
    model: model ?? terminalAgentModelNameOfId(id)!,
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

/// What [ModelsService._resolve] decides a chat's model from, read with no
/// wait between: the chat's pick record, the account's selection, the
/// model list, the stored chat (the model it was saved with), the
/// account's default model, and the selected terminal and the terminal
/// list New Chat's coding agent was checked against.
typedef _ModelInputs = ({
  _Pick? pick,
  core.Model? selected,
  List<core.Model>? listed,
  Conversation? chat,
  String? defaultId,
  String? terminal,
  Object? terminals,
});

/// [ModelsService._resolve]'s answer: the model the chat shows, the model
/// id an unnamed turn runs on, and what it was decided with.
typedef _Resolved = ({
  core.Model? shown,
  String? runs,
  _Pick? record,
  List<core.Model> listed,
  Conversation? conversation,
});

/// Implements `models.*` over the core's model providers.
final class ModelsService {
  ModelsService(this._container, {EventBus? events}) : _events = events {
    if (events != null) {
      _announceChanges(events);
      _followRemaps(events);
    }
  }

  /// Per account ([AccountScope.identity]: the server and user, the
  /// LibreChat account, whichever backend is in charge), per chat (null:
  /// the New Chat slot), the model picked there: the one record of each
  /// chat's selection. A chat with no pick of its own has the account's
  /// default (never an agent picked for another chat); another account
  /// never sees it.
  final Map<Object, Map<String?, _Pick>> _picks =
      <Object, Map<String?, _Pick>>{};

  /// The revision of the newest change to any pick, for the whole process:
  /// every change (a pick made, New Chat's taken by a send, a pick moved
  /// with its chat) takes the next one, and it never goes back, so no
  /// answer for a chat or New Chat ever reports an older revision than one
  /// it reported before.
  int _revision = 0;

  /// The picks of [account].
  Map<String?, _Pick> _picksOf(AccountScope account) =>
      _picks.putIfAbsent(account.identity, () => <String?, _Pick>{});

  /// [model] as [chatId]'s pick for [account], at a new revision.
  void _pick(AccountScope account, String? chatId, core.Model model) {
    _picksOf(account)[_now(chatId)] = _Pick(model, ++_revision);
  }

  /// The slot of a temporary new chat's pick: its own, never New Chat's
  /// (both have no chat yet). No chat id is ever this.
  static const _temporaryNewChat = '\u0000temporary';

  /// Where [chatId]'s pick is kept: the chat's own slot, else New Chat's
  /// (null), else -- a [temporary] new chat -- the temporary one's.
  String? _slotOf(String? chatId, {bool temporary = false}) =>
      chatId == null && temporary ? _temporaryNewChat : _now(chatId);

  /// Chat ids that moved (`route.remap`), old to new.
  final Map<String, String> _moved = <String, String>{};

  /// [chatId] as it is now, after every move: a pick asked under a chat's
  /// old id lands on its new one.
  String? _now(String? chatId) {
    var id = chatId;
    for (var hops = 0; id != null && hops < 8; hops++) {
      final next = _moved[id];
      if (next == null) break;
      id = next;
    }
    return id;
  }

  /// New Chat's coding agent for [account], checked as it is read against
  /// the terminals now, by the rule the account's own selection follows
  /// (the core's [agentTerminalGone]): a new chat runs on the terminal
  /// selected, so the agent goes once another terminal or none is selected,
  /// or once the server confirms its terminal is gone. Its slot is cleared
  /// then, at the next revision, and every window showing New Chat lists it
  /// again. A chat's own agent stays: it runs on its own terminal.
  ///
  /// Every reader of New Chat's pick checks through this, and it refuses
  /// ([AccountScope.require]) once another account is in charge, before the
  /// check and after its wait: the pick is [account]'s, and the request
  /// would otherwise answer the next account with it.
  ///
  /// A [temporary] new chat's pick, in its own slot ([_slotOf]), is checked
  /// the same way.
  Future<void> _checkNewChat(
    AccountScope account, {
    bool temporary = false,
  }) async {
    account.require("New Chat's coding agent is checked");
    final slot = _slotOf(null, temporary: temporary);
    final pick = _picksOf(account)[slot];
    final agent = pick?.model;
    if (pick == null || terminalAgentTerminalId(agent) == null) return;
    final gone =
        await agentTerminalGone(
          agent,
          selected: (id: _container.read(selectedTerminalIdProvider)),
          listed: _container.read(terminalAvailableServersProvider),
          service: _container.read(terminalServiceProvider),
          scope: _container.read(terminalSessionScopeIdProvider),
        ) ||
        // Another terminal, or none, chosen while the server was read.
        await agentTerminalGone(
          agent,
          selected: (id: _container.read(selectedTerminalIdProvider)),
        );
    account.require("New Chat's coding agent is checked");
    if (!gone) return;
    // Gone for every send that took this pick, though a newer one may have
    // taken its place in the slot meanwhile.
    pick.gone = true;
    final picks = _picksOf(account);
    if (!identical(picks[slot], pick)) return;
    picks[slot] = _Pick(null, ++_revision);
    _announce();
  }

  /// A chat's id moved (`route.remap`): its pick moves with it, unless a
  /// newer one was already made under the new id.
  void _followRemaps(EventBus events) {
    _untap = events.tap((event, _, payload) {
      if (event != ConduitEvents.routeRemap) return;
      final remap = RouteRemap.fromJson(payload);
      _moved[remap.fromId] = remap.toId;
      for (final picks in _picks.values) {
        final pick = picks.remove(remap.fromId);
        if (pick != null) _land(picks, remap.toId, pick);
      }
    });
  }

  /// [pick]'s model as [chatId]'s in [picks], at the next revision, unless
  /// a pick made after [pick] is there.
  void _land(Map<String?, _Pick> picks, String chatId, _Pick pick) {
    final there = picks[_now(chatId)];
    if (there != null && there.revision > pick.revision) return;
    picks[_now(chatId)] = _Pick(pick.model, ++_revision, idOnly: pick.idOnly);
  }

  /// A turn is about to be sent from [fromChat] (null: from New Chat, or
  /// from a [temporary] new chat, whose pick is its own): what its landing
  /// may move, captured before any wait (a pick made while the turn waits
  /// is not its), then, from a new chat, that pick checked against the
  /// terminals ([_checkNewChat]) whether or not the turn names a model: an
  /// agent whose terminal went is not carried to the chat it makes.
  Future<ModelSend> sending(String? fromChat, {bool temporary = false}) async {
    final account = AccountScope.capture(_container);
    final slot = _slotOf(fromChat, temporary: temporary);
    final send = ModelSend._(
      account,
      fromChat,
      slot,
      fromChat == null ? _picksOf(account)[slot] : null,
      _revision,
    );
    if (fromChat == null) await _checkNewChat(account, temporary: temporary);
    return send;
  }

  /// [send] was admitted and went to [toChat], with [model].
  ///
  /// A turn in a chat that exists changes no pick: a pick is made by
  /// `models.select` alone, and a send that lands after a later one would
  /// otherwise take it back. A turn from New Chat makes the chat: New
  /// Chat's pick, of any kind, as it was when the turn was sent, is that
  /// chat's now (whatever model the first message went to for itself
  /// alone, with `@`), and leaves New Chat unless New Chat was picked again
  /// meanwhile. A coding agent the turn named with none picked is the
  /// chat's too, known by its id alone. A coding agent found gone since
  /// ([_checkNewChat]) is not: the turn ran without it. Either lands only
  /// where no newer pick was made, and only
  /// while the account the turn was sent under is still the one in charge,
  /// with nothing changed in between: otherwise nothing is written.
  void sent(ModelSend send, {required String toChat, String? model}) {
    if (send._fromChat != null || !send._account.isCurrent) return;
    final picks = _picksOf(send._account);
    final slot = send._slot;
    // New Chat's pick (a temporary new chat's, from its own slot), taken: a
    // record with no model, at the next revision, and every window showing
    // New Chat (Quick Ask too) lists it again.
    if (slot != null && picks[send._slotKey]?.revision == slot.revision) {
      picks[send._slotKey] = _Pick(null, ++_revision);
      _announce();
    }
    final taken = slot == null || slot.gone ? null : slot.model;
    final made = taken != null
        // A coding agent New Chat picked, as New Chat's terminal offered it:
        // the chat knows it by its id alone, its controls asked of its own.
        ? _Pick(taken, slot!.revision, idOnly: isTerminalAgentModelId(taken.id))
        : model != null && isTerminalAgentModelId(model)
        ? _Pick(
            core.Model(
              id: model,
              name: terminalAgentDisplayName(model) ?? model,
            ),
            send._revision,
            idOnly: true,
          )
        : null;
    if (made != null) _land(picks, toChat, made);
  }

  final ProviderContainer _container;

  /// Where `models.changed` goes (none in some tests).
  final EventBus? _events;

  /// Whether a pick is being made ([_picked]): it announces itself once,
  /// so the listeners its changes fire stay quiet.
  bool _picking = false;

  /// What [_announceChanges] holds, and the remap tap.
  final List<ProviderSubscription<Object?>> _watches =
      <ProviderSubscription<Object?>>[];
  void Function()? _untap;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    for (final watch in _watches) {
      watch.close();
    }
    _watches.clear();
    _untap?.call();
    _untap = null;
  }

  void _announce() {
    if (_picking || _disposed) return;
    _events?.emit(ConduitEventSpecs.modelsChanged, null);
  }

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
    _watches.addAll(<ProviderSubscription<Object?>>[
      _container.listen<void>(defaultModelSettingSelectionProvider, (_, _) {}),
      // As mobile keeps them: a coding agent goes when its terminal is
      // turned off, and a control's pick the model no longer offers is
      // cleared.
      _container.listen<void>(terminalAgentSelectionGuardProvider, (_, _) {}),
      _container.listen<AsyncValue<ModelControlChoices>>(
        modelControlChoicesProvider,
        (_, _) {},
      ),
      _container.listen<core.Model?>(selectedModelProvider, (previous, next) {
        if (previous?.id == next?.id) return;
        _announce();
      }),
      // The coding agents on offer are the selected terminal's: another
      // terminal changes the list even when the model stays.
      _container.listen<String?>(selectedTerminalIdProvider, (previous, next) {
        if (previous == next) return;
        _announce();
      }),
      // A Tether device changed what it offers, its models read again.
      _container.listen<int>(tetherDevicesProvider, (_, _) => _announce()),
    ]);
    List<String>? last;
    _watches.add(
      _container.listen<AsyncValue<List<core.Model>>>(modelsProvider, (
        _,
        next,
      ) {
        final models = next.value;
        if (models == null) return;
        final ids = models.map((model) => model.id).toList(growable: false);
        final previous = last;
        last = ids;
        if (previous == null || _sameIds(previous, ids)) return;
        _announce();
      }),
    );
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

  /// Numbers each model pick: a pick writes only while it is the newest.
  int _pickTickets = 0;

  /// How long Switch waits for the agent's own terminal to answer.
  static const Duration _agentLookupWait = Duration(seconds: 3);

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
      final ModelList list;
      try {
        list = await _list(query);
      } on RpcError catch (error) {
        // A list that names no chat is put together again for the next
        // account, once; a chat's own list is refused (below).
        if (error.code == ConduitErrorCodes.sessionExpired &&
            attempt == 0 &&
            query.chatId == null) {
          continue;
        }
        rethrow;
      }
      if (identical(
            session,
            _container.read(openWebUiAuthSessionEpochProvider),
          ) &&
          accountId == currentPreferenceAccountId()) {
        return list;
      }
      // A chat is the account's that asked: never listed again, nor looked
      // up, for the next account.
      if (attempt > 0 || query.chatId != null) {
        throw const RpcError(
          code: ConduitErrorCodes.sessionExpired,
          debugMessage: 'the account changed while its models were listed',
        );
      }
    }
  }

  Future<ModelList> _list(ModelListQuery query) async {
    final account = AccountScope.capture(_container);
    final chatId = query.chatId;
    await _accountSettings(wait: _listSettingsWait);
    final conversation = chatId == null
        ? null
        : await _conversation(chatId, account);
    // A named chat that could not be read is not a new chat: its agents are
    // unknown, so none is offered (an unread chat is never taken for none).
    final terminal = _container.read(selectedTerminalIdProvider);
    final found = chatId != null && conversation == null
        ? (agents: const <core.Model>[], asked: false)
        : await _agents(conversation, account, temporary: query.temporary);
    // The model the next turn runs with, not the first in the list: the
    // composer shows this, and showing a model the next turn would not
    // actually use is worse than showing none. The list only reports what
    // the terminal offers: it never decides the selection (the window keeps
    // each chat's own pick), so nothing is added to it for the selection.
    // Decided in one place with `turns.*` ([_resolve]).
    final resolved = await _resolve(
      chatId,
      account,
      temporary: query.temporary,
    );
    // Checked right before the answer is put together, after its last
    // wait: the account it was asked for, and the terminal its agents came
    // from, are still the ones in charge.
    account.require('the models are answered');
    // The answer's revision is the pick's it was decided from: the window
    // orders this answer against its others for the chat by it.
    final models = resolved.listed;
    final record = resolved.record;
    final pick = record?.model;
    final selected = resolved.shown;
    final selectedId = selected?.id;
    final found2 = _container.read(selectedTerminalIdProvider) == terminal
        ? found.agents
        : const <core.Model>[];
    // The chat's agent stays on offer beside what its terminal lists now.
    final agents = [
      ...found2,
      if (selected != null &&
          isTerminalAgentModel(selected) &&
          !found2.any((agent) => agent.id == selected.id))
        selected,
    ];
    // A model the server hides from the picker but still offers (the chat's
    // saved model, or a pick or selection on one hidden since) is listed
    // for it, so the window can show and send it; the picker's layout
    // (below) leaves it out, as mobile's picker does. One it no longer
    // offers at all was never selected above.
    final hidden =
        selected != null &&
            !isTerminalAgentModel(selected) &&
            !models.any((m) => m.id == selected.id)
        ? selected
        : null;
    final plain = ModelList(
      models: [...models, ?hidden].map(_summarize).toList(growable: false),
      selectedId: selectedId,
      agents: agents.map(_summarize).toList(growable: false),
      agentNames: _agentNames(resolved.conversation ?? conversation),
      chatAgent: _chatAgent(resolved.conversation ?? conversation, pick),
      revision: record?.revision ?? 0,
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
    final account = AccountScope.capture(_container);
    await _accountSettings();
    account.require('the pin is made');
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
    // Answered for the account that pinned, right after the pin's last
    // wait: once another is in charge, its chat is never looked up (the
    // window lists its open chat again itself).
    account.require('the pin is answered');
    return _answerPick(request.chatId, account);
  }

  /// `models.options`: reasoning effort (an Ollama model's thinking level)
  /// and Hermes' Fast tier for one model.
  Future<ModelOptionsDto> options(ModelOptionsQuery query) async {
    // A coding agent is found among its terminal's, and offers none: its
    // effort is a control of its own (`models.controls`).
    final account = AccountScope.capture(_container);
    final model = await _controlled(query.modelId, query.chatId, account);
    final options = await _options(model);
    account.require('the model options are answered');
    // A chat's own saved effort is what its next turn sends: shown for it
    // over the model's pick.
    final chatId = query.chatId;
    if (chatId == null || model == null || !_savedOnChat(model)) {
      return options;
    }
    final params = (await _conversation(chatId, account))?.chatParams;
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
    final account = AccountScope.capture(_container);
    void sameAccount() => account.require('the reasoning pick is made');

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
    final conversation = chatId == null
        ? null
        : await _conversation(chatId, account);
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
    final options = await _options(model);
    sameAccount();
    return options.copyWith(draft: draft);
  }

  /// `models.setFastTier`: Hermes' Fast tier for the next turns, until the
  /// model changes (the core resets it then, as on mobile). A turn's scope
  /// takes it when the turn starts.
  Future<ModelOptionsDto> setFastTier(SetFastTier request) async {
    final account = AccountScope.capture(_container);
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
    // Checked, written and answered with no wait between: the switch is
    // never left on for another account.
    account.require('the Fast tier is switched');
    _container.read(hermesFastTierSelectionProvider.notifier).set(request.on);
    return _optionsFor(model, selected);
  }

  bool _savedOnChat(core.Model model) =>
      !isHermesModel(model) &&
      _container.read(directModelRegistryProvider).resolve(model) == null;

  Future<ModelOptionsDto> _options(core.Model? model) async =>
      _optionsFor(model, (await currentModel(_container))?.id);

  /// [model]'s options while [selectedId] is the model in use.
  ModelOptionsDto _optionsFor(core.Model? model, String? selectedId) {
    final read = _container.read;
    final policy = reasoningEffortPolicyForModel(read, model);
    final binding = model == null
        ? null
        : read(directModelRegistryProvider).resolve(model);
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

  /// The model [id] names (the selection for null), by the core's one rule
  /// ([modelForId]): a hidden model a chat was saved with included.
  Future<core.Model?> _model(String? id) async {
    if (id == null) return currentModel(_container);
    final account = AccountScope.capture(_container);
    // The settled list first, as before; past it, the core's rule.
    final listed = (await _models()).where((m) => m.id == id).firstOrNull;
    if (listed != null) return listed;
    try {
      return await modelForId(
        _container.read,
        id,
        isCurrent: () => account.isCurrent,
      );
    } on Object {
      return null;
    }
  }

  /// The chat [chatId], read for [account] only (checked before the read
  /// and after it), or null when it could not be read.
  Future<Conversation?> _conversation(
    String chatId,
    AccountScope account,
  ) async {
    account.require('the chat is read');
    try {
      return await readSettled(
        _container,
        loadConversationProvider(chatId).future,
      );
    } on Object {
      return null;
    } finally {
      account.require('the chat was read');
    }
  }

  /// Picks [id] for [chatId] (null: New Chat, or a [temporary] new chat,
  /// whose pick is its own and which offers no coding agent).
  Future<ModelList> select(
    String id, {
    String? chatId,
    bool temporary = false,
  }) async {
    // The pick is made for the account it was asked under, or not at all,
    // and only while no later pick was asked (newest wins).
    final account = AccountScope.capture(_container);
    final ticket = ++_pickTickets;
    void stillTheNewest(String what) {
      account.require(what);
      if (ticket != _pickTickets) {
        throw const RpcError(
          code: ConduitErrorCodes.conflict,
          args: <String, String>{'reason': 'superseded'},
          debugMessage: 'a later model pick was asked',
        );
      }
    }

    if (isTerminalAgentModelId(id)) {
      final conversation = chatId == null
          ? null
          : await _conversation(chatId, account);
      if (chatId != null && conversation == null) {
        throw RpcError(
          code: ConduitErrorCodes.notFound,
          args: <String, String>{'id': chatId},
          debugMessage: 'no chat $chatId to pick a coding agent for',
        );
      }
      final agent =
          (await _agents(
            conversation,
            account,
            temporary: temporary,
          )).agents.where((candidate) => candidate.id == id).firstOrNull ??
          // Switch: the chat's own agent, asked of its own terminal (picking
          // it selects that terminal), whichever terminal is selected now.
          (conversation?.model == id ? await _onItsTerminal(id, chatId) : null);
      if (agent == null) {
        throw RpcError(
          code: ConduitErrorCodes.notFound,
          args: <String, String>{'id': id},
          debugMessage: 'the selected terminal does not offer $id here',
        );
      }
      stillTheNewest('the coding agent is selected');
      _picked(() => _selectAgent(agent), account, chatId, agent);
      return _answerPick(chatId, account, temporary: temporary);
    }
    // A listed model, or one the server hides from the picker but still
    // offers ([_model]): a chat on it lists it, so it can be picked there.
    final model = await _model(id);
    if (model == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'id': id},
        debugMessage: 'this server does not offer $id',
      );
    }
    stillTheNewest('the model is selected');
    // A temporary chat's pick lives in its own slot only: as the account's
    // selection, New Chat would fall back on it. So does a model the server
    // hides from the picker (a chat's own, listed for it): as on mobile, it
    // is never what New Chat or another chat starts on.
    _picked(
      (temporary && chatId == null) || model.isHidden
          ? () {}
          : () {
              _container.read(selectedModelProvider.notifier).set(model);
              // Chosen by hand, as mobile's picker marks it: the default
              // restored when the account changes leaves it alone.
              _container
                  .read(isManualModelSelectionProvider.notifier)
                  .set(true);
            },
      account,
      _slotOf(chatId, temporary: temporary),
      model,
    );
    return _answerPick(chatId, account, temporary: temporary);
  }

  /// [model] picked for [chatId]: [select] selects it for the account (an
  /// agent's terminal too), and the pick is kept. One `models.changed`, for
  /// whatever it changed: the chat's other windows list it again, though
  /// the account had selected it already, since they show that chat's pick.
  void _picked(
    void Function() select,
    AccountScope account,
    String? chatId,
    core.Model model,
  ) {
    _picking = true;
    try {
      select();
      _pick(account, chatId, model);
    } finally {
      _picking = false;
    }
    _announce();
  }

  /// The list a pick answers with: [chatId]'s, put together for the
  /// account the pick was made for and refused once another is in charge
  /// (never started again for the next account).
  Future<ModelList> _answerPick(
    String? chatId,
    AccountScope account, {
    bool temporary = false,
  }) async {
    final reply = await _list(
      ModelListQuery(chatId: _now(chatId), temporary: temporary),
    );
    account.require('the pick is answered');
    return reply;
  }

  /// The model a turn in [chatId] (null: a new chat) runs with when it
  /// names none: that chat's own pick, else the coding agent or the model it
  /// was saved with, else a regular model (the account's selection when it is one,
  /// else its default, else the first). Never an agent picked for another
  /// chat: with no regular model left, the turn is refused.
  Future<String> modelFor(String? chatId, {bool temporary = false}) async {
    final account = AccountScope.capture(_container);
    final runs = (await _resolve(chatId, account, temporary: temporary)).runs;
    if (runs == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'no model this chat can run with',
      );
    }
    return runs;
  }

  /// How many times [_resolve] decides before it gives up on inputs that
  /// keep changing under it.
  static const int _resolveAttempts = 4;

  /// The model [chatId] (null: New Chat, or a [temporary] one) shows and the
  /// model a turn there that names none runs on, decided in this one place
  /// for `models.list` and `turns.*`:
  ///
  /// * the chat's own pick, while the server still offers its model (a
  ///   temporary chat runs no coding agent);
  /// * else, for a turn, the coding agent the chat was saved with (the list
  ///   offers it as Switch instead);
  /// * else the model the chat was saved with ([modelSavedWithChat]);
  /// * else the account's selection, while the server still offers it and
  ///   it is not another chat's coding agent; else the account's default,
  ///   else the first model ([_regularDefault]).
  ///
  /// An attempt does its first waits, then reads what the answer depends on
  /// (the pick, the account's selection, the model list, the chat's saved
  /// model) once, with no wait between, decides from that alone, and after
  /// its last wait reads them again: if any changed, it starts over. So no
  /// value read before a wait is answered after it unchecked. An account
  /// change ends it ([AccountScope.require]); inputs that are still changing
  /// after [_resolveAttempts] tries end it with a conflict to ask again.
  Future<_Resolved> _resolve(
    String? chatId,
    AccountScope account, {
    bool temporary = false,
  }) async {
    // Kept alive while it is read, so the chat's saved model is read again
    // after the waits without fetching the chat again.
    final chat = chatId == null
        ? null
        : _container.listen<AsyncValue<Conversation>>(
            loadConversationProvider(chatId),
            (_, _) {},
          );
    _ModelInputs inputs() => (
      // Looked up afresh: a pick moves with its chat's id (`route.remap`).
      pick: _picksOf(account)[_slotOf(chatId, temporary: temporary)],
      selected: _container.read(selectedModelProvider),
      listed: _container.read(modelsProvider).value,
      chat: chat?.read().value,
      defaultId: _defaultIdOrNull(),
      // New Chat's check reads these; a chat's own pick needs neither.
      terminal: chatId == null
          ? _container.read(selectedTerminalIdProvider)
          : null,
      terminals: chatId == null
          ? _container.read(terminalAvailableServersProvider).value
          : null,
    );
    try {
      for (var attempt = 1; ; attempt++) {
        final models = await _models();
        final conversation = chatId == null
            ? null
            : await _conversation(chatId, account);
        // Last before the inputs are read: what it found holds only while
        // the terminal it checked against does, which they include.
        if (chatId == null) await _checkNewChat(account, temporary: temporary);
        account.require('the model in use is read');
        final read = inputs();
        // The list waited for above is the one read now, or the attempt
        // starts over: everything below decides with it.
        if (!identical(read.listed, models)) {
          if (attempt == _resolveAttempts) throw _keptChanging;
          continue;
        }
        final pick = read.pick?.model;
        final pickOffered =
            pick != null && await _stillOffered(pick, models, account);
        final holds =
            pickOffered && !(isTerminalAgentModel(pick) && temporary);
        final savedId = read.chat?.model?.trim();
        final savedAgent = savedId != null && isTerminalAgentModelId(savedId)
            ? savedId
            : null;
        final saved = holds ? null : await _savedModel(savedId, account);
        // The account's selection, else its default: with none selected the
        // list shows none, while a turn still runs on the default.
        core.Model? shownFallback;
        core.Model? runFallback;
        if (!holds && saved == null) {
          final selection = read.selected ?? await currentModel(_container);
          if (selection != null &&
              !isTerminalAgentModel(selection) &&
              await _stillOffered(selection, models, account)) {
            shownFallback = runFallback = selection;
          } else {
            runFallback = await _regularDefault(models);
            shownFallback = selection == null ? null : runFallback;
          }
        }
        account.require('the model in use is read');
        if (_sameInputs(read, inputs())) {
          final shown = holds ? pick : saved ?? shownFallback;
          return (
            shown: shown,
            runs: pickOffered
                ? pick.id
                : savedAgent ?? (saved ?? runFallback)?.id,
            record: read.pick,
            listed: models,
            conversation: read.chat ?? conversation,
          );
        }
        if (attempt == _resolveAttempts) throw _keptChanging;
      }
    } finally {
      chat?.close();
    }
  }

  static const _keptChanging = RpcError(
    code: ConduitErrorCodes.conflict,
    retryable: true,
    debugMessage: "the chat's model kept changing while it was read",
  );

  /// The account's default model id, or null when it cannot be read.
  String? _defaultIdOrNull() {
    try {
      return _defaultModelId();
    } on Object {
      return null;
    }
  }

  static bool _sameInputs(_ModelInputs a, _ModelInputs b) =>
      identical(a.pick, b.pick) &&
      identical(a.selected, b.selected) &&
      identical(a.listed, b.listed) &&
      identical(a.chat, b.chat) &&
      a.defaultId == b.defaultId &&
      a.terminal == b.terminal &&
      identical(a.terminals, b.terminals);

  /// Whether the server still offers [model]: listed, a coding agent (its
  /// terminal's to offer), or hidden from the picker but still offered
  /// ([modelForId]). A pick or selection on one it no longer has falls
  /// back, as a chat whose saved model is offered nowhere does.
  Future<bool> _stillOffered(
    core.Model model,
    List<core.Model> listed,
    AccountScope account,
  ) async {
    if (isTerminalAgentModel(model) || listed.any((m) => m.id == model.id)) {
      return true;
    }
    try {
      // Stops, asking and remembering nothing, once [account] has left.
      return await modelForId(
            _container.read,
            model.id,
            isCurrent: () => account.isCurrent,
          ) !=
          null;
    } on Object {
      return false;
    }
  }

  /// The model a chat saved as [id] runs on when opened with no pick
  /// ([modelSavedWithChat], as on mobile). Null for none, for a coding
  /// agent (offered as Switch), and for one offered nowhere now.
  Future<core.Model?> _savedModel(String? id, AccountScope account) async {
    if (id == null || id.isEmpty || isTerminalAgentModelId(id)) return null;
    try {
      // Stops, asking and remembering nothing, once [account] has left.
      return await modelSavedWithChat(
        _container.read,
        id,
        isCurrent: () => account.isCurrent,
      );
    } on Object catch (error) {
      DebugLogger.warning(
        'saved-model-unresolved',
        scope: 'daemon/models',
        data: <String, Object?>{'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  /// The account's default model among [models]' regular ones, else the
  /// one the core takes with none picked: for a chat with no pick while the
  /// account's selection is another chat's coding agent (or none). Never a
  /// coding agent.
  Future<core.Model?> _regularDefault(List<core.Model> models) async {
    String? id;
    try {
      id = _defaultModelId();
    } on Object {
      // No default to read: the core's choice.
    }
    final primary = _container.read(primaryAccountKindProvider);
    core.Model? among(List<core.Model> models) {
      final regular = models.where((m) => !isTerminalAgentModel(m));
      return regular.where((m) => m.id == id).firstOrNull ??
          unpickedSendModelAmong(regular, primary);
    }

    final now = among(models);
    if (now != null || primary != PrimaryAccountKind.libreChat) return now;
    // LibreChat's catalog may still be on its way (the list does not wait
    // for it): a send waits for it, as mobile's does, then takes the same
    // order from the list that has it (the default first).
    try {
      await modelForUnpickedSend(_container.read);
      return among(await _models());
    } on Object {
      return null;
    }
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
  /// was not reached in time. [asked] tells whether a terminal was asked at
  /// all (the chat can have an agent). Asked and answered for [account]
  /// and for the terminal selected when it was asked: both are checked
  /// right before the terminal is asked (the core reads the account's API
  /// then) and when the answer is back, so no caller goes on (to Switch's
  /// own-terminal lookup, say) for another account, and no list offers one
  /// terminal's agents beside another's selection.
  Future<({List<core.Model> agents, bool asked})> _agents(
    Conversation? conversation,
    AccountScope account, {
    bool temporary = false,
  }) async {
    const none = (agents: <core.Model>[], asked: false);
    final terminal = _container.read(selectedTerminalIdProvider);
    try {
      final scope = await terminalAgentScopeFor(
        _container,
        conversation,
        temporary: temporary,
      );
      account.require('the coding agents are asked for');
      if (_container.read(selectedTerminalIdProvider) != terminal) return none;
      if (scope == null) return none;
      final agents = await terminalAgentModelsIn(_container, scope);
      account.require('the coding agents are answered');
      if (_container.read(selectedTerminalIdProvider) != terminal) return none;
      return (agents: agents, asked: true);
    } on RpcError {
      rethrow;
    } on Object catch (error) {
      DebugLogger.warning(
        'agents-unlisted',
        scope: 'daemon/models',
        data: <String, Object?>{'error': error.runtimeType.toString()},
      );
      return none;
    }
  }

  /// The coding agent [id] as its own terminal offers it to [chatId], or
  /// null when that terminal does not offer it or could not be asked.
  Future<core.Model?> _onItsTerminal(String id, String? chatId) async {
    try {
      return await resolveTerminalAgentModel(
        _container,
        id,
        chatId: chatId,
        timeout: _agentLookupWait,
      );
    } on Object catch (error) {
      DebugLogger.warning(
        'agent-lookup-failed',
        scope: 'daemon/models',
        data: <String, Object?>{'error': error.runtimeType.toString()},
      );
      return null;
    }
  }

  /// The coding agent [conversation] was saved with, while the chat's own
  /// [pick] is not it: the window offers Switch to it.
  static String? _chatAgent(Conversation? conversation, core.Model? pick) {
    final id = conversation?.model;
    return isTerminalAgentModelId(id) && pick?.id != id ? id : null;
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
    final account = AccountScope.capture(_container);
    final model = await _controlled(query.modelId, query.chatId, account);
    return _controlsOf(model, account);
  }

  /// `models.setControl`: the pick, saved in the account's Open WebUI
  /// settings through the core (taken back if the server refuses it).
  Future<ModelControlList> setControl(SetModelControl request) async {
    // The pick is saved on the server of the account it was made under
    // ([AccountScope]), or nowhere.
    final account = AccountScope.capture(_container);
    final model = await _controlled(request.modelId, request.chatId, account);
    account.require('the model control is checked');
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
    // Saved for that account: answered only to it, never written again
    // for another.
    return _controlsOf(model, account);
  }

  /// [model]'s controls with [account]'s picks, answered only while that
  /// account is in charge.
  Future<ModelControlList> _controlsOf(
    core.Model? model,
    AccountScope account,
  ) async {
    if (model == null || modelControlsOf(model).isEmpty) {
      account.require('the model controls are answered');
      return ModelControlList(modelId: model?.id);
    }
    final choices = await _choices();
    account.require('the model controls are answered');
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
  Future<core.Model?> _controlled(
    String? id,
    String? chatId,
    AccountScope account,
  ) async {
    final selected = await currentModel(_container);
    if (id == null) return selected;
    if (isTerminalAgentModelId(id)) {
      // The chat's own agent, as it was picked there, else asked of its own
      // terminal: never as the account selected it for another chat, nor on
      // the terminal selected for one. A pick known by its id alone carries
      // no controls.
      if (chatId == null) await _checkNewChat(account);
      final pick = _picksOf(account)[_now(chatId)];
      if (pick != null && pick.model?.id == id && !pick.idOnly) {
        return pick.model;
      }
      // Read again: the selection may have moved during the check above.
      final now = _container.read(selectedModelProvider);
      if (chatId == null && now?.id == id) return now;
      final conversation = chatId == null
          ? null
          : await _conversation(chatId, account);
      if (chatId != null && conversation == null) return null;
      final own = await _onItsTerminal(id, chatId);
      if (own != null) return own;
      return (await _agents(
        conversation,
        account,
      )).agents.where((candidate) => candidate.id == id).firstOrNull;
    }
    // By the core's one rule, never the selection by its id alone: one the
    // server no longer offers takes no control.
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
    device: tetherModelDeviceTag(model),
    logo: _logo(model),
    agent: terminalAgentDto(
      model.id,
      // The server's metadata, copied as sent: only text names a terminal.
      terminalName: switch (model.metadata?[kTerminalAgentTerminalNameKey]) {
        final String name => name,
        _ => null,
      },
      model: terminalAgentModelName(model),
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

/// One chat's pick, and the revision it was written at.
final class _Pick {
  _Pick(this.model, this.revision, {this.idOnly = false});

  /// Null once the pick is gone (New Chat's, taken by its first send): the
  /// record stays for its revision.
  final core.Model? model;
  final int revision;

  /// Whether [model] is known by its id alone (a coding agent a first send
  /// named), not as a terminal offered it: it has none of its controls.
  final bool idOnly;

  /// Set once [model], New Chat's coding agent, was found gone
  /// ([ModelsService._checkNewChat]): a send that took this pick before then
  /// ran without it, and leaves it to no chat.
  bool gone = false;
}

/// A turn on its way ([ModelsService.sending]): the account and chat it
/// was sent from, New Chat's pick then, and the newest revision then.
final class ModelSend {
  ModelSend._(
    this._account,
    this._fromChat,
    this._slotKey,
    this._slot,
    this._revision,
  );

  final AccountScope _account;
  final String? _fromChat;

  /// Where the pick it may take is kept ([ModelsService._slotOf]).
  final String? _slotKey;
  final _Pick? _slot;
  final int _revision;
}

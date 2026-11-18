import 'dart:async';
import 'dart:math';

import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/automations/automation_run_tracking.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_editor_options_provider.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_terminal_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_agent_model.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'models_service.dart' show terminalAgentDto;
import 'settled.dart';

/// `automations.*`: the account's Open WebUI scheduled tasks, through core's
/// [Automations], as the phone's Scheduled Tasks pages use them.
///
/// Run Now is watched here, as the phone's task page watches it: the
/// server only accepts the request, so the history is read every
/// [automationRunPollInterval] until the run shows up, and each step goes
/// out as `automations.runProgress`.
final class AutomationsService {
  AutomationsService(
    this._container, {
    EventBus? events,
    Duration pollInterval = automationRunPollInterval,
    int pollLimit = automationRunPollLimit,
  }) : _events = events,
       _pollInterval = pollInterval,
       _pollLimit = pollLimit;

  final ProviderContainer _container;
  final EventBus? _events;
  final Duration _pollInterval;
  final int _pollLimit;

  ProviderSubscription<AsyncValue<AutomationsData>>? _watch;
  final Map<String, _TaskEditor> _editors = <String, _TaskEditor>{};
  static const int _maxEditors = 8;
  final Random _random = Random.secure();

  /// Run Now per task: where it stands, and the run an earlier request found
  /// (part of the next request's baseline), each with the account it was
  /// asked for: another account signed in sees neither.
  final Map<String, AutomationRunProgress> _progress =
      <String, AutomationRunProgress>{};
  final Map<String, AutomationsOwner> _progressOwner =
      <String, AutomationsOwner>{};
  final Map<String, ({AutomationsOwner owner, AutomationRun run})> _requested =
      <String, ({AutomationsOwner owner, AutomationRun run})>{};
  final Map<String, Timer> _polls = <String, Timer>{};

  Automations get _notifier => _container.read(automationsProvider.notifier);

  void dispose() {
    _watch?.close();
    _watch = null;
    for (final timer in _polls.values) {
      timer.cancel();
    }
    _polls.clear();
    for (final editor in _editors.values) {
      editor.close();
    }
    _editors.clear();
  }

  void _ensureWatching() {
    _watch ??= _container.listen<AsyncValue<AutomationsData>>(
      automationsProvider,
      (previous, next) {
        if (next.isLoading && !next.hasValue) return;
        _events?.emit(ConduitEventSpecs.automationsChanged, null);
      },
    );
  }

  // ── The list ───────────────────────────────────────────────────────────

  Future<AutomationList> list(AutomationQuery query) async {
    if (!await _available()) {
      return const AutomationList(failure: 'unavailable');
    }
    _ensureWatching();
    AutomationsData? data;
    try {
      data = await readSettled(_container, automationsProvider.future);
    } on Object {
      // Shown as the failure below.
    }
    final owner = _notifier.captureOwner();
    if (owner == null) return const AutomationList(failure: 'accountChanged');
    final status = switch (query.status) {
      'active' => AutomationStatusFilter.active,
      'paused' => AutomationStatusFilter.paused,
      'all' => AutomationStatusFilter.all,
      _ => null,
    };
    if (query.query != null ||
        status != null ||
        query.refresh ||
        data == null) {
      await _notifier.refresh(owner: owner, query: query.query, status: status);
    }
    return _listOf(_container.read(automationsProvider));
  }

  Future<AutomationList> loadMore() async {
    await _requireData();
    await _notifier.loadMore(owner: _owner());
    return _listOf(_container.read(automationsProvider));
  }

  Future<AutomationDetail> get(AutomationRef ref) async {
    await _requireData();
    final owner = _owner();
    final task = await _guard(() => _notifier.fetch(ref.id, owner: owner));
    // The model's, channel's, folder's and terminal's names, when they load
    // soon.
    await _settle(const Duration(seconds: 2));
    final terminals = await _terminalsSoon();
    _stillCurrent(owner);
    return _detailOf(task, terminals: terminals);
  }

  /// The server's terminals for tasks, when they arrive within two seconds.
  Future<List<TerminalServerInfo>?> _terminalsSoon() async {
    try {
      return await readSettled(
        _container,
        automationTerminalsProvider.future,
      ).timeout(const Duration(seconds: 2));
    } on Object {
      return null;
    }
  }

  Future<AutomationRuns> runs(AutomationRunsQuery query) async {
    await _requireData();
    final page = await _guard(
      () => _notifier.runs(query.id, skip: query.skip, owner: _owner()),
    );
    return AutomationRuns(
      items: [for (final run in page) _runDto(run)],
      hasMore: page.length >= automationRunsPageSize,
    );
  }

  Future<AutomationDetail> setActive(AutomationToggle toggle) async {
    await _requireData();
    final task = await _guard(
      () => _notifier.setActive(toggle.id, toggle.active, owner: _owner()),
    );
    return _detailOf(task);
  }

  Future<AutomationList> delete(AutomationRef ref) async {
    await _requireData();
    await _guard(() => _notifier.remove(ref.id, owner: _owner()));
    _polls.remove(ref.id)?.cancel();
    _progress.remove(ref.id);
    _progressOwner.remove(ref.id);
    _requested.remove(ref.id);
    return _listOf(_container.read(automationsProvider));
  }

  // ── Run Now ────────────────────────────────────────────────────────────

  AutomationRunProgress runState(AutomationRef ref) =>
      _progressOf(ref.id) ?? AutomationRunProgress(id: ref.id);

  /// [id]'s Run Now, when it was asked for the account signed in now.
  AutomationRunProgress? _progressOf(String id) {
    final owner = _progressOwner[id];
    if (owner == null || !_notifier.isCurrentOwner(owner)) return null;
    return _progress[id];
  }

  Future<AutomationRunProgress> run(AutomationRef ref) async {
    final id = ref.id;
    final shown = _progressOf(id);
    if (shown?.phase == 'requesting' || shown?.phase == 'waiting') {
      return shown!;
    }
    await _requireData();
    final owner = _owner();
    _polls.remove(id)?.cancel();
    final earlier = _requested[id];
    final requested = earlier != null && _notifier.isCurrentOwner(earlier.owner)
        ? earlier.run
        : null;
    void set(AutomationRunProgress progress) => _set(progress, owner);
    set(AutomationRunProgress(id: id, phase: 'requesting'));
    try {
      // What the history held right before the request: a scheduled run
      // that finished meanwhile must not pass for the requested one.
      var latest = const <AutomationRun>[];
      Automation? task;
      try {
        task = await _notifier.fetch(id, owner: owner);
        latest = await _notifier.runs(id, owner: owner);
      } on AutomationsOwnerChangedException {
        rethrow;
      } on Object {
        // The request still goes; what is known is the baseline.
      }
      final baseline = AutomationRunBaseline.of(
        runs: [...latest, ?requested],
        task: task,
      );
      await _notifier.run(id, owner: owner);
      set(AutomationRunProgress(id: id, phase: 'waiting'));
      var polls = 0;
      var inFlight = false;
      _polls[id] = Timer.periodic(_pollInterval, (timer) async {
        if (inFlight) return;
        if (!_notifier.isCurrentOwner(owner)) {
          timer.cancel();
          _polls.remove(id);
          set(
            AutomationRunProgress(
              id: id,
              phase: 'idle',
              failure: 'accountChanged',
            ),
          );
          return;
        }
        inFlight = true;
        polls++;
        try {
          final page = await _notifier.runs(id, owner: owner);
          if (_progress[id]?.phase != 'waiting') return;
          final found = baseline.requestedRun(page);
          if (found != null) {
            timer.cancel();
            _polls.remove(id);
            _requested[id] = (owner: owner, run: found);
            set(
              AutomationRunProgress(
                id: id,
                phase: found.succeeded ? 'finished' : 'failed',
                run: _runDto(found),
              ),
            );
            // The list's last run and the calendar's runs move too.
            unawaited(_refreshQuietly());
          }
        } on AutomationsOwnerChangedException {
          timer.cancel();
          _polls.remove(id);
          set(
            AutomationRunProgress(
              id: id,
              phase: 'idle',
              failure: 'accountChanged',
            ),
          );
        } on Object {
          // A failed read is tried again on the next tick.
        } finally {
          inFlight = false;
          if (_progress[id]?.phase == 'waiting' && polls >= _pollLimit) {
            timer.cancel();
            _polls.remove(id);
            set(AutomationRunProgress(id: id, phase: 'timedOut'));
          }
        }
      });
    } on Object catch (error) {
      set(
        AutomationRunProgress(id: id, phase: 'idle', failure: _failure(error)),
      );
    }
    return _progress[id]!;
  }

  void _set(AutomationRunProgress progress, AutomationsOwner owner) {
    _progress[progress.id] = progress;
    _progressOwner[progress.id] = owner;
    _events?.emit(ConduitEventSpecs.automationsRunProgress, progress);
  }

  Future<void> _refreshQuietly() async {
    final owner = _notifier.captureOwner();
    if (owner == null) return;
    try {
      await _notifier.refresh(owner: owner);
    } on Object {
      // The list marks itself stale.
    }
  }

  // ── The editor ─────────────────────────────────────────────────────────

  Future<AutomationEditor> editor(AutomationEditorOpen open) async {
    await _requireData();
    final owner = _owner();
    final id = open.id;
    final draft = id == null
        ? AutomationDraft.create(
            schedule: const DailyAutomationSchedule(hour: 9, minute: 0),
          )
        : AutomationDraft.edit(
            await _guard(() => _notifier.fetch(id, owner: owner)),
          );
    final options = _container.listen<AutomationEditorOptions>(
      automationEditorOptionsProvider,
      (_, _) {},
    );
    final terminals = _container.listen<AsyncValue<List<TerminalServerInfo>?>>(
      automationTerminalsProvider,
      (_, _) {},
    );
    // Give the lists a moment to load, so the editor opens with them.
    await _settle(const Duration(seconds: 5));
    await _terminalsSoon();
    if (!_notifier.isCurrentOwner(owner)) {
      options.close();
      terminals.close();
      _stillCurrent(owner);
    }
    final token = List.generate(
      12,
      (_) => _random.nextInt(36).toRadixString(36),
    ).join();
    final editor = _TaskEditor(_container, owner, draft, options, terminals);
    _editors[token] = editor;
    while (_editors.length > _maxEditors) {
      _editors.remove(_editors.keys.first)?.close();
    }
    await editor.agentsSoon(draft);
    // The wait for the terminal's agents is a wait like the others: the
    // editor answers only while it is still open for the account that
    // opened it, with that account's lists.
    _heldAfterWait(token, editor);
    final now = editor.optionsFor(draft);
    return AutomationEditor(
      token: token,
      isNew: draft.isNew,
      fields: _fieldsOf(draft),
      models: _modelOptions(now.models),
      terminals: _terminalOptions(now.terminals),
      agentsUnknown: now.agentsUnknown,
      agentName: terminalAgentDisplayName(draft.modelId.trim()),
      channels: now.channels == null
          ? null
          : [
              for (final channel in now.channels!)
                AutomationOption(id: channel.id, name: channel.name),
            ],
      folders: now.folders == null
          ? null
          : [
              for (final folder in now.folders!)
                AutomationOption(id: folder.id, name: folder.name),
            ],
      terminal: draft.original?.terminal != null,
    );
  }

  /// `automations.terminals`: the terminals, and the models with the
  /// draft's terminal's coding agents, once that terminal has answered (or
  /// failed to in time).
  Future<AutomationTerminals> terminals(AutomationDraftEdit edit) async {
    final editor = _editor(edit.token);
    final draft = editor.apply(edit.fields);
    await editor.agentsSoon(draft);
    final now = _heldAfterWait(edit.token, editor).optionsFor(draft);
    return AutomationTerminals(
      terminals: _terminalOptions(now.terminals),
      models: _modelOptions(now.models),
      agentsUnknown: now.agentsUnknown,
    );
  }

  static List<AutomationOption>? _modelOptions(List<Model>? models) =>
      models == null
      ? null
      : [
          for (final model in models)
            AutomationOption(
              id: model.id,
              name: model.name,
              detail: terminalAgentPickerSubtitle(model),
              agent: isTerminalAgentModel(model),
            ),
        ];

  static List<AutomationOption>? _terminalOptions(
    List<TerminalServerInfo>? terminals,
  ) => terminals == null
      ? null
      : [
          for (final terminal in terminals)
            AutomationOption(
              id: terminal.selectionId,
              name: terminal.displayName,
            ),
        ];

  Future<void> _settle(Duration limit) async {
    Future<void> wait(Future<void> Function() read) async {
      try {
        await read().timeout(limit);
      } on Object {
        // The editor opens without that list; the server decides then.
      }
    }

    await Future.wait([
      wait(() => readSettled(_container, modelsProvider.future)),
      wait(() => readSettled(_container, channelsListProvider.future)),
      wait(() => readSettled(_container, foldersProvider.future)),
    ]);
  }

  Future<AutomationDraftState> checkDraft(AutomationDraftEdit edit) async {
    final editor = _editor(edit.token);
    var draft = editor.apply(edit.fields);
    final kind = switch (edit.chooseKind) {
      'once' => AutomationScheduleKind.once,
      'daily' => AutomationScheduleKind.daily,
      'weekly' => AutomationScheduleKind.weekly,
      _ => null,
    };
    if (kind != null) {
      draft = draft.copyWith(
        schedule: automationScheduleOfKind(
          kind,
          current: draft.schedule,
          now: DateTime.now(),
        ),
      );
    }
    return editor.stateOf(draft, _fieldsOf(draft));
  }

  Future<AutomationDraftState> save(AutomationDraftEdit edit) async {
    final editor = _editor(edit.token);
    final draft = editor.apply(edit.fields);
    var state = editor.stateOf(draft, _fieldsOf(draft));
    if (state.issues.isNotEmpty) return state;
    final channel = draft.target.channelId;
    try {
      if (draft.target.isChannel &&
          channel != null &&
          editor.base.read().needsWriteReadBack(channel)) {
        final writable = await _notifier.channelWritable(
          channel,
          owner: editor.owner,
        );
        if (!writable) {
          return state.copyWith(issues: const <String>['channelNoWrite']);
        }
      }
      final original = draft.original;
      final saved = original == null
          ? await _notifier.create(draft.toForm(), owner: editor.owner)
          : await _notifier.updateTask(
              original.id,
              draft.toForm(),
              owner: editor.owner,
            );
      // The editor goes on as an edit of the task saved: what the window
      // typed while this save was out is saved to it next, never made again.
      if (_editors.containsKey(edit.token)) {
        editor._agents?.close();
        editor._agents = null;
        _editors[edit.token] = _TaskEditor(
          _container,
          editor.owner,
          AutomationDraft.edit(saved),
          editor.base,
          editor.terminals,
        );
      }
      state = state.copyWith(saved: true, id: saved.id);
    } on Object catch (error) {
      state = state.copyWith(failure: _failure(error));
    }
    return state;
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Whether the account may use the scheduled tasks, once the server's config and
  /// the account's permissions have loaded (both read as no while loading).
  Future<bool> _available() async {
    if (_container.read(automationsAvailableProvider)) return true;
    if (_container.read(apiServiceProvider) == null) return false;
    // The config answers with its cached copy first and refreshes behind
    // it, so right after a sign-in the rule can still read the old one.
    try {
      await _container
          .read(backendConfigProvider.notifier)
          .refresh()
          .timeout(const Duration(seconds: 10));
      await readSettled(
        _container,
        userPermissionsProvider.future,
      ).timeout(const Duration(seconds: 10));
    } on Object {
      // A failed read leaves the rule at its answer, which is no.
    }
    return _container.read(automationsAvailableProvider);
  }

  /// The editor open under [token] after a wait that began with [editor]:
  /// refused once it was closed (or pushed out by newer ones) meanwhile, or
  /// once another account is in charge than the one that opened it (then
  /// it is closed too). A save meanwhile replaces it with the editor of the
  /// saved task, which is the one answered for.
  _TaskEditor _heldAfterWait(String token, _TaskEditor editor) {
    final now = _editor(token);
    if (!_notifier.isCurrentOwner(now.owner)) {
      if (identical(_editors[token], now)) _editors.remove(token)?.close();
      _stillCurrent(now.owner);
    }
    return now;
  }

  _TaskEditor _editor(String token) =>
      _editors[token] ??
      (throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: const <String, String>{'reason': 'editorClosed'},
        debugMessage: 'no open task editor "$token"',
      ));

  Future<void> _requireData() async {
    if (!await _available()) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        args: <String, String>{'reason': 'unavailable'},
      );
    }
    _ensureWatching();
    try {
      await readSettled(_container, automationsProvider.future);
    } on Object {
      // A failed list does not stop a task being read on its own.
    }
  }

  AutomationsOwner _owner() =>
      _notifier.captureOwner() ??
      (throw const RpcError(
        code: ConduitErrorCodes.conflict,
        args: <String, String>{'reason': 'accountChanged'},
        debugMessage: 'no Open WebUI account holds scheduled tasks now',
      ));

  /// Refuses an answer read for [owner] once another account is signed in.
  void _stillCurrent(AutomationsOwner owner) {
    if (_notifier.isCurrentOwner(owner)) return;
    throw const RpcError(
      code: ConduitErrorCodes.conflict,
      args: <String, String>{'reason': 'accountChanged'},
      debugMessage: 'another account signed in while the task was read',
    );
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RpcError {
      rethrow;
    } on Object catch (error) {
      throw _rpcError(error);
    }
  }

  /// What the window says about a refusal: a reason it words itself, or the
  /// server's own explanation (such as the minimum interval).
  static String _failure(Object error) {
    if (error is AutomationsOwnerChangedException) return 'accountChanged';
    if (error is AutomationsUnavailableException) return 'unavailable';
    if (error is DioException && error.response?.statusCode == 404) {
      return 'notFound';
    }
    return automationErrorDetail(error) ?? 'failed';
  }

  static RpcError _rpcError(Object error) {
    final reason = _failure(error);
    if (error is DioException && error.response == null) {
      return RpcError(
        code: ConduitErrorCodes.connectionFailed,
        debugMessage: error.message,
        retryable: true,
      );
    }
    return RpcError(
      code: switch (reason) {
        'accountChanged' => ConduitErrorCodes.conflict,
        'unavailable' => ConduitErrorCodes.unsupported,
        'notFound' => ConduitErrorCodes.notFound,
        _ => ConduitErrorCodes.serverError,
      },
      args: switch (reason) {
        'accountChanged' ||
        'unavailable' ||
        'notFound' ||
        'failed' => {'reason': reason},
        _ => {'reason': 'server', 'detail': reason},
      },
      debugMessage: error.toString(),
    );
  }

  AutomationList _listOf(AsyncValue<AutomationsData> state) {
    final data = state.asData?.value;
    if (data == null) {
      final error = state.error;
      return AutomationList(
        available: true,
        failure: error == null ? null : _failure(error),
      );
    }
    return AutomationList(
      available: true,
      stale: data.stale,
      query: data.query,
      status: data.status.name,
      items: [for (final task in data.items) _summaryOf(task)],
      total: data.total,
      hasMore: data.hasMore,
    );
  }

  static int? _ms(int? nanoseconds) =>
      nanoseconds == null ? null : nanoseconds ~/ 1000000;

  AutomationSummary _summaryOf(Automation task) => AutomationSummary(
    id: task.id,
    name: task.name,
    active: task.isActive,
    schedule: _scheduleDto(AutomationSchedule.parse(task.rrule)),
    nextRunAt: _ms(task.nextRunNs),
    lastRunAt: _ms(task.lastRun?.createdAtNs ?? task.lastRunAtNs),
    lastRunFailed: task.lastRun?.succeeded == false,
    agent: terminalAgentDto(task.modelId.trim()),
  );

  AutomationDetail _detailOf(
    Automation task, {
    List<TerminalServerInfo>? terminals,
  }) {
    final models = _container.read(modelsProvider).asData?.value;
    final channels = _container.read(channelsListProvider).asData?.value;
    final folders = _container.read(foldersProvider).asData?.value;
    final channelId = task.target.channelId;
    // What the editor reads back: the terminal and its folder, as stored.
    final opened = AutomationDraft.edit(task);
    final terminalName = terminals
        ?.where((t) => t.selectionId == opened.terminalId)
        .map((t) => t.displayName)
        .firstOrNull;
    return AutomationDetail(
      summary: _summaryOf(task),
      prompt: task.prompt,
      modelId: task.modelId,
      // A coding agent is named as the picker names it, not as a model the
      // account does not have (a task made on the web with an agent).
      modelName:
          models
              ?.where((m) => m.id == task.modelId)
              .map((m) => m.name)
              .firstOrNull ??
          terminalAgentDisplayName(task.modelId.trim()),
      terminalId: opened.terminalId,
      terminalName: terminalName,
      workingDirectory: opened.terminalCwd,
      agent: terminalAgentDto(task.modelId.trim(), terminalName: terminalName),
      target: task.target.isChannel ? 'channel' : 'chat',
      channelId: channelId,
      channelName: channels
          ?.where((c) => c.id == channelId)
          .map((c) => c.name)
          .firstOrNull,
      folderId: task.folderId,
      folderName: folders
          ?.where((f) => f.id == task.folderId)
          .map((f) => f.name)
          .firstOrNull,
      terminal: task.terminal != null,
      nextRuns: task.isActive
          ? [for (final ns in task.nextRunsNs ?? const <int>[]) ns ~/ 1000000]
          : const <int>[],
    );
  }

  static AutomationRunDto _runDto(AutomationRun run) => AutomationRunDto(
    id: run.id,
    status: run.status,
    succeeded: run.succeeded,
    error: run.error,
    createdAt: _ms(run.createdAtNs),
    resultChatId: run.resultChatId,
    resultChannelId: run.resultChannelId,
  );

  static AutomationScheduleDto _scheduleDto(AutomationSchedule schedule) =>
      switch (schedule) {
        final OnceAutomationSchedule once => AutomationScheduleDto(
          kind: 'once',
          year: once.year,
          month: once.month,
          day: once.day,
          hour: once.hour,
          minute: once.minute,
          rrule: once.toRrule(),
        ),
        final DailyAutomationSchedule daily => AutomationScheduleDto(
          kind: 'daily',
          hour: daily.hour,
          minute: daily.minute,
          rrule: daily.toRrule(),
        ),
        final WeeklyAutomationSchedule weekly => AutomationScheduleDto(
          kind: 'weekly',
          hour: weekly.hour,
          minute: weekly.minute,
          days: [
            for (final code in AutomationSchedule.weekdayCodes)
              if (weekly.days.contains(code)) code,
          ],
          rrule: weekly.toRrule(),
        ),
        final RawAutomationSchedule raw => AutomationScheduleDto(
          kind: 'custom',
          rrule: raw.rrule,
        ),
      };

  static AutomationSchedule _scheduleOf(AutomationScheduleDto dto) =>
      switch (dto.kind) {
        'once' => OnceAutomationSchedule(
          year: dto.year,
          month: dto.month,
          day: dto.day,
          hour: dto.hour,
          minute: dto.minute,
        ),
        'daily' => DailyAutomationSchedule(hour: dto.hour, minute: dto.minute),
        'weekly' => WeeklyAutomationSchedule(
          hour: dto.hour,
          minute: dto.minute,
          days: dto.days.toSet(),
        ),
        // Typed into the rule field: it reads back as the controls' kind
        // when they can write it.
        _ => AutomationSchedule.parse(dto.rrule),
      };

  static AutomationFields _fieldsOf(AutomationDraft draft) => AutomationFields(
    name: draft.name,
    prompt: draft.prompt,
    modelId: draft.modelId,
    active: draft.isActive,
    schedule: _scheduleDto(draft.schedule),
    target: draft.target.isChannel ? 'channel' : 'chat',
    channelId: draft.target.channelId,
    folderId: draft.folderId,
    terminalId: draft.terminalId,
    workingDirectory: draft.terminalCwd,
  );
}

/// One open task editor: the account it was opened for, the draft it
/// started from, and the options it offers (kept alive while it is open):
/// the account's models, channels and folders, the server's terminals, and
/// the coding agents of the draft's terminal.
final class _TaskEditor {
  _TaskEditor(
    this._container,
    this.owner,
    this.opened,
    this.base,
    this.terminals,
  ) : _terminal = opened.terminalId;

  final ProviderContainer _container;
  final AutomationsOwner owner;
  final AutomationDraft opened;
  final ProviderSubscription<AutomationEditorOptions> base;
  final ProviderSubscription<AsyncValue<List<TerminalServerInfo>?>> terminals;

  /// The terminal the draft was last on: moving off it drops its folder and
  /// any agent of it ([AutomationDraft.withTerminal]).
  String? _terminal;

  /// Keeps the draft's terminal's coding agents read while it is open.
  ProviderSubscription<AsyncValue<List<Model>?>>? _agents;
  AutomationAgentQuery? _agentsQuery;

  void close() {
    base.close();
    terminals.close();
    _agents?.close();
    _agents = null;
  }

  /// What [draft] can pick now ([AutomationEditorOptions.withTerminalAgents]),
  /// asking its terminal for its agents when that changed.
  AutomationEditorOptions optionsFor(AutomationDraft draft) {
    final servers = terminals.read();
    final query = automationAgentQueryFor(
      draft,
      servers.asData?.value,
      cwd: draft.terminalCwd?.trim(),
    );
    if (query != _agentsQuery) {
      _agents?.close();
      _agentsQuery = query;
      _agents = query == null
          ? null
          : _container.listen<AsyncValue<List<Model>?>>(
              automationAgentModelsProvider(query),
              (_, _) {},
            );
    }
    return base.read().withTerminalAgents(
      draft: draft,
      terminals: servers,
      agents: _agents?.read(),
    );
  }

  /// Waits (a few seconds at most) for [draft]'s terminal to list its
  /// agents, so an answer carries them.
  Future<void> agentsSoon(AutomationDraft draft) async {
    optionsFor(draft);
    final query = _agentsQuery;
    if (query == null) return;
    try {
      await readSettled(
        _container,
        automationAgentModelsProvider(query).future,
      ).timeout(const Duration(seconds: 5));
    } on Object {
      // Left unknown: the server decides.
    }
  }

  AutomationDraft apply(AutomationFields fields) {
    final channel = fields.target == 'channel';
    final channelId = fields.channelId;
    final draft = _withTerminal(_applied(fields, channel, channelId), fields);
    _terminal = draft.terminalId;
    return draft;
  }

  /// [draft] on the fields' terminal and folder. A terminal other than the
  /// one it was on starts from that terminal's own folder, and keeps no
  /// agent of the old one.
  AutomationDraft _withTerminal(AutomationDraft draft, AutomationFields f) {
    final id = _text(f.terminalId);
    final cwd = _text(f.workingDirectory);
    final previous = _terminal;
    var next = draft.copyWith(clearTerminal: true);
    if (previous != null) {
      next = next.copyWith(terminalId: previous, terminalCwd: cwd);
    }
    return id == previous ? next : next.withTerminal(id);
  }

  static String? _text(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  AutomationDraft _applied(
    AutomationFields fields,
    bool channel,
    String? channelId,
  ) {
    return opened.copyWith(
      name: fields.name,
      prompt: fields.prompt,
      modelId: fields.modelId,
      isActive: fields.active,
      schedule: AutomationsService._scheduleOf(fields.schedule),
      target: !channel
          ? const AutomationTarget.chat()
          : channelId == null || channelId.isEmpty
          ? const AutomationTarget.channelPending()
          : AutomationTarget.channel(channelId),
      folderId: fields.folderId,
      clearFolder: fields.folderId == null || fields.folderId!.isEmpty,
    );
  }

  AutomationDraftState stateOf(AutomationDraft draft, AutomationFields shown) =>
      AutomationDraftState(
        fields: shown,
        issues: [
          for (final issue in optionsFor(draft).issuesFor(draft)) issue.name,
        ],
        changed: draft.isNew
            ? shown != AutomationsService._fieldsOf(opened)
            : draft.isChanged,
      );
}

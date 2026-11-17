import 'dart:async';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        HermesDecisionAnswerOutcome,
        HermesPendingDecision,
        hermesDecisionsAskTheSame,
        answerHermesDecision,
        pendingHermesDecisionOf;
import 'package:conduit_core/features/hermes/models/hermes_background_work.dart'
    as core;
import 'package:conduit_core/features/hermes/models/hermes_clarify_form.dart';
import 'package:conduit_core/features/hermes/models/hermes_context_usage.dart'
    as core;
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart'
    show HermesDecisionKind;
import 'package:conduit_core/features/hermes/models/hermes_todo.dart';
import 'package:conduit_core/features/hermes/providers/hermes_background_work_providers.dart'
    hide HermesSubagentRef;
import 'package:conduit_core/features/hermes/providers/hermes_context_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_todo_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_working_directory_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'hermes_service.dart' show hermesSessionOf;
import 'ui_requests_service.dart';

/// Opens (or joins) the live scope of a chat and keeps it open until
/// [ScopeRelease] is called as many times.
typedef ScopeHold = Future<ProviderContainer> Function(String chatId);
typedef ScopeRelease = void Function(String chatId);

/// The Hermes agent's cards in a chat, over the core's providers:
///
/// * **Work** (`hermes.work.*`): a window showing a Hermes chat watches it,
///   which holds the chat's scope open and listens there to what mobile's
///   chat screen watches -- the background work list (subagents and
///   processes, polled while anything runs), the plan, the working
///   directory, and the output of the subagent the window reads. Every
///   change goes out as `hermes.work.changed`, scoped to the chat. Steer,
///   Stop and Kill go through the same controller mobile's sheet uses.
/// * **Context** (`hermes.context.*`): the chat's context window and usage
///   report, and Compact Now.
/// * **Decisions** (`hermes.decisions.*`): a clarify form, a sudo password,
///   a secret or an MCP set-up the agent is waiting on goes to every window
///   as a `ui.request` (docked above the composer), and is answered with
///   `hermes.decisions.answer` through the core's [answerHermesDecision],
///   which waits for Hermes to take it. A question that goes away (answered
///   elsewhere, expired) settles its card.
final class HermesCardsService {
  HermesCardsService(
    this._container,
    this._events, {
    required ScopeHold hold,
    required ScopeRelease release,
    UiRequestsService? uiRequests,
  }) : _hold = hold,
       _release = release,
       _uiRequests = uiRequests;

  final ProviderContainer _container;
  final EventBus _events;
  final ScopeHold _hold;
  final ScopeRelease _release;
  final UiRequestsService? _uiRequests;

  // ---------------------------------------------------------------------------
  // hermes.work.*
  // ---------------------------------------------------------------------------

  final Map<String, _Watch> _watches = <String, _Watch>{};
  final Map<String, Future<_Watch>> _opening = <String, Future<_Watch>>{};

  /// Starts (or goes on) following [request]'s chat for the window
  /// [sessionId], and answers with its work as it stands.
  Future<HermesWork> watch(String sessionId, HermesWorkWatch request) async {
    final chatId = request.chatId;
    final watch = await _watchFor(chatId);
    watch.windows[sessionId] = request.subagentId;
    _followOutput(watch, request.subagentId);
    final work = _snapshot(watch);
    watch.last = work;
    return work;
  }

  Future<_Watch> _watchFor(String chatId) async {
    final existing = _watches[chatId];
    if (existing != null) return existing;
    final opening = _opening[chatId];
    if (opening != null) return opening;
    final future = () async {
      final container = await _hold(chatId);
      final watch = _Watch(chatId, container);
      watch.subscriptions.addAll(<ProviderSubscription<Object?>>[
        container.listen<core.HermesBackgroundWork?>(
          hermesBackgroundWorkProvider,
          (_, _) => _changed(watch),
        ),
        container.listen<AsyncValue<HermesTodoState?>>(
          hermesActiveTodoProvider,
          (_, _) => _changed(watch),
        ),
        container.listen<AsyncValue<String?>>(
          hermesActiveWorkingDirectoryProvider,
          (_, _) => _changed(watch),
        ),
        // The session the chat continues: a subagent's output is read
        // under it, so a new one re-reads it.
        container.listen<String?>(hermesOpenSessionIdProvider, (_, _) {
          _followOutput(watch, watch.outputFor, force: true);
          _changed(watch);
        }),
      ]);
      _watches[chatId] = watch;
      return watch;
    }();
    _opening[chatId] = future;
    try {
      return await future;
    } finally {
      _opening.remove(chatId);
    }
  }

  /// Stops following [chatId] for the window [sessionId].
  OkResult unwatch(String sessionId, String chatId) {
    final watch = _watches[chatId];
    if (watch == null || !watch.windows.containsKey(sessionId)) {
      return const OkResult(ok: false);
    }
    watch.windows.remove(sessionId);
    _afterWindowLeft(watch);
    return const OkResult(ok: true);
  }

  /// One fewer window watches [watch]: closed when none is left, else the
  /// output read is another window's.
  void _afterWindowLeft(_Watch watch) {
    if (watch.windows.isEmpty) {
      _close(watch);
    } else {
      _followOutput(watch, watch.windows.values.last);
      _changed(watch);
    }
  }

  /// A window went away: it watches nothing any more.
  void forgetWindow(String sessionId) {
    for (final watch in _watches.values.toList()) {
      if (!watch.windows.containsKey(sessionId)) continue;
      watch.windows.remove(sessionId);
      _afterWindowLeft(watch);
    }
  }

  void _close(_Watch watch) {
    if (_watches[watch.chatId] != watch) return;
    _watches.remove(watch.chatId);
    for (final subscription in watch.subscriptions) {
      subscription.close();
    }
    watch.output?.close();
    watch.closed = true;
    _release(watch.chatId);
  }

  /// Reads [subagentId]'s output with the work (none for null).
  void _followOutput(_Watch watch, String? subagentId, {bool force = false}) {
    if (!force && watch.outputFor == subagentId && watch.output != null) {
      return;
    }
    watch.output?.close();
    watch.output = null;
    watch.outputFor = subagentId;
    if (subagentId == null) return;
    final storedId = watch.container.read(hermesOpenSessionIdProvider);
    if (storedId == null) return;
    watch.output = watch.container.listen<HermesSubagentTailView>(
      hermesSubagentTailProvider((storedId: storedId, subagentId: subagentId)),
      (_, _) => _changed(watch),
    );
  }

  /// Sends the chat's work once whatever changed together has.
  void _changed(_Watch watch) {
    if (watch.scheduled || watch.closed) return;
    watch.scheduled = true;
    scheduleMicrotask(() {
      watch.scheduled = false;
      if (watch.closed) return;
      final work = _snapshot(watch);
      if (work == watch.last) return;
      watch.last = work;
      _events.emit(
        ConduitEventSpecs.hermesWorkChanged,
        work,
        scope: watch.chatId,
      );
    });
  }

  HermesWork _snapshot(_Watch watch) {
    final container = watch.container;
    final work = container.read(hermesBackgroundWorkProvider);
    final plan = container.read(hermesActiveTodoProvider).value;
    final directory = container
        .read(hermesActiveWorkingDirectoryProvider)
        .value;
    final subagentId = watch.outputFor;
    final output = watch.output?.read();
    return HermesWork(
      chatId: watch.chatId,
      loaded: work != null,
      subagents: <HermesSubagentDto>[
        for (final subagent in work?.subagents ?? const <core.HermesSubagent>[])
          HermesSubagentDto(
            id: subagent.id,
            goal: subagent.goal,
            parentId: subagent.parentId,
            depth: subagent.depth,
            model: subagent.model,
            startedAtMs: subagent.startedAt?.millisecondsSinceEpoch,
            status: subagent.status,
            running: subagent.running,
            toolCount: subagent.toolCount,
            lastTool: subagent.lastTool,
            acceptingSteer: subagent.acceptingSteer,
          ),
      ],
      processes: <HermesProcessDto>[
        for (final process
            in work?.processes ?? const <core.HermesBackgroundProcess>[])
          HermesProcessDto(
            id: process.id,
            command: process.command,
            running: process.running,
            startedAtMs: process.startedAt?.millisecondsSinceEpoch,
            exitCode: process.exitCode,
            output: process.output,
          ),
      ],
      plan: plan == null || plan.isEmpty ? null : _plan(plan),
      output: subagentId == null
          ? null
          : HermesSubagentOutputDto(
              subagentId: subagentId,
              loaded: output?.tail != null || (output?.failed ?? false),
              failed: output?.failed ?? false,
              available: output?.tail?.available ?? false,
              text: output?.tail?.text ?? '',
              truncated: output?.tail?.truncated ?? false,
            ),
      workingDirectory: directory,
    );
  }

  static HermesPlanDto _plan(HermesTodoState plan) => HermesPlanDto(
    items: <HermesPlanItemDto>[
      for (final item in plan.items)
        HermesPlanItemDto(
          id: item.id,
          content: item.content,
          status: switch (item.status) {
            HermesTodoStatus.pending => 'pending',
            HermesTodoStatus.inProgress => 'in_progress',
            HermesTodoStatus.completed => 'completed',
            HermesTodoStatus.cancelled => 'cancelled',
          },
          depth: plan.depthOf(item),
        ),
    ],
    done: plan.done,
    active: plan.active,
    currentId: plan.current?.id,
    revision: plan.revision,
  );

  HermesBackgroundWorkController _controller(String chatId) {
    final watch = _watches[chatId];
    if (watch == null) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'that chat is not watched (hermes.work.watch)',
      );
    }
    return watch.container.read(hermesBackgroundWorkProvider.notifier);
  }

  Future<OkResult> steer(HermesSteerSubagent request) async {
    final text = request.text.trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'nothing to send',
      );
    }
    final ok = await _guard(
      () => _controller(request.chatId).steer(request.subagentId, text),
    );
    return OkResult(ok: ok);
  }

  Future<OkResult> stop(HermesSubagentRef request) async {
    final found = await _guard(
      () => _controller(request.chatId).stop(request.subagentId),
    );
    return OkResult(ok: found);
  }

  Future<HermesProcessKill> kill(HermesProcessRef request) async {
    final result = await _guard(
      () => _controller(request.chatId).kill(request.processId),
    );
    return HermesProcessKill(
      status: switch (result.status) {
        core.HermesProcessKillStatus.killed => HermesProcessKillStatus.killed,
        core.HermesProcessKillStatus.alreadyExited =>
          HermesProcessKillStatus.alreadyExited,
        core.HermesProcessKillStatus.notFound =>
          HermesProcessKillStatus.notFound,
        core.HermesProcessKillStatus.failed => HermesProcessKillStatus.failed,
      },
      output: result.output,
      error: result.error,
    );
  }

  // ---------------------------------------------------------------------------
  // hermes.context.*
  // ---------------------------------------------------------------------------

  /// The Hermes session behind [chatId]: a Hermes chat's own.
  String _sessionOf(String chatId) {
    final sessionId = hermesSessionOf(chatId);
    if (sessionId == null) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'not a Hermes chat',
      );
    }
    return sessionId;
  }

  Future<HermesContextReportDto> context(HermesContextRef request) async {
    final sessionId = _sessionOf(request.chatId);
    final service = _container.read(hermesApiServiceProvider);
    if (service == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'Hermes is not connected',
      );
    }
    final report = await _guard(
      () => loadHermesContextReport(service, sessionId),
    );
    return _report(
      report,
      compacting:
          service is HermesDesktopApiService &&
          service.compactionPending(sessionId),
    );
  }

  Future<HermesCompactResultDto> compact(HermesCompact request) async {
    final sessionId = _sessionOf(request.chatId);
    final service = _container.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'only a Hermes Desktop Gateway compacts a chat',
      );
    }
    final focus = request.focus?.trim();
    final result = await _guard(
      () => service.compactSession(
        sessionId,
        focus: focus == null || focus.isEmpty ? null : focus,
      ),
    );
    return HermesCompactResultDto(
      outcome: switch (result.outcome) {
        core.HermesCompactOutcome.compacted => HermesCompactOutcome.compacted,
        core.HermesCompactOutcome.unchanged => HermesCompactOutcome.unchanged,
        core.HermesCompactOutcome.refused => HermesCompactOutcome.refused,
        core.HermesCompactOutcome.aborted => HermesCompactOutcome.aborted,
        core.HermesCompactOutcome.pending => HermesCompactOutcome.pending,
        core.HermesCompactOutcome.busy => HermesCompactOutcome.busy,
      },
      beforeTokens: result.beforeTokens,
      afterTokens: result.afterTokens,
      beforeMessages: result.beforeMessages,
      afterMessages: result.afterMessages,
    );
  }

  static HermesContextReportDto _report(
    core.HermesContextReport report, {
    required bool compacting,
  }) {
    final totals = report.totals;
    HermesPlanGaugeDto gauge(core.HermesPlanGauge gauge) => HermesPlanGaugeDto(
      id: gauge.id,
      title: gauge.title,
      usedFraction: gauge.usedFraction,
      resetsAtMs: gauge.resetsAt?.millisecondsSinceEpoch,
    );
    HermesUsageBarDto? bar(core.HermesUsageBar? bar) => bar == null
        ? null
        : HermesUsageBarDto(
            kind: bar.kind,
            fill: bar.fill,
            remaining: bar.remaining,
            total: bar.total,
            spent: bar.spent,
            usedPercent: bar.usedPercent,
          );
    final bars = report.usageBars;
    final plan = report.providerPlan;
    return HermesContextReportDto(
      model: report.model,
      contextUsed: report.contextUsed,
      contextMax: report.contextMax,
      contextEstimated: report.contextEstimated,
      estimatedTotal: report.estimatedTotal,
      categories: <HermesContextCategoryDto>[
        for (final category in report.categories)
          HermesContextCategoryDto(
            id: category.id,
            label: category.label,
            tokens: category.tokens,
          ),
      ],
      totals: HermesTokenTotalsDto(
        input: totals.input,
        output: totals.output,
        reasoning: totals.reasoning,
        cacheRead: totals.cacheRead,
        cacheWrite: totals.cacheWrite,
        cacheHitPercent: totals.cacheHitPercent,
        total: totals.total,
        calls: totals.calls,
        compressions: totals.compressions,
        costUsd: totals.costUsd,
        costEstimated: totals.costEstimated,
      ),
      planGauges: report.planGauges.map(gauge).toList(growable: false),
      creditsLines: report.creditsLines,
      usageBars: bars == null
          ? null
          : HermesUsageBarsDto(
              planName: bars.planName,
              renews: bars.renews,
              plan: bar(bars.plan),
              topup: bar(bars.topup),
              totalSpendable: bars.totalSpendable,
            ),
      providerPlan: plan == null || plan.isEmpty
          ? null
          : HermesProviderPlanDto(
              provider: plan.provider,
              planName: plan.planName,
              gauges: plan.gauges.map(gauge).toList(growable: false),
              rateLimited: plan.rateLimited,
              rateLimitedUntilMs: plan.rateLimitedUntil?.millisecondsSinceEpoch,
              usageLevel: plan.usageLevel,
            ),
      canCompact: report.canCompact,
      compacting: compacting,
    );
  }

  // ---------------------------------------------------------------------------
  // hermes.decisions.*
  // ---------------------------------------------------------------------------

  /// Offered questions, by their `ui.request` id.
  final Map<String, _Offer> _offers = <String, _Offer>{};

  /// The `ui.request` id of each question offered, by the question.
  final Map<String, String> _offered = <String, String>{};

  static String _key(String chatId, HermesPendingDecision decision) =>
      '$chatId\u0000${decision.runtimeId}\u0000${decision.requestId}';

  /// [message], an answer in [chatId]'s live scope [container], changed:
  /// offers the question it waits on, once, and settles a card whose
  /// question went away (answered elsewhere, or expired).
  void project(
    String chatId,
    ProviderContainer container,
    String ownerConversationId,
    ChatMessage message,
  ) {
    final decision = pendingHermesDecisionOf(message);
    for (final offer in _offers.values.toList()) {
      if (offer.chatId != chatId || offer.decision.messageId != message.id) {
        continue;
      }
      final renewed =
          decision != null &&
          (decision.requestId != offer.decision.requestId ||
              decision.runtimeId != offer.decision.runtimeId);
      // The same question asked again under new ids (a resumed session
      // replays what it still waits on), by the connection that asked: its
      // card stays, with what the user is typing into it, and its answer
      // goes to the question as asked now. Asked by another connection, it
      // is another card: nothing typed for one goes to the next.
      if (renewed &&
          hermesDecisionsAskTheSame(offer.decision, decision) &&
          identical(
            offer.container.read(hermesApiServiceProvider),
            offer.service,
          )) {
        _renew(offer, chatId, decision);
        continue;
      }
      if (decision == null || renewed) {
        _settle(offer, choice: 'deny');
      }
    }
    if (decision == null) return;
    final key = _key(chatId, decision);
    if (_offered.containsKey(key)) return;
    _offer(chatId, container, ownerConversationId, decision, key);
  }

  void _offer(
    String chatId,
    ProviderContainer container,
    String ownerConversationId,
    HermesPendingDecision decision,
    String key,
  ) {
    final ask = _uiRequests;
    if (ask == null) return;
    final timeout = decision.expiresAt.difference(DateTime.now().toUtc());
    if (timeout <= Duration.zero) return;
    final prompt = decision.prompt?.trim() ?? '';
    final (kind, code, args) = switch (decision.kind) {
      HermesDecisionKind.sudo => (
        UiRequestKind.hermesSudo,
        'hermes.sudo',
        <String, String>{'prompt': prompt},
      ),
      HermesDecisionKind.secret => (
        UiRequestKind.hermesSecret,
        'hermes.secret',
        <String, String>{'prompt': prompt},
      ),
      HermesDecisionKind.mcpSetup => (
        UiRequestKind.hermesDecision,
        'hermes.mcpSetup',
        <String, String>{
          'server': decision.mcpServer?.trim() ?? '',
          'action': decision.mcpAction?.trim() ?? '',
        },
      ),
      HermesDecisionKind.clarification => (
        UiRequestKind.hermesClarify,
        'hermes.clarify',
        <String, String>{'prompt': prompt},
      ),
    };
    final detail = <String, dynamic>{
      'chatId': chatId,
      if (decision.kind == HermesDecisionKind.clarification)
        'questions': _questions(decision),
    };
    final opened = ask.open(
      kind,
      messageCode: code,
      args: args,
      detail: detail,
      timeout: timeout,
    );
    final offer = _Offer(
      chatId: chatId,
      requestId: opened.requestId,
      key: key,
      decision: decision,
      container: container,
      owner: ownerConversationId,
      service: container.read(hermesApiServiceProvider),
    );
    _offers[offer.requestId] = offer;
    _offered[key] = offer.requestId;
    // Held while it waits: the answer goes through the chat's scope, even
    // once its turn has ended.
    unawaited(
      _hold(chatId).then((_) {
        if (offer.done) {
          _release(chatId);
        } else {
          offer.held = true;
        }
      }, onError: (Object _) {}),
    );
    unawaited(
      opened.answer.then((_) => _forget(offer), onError: (Object _) {}),
    );
  }

  /// The questions a `hermesClarify` card asks: a form's, or the one a
  /// plain reply asks (its prompt, with its choices).
  static List<Map<String, dynamic>> _questions(HermesPendingDecision decision) {
    final questions = decision.questions.isNotEmpty
        ? decision.questions
        : <HermesClarifyQuestion>[
            HermesClarifyQuestion(
              id: kHermesSingleClarifyQuestionId,
              text: decision.prompt?.trim() ?? '',
              choices: decision.choices,
              multiSelect: decision.multiSelect,
            ),
          ];
    return <Map<String, dynamic>>[
      for (final question in questions)
        <String, dynamic>{
          'id': question.id,
          'text': question.text,
          'choices': <Map<String, dynamic>>[
            for (final choice in question.choices)
              <String, dynamic>{
                // What goes back: the whole choice, as Hermes sent it (its
                // "(Recommended)" label is taken off by the answer).
                'value': hermesClarifyBareChoice(choice),
                'label': hermesClarifyChoiceLabel(choice),
                'recommended': hermesClarifyChoiceIsRecommended(choice),
              },
          ],
          'multiSelect': question.multiSelect,
          'locked': question.locked,
          'lockedAnswer': ?question.lockedAnswer,
        },
    ];
  }

  /// Answers the question behind the card [request] names, and waits for
  /// Hermes to take it.
  Future<HermesDecisionResult> answer(HermesDecisionAnswer request) async {
    final offer = _offers[request.requestId];
    // Gone: answered on another device, or it expired.
    if (offer == null || offer.done) {
      return const HermesDecisionResult(status: HermesDecisionStatus.settled);
    }
    if (offer.answering) {
      return const HermesDecisionResult(status: HermesDecisionStatus.failed);
    }
    // Asked by another connection than the one now set: a password or
    // secret typed for it never goes to this one. The question ended with
    // its connection.
    if (!identical(
      offer.container.read(hermesApiServiceProvider),
      offer.service,
    )) {
      _settle(offer, choice: 'deny');
      return const HermesDecisionResult(status: HermesDecisionStatus.settled);
    }
    offer.answering = true;
    final decision = offer.decision;
    // The question as asked now: a replay meanwhile ([_renew]) makes this
    // answer one to the question as it was, which settles nothing.
    final turn = offer.turn;
    bool current() => !offer.done && offer.turn == turn;
    final answers = <String, String?>{
      for (final answer in request.answers) answer.questionId: answer.answer,
    };
    // A plain reply (asked without question text) takes its one answer as
    // a value.
    final value = decision.isForm
        ? null
        : request.value ?? answers[kHermesSingleClarifyQuestionId];
    HermesDecisionAnswerOutcome outcome;
    try {
      outcome = await answerHermesDecision(
        offer.container,
        decision,
        ownerConversationId: offer.owner,
        value: value,
        answers: decision.isForm ? answers : null,
        isCurrent: current,
      );
    } on Object catch (error) {
      DebugLogger.warning(
        'hermes-decision-answer-failed',
        scope: 'daemon/hermes',
        data: <String, Object?>{'kind': decision.kind.name},
      );
      outcome = HermesDecisionAnswerOutcome.failed;
      assert(error is! Error, '$error');
    } finally {
      offer.answering = false;
    }
    if (!current()) {
      return HermesDecisionResult(
        status: offer.done
            ? HermesDecisionStatus.settled
            : HermesDecisionStatus.failed,
      );
    }
    switch (outcome) {
      case HermesDecisionAnswerOutcome.answered:
        _settle(offer, choice: 'allow');
        return const HermesDecisionResult(
          status: HermesDecisionStatus.answered,
        );
      case HermesDecisionAnswerOutcome.settled:
        _settle(offer, choice: 'deny');
        return const HermesDecisionResult(status: HermesDecisionStatus.settled);
      case HermesDecisionAnswerOutcome.failed:
        return const HermesDecisionResult(status: HermesDecisionStatus.failed);
    }
  }

  /// Points [offer]'s card at [decision], the question it shows asked
  /// again under new ids.
  void _renew(_Offer offer, String chatId, HermesPendingDecision decision) {
    // Said in the log as a warning (the daemon's log keeps no core info):
    // a replay that would have reset a card the user may be typing into.
    DebugLogger.warning(
      'hermes-decision-replayed',
      scope: 'daemon/hermes',
      data: <String, Object?>{'kind': decision.kind.name},
    );
    if (_offered[offer.key] == offer.requestId) _offered.remove(offer.key);
    offer.key = _key(chatId, decision);
    offer.decision = decision;
    offer.turn++;
    _offered[offer.key] = offer.requestId;
  }

  void _settle(_Offer offer, {required String choice}) {
    if (offer.done) return;
    _uiRequests?.settle(offer.requestId, choice: choice);
    _forget(offer);
  }

  void _forget(_Offer offer) {
    if (offer.done) return;
    offer.done = true;
    _offers.remove(offer.requestId);
    if (_offered[offer.key] == offer.requestId) _offered.remove(offer.key);
    if (offer.held) {
      offer.held = false;
      _release(offer.chatId);
    }
  }

  /// Everything a closing daemon still holds.
  void dispose() {
    for (final offer in _offers.values.toList()) {
      _forget(offer);
    }
    for (final watch in _watches.values.toList()) {
      _close(watch);
    }
  }

  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on RpcError {
      rethrow;
    } on Object catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: _short('$error'),
      );
    }
  }

  static String _short(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 199)}…';
}

final class _Watch {
  _Watch(this.chatId, this.container);

  final String chatId;
  final ProviderContainer container;

  /// The windows watching, each with the subagent whose output it reads.
  final Map<String, String?> windows = <String, String?>{};
  final List<ProviderSubscription<Object?>> subscriptions =
      <ProviderSubscription<Object?>>[];

  /// The subagent whose output is read, and its subscription.
  String? outputFor;
  ProviderSubscription<HermesSubagentTailView>? output;
  HermesWork? last;
  bool scheduled = false;
  bool closed = false;
}

final class _Offer {
  _Offer({
    required this.chatId,
    required this.requestId,
    required this.key,
    required this.decision,
    required this.container,
    required this.owner,
    required this.service,
  });

  final String chatId;
  final String requestId;

  /// The question it shows, as asked now ([HermesCardsService._renew]
  /// moves it to a replay's ids).
  String key;
  HermesPendingDecision decision;
  final ProviderContainer container;

  /// The conversation that asked, as the scope opened it.
  final String owner;

  /// The Hermes connection that asked: only it is answered, and only its
  /// replays renew the card.
  final HermesBackendService? service;

  /// Bumped by each replay ([HermesCardsService._renew]): an answer sent
  /// under an older one settles nothing.
  int turn = 0;
  bool answering = false;
  bool held = false;
  bool done = false;
}

import 'dart:async';

import 'package:conduit_core/ports/ui_request_port.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:uuid/uuid.dart';

import 'event_bus.dart';

/// The core asking a person something, answered from any window.
///
/// Implements the core's [UiRequestPort], so the streaming pipeline asks
/// the same way it does on mobile. The question goes out as a `ui.request`
/// event and the answer comes back through `ui.respond`.
///
/// One broker for the whole daemon, not one per window. A tool that wants
/// approval belongs to a turn, and a turn belongs to no particular window.
/// The request goes to every window, and the first answer counts. The
/// earlier per-session version waited on an answer from exactly one
/// window, which nothing ever called.
///
/// The conservative answer is the default everywhere a person does not
/// answer: no window open, the last window closed, a timeout. A tool never
/// runs, and a prompt never gets a value, by omission.
final class UiRequestsService implements UiRequestPort {
  UiRequestsService(this._events, {Duration? promptTimeout})
    : _promptTimeout = promptTimeout ?? const Duration(minutes: 5);

  final EventBus _events;

  /// How long a free-text prompt waits. Confirmations wait indefinitely: a
  /// tool approval left unanswered should stay unanswered, not quietly
  /// turn into a decision.
  final Duration _promptTimeout;

  static const Uuid _uuid = Uuid();

  final Map<String, ({UiRequest request, Completer<UiResponse> answer})>
  _pending = <String, ({UiRequest request, Completer<UiResponse> answer})>{};

  /// Requests a window answered (not settled with their default), until
  /// the one who asked reads the answer.
  final Set<String> _answeredByWindow = <String>{};

  /// Requests still waiting, for a window that connects after they were
  /// sent.
  List<UiRequest> get pending =>
      _pending.values.map((entry) => entry.request).toList(growable: false);

  /// Records an answer. False when nothing is waiting for it: it came late,
  /// or another window answered first.
  bool respond(UiResponse response) {
    final entry = _pending.remove(response.requestId);
    if (entry == null || entry.answer.isCompleted) return false;
    _answeredByWindow.add(response.requestId);
    entry.answer.complete(response);
    _publishSettled(response.requestId);
    return true;
  }

  /// Settles everything with its default once no window is left to ask.
  void onWindowsChanged() {
    if (_events.subscriberCount > 0) return;
    for (final id in _pending.keys.toList()) {
      final entry = _pending.remove(id)!;
      entry.answer.complete(
        UiResponse(requestId: id, choice: entry.request.defaultChoice),
      );
    }
  }

  @override
  Future<bool> confirm({
    required String title,
    String message = '',
    String? confirmLabel,
    String? cancelLabel,
  }) async {
    final response = await _ask(
      UiRequestKind.confirm,
      args: <String, String>{
        'title': title,
        'message': message,
        'confirmLabel': ?confirmLabel,
        'cancelLabel': ?cancelLabel,
      },
    );
    return response.choice == 'allow';
  }

  @override
  Future<String?> promptForText({
    required String title,
    String message = '',
    String? placeholder,
    String? initialValue,
    UiTextInputType inputType = UiTextInputType.text,
    List<UiSelectOption> options = const <UiSelectOption>[],
    String? confirmLabel,
    String? cancelLabel,
  }) async {
    final response = await _ask(
      UiRequestKind.inputPrompt,
      args: <String, String>{
        'title': title,
        'message': message,
        'placeholder': ?placeholder,
        'initialValue': ?initialValue,
        'confirmLabel': ?confirmLabel,
        'cancelLabel': ?cancelLabel,
      },
      defaultChoice: 'cancel',
      timeout: _promptTimeout,
      // Plain text is the default on the wire too, so it is left out.
      inputType: switch (inputType) {
        UiTextInputType.text => null,
        UiTextInputType.password => UiInputType.password,
        UiTextInputType.select => UiInputType.select,
      },
      options: inputType == UiTextInputType.select
          ? <UiInputOption>[
              for (final option in options)
                UiInputOption(value: option.value, label: option.label),
            ]
          : null,
    );
    if (response.choice != 'allow') return null;
    // The core's contract, and what mobile does: the value unchanged, and
    // nothing for an empty one. A passphrase can begin or end with a space.
    final text = response.text;
    if (text == null || text.isEmpty) return null;
    // Only a value that was offered: a stale card must not answer with
    // something the server never listed.
    if (inputType == UiTextInputType.select &&
        !options.any((option) => option.value == text)) {
      return null;
    }
    return text;
  }

  /// Asks whether an MCP tool may run, and how long the answer holds.
  ///
  /// The four answers mobile offers: `allow` (once), `allowSession`,
  /// `allowAlways`, or anything else, which denies. Unanswered for
  /// [timeout], it is denied, as the core's own approvals are.
  Future<String> askMcpApproval({
    required String serverName,
    required String toolName,
    required String argumentsJson,
    Duration? timeout,
  }) async {
    final response = await _ask(
      UiRequestKind.mcpApproval,
      messageCode: 'mcp.approval',
      args: <String, String>{'serverName': serverName, 'toolName': toolName},
      detail: <String, dynamic>{'arguments': argumentsJson},
      timeout: timeout,
    );
    return response.choice;
  }

  /// Asks whether an Open WebUI tool may run: a tool approval the server
  /// raised mid-turn. Unanswered, it is denied.
  Future<bool> askToolApproval({
    required String title,
    String message = '',
  }) async {
    final response = await _ask(
      UiRequestKind.toolApproval,
      args: <String, String>{'title': title, 'message': message},
    );
    return response.choice == 'allow';
  }

  /// Whether a window is there to answer: without one a question takes its
  /// default at once.
  bool get canAsk => _events.subscriberCount > 0;

  /// True once a window is there to answer, at once when one is; false
  /// when [until] completes first.
  Future<bool> windowBack(Future<void> until) async {
    if (canAsk) return true;
    return _events.attachBefore(until);
  }

  /// Asks whether a LibreChat run may go on with tool [toolName]: a run that
  /// paused for approval. Unanswered, it is rejected; [until] completing
  /// (the turn that asked ended) takes the card back. [answered] says
  /// whether a window answered, rather than the card being settled with
  /// its default (nobody there, every window gone, the turn over).
  Future<({bool allow, bool answered})> askLibreChatToolApproval({
    required String chatId,
    required String toolName,
    String? description,
    String? argumentsJson,
    Future<void>? until,
  }) async {
    final (:response, :answered) = await _askReadingWho(
      UiRequestKind.toolApproval,
      messageCode: 'librechat.toolApproval',
      args: <String, String>{
        'title': toolName,
        'message': description ?? '',
        'chatId': chatId,
      },
      detail: <String, dynamic>{
        'backend': 'libreChat',
        'arguments': ?argumentsJson,
      },
      defaultChoice: 'deny',
      until: until,
    );
    return (allow: response.choice == 'allow', answered: answered);
  }

  /// Puts a LibreChat agent's question to the user: its options, or words
  /// of their own. [text] is null when it was cancelled (or nobody could be
  /// asked); [until] completing (the turn that asked ended) takes the card
  /// back. [answered] says whether a window answered, rather than the card
  /// being settled with its default.
  Future<({String? text, bool answered})> askLibreChatQuestion({
    required String chatId,
    required String question,
    String? description,
    List<Map<String, String>> options = const <Map<String, String>>[],
    bool multiSelect = false,
    String? progress,
    Future<void>? until,
  }) async {
    final (:response, :answered) = await _askReadingWho(
      UiRequestKind.libreChatQuestion,
      messageCode: 'librechat.question',
      args: <String, String>{
        'title': question,
        'chatId': chatId,
        'progress': ?progress,
      },
      detail: <String, dynamic>{
        'question': question,
        'description': ?description,
        'options': options,
        'multiSelect': multiSelect,
      },
      defaultChoice: 'cancel',
      until: until,
    );
    // The window's question card answers `allow` with the text (the same
    // card as any server's question); `answer` is the plain word for it.
    final text = response.text?.trim();
    final given = response.choice == 'answer' || response.choice == 'allow';
    if (!given || text == null || text.isEmpty) {
      return (text: null, answered: answered);
    }
    return (text: text, answered: answered);
  }

  /// Asks whether an MCP App in a chat may call one of its server's tools,
  /// as mobile asks before every call. Unanswered, it is refused.
  Future<bool> askMcpAppToolCall({
    required String serverName,
    required String toolName,
    required String argumentsJson,
    Future<void>? until,
  }) async {
    final response = await _ask(
      UiRequestKind.mcpAppToolCall,
      messageCode: 'mcpApp.toolCall',
      args: <String, String>{'serverName': serverName, 'toolName': toolName},
      detail: <String, dynamic>{'arguments': argumentsJson},
      until: until,
    );
    return response.choice == 'allow';
  }

  /// Asks whether to open [url], a page an MCP App asked for: an app can
  /// ask at any time, not only when the user clicked something.
  /// [until] completing (the app closed) takes the question back: it is
  /// settled as refused and every window closes its card.
  Future<bool> askMcpAppOpenLink({
    required String url,
    Future<void>? until,
  }) async {
    final response = await _ask(
      UiRequestKind.mcpAppOpenLink,
      messageCode: 'mcpApp.openLink',
      args: <String, String>{'url': url},
      until: until,
    );
    return response.choice == 'allow';
  }

  /// Asks whether a Hermes agent may go on with what it wants to do:
  /// run a command, write a file. [choices] are the agent's own -- `once`,
  /// `session`, `always`, `deny` -- and unanswered it is denied. A paid
  /// tool's [cost] (`{price, approximate, note, spent, limit, server,
  /// overLimit}`) shows as chips on the card.
  Future<String> askHermesApproval({
    required String summary,
    required List<String> choices,
    Map<String, dynamic>? cost,
    Duration? timeout,
  }) async {
    final response = await _ask(
      UiRequestKind.hermesDecision,
      messageCode: 'hermes.approval',
      args: <String, String>{'summary': summary},
      detail: <String, dynamic>{'choices': choices, 'cost': ?cost},
      timeout: timeout,
    );
    return choices.contains(response.choice) ? response.choice : 'deny';
  }

  /// Asks whether to switch a Hermes chat to [model], a model Hermes holds
  /// for the user's confirmation, and send the waiting message: true to
  /// switch, false to keep the current model. Null when nobody answered
  /// (no window, or the prompt timed out): core then refuses the switch,
  /// as it does with no prompt bound. [reason] is Hermes' own, as it gave
  /// it; the window words the rest.
  Future<bool?> askHermesModelSwitch({
    required String model,
    String? reason,
  }) async {
    final response = await _ask(
      UiRequestKind.hermesModelSwitch,
      messageCode: 'hermes.modelSwitch',
      args: <String, String>{
        'model': model,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason,
      },
      defaultChoice: 'cancel',
      timeout: _promptTimeout,
    );
    return switch (response.choice) {
      'allow' => true,
      'deny' => false,
      _ => null,
    };
  }

  /// Asks the windows something whose answer arrives some other way (a
  /// Hermes question answered with `hermes.decisions.answer`): the request
  /// goes out like any other, and [settle] takes it away once answered.
  /// The future completes with the window's dismissal, the timeout's
  /// default, or [settle]'s choice.
  ({String requestId, Future<UiResponse> answer}) open(
    UiRequestKind kind, {
    required String messageCode,
    Map<String, String> args = const <String, String>{},
    Map<String, dynamic> detail = const <String, dynamic>{},
    Duration? timeout,
    String defaultChoice = 'deny',
    Future<void>? until,
  }) => _open(
    kind,
    args: args,
    messageCode: messageCode,
    detail: detail,
    defaultChoice: defaultChoice,
    timeout: timeout,
    until: until,
  );

  /// Settles [requestId] with [choice] and tells every window, as an answer
  /// through `ui.respond` would. False when nothing waits for it.
  bool settle(String requestId, {String choice = 'allow'}) =>
      respond(UiResponse(requestId: requestId, choice: choice));

  @override
  void notify(UiNoticeLevel level, String message) {
    _events.emit(
      ConduitEventSpecs.notifyShow,
      Notice(
        level: switch (level) {
          UiNoticeLevel.info => NoticeLevel.info,
          UiNoticeLevel.success => NoticeLevel.success,
          UiNoticeLevel.warning => NoticeLevel.warning,
          UiNoticeLevel.error => NoticeLevel.error,
        },
        message: message,
      ),
    );
  }

  Future<UiResponse> _ask(
    UiRequestKind kind, {
    required Map<String, String> args,
    // By default the server wrote this text, so it arrives as prose in
    // `messageArgs`. The code tells the renderer that is what it is
    // looking at.
    String messageCode = 'server.prompt',
    Map<String, dynamic> detail = const <String, dynamic>{},
    String defaultChoice = 'deny',
    Duration? timeout,
    UiInputType? inputType,
    List<UiInputOption>? options,
    Future<void>? until,
  }) => _open(
    kind,
    args: args,
    messageCode: messageCode,
    detail: detail,
    defaultChoice: defaultChoice,
    timeout: timeout,
    inputType: inputType,
    options: options,
    until: until,
  ).answer;

  /// [_ask], and whether a window answered rather than the default settling
  /// the question.
  Future<({UiResponse response, bool answered})> _askReadingWho(
    UiRequestKind kind, {
    required Map<String, String> args,
    required String messageCode,
    required Map<String, dynamic> detail,
    required String defaultChoice,
    Future<void>? until,
  }) async {
    final open = _open(
      kind,
      args: args,
      messageCode: messageCode,
      detail: detail,
      defaultChoice: defaultChoice,
      until: until,
    );
    final response = await open.answer;
    return (
      response: response,
      answered: _answeredByWindow.remove(open.requestId),
    );
  }

  /// [until]: what asked can stop (an MCP App, a turn); once it completes
  /// the question goes, answered with [defaultChoice].
  ({String requestId, Future<UiResponse> answer}) _open(
    UiRequestKind kind, {
    required Map<String, String> args,
    required String messageCode,
    required Map<String, dynamic> detail,
    required String defaultChoice,
    Duration? timeout,
    UiInputType? inputType,
    List<UiInputOption>? options,
    Future<void>? until,
  }) {
    final request = UiRequest(
      requestId: _uuid.v4(),
      kind: kind,
      messageCode: messageCode,
      messageArgs: args,
      detail: detail,
      timeoutMs: timeout?.inMilliseconds,
      defaultChoice: defaultChoice,
      inputType: inputType,
      options: options,
    );
    // Nobody to ask means the conservative answer, now. Waiting would hang
    // the turn on a question that cannot be seen.
    if (_events.subscriberCount == 0) {
      return (
        requestId: request.requestId,
        answer: Future<UiResponse>.value(
          UiResponse(requestId: request.requestId, choice: defaultChoice),
        ),
      );
    }

    final answer = Completer<UiResponse>();
    _pending[request.requestId] = (request: request, answer: answer);
    _events.emit(ConduitEventSpecs.uiRequest, request);
    // What asked is gone: the question goes with it, answered as refused.
    unawaited(
      until?.then((_) {
        if (_pending.remove(request.requestId) == null) return;
        _publishSettled(request.requestId);
        if (!answer.isCompleted) {
          answer.complete(
            UiResponse(requestId: request.requestId, choice: defaultChoice),
          );
        }
      }),
    );

    if (timeout == null) {
      return (requestId: request.requestId, answer: answer.future);
    }
    return (
      requestId: request.requestId,
      answer: answer.future.timeout(
        timeout,
        onTimeout: () {
          _pending.remove(request.requestId);
          _publishSettled(request.requestId);
          return UiResponse(
            requestId: request.requestId,
            choice: defaultChoice,
          );
        },
      ),
    );
  }

  /// Tells every window the question is settled, so the ones that did not
  /// answer close their card instead of offering a choice that no longer
  /// counts.
  void _publishSettled(String requestId) => _events.emit(
    ConduitEventSpecs.uiSettled,
    UiSettled(requestId: requestId),
  );
}

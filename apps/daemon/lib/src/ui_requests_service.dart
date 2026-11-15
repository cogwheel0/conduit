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

  /// Requests still waiting, for a window that connects after they were
  /// sent.
  List<UiRequest> get pending =>
      _pending.values.map((entry) => entry.request).toList(growable: false);

  /// Records an answer. False when nothing is waiting for it: it came late,
  /// or another window answered first.
  bool respond(UiResponse response) {
    final entry = _pending.remove(response.requestId);
    if (entry == null || entry.answer.isCompleted) return false;
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
  /// `session`, `always`, `deny` -- and unanswered it is denied.
  Future<String> askHermesApproval({
    required String summary,
    required List<String> choices,
    Duration? timeout,
  }) async {
    final response = await _ask(
      UiRequestKind.hermesDecision,
      messageCode: 'hermes.approval',
      args: <String, String>{'summary': summary},
      detail: <String, dynamic>{'choices': choices},
      timeout: timeout,
    );
    return choices.contains(response.choice) ? response.choice : 'deny';
  }

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
      return Future<UiResponse>.value(
        UiResponse(requestId: request.requestId, choice: defaultChoice),
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

    if (timeout == null) return answer.future;
    return answer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(request.requestId);
        _publishSettled(request.requestId);
        return UiResponse(requestId: request.requestId, choice: defaultChoice);
      },
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

import 'dart:async';

import 'package:conduit_core/ports/ui_request_port.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:uuid/uuid.dart';

import 'event_bus.dart';

/// The core asking a person something, answered from any window (WP-3.6).
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
    );
    if (response.choice != 'allow') return null;
    final text = response.text?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// Asks whether an MCP tool may run (M4), and how long the answer holds.
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

  @override
  void notify(UiNoticeLevel level, String message) {
    _events.publish(
      ConduitEvents.notifyShow,
      payload: <String, dynamic>{'level': level.name, 'message': message},
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
  }) {
    final request = UiRequest(
      requestId: _uuid.v4(),
      kind: kind,
      messageCode: messageCode,
      messageArgs: args,
      detail: detail,
      timeoutMs: timeout?.inMilliseconds,
      defaultChoice: defaultChoice,
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
    _events.publish(ConduitEvents.uiRequest, payload: request.toJson());

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
  void _publishSettled(String requestId) => _events.publish(
    ConduitEvents.uiSettled,
    payload: <String, dynamic>{'requestId': requestId},
  );
}

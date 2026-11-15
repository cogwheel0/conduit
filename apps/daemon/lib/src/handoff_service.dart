import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:uuid/uuid.dart';

import 'event_bus.dart';
import 'ports/handoff.dart';

/// A server's suggestion to carry on in a new chat with another model,
/// put to the windows.
///
/// The question goes out as `handoff.requested` to every window; the first
/// `handoff.answer` decides, and `handoff.settled` closes it everywhere
/// else. Unanswered for [timeout], or with no window left to ask, it is
/// declined: nothing opens by omission. The window that agreed is told to
/// open the new chat, with the model and the prompt, once the core lets it.
final class HandoffService implements HandoffBroker {
  HandoffService(
    this._events, {
    required bool Function(String chatId) claims,
    Duration? timeout,
  }) : _claims = claims,
       _timeout = timeout ?? const Duration(minutes: 2);

  final EventBus _events;
  final bool Function(String chatId) _claims;
  final Duration _timeout;

  static const Uuid _uuid = Uuid();

  final Map<String, _Ask> _asks = <String, _Ask>{};

  /// The question waiting for its open, once agreed to.
  _Ask? _agreed;

  /// Questions still waiting, for a window that connects after they went.
  List<HandoffRequest> get pending => <HandoffRequest>[
    for (final ask in _asks.values)
      if (!ask.answer.isCompleted) ask.request,
  ];

  @override
  bool claims(String chatId) => _claims(chatId);

  @override
  Future<bool> confirm({
    required String chatId,
    required String modelId,
    required String modelName,
    required String prompt,
  }) async {
    if (_events.subscriberCount == 0) return false;
    final ask = _Ask(
      HandoffRequest(
        requestId: _uuid.v4(),
        chatId: chatId,
        modelId: modelId,
        modelName: modelName,
        prompt: prompt,
      ),
    );
    _asks[ask.request.requestId] = ask;
    _events.emit(ConduitEventSpecs.handoffRequested, ask.request);
    final agreed = await ask.answer.future.timeout(
      _timeout,
      onTimeout: () => false,
    );
    _asks.remove(ask.request.requestId);
    if (!ask.settled) {
      ask.settled = true;
      _events.emit(
        ConduitEventSpecs.handoffSettled,
        HandoffSettled(requestId: ask.request.requestId),
      );
    }
    if (agreed) _agreed = ask;
    return agreed;
  }

  @override
  void opened(String modelId, String prompt) {
    final ask = _agreed;
    _agreed = null;
    if (ask == null || ask.opened.isCompleted) return;
    ask.opened.complete((modelId: modelId, prompt: prompt));
  }

  @override
  void ended() {
    final ask = _agreed;
    _agreed = null;
    if (ask != null && !ask.opened.isCompleted) ask.opened.complete(null);
  }

  /// Settles everything as declined once no window is left to ask.
  void onWindowsChanged() {
    if (_events.subscriberCount > 0) return;
    for (final ask in _asks.values.toList()) {
      if (!ask.answer.isCompleted) ask.answer.complete(false);
    }
  }

  /// The user's answer. Only the first counts; a window that answered later
  /// (or after the question ran out of time) is told not to open anything.
  Future<HandoffAnswered> answer(HandoffAnswer answer) async {
    final ask = _asks[answer.requestId];
    if (ask == null || ask.answer.isCompleted) {
      return const HandoffAnswered(open: false);
    }
    ask.settled = true;
    _events.emit(
      ConduitEventSpecs.handoffSettled,
      HandoffSettled(requestId: answer.requestId),
    );
    ask.answer.complete(answer.accept);
    if (!answer.accept) return const HandoffAnswered(open: false);
    // The core checks the chat is still the user's before it opens.
    final opened = await ask.opened.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
    if (opened == null) {
      // Never opened: the question is let go, so no later open is taken
      // for it.
      if (identical(_agreed, ask)) _agreed = null;
      return const HandoffAnswered(open: false);
    }
    return HandoffAnswered(
      open: true,
      modelId: opened.modelId,
      prompt: opened.prompt,
    );
  }
}

final class _Ask {
  _Ask(this.request);

  final HandoffRequest request;
  final Completer<bool> answer = Completer<bool>();
  final Completer<({String modelId, String prompt})?> opened =
      Completer<({String modelId, String prompt})?>();
  bool settled = false;
}

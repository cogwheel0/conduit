import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/openwebui_chat_prompt.dart';

@visibleForTesting
Duration? debugOpenWebUiPromptTimeoutOverride;

@immutable
class OpenWebUiLivePromptState {
  const OpenWebUiLivePromptState({
    required this.conversationId,
    required this.prompt,
  });

  final String conversationId;
  final OpenWebUiComposerPrompt prompt;
}

final openWebUiLivePromptProvider =
    NotifierProvider<OpenWebUiLivePromptNotifier, OpenWebUiLivePromptState?>(
      OpenWebUiLivePromptNotifier.new,
    );

class OpenWebUiLivePromptNotifier extends Notifier<OpenWebUiLivePromptState?> {
  Timer? _timeout;
  void Function(dynamic response)? _acknowledge;

  @override
  OpenWebUiLivePromptState? build() {
    ref.onDispose(() {
      _timeout?.cancel();
      _respondToAbandonedPrompt();
    });
    return null;
  }

  void handleSocketRequest({
    required String conversationId,
    required String type,
    required Map<String, dynamic> data,
    required void Function(dynamic response) acknowledge,
  }) {
    cancel();
    if (type == 'request:user_input') {
      final prompt = parseOpenWebUiAskUserPrompt(
        data,
        identity: 'live:${DateTime.now().microsecondsSinceEpoch}',
      );
      if (prompt == null) {
        _safeAcknowledge(acknowledge, const <String, dynamic>{
          'error': 'Invalid user input request.',
        });
        return;
      }
      _acknowledge = acknowledge;
      state = OpenWebUiLivePromptState(
        conversationId: conversationId,
        prompt: prompt,
      );
      _timeout = Timer(
        debugOpenWebUiPromptTimeoutOverride ?? prompt.timeout,
        cancel,
      );
      return;
    }

    if (type == 'confirmation') {
      final title = _bounded(data['title'], 120);
      final message = _bounded(data['message'], 2000);
      _acknowledge = acknowledge;
      state = OpenWebUiLivePromptState(
        conversationId: conversationId,
        prompt: OpenWebUiComposerPrompt(
          identity: 'live:${DateTime.now().microsecondsSinceEpoch}',
          kind: OpenWebUiComposerPromptKind.confirmation,
          title: title,
          message: message,
        ),
      );
      return;
    }

    _safeAcknowledge(acknowledge, const <String, dynamic>{
      'error': 'Unsupported input request.',
    });
  }

  void answer(String promptIdentity, Map<String, dynamic> answers) {
    final current = state;
    if (current == null || current.prompt.identity != promptIdentity) return;
    _settle(<String, dynamic>{'status': 'answered', 'answers': answers});
  }

  void decide(String promptIdentity, bool approved) {
    final current = state;
    if (current == null ||
        current.prompt.identity != promptIdentity ||
        current.prompt.kind != OpenWebUiComposerPromptKind.confirmation) {
      return;
    }
    _settle(approved);
  }

  void cancelForConversation(String? conversationId) {
    if (conversationId != null && state?.conversationId == conversationId) {
      cancel();
    }
  }

  void cancel() {
    if (state == null && _acknowledge == null) return;
    final kind = state?.prompt.kind;
    _settle(
      kind == OpenWebUiComposerPromptKind.confirmation
          ? false
          : const <String, dynamic>{'status': 'cancelled', 'answers': {}},
    );
  }

  void _settle(dynamic response) {
    final acknowledge = _acknowledge;
    _acknowledge = null;
    _timeout?.cancel();
    _timeout = null;
    state = null;
    if (acknowledge != null) _safeAcknowledge(acknowledge, response);
  }

  void _respondToAbandonedPrompt() {
    final acknowledge = _acknowledge;
    if (acknowledge == null) return;
    _acknowledge = null;
    final response =
        state?.prompt.kind == OpenWebUiComposerPromptKind.confirmation
        ? false
        : const <String, dynamic>{'status': 'cancelled', 'answers': {}};
    _safeAcknowledge(acknowledge, response);
  }

  void _safeAcknowledge(
    void Function(dynamic response) acknowledge,
    dynamic response,
  ) {
    try {
      acknowledge(response);
    } catch (_) {}
  }

  String _bounded(Object? value, int maxLength) {
    final text = value?.toString().trim() ?? '';
    return text.length <= maxLength ? text : text.substring(0, maxLength);
  }
}

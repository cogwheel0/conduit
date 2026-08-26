import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'chat_message.dart';

enum OpenWebUiComposerPromptKind { askUser, toolApproval, confirmation }

enum OpenWebUiToolCallAction { approve, reject, answer }

@immutable
class OpenWebUiPromptOption {
  const OpenWebUiPromptOption({required this.label, required this.description});

  final String label;
  final String description;
}

@immutable
class OpenWebUiPromptQuestion {
  const OpenWebUiPromptQuestion({
    required this.id,
    required this.header,
    required this.question,
    required this.options,
    required this.allowOther,
  });

  final String id;
  final String header;
  final String question;
  final List<OpenWebUiPromptOption> options;
  final bool allowOther;
}

@immutable
class OpenWebUiComposerPrompt {
  const OpenWebUiComposerPrompt({
    required this.identity,
    required this.kind,
    this.title = '',
    this.message = '',
    this.questions = const <OpenWebUiPromptQuestion>[],
    this.timeout = const Duration(minutes: 2),
  });

  final String identity;
  final OpenWebUiComposerPromptKind kind;
  final String title;
  final String message;
  final List<OpenWebUiPromptQuestion> questions;
  final Duration timeout;
}

@immutable
class OpenWebUiPendingToolPrompt {
  const OpenWebUiPendingToolPrompt({
    required this.messageId,
    required this.callId,
    required this.toolName,
    required this.prompt,
  });

  final String messageId;
  final String callId;
  final String toolName;
  final OpenWebUiComposerPrompt prompt;
}

String _boundedString(Object? value, int maxLength) {
  final normalized = value?.toString().trim() ?? '';
  if (normalized.length <= maxLength) return normalized;
  var end = maxLength;
  final last = normalized.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return normalized.substring(0, end);
}

Map<String, dynamic>? _stringMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return null;
}

Map<String, dynamic>? _decodeArguments(Object? value) {
  Object? current = value;
  for (var attempt = 0; attempt < 3 && current is String; attempt++) {
    try {
      current = jsonDecode(current);
    } catch (_) {
      return null;
    }
  }
  return _stringMap(current);
}

OpenWebUiComposerPrompt? parseOpenWebUiAskUserPrompt(
  Object? value, {
  required String identity,
}) {
  final data = _stringMap(value);
  final rawQuestions = data?['questions'];
  if (data == null || rawQuestions is! List || rawQuestions.length > 3) {
    return null;
  }
  if (rawQuestions.isEmpty) return null;

  final defaultAllowOther = data['allow_other'] is bool
      ? data['allow_other'] as bool
      : true;
  final seenIds = <String>{};
  final questions = <OpenWebUiPromptQuestion>[];
  for (var index = 0; index < rawQuestions.length; index++) {
    final rawQuestion = _stringMap(rawQuestions[index]);
    final rawOptions = rawQuestion?['options'];
    if (rawQuestion == null ||
        rawOptions is! List ||
        rawOptions.length < 2 ||
        rawOptions.length > 3) {
      return null;
    }

    final id = _boundedString(rawQuestion['id'], 64);
    final question = _boundedString(rawQuestion['question'], 500);
    if (id.isEmpty || question.isEmpty || !seenIds.add(id)) return null;

    final options = <OpenWebUiPromptOption>[];
    for (final rawOption in rawOptions) {
      final option = _stringMap(rawOption);
      final label = _boundedString(option?['label'], 80);
      final description = _boundedString(option?['description'], 240);
      if (option == null || label.isEmpty || description.isEmpty) return null;
      options.add(
        OpenWebUiPromptOption(label: label, description: description),
      );
    }

    questions.add(
      OpenWebUiPromptQuestion(
        id: id,
        header: _boundedString(rawQuestion['header'], 48).isEmpty
            ? 'Question ${index + 1}'
            : _boundedString(rawQuestion['header'], 48),
        question: question,
        options: List<OpenWebUiPromptOption>.unmodifiable(options),
        allowOther: rawQuestion['allow_other'] is bool
            ? rawQuestion['allow_other'] as bool
            : defaultAllowOther,
      ),
    );
  }

  final rawTimeout = data['timeout_ms'];
  final timeoutMs =
      rawTimeout is int && rawTimeout >= 60000 && rawTimeout <= 240000
      ? rawTimeout
      : 120000;
  return OpenWebUiComposerPrompt(
    identity: identity,
    kind: OpenWebUiComposerPromptKind.askUser,
    questions: List<OpenWebUiPromptQuestion>.unmodifiable(questions),
    timeout: Duration(milliseconds: timeoutMs),
  );
}

OpenWebUiPendingToolPrompt? findPendingOpenWebUiToolPrompt(
  List<ChatMessage> messages,
) {
  for (final message in messages.reversed) {
    if (message.role != 'assistant' || message.output == null) continue;
    final resultCallIds = <String>{
      for (final item in message.output!)
        if (item['type']?.toString() == 'function_call_output' &&
            (item['call_id']?.toString().isNotEmpty ?? false))
          item['call_id'].toString(),
    };
    for (final item in message.output!) {
      if (item['type']?.toString() != 'function_call') continue;
      final callId =
          item['call_id']?.toString().trim() ??
          item['id']?.toString().trim() ??
          '';
      final status = item['status']?.toString();
      if (callId.isEmpty ||
          resultCallIds.contains(callId) ||
          (status != 'pending' &&
              status != 'queued' &&
              status != 'requires_approval') ||
          (status == 'queued' && item['approved'] == true)) {
        continue;
      }

      final name = _boundedString(item['name'], 80);
      if (name == 'ask_user') {
        final arguments = _decodeArguments(item['arguments']);
        final prompt = parseOpenWebUiAskUserPrompt(
          arguments,
          identity: 'saved:${message.id}:$callId',
        );
        if (prompt == null) continue;
        return OpenWebUiPendingToolPrompt(
          messageId: message.id,
          callId: callId,
          toolName: name,
          prompt: prompt,
        );
      }

      final arguments = formatOpenWebUiToolArguments(item['arguments']);
      return OpenWebUiPendingToolPrompt(
        messageId: message.id,
        callId: callId,
        toolName: name.isEmpty ? 'Tool' : name,
        prompt: OpenWebUiComposerPrompt(
          identity: 'saved:${message.id}:$callId',
          kind: OpenWebUiComposerPromptKind.toolApproval,
          title: name.isEmpty ? 'Tool' : name,
          message: arguments,
        ),
      );
    }
  }
  return null;
}

String formatOpenWebUiToolArguments(Object? value) {
  Object? normalized = value;
  if (value is String) {
    try {
      normalized = jsonDecode(value);
    } catch (_) {}
  }
  String text;
  try {
    text = normalized is Map || normalized is List
        ? const JsonEncoder.withIndent('  ').convert(normalized)
        : normalized?.toString() ?? '';
  } catch (_) {
    text = normalized.toString();
  }
  return _boundedString(text, 2000);
}

List<Map<String, dynamic>> applyOpenWebUiToolCallResolution({
  required List<Map<String, dynamic>> output,
  required String callId,
  required String action,
  Map<String, dynamic>? answers,
}) {
  final next = output
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: true);
  final callIndex = next.indexWhere(
    (item) =>
        item['type']?.toString() == 'function_call' &&
        (item['call_id']?.toString() ?? item['id']?.toString()) == callId,
  );
  if (callIndex == -1) return output;

  final call = next[callIndex];
  switch (action) {
    case 'approve':
      call['status'] = 'queued';
      call['approved'] = true;
      break;
    case 'reject':
      call['status'] = 'rejected';
      next.add({
        'type': 'function_call_output',
        'id': 'fco_$callId',
        'call_id': callId,
        'output': const [
          {'type': 'input_text', 'text': 'Error: tool call rejected by user.'},
        ],
        'status': 'rejected',
      });
      break;
    case 'answer':
      call['status'] = 'completed';
      next.add({
        'type': 'function_call_output',
        'id': 'fco_$callId',
        'call_id': callId,
        'output': [
          {
            'type': 'input_text',
            'text': jsonEncode({
              'status': 'answered',
              'answers': answers ?? const <String, dynamic>{},
            }),
          },
        ],
        'status': 'completed',
      });
      break;
  }
  return List<Map<String, dynamic>>.unmodifiable(next);
}

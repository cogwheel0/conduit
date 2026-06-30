/// Typed representation of Open WebUI structured `output` items.
///
/// These blocks keep protocol parsing separate from UI string rendering. Raw
/// `output` maps can still be stored on messages for round-trip compatibility.
sealed class StructuredOutputBlock {
  const StructuredOutputBlock();
}

final class StructuredOutputTextBlock extends StructuredOutputBlock {
  const StructuredOutputTextBlock({required this.text});

  final String text;
}

final class StructuredOutputReasoningBlock extends StructuredOutputBlock {
  const StructuredOutputReasoningBlock({
    required this.text,
    required this.done,
    this.duration,
  });

  final String text;
  final bool done;
  final String? duration;
}

final class StructuredOutputToolCallBlock extends StructuredOutputBlock {
  const StructuredOutputToolCallBlock({
    required this.id,
    required this.name,
    required this.arguments,
    required this.done,
    this.result,
    this.files,
    this.embeds,
  });

  final String id;
  final String name;
  final Object? arguments;
  final bool done;
  final Object? result;
  final Object? files;
  final Object? embeds;
}

final class StructuredOutputCodeInterpreterBlock extends StructuredOutputBlock {
  const StructuredOutputCodeInterpreterBlock({
    required this.code,
    required this.language,
    required this.done,
    this.duration,
    this.output,
  });

  final String code;
  final String language;
  final bool done;
  final String? duration;
  final Object? output;
}

List<StructuredOutputBlock> parseOpenWebUIStructuredOutput(
  List<dynamic> output,
) {
  if (output.isEmpty) return const [];

  final toolOutputs = <String, Map<String, dynamic>>{};
  for (final item in output) {
    if (item is Map &&
        (item['type']?.toString() == 'function_call_output' ||
            item['type']?.toString() == 'custom_tool_call_output')) {
      final callId = item['call_id']?.toString() ?? item['id']?.toString();
      if (callId != null && callId.isNotEmpty) {
        toolOutputs[callId] = _coerceJsonMap(item);
      }
    }
  }

  final blocks = <StructuredOutputBlock>[];
  for (var index = 0; index < output.length; index++) {
    final rawItem = output[index];
    if (rawItem is! Map) continue;

    final item = _coerceJsonMap(rawItem);
    final itemType = item['type']?.toString() ?? '';
    switch (itemType) {
      case 'message':
        final text = _messageTextFromOutputItem(item);
        if (text.trim().isNotEmpty) {
          blocks.add(StructuredOutputTextBlock(text: text));
        }
      case 'reasoning':
        final text = _reasoningTextFromOutputItem(item);
        if (text.trim().isNotEmpty) {
          blocks.add(
            StructuredOutputReasoningBlock(
              text: text,
              done: _isReasoningDone(item, index, output.length),
              duration: item['duration']?.toString(),
            ),
          );
        }
      case 'function_call':
      case 'custom_tool_call':
        final callId =
            item['call_id']?.toString() ?? item['id']?.toString() ?? '';
        final resultItem = toolOutputs[callId];
        blocks.add(
          StructuredOutputToolCallBlock(
            id: callId,
            name:
                item['name']?.toString() ??
                (itemType == 'custom_tool_call' ? 'Custom Tool' : ''),
            arguments: item['arguments'] ?? item['input'] ?? '',
            done:
                resultItem != null ||
                _isDoneStatus(item['status'], includeCompleted: false),
            result: resultItem?['output'] ?? resultItem?['content'],
            files: resultItem?['files'],
            embeds: resultItem?['embeds'],
          ),
        );
      case 'function_call_output':
      case 'custom_tool_call_output':
        continue;
      case 'web_search_call':
      case 'file_search_call':
      case 'computer_call':
        blocks.add(
          StructuredOutputToolCallBlock(
            id: item['id']?.toString() ?? '',
            name: _openAiToolName(itemType),
            arguments: '',
            done: _isOpenAiToolDone(item, index, output.length),
            result: _openAiToolSummary(item),
          ),
        );
      case 'code_interpreter':
      case 'open_webui:code_interpreter':
        blocks.add(
          StructuredOutputCodeInterpreterBlock(
            code: item['code']?.toString() ?? '',
            language: (item['language'] ?? item['lang'])?.toString() ?? '',
            done: _isCodeInterpreterDone(item, index, output.length),
            duration: item['duration']?.toString(),
            output: item['output'],
          ),
        );
    }
  }

  return List<StructuredOutputBlock>.unmodifiable(blocks);
}

Map<String, dynamic> _coerceJsonMap(Map<dynamic, dynamic> value) {
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String _messageTextFromOutputItem(Map<String, dynamic> item) {
  final content = item['content'];
  if (content is String) {
    return content;
  }
  if (content is! List) {
    return '';
  }

  final messageParts = <String>[];
  for (final part in content) {
    if (part is! Map) continue;
    final partType = part['type']?.toString();
    if (part.containsKey('text') &&
        (partType == null || partType == 'text' || partType == 'output_text')) {
      final text = part['text']?.toString() ?? '';
      if (text.isNotEmpty) {
        messageParts.add(text);
      }
    }
  }
  return messageParts.join('\n');
}

String _reasoningTextFromOutputItem(Map<String, dynamic> item) {
  final summary = item['summary'];
  final content = item['content'];
  final summaryText = summary is List ? _textFromOutputParts(summary) : '';
  if (summaryText.trim().isNotEmpty) {
    return summaryText;
  }
  if (content is String) {
    return content;
  }
  return content is List ? _textFromOutputParts(content) : '';
}

String _textFromOutputParts(List<dynamic> sourceList) {
  final reasoningParts = <String>[];
  for (final part in sourceList) {
    if (part is! Map) continue;
    final text = part['text']?.toString();
    if (text != null && text.isNotEmpty) {
      reasoningParts.add(text);
    }
  }
  return reasoningParts.join('\n');
}

bool _isReasoningDone(Map<String, dynamic> item, int index, int outputLength) {
  final status = item['status']?.toString();
  final hasDuration = item['duration'] != null;
  final isLastItem = index == outputLength - 1;
  return _isDoneStatus(status) ||
      hasDuration ||
      (status == null && !isLastItem);
}

bool _isCodeInterpreterDone(
  Map<String, dynamic> item,
  int index,
  int outputLength,
) {
  final status = item['status']?.toString();
  final hasDuration = item['duration'] != null;
  final isLastItem = index == outputLength - 1;
  return _isDoneStatus(status) || hasDuration || !isLastItem;
}

bool _isDoneStatus(Object? status, {bool includeCompleted = true}) {
  final normalized = status?.toString();
  return includeCompleted && normalized == 'completed';
}

String _openAiToolName(String itemType) {
  return switch (itemType) {
    'web_search_call' => 'Web Search',
    'file_search_call' => 'File Search',
    'computer_call' => 'Computer Use',
    _ => itemType,
  };
}

bool _isOpenAiToolDone(Map<String, dynamic> item, int index, int outputLength) {
  final status = item['status']?.toString();
  return _isDoneStatus(status) || index != outputLength - 1;
}

String _openAiToolSummary(Map<String, dynamic> item) {
  final itemType = item['type']?.toString();
  final action = item['action'];
  if (itemType == 'web_search_call' && action is Map) {
    final actionType = action['type']?.toString();
    if (actionType == 'search') {
      final queries = _stringList(action['queries']);
      final query = action['query']?.toString() ?? '';
      return queries.isNotEmpty
          ? 'Search: ${queries.join(', ')}'
          : query.isNotEmpty
          ? 'Search: $query'
          : '';
    }
    if (actionType == 'open_page') {
      final url = action['url']?.toString() ?? '';
      return url.isEmpty ? '' : 'Open page: $url';
    }
    if (actionType == 'find_in_page') {
      final pattern = action['pattern']?.toString() ?? '';
      return pattern.isEmpty ? '' : 'Find in page: $pattern';
    }
  }

  if (itemType == 'file_search_call') {
    final queries = _stringList(item['queries']);
    return queries.isEmpty ? '' : 'Queries: ${queries.join(', ')}';
  }

  if (itemType == 'computer_call') {
    if (action is Map && action['type'] != null) {
      return 'Action: ${action['type']}';
    }
    final actions = item['actions'];
    if (actions is List && actions.isNotEmpty) {
      final actionTypes = actions
          .map((action) {
            if (action is Map && action['type'] != null) {
              return action['type'].toString();
            }
            return '?';
          })
          .toList(growable: false);
      return 'Actions: ${actionTypes.join(', ')}';
    }
  }

  return '';
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item != null && item.toString().isNotEmpty) item.toString(),
  ];
}

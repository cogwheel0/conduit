part of 'hermes_desktop_api_service.dart';

List<String> _desktopDecisionChoices(Object? value) {
  if (value is! Iterable) return const <String>[];
  return [
    for (final item in value.take(8))
      ?validateHermesBoundedString(item, maxCharacters: 80),
  ];
}

bool _projectHermesTurnEvent(
  HermesDesktopEvent event, {
  required void Function(HermesRunEvent) add,
  required String Function(String key) value,
  required String Function(Iterable<String> keys) firstValue,
}) {
  switch (event.type) {
    case 'message.delta':
      final delta = value('delta').isNotEmpty ? value('delta') : value('text');
      if (delta.isNotEmpty) add(HermesTokenDelta(delta));
    case 'message.interim':
      if (event.payload['already_streamed'] != true) {
        final text = value('text');
        if (text.isNotEmpty) add(HermesTokenDelta(text));
      }
    case 'thinking.delta':
      break;
    case 'reasoning.delta':
      final delta = value('delta').isNotEmpty ? value('delta') : value('text');
      if (delta.isNotEmpty) add(HermesReasoningDelta(delta));
    case 'tool.start':
    case 'tool.generating':
      add(
        HermesToolProgress(
          toolName: value('name').isEmpty ? 'tool' : value('name'),
          detail: value('detail'),
          arguments: firstValue(const ['args_text', 'args', 'arguments']),
          done: false,
        ),
      );
    case 'tool.progress':
      add(
        HermesToolProgress(
          toolName: value('name').isEmpty ? 'tool' : value('name'),
          detail: value('detail').isEmpty ? value('message') : value('detail'),
          done: false,
        ),
      );
    case 'tool.complete':
      add(
        HermesToolProgress(
          toolName: value('name').isEmpty ? 'tool' : value('name'),
          detail: value('error'),
          result: firstValue(const ['result_text', 'result']),
          inlineDiff: value('inline_diff'),
          done: true,
          failed: value('error').isNotEmpty,
        ),
      );
    case 'subagent.spawn_requested':
    case 'subagent.start':
    case 'subagent.thinking':
    case 'subagent.tool':
    case 'subagent.progress':
    case 'subagent.complete':
      final done = event.type == 'subagent.complete';
      final name = firstValue(const ['name', 'subagent_id']);
      add(
        HermesToolProgress(
          toolName: name.isEmpty ? 'subagent' : 'subagent: $name',
          detail: firstValue(const [
            'message',
            'preview',
            'summary',
            'text',
            'goal',
            'tool_preview',
            'tool_name',
            'result',
            'error',
          ]),
          result: done ? firstValue(const ['result', 'summary', 'text']) : null,
          subagent: true,
          done: done,
          failed: done && value('error').isNotEmpty,
        ),
      );
    case 'review.summary':
      add(
        HermesToolProgress(
          toolName: 'review',
          detail: value('text').isEmpty ? value('summary') : value('text'),
          done: true,
          failed: false,
        ),
      );
    default:
      return false;
  }
  return true;
}

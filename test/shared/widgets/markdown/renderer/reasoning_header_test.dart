import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/renderer/details_block_widget.dart';
import 'package:flutter_test/flutter_test.dart';

CompiledMarkdownDetailsData _reasoning({
  required bool isDone,
  required int duration,
  required bool hasDuration,
  String summary = '',
}) => CompiledMarkdownDetailsData(
  summaryText: summary,
  bodyMarkdown: 'why',
  bodyStartIndex: 0,
  hasBody: true,
  kind: CompiledMarkdownDetailsKind.reasoning,
  type: 'reasoning',
  name: '',
  isDone: isDone,
  isPending: !isDone,
  durationSeconds: duration,
  hasDuration: hasDuration,
);

void main() {
  group('resolveReasoningHeader mirrors upstream Collapsible', () {
    test('pending block reads thinking', () {
      check(
        resolveReasoningHeader(
          _reasoning(isDone: false, duration: 0, hasDuration: false),
        ),
      ).isA<ReasoningHeaderThinking>();
    });

    test('done block without a duration reads thoughts, never a fake time', () {
      check(
        resolveReasoningHeader(
          _reasoning(
            isDone: true,
            duration: 0,
            hasDuration: false,
            summary: 'Thinking…',
          ),
        ),
      ).isA<ReasoningHeaderThoughts>();
    });

    test('done block with duration zero reads less than a second', () {
      check(
            resolveReasoningHeader(
              _reasoning(isDone: true, duration: 0, hasDuration: true),
            ),
          )
          .isA<ReasoningHeaderThoughtFor>()
          .has((h) => h.seconds, 'seconds')
          .equals(0);
    });

    test('done block with a real duration reports it', () {
      check(
            resolveReasoningHeader(
              _reasoning(isDone: true, duration: 7, hasDuration: true),
            ),
          )
          .isA<ReasoningHeaderThoughtFor>()
          .has((h) => h.seconds, 'seconds')
          .equals(7);
    });

    test('legacy summary text carrying a duration is honored', () {
      check(
            resolveReasoningHeader(
              _reasoning(
                isDone: true,
                duration: 4,
                hasDuration: false,
                summary: 'Thought for 4 seconds',
              ),
            ),
          )
          .isA<ReasoningHeaderThoughtFor>()
          .has((h) => h.seconds, 'seconds')
          .equals(4);
    });

    test('custom summaries win once done', () {
      check(
            resolveReasoningHeader(
              _reasoning(
                isDone: true,
                duration: 0,
                hasDuration: false,
                summary: 'Planning the route',
              ),
            ),
          )
          .isA<ReasoningHeaderSummary>()
          .has((h) => h.summary, 'summary')
          .equals('Planning the route');
    });
  });
}

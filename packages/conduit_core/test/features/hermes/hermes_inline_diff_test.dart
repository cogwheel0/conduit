import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_inline_diff.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

String _ansi(String code, String text) => '\u001b[${code}m$text\u001b[0m';

/// `tool.complete.inline_diff` as Hermes v0.23.0 renders it
/// (`agent/display.py`): a review header, coloured `a/x → b/x` file
/// headers, hunks, and coloured lines.
final _twoFiles = [
  '  ┊ review diff',
  _ansi('38;2;218;165;32', 'a/src/tide.py → b/src/tide.py'),
  _ansi('38;2;139;134;130', '@@ -3,4 +3,5 @@ def low_tide(hours):'),
  _ansi('38;2;184;134;11', '     start = hours[0]'),
  _ansi('38;2;255;255;255;48;2;119;20;20', '-    return start'),
  _ansi('38;2;255;255;255;48;2;19;87;20', '+    end = hours[-1]'),
  _ansi('38;2;255;255;255;48;2;19;87;20', '+    return (start, end)'),
  _ansi('38;2;184;134;11', '     # done'),
  _ansi('38;2;218;165;32', 'a/docs/notes.md → b/docs/notes.md'),
  _ansi('38;2;139;134;130', '@@ -1,2 +1,2 @@'),
  _ansi('38;2;255;255;255;48;2;119;20;20', '-Low tide at four.'),
  _ansi('38;2;255;255;255;48;2;19;87;20', '+Low tide at five.'),
  _ansi('38;2;184;134;11', ' Bring boots.'),
].join('\n');

ChatStatusUpdate _tool(String diff) => ChatStatusUpdate(
  action: 'hermes_tool_patch',
  done: true,
  items: [hermesInlineDiffItem(sanitizeHermesInlineDiff(diff)!)],
);

void main() {
  group('inline diffs', () {
    test('read files, counts, colours and line numbers', () {
      final diff = parseHermesInlineDiff(_twoFiles)!;

      check(diff.files.map((f) => f.path))
          .deepEquals(['src/tide.py', 'docs/notes.md']);
      check(diff.added).equals(3);
      check(diff.removed).equals(2);
      final tide = diff.files.first;
      check(tide.name).equals('tide.py');
      check(tide.added).equals(2);
      check(tide.removed).equals(1);
      check(
        tide.lines.map((l) => '${l.kind.name} ${l.oldNumber} ${l.newNumber}'),
      ).deepEquals([
        'hunk null null',
        'context 3 3',
        'removed 4 null',
        'added null 4',
        'added null 5',
        'context 5 6',
      ]);
      check(tide.lines[3].text).equals('    end = hours[-1]');
      check(diff.notes).isEmpty();
      check(diff.truncated).isFalse();
    });

    test('keep what Hermes says it left out', () {
      final text = [
        _ansi('38;2;218;165;32', 'a/big.txt → b/big.txt'),
        '@@ -1,100 +1,100 @@',
        for (var i = 0; i < 3; i++) ...['-old $i', '+new $i'],
        _ansi(
          '38;2;139;134;130',
          '… omitted 42 diff line(s) across 1 additional '
              'file(s)/section(s)',
        ),
      ].join('\n');

      final diff = parseHermesInlineDiff(text)!;
      check(diff.files.single.added).equals(3);
      check(diff.notes.single).startsWith('… omitted 42');
      check(diff.files.single.lines.last.kind)
          .equals(HermesDiffLineKind.note);
    });

    test('read plain unified diffs and deletions', () {
      final diff = parseHermesInlineDiff(
        [
          '--- a/old.txt',
          '+++ /dev/null',
          '@@ -1 +0,0 @@',
          '-gone',
          r'\ No newline at end of file',
        ].join('\n'),
      )!;

      check(diff.files.single.path).equals('old.txt');
      check(diff.files.single.removed).equals(1);
      check(diff.files.single.lines.last.kind)
          .equals(HermesDiffLineKind.note);
    });

    test('a diff without file headers is one unnamed file', () {
      final diff = parseHermesInlineDiff('-a\n+b\n c')!;

      check(diff.files.single.path).isEmpty();
      check(diff.files.single.lines.map((l) => l.oldNumber))
          .deepEquals([null, null, null]);
    });

    test('text without changes is no diff', () {
      check(parseHermesInlineDiff('  ┊ review diff\nnothing')).isNull();
      check(parseHermesInlineDiff('')).isNull();
    });

    test('stop at their bounds however much arrives', () {
      final huge = [
        for (var file = 0; file < 200; file++) ...[
          'a/f$file.txt → b/f$file.txt',
          for (var line = 0; line < 50; line++) '+line $line',
        ],
      ].join('\n');

      final diff = parseHermesInlineDiff(huge)!;
      check(diff.truncated).isTrue();
      check(diff.files.length).isLessOrEqual(kMaxHermesInlineDiffFiles + 1);
      check(
        diff.files.fold(0, (sum, f) => sum + f.lines.length),
      ).isLessOrEqual(kMaxHermesInlineDiffLines);
    });
  });

  group('kept diffs', () {
    test('lose colours and secrets but keep their lines', () {
      final safe = sanitizeHermesInlineDiff(
        '${_ansi('31', '-token = synthetic-secret-42')}\r\n+token = env\u0007',
        sensitiveValues: const ['synthetic-secret-42'],
      )!;

      check(safe).equals('-token = [REDACTED]\n+token = env');
    });

    test('are bounded', () {
      final safe = sanitizeHermesInlineDiff('+${'x' * 100000}')!;
      check(safe.runes.length).isLessOrEqual(
        kMaxHermesInlineDiffCharacters + 1,
      );
    });

    test('rows stored before the marker are still diffs', () {
      const old = ChatStatusItem(
        title: kHermesInlineDiffTitle,
        snippet: '�[32m+x�[0m',
        presentation: ChatStatusItemPresentation.detail,
      );
      check(isHermesInlineDiffItem(old)).isTrue();
      check(parseHermesInlineDiff(old.snippet!)!.files.single.lines.single.text)
          .equals('x');
      check(
        isHermesInlineDiffItem(
          const ChatStatusItem(title: 'Result', snippet: '+x'),
        ),
      ).isFalse();
    });
  });

  group('changed files of a reply', () {
    test('merge every edit of a file in first-changed order', () {
      final files = hermesChangedFiles([
        _tool(_twoFiles),
        const ChatStatusUpdate(action: 'hermes_tool_terminal', done: true),
        _tool('a/src/tide.py → b/src/tide.py\n@@ -9 +9 @@\n-a\n+b'),
      ]);

      check(files.map((f) => f.path))
          .deepEquals(['src/tide.py', 'docs/notes.md']);
      check(files.first.added).equals(3);
      check(files.first.removed).equals(2);
      // A blank note marks where the second edit begins.
      check(
        files.first.lines.where(
          (l) => l.kind == HermesDiffLineKind.note && l.text.isEmpty,
        ),
      ).length.equals(1);
    });

    test('come from a live tool completion', () {
      final message = applyHermesRunEventForTest(
        ChatMessage(
          id: 'a',
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2030),
        ),
        HermesToolProgress(
          toolName: 'patch',
          done: true,
          inlineDiff: _twoFiles,
        ),
        runId: 'runtime-1',
      );

      final item = message.statusHistory.single.items.singleWhere(
        isHermesInlineDiffItem,
      );
      check(item.metadata?[kHermesInlineDiffMetadataKey]).equals(true);
      check(item.snippet!).contains('\n');
      check(item.snippet!).not((it) => it.contains('\u001b'));
      check(hermesChangedFiles(message.statusHistory)).length.equals(2);
    });

    List<String> storedPaths(Map<String, dynamic> toolRow) {
      final messages = hermesMessagesToChatMessages([
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-1',
              'type': 'function',
              'function': {'name': 'patch', 'arguments': '{}'},
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call-1',
          'content': '{"success": true}',
          ...toolRow,
        },
        {'role': 'assistant', 'content': 'Done.'},
      ], modelId: 'hermes');
      return [
        for (final file in hermesChangedFiles(
          messages.expand((m) => m.statusHistory),
        ))
          file.path,
      ];
    }

    test('come from a stored transcript', () {
      // Hermes 0.23 keeps it with the row's display metadata, as JSON.
      check(
        storedPaths({
          'display_metadata': jsonEncode({
            'tool_result_metadata': {'inline_diff': _twoFiles},
          }),
        }),
      ).deepEquals(['src/tide.py', 'docs/notes.md']);
      check(
        storedPaths({
          'display_metadata': {
            'tool_result_metadata': {'inline_diff': _twoFiles},
          },
        }),
      ).deepEquals(['src/tide.py', 'docs/notes.md']);
      // Earlier rows carried it at the top level.
      check(storedPaths({'inline_diff': _twoFiles}))
          .deepEquals(['src/tide.py', 'docs/notes.md']);
      check(storedPaths({'display_metadata': '{not json'})).isEmpty();
    });
  });
}

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/notes/views/note_editor_page.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/markdown_preprocessor.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('issue 577 - clipboard content', () {
    test('removes tool-call details but preserves the response markdown', () {
      const input = '''Before

<details type="tool_calls" done="true">
<summary>Tool call</summary>
<div>private tool payload</div>
</details>

**After**''';

      check(
        ConduitMarkdownPreprocessor.sanitizeForClipboard(input),
      ).equals('Before\n\n**After**');
    });

    test('preserves ordinary details and literal tool-call examples', () {
      const input = '''<details><summary>Keep me</summary>Body</details>

`<details type="tool_calls">example</details>`

```
<details type="tool_calls">example</details>
```''';

      check(
        ConduitMarkdownPreprocessor.sanitizeForClipboard(input),
      ).equals(input);
    });

    test('removes tool-call details that contain code spans', () {
      const input = '''Before

<details type="tool_calls" done="true">
<summary>Tool call</summary>
`private inline payload`

```
private fenced payload
```
</details>

After''';

      check(
        ConduitMarkdownPreprocessor.sanitizeForClipboard(input),
      ).equals('Before\n\nAfter');
    });
  });

  group('issue 576 - queued title generation', () {
    ChatMessage message(String id, String role) => ChatMessage(
      id: id,
      role: role,
      content: role,
      timestamp: DateTime(2026),
    );

    test('enables first-turn title and tag tasks', () {
      final messages = [message('user-1', 'user'), message('a-1', 'assistant')];
      final shouldGenerate = shouldGenerateQueuedTitleForTest(
        messages,
        assistantMessageId: 'a-1',
        isTemporary: false,
      );

      check(shouldGenerate).isTrue();
      final backgroundTasks = buildOpenWebUiBackgroundTasksForTest(
        userSettings: null,
        shouldGenerateTitle: shouldGenerate,
      );
      check(backgroundTasks['title_generation']).equals(true);
      check(backgroundTasks['tags_generation']).equals(true);
    });

    test('does not regenerate titles for later turns or temporary chats', () {
      final laterTurn = [
        message('user-1', 'user'),
        message('a-1', 'assistant'),
        message('user-2', 'user'),
        message('a-2', 'assistant'),
      ];

      check(
        shouldGenerateQueuedTitleForTest(
          laterTurn,
          assistantMessageId: 'a-2',
          isTemporary: false,
        ),
      ).isFalse();
      check(
        shouldGenerateQueuedTitleForTest(
          [message('user-1', 'user'), message('a-1', 'assistant')],
          assistantMessageId: 'a-1',
          isTemporary: true,
        ),
      ).isFalse();
    });

    test('anchors first-turn eligibility to the queued assistant', () {
      final queuedTurns = [
        message('user-1', 'user'),
        message('a-1', 'assistant'),
        message('user-2', 'user'),
        message('a-2', 'assistant'),
      ];

      check(
        shouldGenerateQueuedTitleForTest(
          queuedTurns,
          assistantMessageId: 'a-1',
          isTemporary: false,
        ),
      ).isTrue();
    });
  });

  group('issue 511 - rich note colors', () {
    for (final brightness in Brightness.values) {
      testWidgets('uses readable block colors in ${brightness.name} mode', (
        tester,
      ) async {
        FleatherThemeData? fleatherTheme;
        ConduitThemeExtension? conduitTheme;
        final appTheme = brightness == Brightness.dark
            ? AppTheme.dark(TweakcnThemes.conduit)
            : AppTheme.light(TweakcnThemes.conduit);

        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            home: Builder(
              builder: (context) {
                conduitTheme = context.conduitTheme;
                fleatherTheme = buildNoteEditorFleatherTheme(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        final editor = fleatherTheme!;
        final colors = conduitTheme!;
        check(editor.paragraph.style.color).equals(colors.textPrimary);
        check(editor.heading1.style.color).equals(colors.textPrimary);
        check(editor.heading2.style.color).equals(colors.textPrimary);
        check(editor.heading3.style.color).equals(colors.textPrimary);
        check(editor.heading4.style.color).equals(colors.textPrimary);
        check(editor.heading5.style.color).equals(colors.textPrimary);
        check(editor.heading6.style.color).equals(colors.textPrimary);
        check(editor.lists.style.color).equals(colors.textPrimary);
        check(editor.lists.style.fontFamily).equals(AppTypography.fontFamily);
        check(editor.code.style.color).equals(colors.codeText);
        check(editor.code.decoration?.color).equals(colors.codeBackground);
        check(editor.inlineCode.style.color).equals(colors.codeText);
        check(editor.inlineCode.backgroundColor).equals(colors.codeBackground);
      });
    }
  });
}

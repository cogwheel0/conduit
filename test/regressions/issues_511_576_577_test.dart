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

      expect(
        ConduitMarkdownPreprocessor.sanitizeForClipboard(input),
        'Before\n\n**After**',
      );
    });

    test('preserves ordinary details and literal tool-call examples', () {
      const input = '''<details><summary>Keep me</summary>Body</details>

`<details type="tool_calls">example</details>`

```
<details type="tool_calls">example</details>
```''';

      expect(ConduitMarkdownPreprocessor.sanitizeForClipboard(input), input);
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

      expect(shouldGenerate, isTrue);
      expect(
        buildOpenWebUiBackgroundTasksForTest(
          userSettings: null,
          shouldGenerateTitle: shouldGenerate,
        ),
        containsPair('title_generation', true),
      );
      expect(
        buildOpenWebUiBackgroundTasksForTest(
          userSettings: null,
          shouldGenerateTitle: shouldGenerate,
        ),
        containsPair('tags_generation', true),
      );
    });

    test('does not regenerate titles for later turns or temporary chats', () {
      final laterTurn = [
        message('user-1', 'user'),
        message('a-1', 'assistant'),
        message('user-2', 'user'),
        message('a-2', 'assistant'),
      ];

      expect(
        shouldGenerateQueuedTitleForTest(
          laterTurn,
          assistantMessageId: 'a-2',
          isTemporary: false,
        ),
        isFalse,
      );
      expect(
        shouldGenerateQueuedTitleForTest(
          [message('user-1', 'user'), message('a-1', 'assistant')],
          assistantMessageId: 'a-1',
          isTemporary: true,
        ),
        isFalse,
      );
    });

    test('anchors first-turn eligibility to the queued assistant', () {
      final queuedTurns = [
        message('user-1', 'user'),
        message('a-1', 'assistant'),
        message('user-2', 'user'),
        message('a-2', 'assistant'),
      ];

      expect(
        shouldGenerateQueuedTitleForTest(
          queuedTurns,
          assistantMessageId: 'a-1',
          isTemporary: false,
        ),
        isTrue,
      );
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
        expect(editor.paragraph.style.color, colors.textPrimary);
        expect(editor.heading1.style.color, colors.textPrimary);
        expect(editor.heading2.style.color, colors.textPrimary);
        expect(editor.heading3.style.color, colors.textPrimary);
        expect(editor.heading4.style.color, colors.textPrimary);
        expect(editor.heading5.style.color, colors.textPrimary);
        expect(editor.heading6.style.color, colors.textPrimary);
        expect(editor.lists.style.color, colors.textPrimary);
        expect(editor.lists.style.fontFamily, AppTypography.fontFamily);
        expect(editor.code.style.color, colors.codeText);
        expect(editor.code.decoration?.color, colors.codeBackground);
        expect(editor.inlineCode.style.color, colors.codeText);
        expect(editor.inlineCode.backgroundColor, colors.codeBackground);
      });
    }
  });
}

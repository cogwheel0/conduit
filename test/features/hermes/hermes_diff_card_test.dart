import 'package:conduit/features/chat/widgets/streaming_status_widget.dart';
import 'package:conduit/features/hermes/widgets/hermes_diff_card.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/hermes/models/hermes_inline_diff.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _diff = '''  ┊ review diff
a/src/tide.py → b/src/tide.py
@@ -3,4 +3,5 @@ def low_tide(hours):
     start = hours[0]
-    return start
+    end = hours[-1]
+    return (start, end)
     # done
a/docs/notes.md → b/docs/notes.md
@@ -1,2 +1,2 @@
-Low tide at four.
+Low tide at five.
 Bring boots.''';

ChatStatusUpdate _patch(String diff) => ChatStatusUpdate(
  action: 'hermes_tool_patch',
  description: 'patch',
  done: true,
  items: [hermesInlineDiffItem(diff)],
);

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: conduitLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: AppTheme.light(TweakcnThemes.t3Chat),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('lists the changed files with their line counts', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(HermesChangedFilesCard(statuses: [_patch(_diff)])),
    );

    expect(find.text('2 files changed'), findsOneWidget);
    expect(find.text('+3'), findsOneWidget);
    expect(find.text('−2'), findsOneWidget);
    expect(find.text('tide.py'), findsOneWidget);
    expect(find.text('src/'), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);
    expect(
      find.bySemanticsLabel('tide.py, Lines added: 2, removed: 1'),
      findsOneWidget,
    );
  });

  testWidgets('shows nothing for a reply without diffs', (tester) async {
    await tester.pumpWidget(
      _app(
        const HermesChangedFilesCard(
          statuses: [ChatStatusUpdate(action: 'hermes_tool_terminal')],
        ),
      ),
    );

    expect(find.byKey(const ValueKey('hermes-changed-files')), findsNothing);
  });

  testWidgets('opens a file as coloured, numbered lines', (tester) async {
    await tester.pumpWidget(
      _app(HermesChangedFilesCard(statuses: [_patch(_diff)])),
    );

    await tester.tap(find.byKey(const ValueKey('hermes-changed-file-0')));
    await tester.pumpAndSettle();

    expect(find.text('src/tide.py'), findsOneWidget);
    expect(find.text('    end = hours[-1]'), findsOneWidget);
    // Added lines are numbered by the new file, removed ones by the old.
    expect(find.text('4'), findsNWidgets(2));
    expect(find.text('6'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('hermes-diff-file-1')));
    await tester.pumpAndSettle();
    expect(find.text('docs/notes.md'), findsOneWidget);
    expect(find.text('Low tide at five.'), findsOneWidget);
    expect(find.text('    end = hours[-1]'), findsNothing);
  });

  testWidgets('sums up files past the first six', (tester) async {
    final many = [
      for (var i = 0; i < 8; i++) 'a/f$i.txt → b/f$i.txt\n+line',
    ].join('\n');
    await tester.pumpWidget(
      _app(HermesChangedFilesCard(statuses: [_patch(many)])),
    );

    expect(find.text('8 files changed'), findsOneWidget);
    expect(find.text('2 more files'), findsOneWidget);
    expect(find.text('f6.txt'), findsNothing);
  });

  testWidgets('the tool timeline no longer prints the raw diff', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        StreamingStatusWidget(
          updates: [
            ChatStatusUpdate(
              action: 'hermes_tool_patch',
              description: 'patch',
              done: true,
              items: [
                const ChatStatusItem(
                  title: 'Result',
                  snippet: 'patched',
                  presentation: ChatStatusItemPresentation.detail,
                ),
                hermesInlineDiffItem(_diff),
              ],
            ),
          ],
          isStreaming: false,
        ),
      ),
    );
    await tester.tap(find.textContaining('patch').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('Result: patched'), findsOneWidget);
    expect(find.textContaining('Inline diff'), findsNothing);
  });
}

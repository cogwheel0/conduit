import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/chat/widgets/streaming_status_widget.dart';
import 'package:conduit/features/hermes/widgets/hermes_diff_card.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/hermes/models/hermes_inline_diff.dart';
import 'package:conduit_core/features/hermes/providers/hermes_working_directory_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

class _InactiveTts extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

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

  // Absolute paths repeated the project's folder on every row, and the
  // folders nearest the file were cut off.
  testWidgets('lists files from the working directory, in full on open', (
    tester,
  ) async {
    const root = '/home/dev/projects/sample-app';
    const file = '$root/lib/src/widgets/card.dart';
    // Hermes writes a path outside its own folder in full: `a//home/…`.
    const diff = 'a/$file → b/$file\n@@ -1 +1 @@\n-old\n+new';
    await tester.pumpWidget(
      _app(
        HermesChangedFilesCard(
          statuses: [_patch(diff)],
          workingDirectory: root,
        ),
      ),
    );

    expect(find.text('card.dart'), findsOneWidget);
    expect(find.text('lib/src/widgets/'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('hermes-changed-file-0')));
    await tester.pumpAndSettle();
    expect(find.text('$root/lib/src/widgets/card.dart'), findsOneWidget);
  });

  testWidgets('a reply lists its files from the open chat\'s directory', (
    tester,
  ) async {
    const root = '/home/dev/projects/sample-app';
    const file = '$root/lib/main.dart';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          textToSpeechControllerProvider.overrideWith(_InactiveTts.new),
          streamingHapticsEnabledProvider.overrideWithValue(false),
          hermesReplyWorkingDirectoryProvider.overrideWith(
            (ref, session) => session == 'session-1' ? root : null,
          ),
        ],
        child: _app(
          AssistantMessageWidget(
            message: ChatMessage(
              id: 'reply-1',
              role: 'assistant',
              content: 'Done.',
              timestamp: DateTime.utc(2030),
              isStreaming: false,
              metadata: const {
                'responseDone': true,
                'hermesSessionId': 'session-1',
              },
              statusHistory: [_patch('a/$file → b/$file\n+x')],
            ),
            isStreaming: false,
            showFollowUps: false,
            animateOnMount: false,
            onCopy: () {},
            onRegenerate: () {},
            onDelete: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('lib/'), findsOneWidget);
  });

  testWidgets('cuts a long folder in the middle, keeping its end', (
    tester,
  ) async {
    // Narrow enough that the folder is longer than the row in the test font
    // and in Roboto, which an earlier test in the same run may have loaded.
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const folder = '/home/dev/projects/sample-app/packages/client/lib/src/'
        'features/settings/sections/appearance/widgets/';
    await tester.pumpWidget(
      _app(
        HermesChangedFilesCard(
          statuses: [
            _patch('a/${folder}card.dart → b/${folder}card.dart\n+x'),
          ],
        ),
      ),
    );

    expect(find.text('card.dart'), findsOneWidget);
    final shown = tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('hermes-changed-file-0')),
            matching: find.textContaining('…'),
          ),
        )
        .data!;
    expect(shown, startsWith('/home'));
    expect(shown, endsWith('widgets/'));
    expect(shown.length, lessThan(folder.length));
  });

  // The name was held to 60% of the row even with no folder beside it,
  // and a long one lost its end, extension included.
  testWidgets('gives a name the row it needs, keeping its extension', (
    tester,
  ) async {
    const alone = 'a_settings_section_widget_for_tides.dart';
    final long = '${'appearance_' * 8}card.dart';
    await tester.pumpWidget(
      _app(
        HermesChangedFilesCard(
          statuses: [
            _patch('a/$alone → b/$alone\n+x'),
            _patch('a/lib/$long → b/lib/$long\n+x'),
          ],
        ),
      ),
    );

    expect(find.text(alone), findsOneWidget);
    final cut = tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('hermes-changed-file-1')),
            matching: find.textContaining('…'),
          ),
        )
        .data!;
    expect(cut, startsWith('appearance_'));
    expect(cut, endsWith('.dart'));
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

import 'package:conduit/features/chat/widgets/hermes_inline_activity.dart';
import 'package:conduit/features/chat/widgets/streaming_status_widget.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

ChatStatusUpdate operation(
  String name, {
  bool done = true,
  String args = '{}',
  String result = 'ok',
  bool failed = false,
}) => ChatStatusUpdate(
  action: 'hermes_tool_$name',
  description: name,
  done: done,
  items: [
    ChatStatusItem(
      title: 'Arguments',
      snippet: args,
      presentation: ChatStatusItemPresentation.detail,
    ),
    if (done)
      ChatStatusItem(
        title: failed ? 'Error' : 'Result',
        snippet: result,
        presentation: ChatStatusItemPresentation.detail,
      ),
  ],
);

Widget harness(
  List<ChatStatusUpdate> updates, {
  bool streaming = false,
  bool reduce = true,
  bool dark = false,
  double scale = 1,
  String stateId = 'conversation:turn',
  PageStorageBucket? bucket,
  bool show = true,
}) => MaterialApp(
  theme: dark
      ? AppTheme.dark(TweakcnThemes.conduit)
      : AppTheme.light(TweakcnThemes.conduit),
  localizationsDelegates: conduitLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: reduce, textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: PageStorage(
          bucket: bucket ?? PageStorageBucket(),
          child: show
              ? StreamingStatusWidget(
                  updates: updates,
                  isStreaming: streaming,
                  inlineHermesActivity: true,
                  stateId: stateId,
                )
              : const SizedBox.shrink(),
        ),
      ),
    ),
  ),
);

void main() {
  const groupKey = ValueKey('hermes-tool-group-toggle');
  testWidgets(
    'real status entry opens inline, bounds command and copies sanitized payload with icon only',
    (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            clipboard = (call.arguments as Map)['text'] as String;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final updates = [
        operation(
          'terminal',
          args: '{"command":"echo safe"}',
          result: 'safe output',
        ),
      ];
      await tester.pumpWidget(harness(updates));
      expect(find.text('safe output'), findsNothing);
      await tester.tap(find.byKey(groupKey));
      await tester.pumpAndSettle();
      expect(
        tester
            .getTopLeft(
              find.byKey(
                const ValueKey<Object>((
                  'hermes-tool-entry',
                  (0, 'hermes_tool_terminal'),
                )),
              ),
            )
            .dx,
        closeTo(tester.getTopLeft(find.byKey(groupKey)).dx, .1),
      );
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('Ran command'));
      await tester.pumpAndSettle();
      expect(find.text('echo safe'), findsOneWidget);
      expect(find.text('safe output'), findsOneWidget);
      expect(find.byIcon(Icons.content_copy), findsNothing);
      await tester.tap(find.text('Tool payload'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.content_copy), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
      final button = find.byType(IconButton);
      expect(tester.getSize(button), const Size(48, 48));
      final copy = tester.getRect(button);
      final payload = find.byKey(
        const ValueKey<Object>((
          'hermes-tool-payload',
          (0, 'hermes_tool_terminal'),
        )),
      );
      final box = tester.getRect(payload);
      expect(copy.right, closeTo(box.right, .1));
      expect(copy.top, closeTo(box.top, .1));
      await tester.tap(button);
      await tester.pump();
      expect(
        clipboard,
        'Arguments:\n{"command":"echo safe"}\n\nResult:\nsafe output',
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pending to complete keeps entry, payload, group and reasoning expanded',
    (tester) async {
      final pending = [
        const ChatStatusUpdate(
          action: 'reasoning',
          description: 'Thinking… Check the request.',
          done: false,
        ),
        operation('terminal', done: false, args: '{"command":"echo safe"}'),
      ];
      await tester.pumpWidget(harness(pending, streaming: true));
      await tester.tap(find.byKey(groupKey));
      await tester.pump();
      await tester.tap(find.text('Running command'));
      await tester.pump();
      await tester.tap(find.text('Tool payload'));
      await tester.pump();
      final entry = find.byKey(
        const ValueKey<Object>((
          'hermes-tool-entry',
          (1, 'hermes_tool_terminal'),
        )),
      );
      final element = tester.element(entry);
      await tester.pumpWidget(
        harness([
          pending.first,
          operation(
            'terminal',
            args: '{"command":"echo safe"}',
            result: 'safe output',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(tester.element(entry), same(element));
      expect(find.text('safe output'), findsOneWidget);
      expect(find.textContaining('Arguments:\n'), findsOneWidget);
      expect(find.byType(HermesBreatheIndicator), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reasoning is only supplied text and remains inline after settling',
    (tester) async {
      const updates = [
        ChatStatusUpdate(
          action: 'reasoning',
          description: 'Thinking… A supplied summary.',
          done: false,
        ),
      ];
      await tester.pumpWidget(harness(updates, streaming: true));
      expect(find.text('A supplied summary.'), findsOneWidget);
      await tester.pumpWidget(harness(updates));
      await tester.pumpAndSettle();
      expect(find.text('A supplied summary.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hermes-thinking-toggle')));
      await tester.pump();
      expect(find.text('A supplied summary.'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'repeated same named tools retain separate expansion identities',
    (tester) async {
      final updates = [
        operation('terminal', args: '{"command":"first"}'),
        operation('terminal', args: '{"command":"second"}'),
      ];
      await tester.pumpWidget(harness(updates));
      await tester.tap(find.byKey(groupKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ran command').first);
      await tester.pump();
      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsNothing);
      await tester.tap(find.text('Ran command').last);
      await tester.pump();
      expect(find.text('second'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'entry state survives eviction but never carries into another turn',
    (tester) async {
      final bucket = PageStorageBucket();
      final updates = [operation('terminal', args: '{"command":"safe"}')];
      await tester.pumpWidget(harness(updates, bucket: bucket));
      await tester.tap(find.byKey(groupKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ran command'));
      await tester.pump();
      await tester.pumpWidget(harness(updates, bucket: bucket, show: false));
      await tester.pumpWidget(harness(updates, bucket: bucket));
      await tester.pumpAndSettle();
      expect(find.text('safe'), findsOneWidget);
      await tester.pumpWidget(
        harness(updates, bucket: bucket, stateId: 'different-turn'),
      );
      await tester.pumpAndSettle();
      expect(find.text('safe'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failure and interruption never present an operation as successful',
    (tester) async {
      await tester.pumpWidget(
        harness([operation('terminal', failed: true, result: 'Scoped error')]),
      );
      await tester.tap(find.byKey(groupKey));
      await tester.pumpAndSettle();
      expect(find.text('Run command · Failed'), findsOneWidget);
      await tester.tap(find.text('Run command · Failed'));
      await tester.pump();
      expect(find.text('Scoped error'), findsOneWidget);
      await tester.pumpWidget(
        harness([operation('terminal', done: false)], stateId: 'interrupted'),
      );
      await tester.tap(find.byKey(groupKey));
      await tester.pumpAndSettle();
      expect(find.text('Run command · Unfinished'), findsOneWidget);
      expect(find.byType(HermesBreatheIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('reduced motion has no continuous animation callbacks', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness([operation('terminal', done: false)], streaming: true),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.tap(find.byKey(groupKey));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'normal-motion group handles rapid reversal without layout mutations',
    (tester) async {
      final updates = [operation('terminal')];
      await tester.pumpWidget(harness(updates, reduce: false));
      await tester.tap(find.byKey(groupKey));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(groupKey));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.byKey(groupKey));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Ran command'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'new reasoning after a finished tool is distinguished by receipt time',
    () {
      final before = DateTime(2026, 10, 17, 12);
      final after = before.add(const Duration(seconds: 3));
      final finished = operation('terminal').copyWith(occurredAt: after);
      final thought = ChatStatusUpdate(
        action: 'reasoning',
        description: 'Thinking… supplied',
        done: false,
        occurredAt: before,
      );
      expect(
        hasPendingHermesActivity([thought, finished], hasReplyText: false),
        isFalse,
      );
      expect(
        hasPendingHermesActivity([
          thought.copyWith(occurredAt: after.add(const Duration(seconds: 1))),
          finished,
        ], hasReplyText: false),
        isTrue,
      );
      expect(hasPendingHermesActivity([thought], hasReplyText: true), isFalse);
    },
  );

  testWidgets(
    'malformed and hidden status details stay bounded and safely inspectable',
    (tester) async {
      await tester.pumpWidget(
        harness([
          operation('custom_task', args: '{"command":', result: 'plain result'),
          operation(
            'terminal',
            args: '{"command":"hidden"}',
          ).copyWith(hidden: true),
        ]),
      );
      await tester.tap(find.byKey(groupKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('custom task'));
      await tester.pump();
      await tester.tap(find.text('Tool payload'));
      await tester.pump();
      expect(find.textContaining('Arguments:\n{"command":'), findsOneWidget);
      expect(find.text('hidden'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final dark in [false, true]) {
    testWidgets('compact activity fits 320dp and 200% text: dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        harness(
          [
            operation('skill_view', args: '{"name":"academic-research"}'),
            operation(
              'terminal',
              args: '{"command":"A very long command that should not overflow the available width and should stay bounded"}',
            ),
          ],
          dark: dark,
          scale: 2,
        ),
      );
      await tester.tap(find.byKey(groupKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ran command'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Tool payload'));
      await tester.tap(find.text('Tool payload'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

import 'package:conduit/features/librechat/widgets/librechat_prompt_overlay.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show kLibreChatPendingActionKey;
import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

typedef _Resolved = ({
  Map<String, LibreChatToolDecisionInput>? decisions,
  Map<String, String>? answers,
});

const _approval = LibreChatPendingAction({
  'actionId': 'act-1',
  'conversationId': 'c1',
  'payload': {
    'type': 'tool_approval',
    'action_requests': [
      {
        'tool_call_id': 'call-a',
        'name': 'echo',
        'arguments': {'text': 'hi'},
      },
      {'tool_call_id': 'call-b', 'name': 'delete_file'},
    ],
  },
});

const _questions = LibreChatPendingAction({
  'actionId': 'act-2',
  'payload': {
    'type': 'ask_user_question',
    'questions': [
      {'id': 'q1', 'question': 'Which city?'},
      {
        'id': 'q2',
        'question': 'Which days?',
        'multiSelect': true,
        'options': [
          {'label': 'Mon', 'value': 'monday'},
          'Tue',
        ],
      },
    ],
  },
});

Future<List<_Resolved>> _pump(
  WidgetTester tester,
  LibreChatPendingAction action, {
  Object? failWith,
}) async {
  final resolved = <_Resolved>[];
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: LibreChatComposerPromptOverlay(
            action: action,
            onResolve: ({decisions, answers}) async {
              resolved.add((decisions: decisions, answers: answers));
              if (failWith != null) throw failWith;
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return resolved;
}

void main() {
  test('the pending reply is found by its paused action', () {
    final paused = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kLibreChatTransport,
        kLibreChatPendingActionKey: _approval.raw,
      },
    );
    final other = ChatMessage(
      id: 'a2',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {kLibreChatPendingActionKey: _approval.raw},
    );
    expect(findPendingLibreChatComposerPrompt([paused, other]), paused);
    expect(findPendingLibreChatComposerPrompt([other]), isNull);
  });

  testWidgets('each tool call is decided, then all are sent together', (
    tester,
  ) async {
    final resolved = await _pump(tester, _approval);

    expect(find.textContaining('Allow echo to run?'), findsOneWidget);
    expect(find.textContaining('"text": "hi"'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(resolved, isEmpty);

    expect(find.textContaining('Allow delete_file to run?'), findsOneWidget);
    await tester.tap(find.text('Deny'));
    await tester.pumpAndSettle();

    final decisions = resolved.single.decisions!;
    expect(decisions.keys, ['call-a', 'call-b']);
    expect(decisions['call-a']!.decision, LibreChatToolDecision.approve);
    expect(decisions['call-b']!.decision, LibreChatToolDecision.reject);
    expect(resolved.single.answers, isNull);
  });

  testWidgets('a call that may only be answered offers just Respond, and '
      'sends the text', (tester) async {
    final resolved = await _pump(
      tester,
      const LibreChatPendingAction({
        'actionId': 'act-4',
        'payload': {
          'type': 'tool_approval',
          'action_requests': [
            {'tool_call_id': 'call-r', 'name': 'lookup'},
          ],
          'review_configs': [
            {
              'tool_call_id': 'call-r',
              'allowed_decisions': ['respond'],
            },
          ],
        },
      }),
    );

    expect(find.text('Approve'), findsNothing);
    expect(find.text('Deny'), findsNothing);
    await tester.tap(find.text('Respond'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Sample result  ');
    await tester.pump();
    await tester.tap(find.text('Send Response'));
    await tester.pumpAndSettle();

    final decision = resolved.single.decisions!['call-r']!;
    expect(decision.decision, LibreChatToolDecision.respond);
    expect(decision.responseText, 'Sample result');
  });

  testWidgets('an edit runs the call with the arguments typed, once they '
      'are a JSON object', (tester) async {
    final resolved = await _pump(
      tester,
      const LibreChatPendingAction({
        'actionId': 'act-5',
        'payload': {
          'type': 'tool_approval',
          'action_requests': [
            {
              'tool_call_id': 'call-e',
              'name': 'echo',
              'arguments': '{"text":"hi"}',
            },
          ],
          'review_configs': [
            {
              'tool_call_id': 'call-e',
              'allowed_decisions': ['approve', 'reject', 'edit'],
            },
          ],
        },
      }),
    );

    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    expect(find.text('Respond'), findsNothing);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '{\n  "text": "hi"\n}',
    );

    await tester.enterText(find.byType(TextField), '["not", "an object"]');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(resolved, isEmpty);
    expect(find.text('Enter a valid JSON object.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '{"text": "bye"}');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    final decision = resolved.single.decisions!['call-e']!;
    expect(decision.decision, LibreChatToolDecision.edit);
    expect(decision.editedArguments, {'text': 'bye'});
  });

  testWidgets('a batch of questions is answered in turn', (tester) async {
    final resolved = await _pump(tester, _questions);

    expect(find.text('Question 1 of 2'), findsOneWidget);
    expect(find.text('Which city?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Paris');
    await tester.tap(find.text('Send Response'));
    await tester.pumpAndSettle();
    expect(resolved, isEmpty);

    expect(find.text('Question 2 of 2'), findsOneWidget);
    await tester.tap(find.text('Mon'));
    await tester.tap(find.text('Tue'));
    await tester.pump();
    await tester.tap(find.text('Send Response'));
    await tester.pumpAndSettle();

    // Each choice is answered with its value, as LibreChat's client does.
    expect(resolved.single.answers, {'q1': 'Paris', 'q2': 'monday, Tue'});
    expect(resolved.single.decisions, isNull);
  });

  testWidgets('a long question scrolls within half the screen', (
    tester,
  ) async {
    final long = LibreChatPendingAction({
      'actionId': 'act-3',
      'payload': {
        'type': 'ask_user_question',
        'question': {
          'question': 'Which file?',
          'description': List.filled(200, 'A line of context.').join('\n'),
        },
        'tool_call_id': 'call_q',
      },
    });
    await _pump(tester, long);

    expect(tester.takeException(), isNull);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final card = tester.getSize(
      find
          .descendant(
            of: find.byType(LibreChatComposerPromptOverlay),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
    );
    expect(card.height, lessThanOrEqualTo(screen.height / 2));
    expect(find.text('Send Response'), findsOneWidget);
  });

  testWidgets('a failed answer can be sent again', (tester) async {
    final resolved = await _pump(
      tester,
      const LibreChatPendingAction({
        'actionId': 'act-3',
        'payload': {
          'type': 'ask_user_question',
          'tool_call_id': 'call-q',
          'question': {'question': 'Proceed?'},
        },
      }),
      failWith: StateError('offline'),
    );

    // A single question is its own title.
    expect(find.text('Proceed?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'yes');
    await tester.tap(find.text('Send Response'));
    await tester.pumpAndSettle();

    expect(resolved.single.answers, {'call-q': 'yes'});
    expect(
      find.text("Couldn't send your answer. Try again."),
      findsOneWidget,
    );
    expect(find.text('Send Response'), findsOneWidget);

    // Sent again, the answer goes out again.
    await tester.enterText(find.byType(TextField), 'yes');
    await tester.tap(find.text('Send Response'));
    await tester.pumpAndSettle();
    expect(resolved, hasLength(2));
    expect(resolved.last.answers, {'call-q': 'yes'});
  });
}

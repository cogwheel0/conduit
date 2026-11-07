import 'package:conduit/features/hermes/widgets/hermes_todo_card.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/hermes/models/hermes_todo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

HermesTodoState _plan(List<String> statuses, {int revision = 1}) =>
    HermesTodoState.fromPayload({
      'revision': revision,
      'todos': [
        for (final (index, status) in statuses.indexed)
          {'id': 't$index', 'content': 'Step $index', 'status': status},
      ],
    })!;

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light(TweakcnThemes.t3Chat),
  localizationsDelegates: conduitLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: child)),
);

void main() {
  testWidgets('shows the plan open while work remains, and folds it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        HermesTodoCard(
          plan: _plan(['completed', 'in_progress', 'pending']),
          chatKey: 'chat-open',
        ),
      ),
    );

    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('1 of 3 done'), findsOneWidget);
    expect(find.text('Step 0'), findsOneWidget);
    expect(find.text('Step 2'), findsOneWidget);
    final done = tester.widget<Text>(find.text('Step 0'));
    expect(done.style?.decoration, TextDecoration.lineThrough);

    await tester.tap(find.byKey(const ValueKey('hermes-todo-toggle')));
    await tester.pump();
    // Folded: one line naming the step under way.
    expect(find.text('Step 1'), findsOneWidget);
    expect(find.text('Step 0'), findsNothing);
    expect(find.text('Step 2'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('^Show plan')), findsOneWidget);
  });

  testWidgets('a finished plan starts folded; the choice is per chat', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        HermesTodoCard(
          plan: _plan(['completed', 'cancelled']),
          chatKey: 'chat-done',
        ),
      ),
    );
    expect(find.text('1 of 2 done'), findsOneWidget);
    expect(find.text('Step 0'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('hermes-todo-toggle')));
    await tester.pump();
    expect(find.text('Step 1'), findsOneWidget);

    // The same chat reopened keeps it open; another chat does not.
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pumpWidget(
      _app(
        HermesTodoCard(
          plan: _plan(['completed', 'cancelled'], revision: 2),
          chatKey: 'chat-done',
        ),
      ),
    );
    expect(find.text('Step 1'), findsOneWidget);
    await tester.pumpWidget(
      _app(
        HermesTodoCard(
          plan: _plan(['completed', 'cancelled']),
          chatKey: 'chat-other',
        ),
      ),
    );
    expect(find.text('Step 1'), findsNothing);
  });

  testWidgets('sits above a prompt card and leaves it alone otherwise', (
    tester,
  ) async {
    const prompt = Text('Approval card');
    for (final none in [
      null,
      HermesTodoState.fromPayload({'todos': [], 'revision': 2}),
    ]) {
      await tester.pumpWidget(
        _app(withHermesPlan(prompt, plan: none, chatKey: 'c')!),
      );
      expect(find.text('Approval card'), findsOneWidget);
      expect(find.byKey(const ValueKey('hermes-todo-card')), findsNothing);
    }
    expect(withHermesPlan(null, plan: null, chatKey: 'c'), isNull);

    await tester.pumpWidget(
      _app(
        withHermesPlan(
          prompt,
          plan: _plan(['in_progress']),
          chatKey: 'chat-prompt',
        )!,
      ),
    );
    expect(find.text('Approval card'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('hermes-todo-card'))).dy,
      lessThan(tester.getTopLeft(find.text('Approval card')).dy),
    );
  });

  testWidgets('keeps a half-answered card as the plan comes and goes', (
    tester,
  ) async {
    Widget composer(HermesTodoState? plan) => _app(
      withHermesPlan(
        const ConduitInput(key: ValueKey('synthetic-answer'), hint: 'Answer'),
        plan: plan,
        chatKey: 'chat-half',
      )!,
    );
    Finder field() => find.descendant(
      of: find.byKey(const ValueKey('synthetic-answer')),
      matching: find.byType(EditableText),
    );

    await tester.pumpWidget(composer(null));
    await tester.enterText(field(), 'Half an answer');
    final state = tester.state(field());

    await tester.pumpWidget(composer(_plan(['in_progress'])));
    expect(find.byKey(const ValueKey('hermes-todo-card')), findsOneWidget);
    await tester.pumpWidget(composer(null));

    expect(tester.state(field()), same(state));
    expect(find.text('Half an answer'), findsOneWidget);
  });

  // With the keyboard up the plan and a long form outgrew the space above
  // it, hiding questions and the plan's own fold control.
  testWidgets('folds over a card while the keyboard is up', (tester) async {
    Widget composer(double keyboard) => _app(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(400, 800),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: withHermesPlan(
          const Text('Question card'),
          plan: _plan(['completed', 'in_progress', 'pending']),
          chatKey: 'chat-typing',
        )!,
      ),
    );

    await tester.pumpWidget(composer(300));
    expect(find.text('Step 1'), findsOneWidget);
    expect(find.text('Step 2'), findsNothing);

    // Opened on purpose, it stays open while the user types.
    await tester.tap(find.byKey(const ValueKey('hermes-todo-toggle')));
    await tester.pump();
    expect(find.text('Step 2'), findsOneWidget);

    // The chat's own choice was left alone: open again, keyboard or not.
    await tester.pumpWidget(composer(0));
    expect(find.text('Step 2'), findsOneWidget);
    await tester.pumpWidget(composer(300));
    expect(find.text('Step 2'), findsNothing);
  });
}

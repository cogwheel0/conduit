import 'package:conduit/features/hermes/widgets/hermes_todo_card.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
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
    expect(withHermesPlan(prompt, plan: null, chatKey: 'c'), same(prompt));
    expect(
      withHermesPlan(
        prompt,
        plan: HermesTodoState.fromPayload({'todos': [], 'revision': 2}),
        chatKey: 'c',
      ),
      same(prompt),
    );
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
}

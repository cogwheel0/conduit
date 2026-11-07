import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/widgets/hermes_background_work_chip.dart';
import 'package:conduit/features/hermes/widgets/hermes_background_work_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/features/hermes/models/hermes_background_work.dart';
import 'package:conduit_core/features/hermes/providers/hermes_background_work_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The open chat's work, set by the test; records what the user did.
final class _FakeWork extends HermesBackgroundWorkController {
  _FakeWork(this.initial);

  final HermesBackgroundWork? initial;
  final steered = <(String, String)>[];
  final stopped = <String>[];
  final killed = <String>[];
  bool steerQueued = true;
  HermesProcessKillResult killResult = const HermesProcessKillResult(
    status: HermesProcessKillStatus.killed,
  );

  @override
  HermesBackgroundWork? build() => initial;

  void show(HermesBackgroundWork work) => state = work;

  @override
  Future<bool> steer(String subagentId, String text) async {
    steered.add((subagentId, text));
    return steerQueued;
  }

  @override
  Future<bool> stop(String subagentId) async {
    stopped.add(subagentId);
    return true;
  }

  @override
  Future<HermesProcessKillResult> kill(String processId) async {
    killed.add(processId);
    return killResult;
  }
}

/// A subagent's output, as read once.
final class _FakeTail extends HermesSubagentTailController {
  _FakeTail(super.subagent);

  @override
  HermesSubagentTailView build() => const HermesSubagentTailView(
    tail: HermesSubagentTail(
      available: true,
      text: _output,
      truncated: true,
    ),
  );
}

HermesBackgroundWork _work({
  List<Map<String, Object?>> subagents = const [],
  List<Map<String, Object?>> processes = const [],
}) {
  final started = DateTime.now().subtract(const Duration(seconds: 65));
  final epoch = started.millisecondsSinceEpoch / 1000;
  return HermesBackgroundWork.fromResults(
    subagents: {
      'subagents': [
        for (final row in subagents) {'started_at': epoch, ...row},
      ],
    },
    processes: {
      'processes': [
        for (final row in processes) {'started_epoch': epoch, ...row},
      ],
    },
  );
}

const _output = 'Reading tide tables\nFound 3 stations';

const _survey = {
  'subagent_id': 'sa-1',
  'goal': 'Survey the tide tables',
  'model': 'synthetic-model',
  'status': 'running',
  'tool_count': 2,
  'last_tool': 'web_search',
  'accepting_steer': true,
};

const _server = {
  'session_id': 'proc_a',
  'command': 'python3 -m http.server 8000',
  'status': 'running',
};

void main() {
  late _FakeWork work;

  Widget app(Widget home, HermesBackgroundWork? initial) => ProviderScope(
    overrides: [
      hermesBackgroundWorkProvider.overrideWith(
        () => work = _FakeWork(initial),
      ),
      hermesOpenSessionIdProvider.overrideWithValue('local-1'),
      hermesSubagentTailProvider.overrideWith2(_FakeTail.new),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: home),
    ),
  );

  Future<void> pumpSheet(WidgetTester tester, HermesBackgroundWork? w) async {
    await tester.pumpWidget(app(const HermesBackgroundWorkSheet(), w));
    await tester.pump();
  }

  Finder steerField() => find.descendant(
    of: find.byKey(const ValueKey('hermes-subagent-steer-field')),
    matching: find.byType(EditableText),
  );

  group('chip', () {
    testWidgets('shows only while something runs', (tester) async {
      check(withHermesBackgroundWork(null, agents: 0, processes: 0)).isNull();
      const plan = SizedBox(key: ValueKey('plan'));

      await tester.pumpWidget(
        app(
          Align(
            alignment: Alignment.bottomCenter,
            child: withHermesBackgroundWork(plan, agents: 0, processes: 0),
          ),
          null,
        ),
      );
      expect(find.byKey(const ValueKey('plan')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('hermes-background-work-chip')),
        findsNothing,
      );

      await tester.pumpWidget(
        app(
          Align(
            alignment: Alignment.bottomCenter,
            child: withHermesBackgroundWork(plan, agents: 2, processes: 1),
          ),
          null,
        ),
      );
      expect(find.text('2 agents · 1 process'), findsOneWidget);
      expect(find.byKey(const ValueKey('plan')), findsOneWidget);

      await tester.pumpWidget(
        app(
          Align(
            alignment: Alignment.bottomCenter,
            child: withHermesBackgroundWork(null, agents: 0, processes: 3),
          ),
          null,
        ),
      );
      expect(find.text('3 processes'), findsOneWidget);
    });

    testWidgets('keeps a half-answered card as work starts and ends', (
      tester,
    ) async {
      Widget composer(int processes) => app(
        Align(
          alignment: Alignment.bottomCenter,
          child: withHermesBackgroundWork(
            const ConduitInput(
              key: ValueKey('synthetic-answer'),
              hint: 'Answer',
            ),
            agents: 0,
            processes: processes,
          ),
        ),
        null,
      );
      Finder field() => find.descendant(
        of: find.byKey(const ValueKey('synthetic-answer')),
        matching: find.byType(EditableText),
      );

      await tester.pumpWidget(composer(0));
      await tester.enterText(field(), 'Half an answer');
      final state = tester.state(field());

      await tester.pumpWidget(composer(1));
      expect(find.text('1 process'), findsOneWidget);
      await tester.pumpWidget(composer(0));
      expect(find.text('1 process'), findsNothing);

      expect(tester.state(field()), same(state));
      expect(find.text('Half an answer'), findsOneWidget);
    });

    testWidgets('a screen reader can open the sheet', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        app(
          const Align(
            alignment: Alignment.bottomCenter,
            child: HermesBackgroundWorkChip(agents: 1, processes: 0),
          ),
          _work(subagents: [_survey]),
        ),
      );

      final chip = find.semantics.byLabel('1 agent');
      expect(
        tester.getSemantics(find.bySemanticsLabel('1 agent')),
        isSemantics(isButton: true, hasTapAction: true),
      );
      tester.semantics.tap(chip);
      await tester.pumpAndSettle();

      expect(find.text('Background work'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('opens the background work sheet', (tester) async {
      await tester.pumpWidget(
        app(
          const Align(
            alignment: Alignment.bottomCenter,
            child: HermesBackgroundWorkChip(agents: 1, processes: 0),
          ),
          _work(subagents: [_survey]),
        ),
      );
      expect(find.text('1 agent'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('hermes-background-work-chip')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Background work'), findsOneWidget);
      expect(find.text('Survey the tide tables'), findsOneWidget);
    });
  });

  group('sheet', () {
    testWidgets('lists running agents and processes', (tester) async {
      await pumpSheet(
        tester,
        _work(
          subagents: [_survey],
          processes: [
            _server,
            {'session_id': 'proc_b', 'command': 'ls', 'status': 'exited'},
          ],
        ),
      );

      expect(find.text('Agents'), findsOneWidget);
      expect(find.text('Survey the tide tables'), findsOneWidget);
      expect(
        find.textContaining(
          RegExp(r'^synthetic-model · 1m0\ds · last tool: web_search$'),
        ),
        findsOneWidget,
      );
      expect(find.text('Processes'), findsOneWidget);
      expect(find.text('python3 -m http.server 8000'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^1m0\ds$')), findsOneWidget);
      // A process that ended is not background work any more.
      expect(find.text('ls'), findsNothing);
    });

    testWidgets('says when nothing runs', (tester) async {
      await pumpSheet(tester, HermesBackgroundWork.empty);
      expect(
        find.text('Nothing is running in the background.'),
        findsOneWidget,
      );
    });

    testWidgets('kills a process only once confirmed', (tester) async {
      await pumpSheet(tester, _work(processes: [_server]));
      final kill = find.byKey(const ValueKey('hermes-process-kill-proc_a'));

      await tester.tap(kill);
      await tester.pumpAndSettle();
      expect(find.text('Kill this process?'), findsOneWidget);
      expect(
        find.textContaining('python3 -m http.server 8000'),
        findsNWidgets(2),
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      check(work.killed).isEmpty();

      await tester.tap(kill);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kill'));
      await tester.pumpAndSettle();
      check(work.killed).deepEquals(['proc_a']);
      expect(find.text('Process killed.'), findsOneWidget);
    });

    testWidgets('says why a kill failed', (tester) async {
      await pumpSheet(tester, _work(processes: [_server]));
      work.killResult = const HermesProcessKillResult(
        status: HermesProcessKillStatus.failed,
        error: 'Kill incomplete: 1 process(es) still alive',
      );

      await tester.tap(
        find.byKey(const ValueKey('hermes-process-kill-proc_a')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kill'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Couldn\'t kill it: Kill incomplete: 1 process(es) still alive',
        ),
        findsOneWidget,
      );
    });

    testWidgets('reads, steers and stops a subagent', (tester) async {
      await pumpSheet(tester, _work(subagents: [_survey]));

      await tester.tap(
        find.byKey(const ValueKey('hermes-subagent-row-sa-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Live output'), findsOneWidget);
      expect(find.text(_output), findsOneWidget);
      expect(
        find.text('Showing the latest part of its output.'),
        findsOneWidget,
      );

      bool steerEnabled() => tester
          .widget<ConduitButton>(
            find.byKey(const ValueKey('hermes-subagent-steer')),
          )
          .onPressed != null;
      check(steerEnabled()).isFalse();
      await tester.enterText(steerField(), '  Only check May  ');
      await tester.pump();
      check(steerEnabled()).isTrue();
      await tester.tap(find.byKey(const ValueKey('hermes-subagent-steer')));
      await tester.pumpAndSettle();
      check(work.steered).deepEquals([('sa-1', 'Only check May')]);
      expect(
        find.text('Sent. The agent reads it at its next step.'),
        findsOneWidget,
      );
      check(tester.widget<EditableText>(steerField()).controller.text)
          .isEmpty();

      work.steerQueued = false;
      await tester.enterText(steerField(), 'Too late');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hermes-subagent-steer')));
      await tester.pumpAndSettle();
      expect(
        find.text('This agent no longer takes instructions.'),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('hermes-subagent-stop')),
      );
      await tester.tap(find.byKey(const ValueKey('hermes-subagent-stop')));
      await tester.pumpAndSettle();
      check(work.stopped).deepEquals(['sa-1']);
      expect(find.text('Asked the agent to stop.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hermes-subagent-back')));
      await tester.pumpAndSettle();
      expect(find.text('Background work'), findsOneWidget);
    });

    testWidgets('a finished subagent keeps its output, without controls', (
      tester,
    ) async {
      await pumpSheet(tester, _work(subagents: [_survey]));
      await tester.tap(
        find.byKey(const ValueKey('hermes-subagent-row-sa-1')),
      );
      await tester.pumpAndSettle();

      work.show(HermesBackgroundWork.empty);
      await tester.pump();

      expect(find.text('This agent has finished.'), findsOneWidget);
      expect(find.text('Survey the tide tables'), findsOneWidget);
      expect(find.text(_output), findsOneWidget);
      for (final key in ['hermes-subagent-steer', 'hermes-subagent-stop']) {
        check(
          tester.widget<ConduitButton>(find.byKey(ValueKey(key))).onPressed,
        ).isNull();
      }
      check(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey('hermes-subagent-steer-field')),
                matching: find.byType(TextField),
              ),
            )
            .enabled,
      ).equals(false);
    });
  });
}

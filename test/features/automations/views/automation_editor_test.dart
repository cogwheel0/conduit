import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'automation_harness.dart';

const _editA = '/profile/scheduled-tasks/a/edit';
const _weekly = 'RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=18;BYMINUTE=30';

Future<AutomationSession> _edit(
  WidgetTester tester, {
  Map<String, dynamic>? task,
  List<Folder> folders = const [],
  List<Channel> channels = const [],
}) => pumpAutomations(
  tester,
  location: _editA,
  tasks: [task ?? taskJson('a', name: 'Morning digest')],
  folders: folders,
  channels: channels,
);

Future<void> _save(WidgetTester tester) async {
  // Typing updates state but draws no frame, and Save is only enabled once
  // the change has been drawn, as it would be for a person pressing it.
  await tester.pump();
  await tester.tap(find.byKey(const Key('scheduled-task-save')));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _body(AutomationWire wire, String suffix) =>
    wire.where('POST', suffix).single.data as Map<String, dynamic>;

void main() {
  group('a new task', () {
    testWidgets('needs a name, instructions and a model before it sends', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        location: '/profile/scheduled-tasks/new',
      );

      await _save(tester);
      expect(find.text('Enter a name.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('scheduled-task-name')), 'n');
      await _save(tester);
      expect(find.text('Enter instructions.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('scheduled-task-prompt')),
        'p',
      );
      await _save(tester);
      expect(find.text('Choose a model.'), findsOneWidget);

      expect(session.wire.writes, isEmpty);
    });

    testWidgets('creates a daily task in the web client\'s shape, then shows '
        'the server\'s next runs', (tester) async {
      final session = await pumpAutomations(
        tester,
        location: '/profile/scheduled-tasks/new',
      );

      await tester.enterText(
        find.byKey(const Key('scheduled-task-name')),
        '  Morning digest ',
      );
      await tester.enterText(
        find.byKey(const Key('scheduled-task-prompt')),
        'Summarize the news',
      );
      await tester.tap(find.byKey(const Key('scheduled-task-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-option-claude')));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(_body(session.wire, '/create'), {
        'name': 'Morning digest',
        'folder_id': null,
        'data': {
          'prompt': 'Summarize the news',
          'model_id': 'claude',
          'rrule': 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
          'target': {'type': 'chat'},
        },
        'is_active': true,
      });
      expect(session.wire.where('POST', '/create'), hasLength(1));
      // The new task's own page, with the times the server computed.
      expect(
        find.byKey(const Key('scheduled-task-next-run-1791320967000000001')),
        findsOneWidget,
      );
    });

    testWidgets('one time writes the web client\'s DTSTART rule', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        location: '/profile/scheduled-tasks/new',
      );
      await tester.enterText(find.byKey(const Key('scheduled-task-name')), 'n');
      await tester.enterText(
        find.byKey(const Key('scheduled-task-prompt')),
        'p',
      );
      await tester.tap(find.byKey(const Key('scheduled-task-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-option-claude')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('scheduled-task-kind-once')));
      await tester.pumpAndSettle();
      await _save(tester);

      final data = _body(session.wire, '/create')['data'] as Map;
      expect(
        data['rrule'],
        matches(RegExp(r'^DTSTART:\d{8}T\d{4}00\nRRULE:FREQ=DAILY;COUNT=1$')),
      );
    });

    testWidgets('says which time zone a schedule is read in', (tester) async {
      await pumpAutomations(tester, location: '/profile/scheduled-tasks/new');

      expect(
        find.byKey(const Key('scheduled-task-timezone-note')),
        findsOneWidget,
      );
      expect(find.textContaining('account time zone'), findsOneWidget);
    });
  });

  group('editing keeps what the server holds', () {
    testWidgets('a name change sends the whole task back, unchanged parts '
        'included', (tester) async {
      final session = await _edit(
        tester,
        task: taskJson(
          'a',
          name: 'Morning digest',
          rrule: 'RRULE:FREQ=WEEKLY;BYDAY=WE,MO;BYHOUR=18;BYMINUTE=30',
          terminal: {'server_id': 'term-1', 'cwd': '/work'},
          meta: {'system_prompt': 'Be brief', 'temperature': 0.2},
        ),
      );

      await tester.enterText(
        find.byKey(const Key('scheduled-task-name')),
        'Renamed',
      );
      await _save(tester);

      expect(_body(session.wire, '/update'), {
        'name': 'Renamed',
        'folder_id': null,
        'data': {
          'prompt': 'Summarize the news',
          'model_id': 'gpt-4o',
          // Tap order from the web client, kept as stored.
          'rrule': 'RRULE:FREQ=WEEKLY;BYDAY=WE,MO;BYHOUR=18;BYMINUTE=30',
          'terminal': {'server_id': 'term-1', 'cwd': '/work'},
          'target': {'type': 'chat'},
        },
        'meta': {'system_prompt': 'Be brief', 'temperature': 0.2},
        'is_active': true,
      });
      // What the server stored afterwards still has them.
      final stored = session.wire.tasks.single;
      expect((stored['data'] as Map)['terminal'], isNotNull);
      expect(stored['meta'], {'system_prompt': 'Be brief', 'temperature': 0.2});
    });

    testWidgets('Save is off until something changes', (tester) async {
      final session = await _edit(tester);

      expect(
        tester
            .widget<ConduitButton>(find.byKey(const Key('scheduled-task-save')))
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const Key('scheduled-task-save')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(session.wire.writes, isEmpty);
    });

    testWidgets('a weekday change writes the control rule', (tester) async {
      final session = await _edit(tester, task: taskJson('a', rrule: _weekly));

      await tester.tap(find.byKey(const Key('scheduled-task-day-WE')));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(
        (_body(session.wire, '/update')['data'] as Map)['rrule'],
        'RRULE:FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=18;BYMINUTE=30',
      );
    });

    testWidgets('a weekly task cannot drop its last day', (tester) async {
      final session = await _edit(tester, task: taskJson('a', rrule: _weekly));

      await tester.tap(find.byKey(const Key('scheduled-task-day-MO')));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(find.text('Complete the schedule.'), findsOneWidget);
      expect(session.wire.writes, isEmpty);
    });

    testWidgets('a one-time task keeps its rule when only the name changes', (
      tester,
    ) async {
      const once = 'DTSTART:20261007T090500\nRRULE:FREQ=DAILY;COUNT=1';
      final session = await _edit(tester, task: taskJson('a', rrule: once));
      expect(find.byKey(const Key('scheduled-task-date')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('scheduled-task-name')),
        'Renamed',
      );
      await _save(tester);

      expect((_body(session.wire, '/update')['data'] as Map)['rrule'], once);
    });
  });

  group('a rule the controls cannot edit', () {
    const monthly = 'RRULE:FREQ=MONTHLY;BYMONTHDAY=15;BYHOUR=9;BYMINUTE=0';

    testWidgets('is shown as stored and kept through an unrelated edit', (
      tester,
    ) async {
      final session = await _edit(tester, task: taskJson('a', rrule: monthly));

      expect(
        find.byKey(const Key('scheduled-task-raw-summary')),
        findsOneWidget,
      );
      expect(find.textContaining(monthly), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('scheduled-task-name')),
        'Renamed',
      );
      await _save(tester);

      expect((_body(session.wire, '/update')['data'] as Map)['rrule'], monthly);
    });

    testWidgets('is replaced only when a schedule type is chosen', (
      tester,
    ) async {
      final session = await _edit(tester, task: taskJson('a', rrule: monthly));

      await tester.tap(find.byKey(const Key('scheduled-task-kind-daily')));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(
        (_body(session.wire, '/update')['data'] as Map)['rrule'],
        'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
      );
    });

    testWidgets('the Advanced schedule field edits the raw rule', (
      tester,
    ) async {
      final session = await _edit(tester, task: taskJson('a', rrule: monthly));
      expect(find.byKey(const Key('scheduled-task-rrule')), findsNothing);

      await tester.tap(find.byKey(const Key('scheduled-task-advanced')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('scheduled-task-rrule')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        monthly,
      );

      const custom = 'RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=7;BYMINUTE=30';
      await tester.enterText(
        find.byKey(const Key('scheduled-task-rrule')),
        custom,
      );
      await _save(tester);

      expect((_body(session.wire, '/update')['data'] as Map)['rrule'], custom);
    });
  });

  group('a refused save', () {
    testWidgets('shows the server\'s reason and keeps the form to retry', (
      tester,
    ) async {
      final session = await _edit(tester);
      session.wire.rejectWrites = (
        status: 400,
        detail: 'Schedule too frequent. Minimum interval is 3600 seconds.',
      );
      await tester.enterText(
        find.byKey(const Key('scheduled-task-name')),
        'Renamed',
      );
      await tester.enterText(
        find.byKey(const Key('scheduled-task-prompt')),
        'A new prompt',
      );

      await _save(tester);

      expect(
        find.text('Schedule too frequent. Minimum interval is 3600 seconds.'),
        findsOneWidget,
      );
      expect(find.text('Renamed'), findsOneWidget);
      expect(find.text('A new prompt'), findsOneWidget);
      expect(session.wire.where('POST', '/update'), hasLength(1));

      // Nothing was lost, so the same form saves once the server agrees.
      session.wire.rejectWrites = null;
      await _save(tester);

      expect(session.wire.where('POST', '/update'), hasLength(2));
      expect(
        _bodyOf(session.wire.where('POST', '/update').last)['name'],
        'Renamed',
      );
      expect(session.wire.tasks.single['name'], 'Renamed');
    });

    testWidgets('after an account switch sends nothing and keeps the form', (
      tester,
    ) async {
      final session = await _edit(tester);
      await tester.enterText(
        find.byKey(const Key('scheduled-task-name')),
        'Renamed',
      );
      session.switchAccount();
      await tester.pumpAndSettle();
      session.wire.requests.clear();

      await _save(tester);

      expect(session.wire.writes, isEmpty);
      expect(
        find.text('The account changed. Reopen scheduled tasks to continue.'),
        findsOneWidget,
      );
      expect(find.text('Renamed'), findsOneWidget);
    });
  });

  // A slow network can answer after another account has signed in on the same
  // server. What the first account asked for stays done; none of it may reach
  // the screen or the navigation of the second.
  group('an answer that arrives after the account changed', () {
    const accountChanged =
        'The account changed. Reopen scheduled tasks to continue.';

    Finder field(String key) => find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(EditableText),
    );

    Future<void> switchWhileHeld(
      WidgetTester tester,
      AutomationSession session,
      AutomationHold hold,
    ) async {
      await reach(tester, hold);
      session.switchAccount();
      await tester.pump(const Duration(milliseconds: 100));
      hold.release();
      await tester.pumpAndSettle();
    }

    testWidgets('a task read does not fill the form for the new account', (
      tester,
    ) async {
      final session = await pumpAutomations(
        tester,
        tasks: [taskJson('a', name: 'Morning digest')],
      );
      final hold = session.wire.hold('GET', '/api/v1/automations/a');
      unawaited(session.router.push<void>(_editA));

      await switchWhileHeld(tester, session, hold);

      expect(find.byKey(const Key('scheduled-task-name')), findsNothing);
      expect(find.text('Morning digest'), findsNothing);
      expect(find.text(accountChanged), findsOneWidget);
    });

    testWidgets('a saved edit stays saved but does not close the form for the '
        'new account', (tester) async {
      final session = await _edit(tester);
      await tester.enterText(field('scheduled-task-name'), 'Changed by A');
      await tester.pump();
      final hold = session.wire.hold('POST', '/api/v1/automations/a/update');
      await tester.tap(find.byKey(const Key('scheduled-task-save')));

      await switchWhileHeld(tester, session, hold);

      expect(session.router.state.uri.path, _editA);
      expect(session.wire.where('POST', '/update'), hasLength(1));
      expect(session.wire.tasks.single['name'], 'Changed by A');
      expect(find.text('Changed by A'), findsOneWidget);
      expect(find.text(accountChanged), findsOneWidget);

      // Nothing is retried for the new account.
      session.wire.requests.clear();
      await tester.tap(find.byKey(const Key('scheduled-task-save')));
      await tester.pumpAndSettle();
      expect(session.wire.writes, isEmpty);
    });

    testWidgets('a created task stays created but its page is not opened for '
        'the new account', (tester) async {
      final session = await pumpAutomations(
        tester,
        location: '/profile/scheduled-tasks/new',
      );
      await tester.enterText(field('scheduled-task-name'), 'n');
      await tester.enterText(field('scheduled-task-prompt'), 'p');
      await tester.tap(find.byKey(const Key('scheduled-task-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-option-claude')));
      await tester.pumpAndSettle();
      await tester.pump();
      final hold = session.wire.hold('POST', '/api/v1/automations/create');
      await tester.tap(find.byKey(const Key('scheduled-task-save')));

      await switchWhileHeld(tester, session, hold);

      expect(session.router.state.uri.path, '/profile/scheduled-tasks/new');
      expect(session.wire.where('POST', '/create'), hasLength(1));
      expect(session.wire.tasks.first['id'], 'new-1');
      expect(find.text(accountChanged), findsOneWidget);
    });

    testWidgets('a save does not close a page opened over the form', (
      tester,
    ) async {
      final session = await _edit(tester);
      await tester.enterText(field('scheduled-task-name'), 'Changed');
      await tester.pump();
      final hold = session.wire.hold('POST', '/api/v1/automations/a/update');
      await tester.tap(find.byKey(const Key('scheduled-task-save')));
      await reach(tester, hold);
      unawaited(session.router.push<void>('/profile/scheduled-tasks'));
      await tester.pumpAndSettle();

      hold.release();
      await tester.pumpAndSettle();

      expect(session.wire.where('POST', '/update'), hasLength(1));
      expect(session.router.state.uri.path, '/profile/scheduled-tasks');
    });

    testWidgets('a channel write check does not choose a channel for the new '
        'account', (tester) async {
      final session = await _edit(
        tester,
        channels: const [Channel(id: 'c1', name: 'general')],
      );
      await tester.tap(find.byKey(const Key('scheduled-task-target-channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-channel')));
      await tester.pumpAndSettle();
      final hold = session.wire.hold('GET', '/api/v1/channels/c1');
      await tester.tap(find.byKey(const Key('scheduled-task-option-c1')));

      await switchWhileHeld(tester, session, hold);

      expect(find.text('Choose a channel'), findsOneWidget);
      expect(find.text('#general'), findsNothing);
      expect(find.text(accountChanged), findsOneWidget);
    });

    testWidgets('a choice made while the picker was open is not carried into '
        'the form', (tester) async {
      final session = await _edit(tester);
      await tester.tap(find.byKey(const Key('scheduled-task-model')));
      await tester.pumpAndSettle();

      session.switchAccount();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-option-claude')));
      await tester.pumpAndSettle();

      expect(find.text('GPT-4o'), findsOneWidget);
      expect(find.text('Claude'), findsNothing);
      expect(find.text(accountChanged), findsOneWidget);
    });
  });

  group('on a phone', () {
    // An iPhone 14 with its software keyboard up: 390x844, a 47pt status bar,
    // a 34pt home indicator that the keyboard replaces, and a 336pt keyboard.
    const keyboardTop = 844.0 - 336;
    final models = [
      for (var i = 0; i < 40; i++) Model(id: 'm$i', name: 'Model $i'),
    ];

    Future<AutomationSession> pumpPhone(
      WidgetTester tester, {
      bool native = false,
    }) async {
      final session = await pumpAutomations(
        tester,
        location: _editA,
        models: models,
        tasks: [taskJson('a', model: 'm1')],
        // The iOS 26 presenter shows Flutter's own modal route, which looks up
        // Flutter's MaterialLocalizations beside material_ui's.
        localizationsDelegates: native
            ? [
                ...AppLocalizations.localizationsDelegates,
                ...conduitLocalizationsDelegates,
              ]
            : conduitLocalizationsDelegates,
      );
      if (native) {
        // Flutter's localizations finish loading on a real timer.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
      tester.view
        ..physicalSize = const Size(390, 844)
        ..viewPadding = const FakeViewPadding(top: 47, bottom: 34)
        ..padding = const FakeViewPadding(top: 47, bottom: 34);
      await tester.pumpAndSettle();
      return session;
    }

    void raiseKeyboard(WidgetTester tester) {
      tester.view
        ..viewInsets = const FakeViewPadding(bottom: 336)
        ..padding = const FakeViewPadding(top: 47);
    }

    void lowerKeyboard(WidgetTester tester) {
      tester.view
        ..viewInsets = FakeViewPadding.zero
        ..padding = const FakeViewPadding(top: 47, bottom: 34);
    }

    Finder option(String id) => find.byKey(Key('scheduled-task-option-$id'));
    const search = Key('scheduled-task-option-search');

    // The same checks on Flutter's sheet and on the iOS 26 presenter.
    for (final native in [false, true]) {
      final presenter = native ? 'the iOS 26 presenter' : 'Material';

      testWidgets('the model search and its results stay above the keyboard '
          'with $presenter', (tester) async {
        final session = await pumpPhone(tester, native: native);
        if (native) {
          PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
          PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
          PlatformUiCapabilities.debugNativeIOS26Override = true;
          addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        }
        await tester.ensureVisible(
          find.byKey(const Key('scheduled-task-model')),
        );
        await tester.tap(find.byKey(const Key('scheduled-task-model')));
        await tester.pumpAndSettle();

        // Many matches: the list scrolls in the room above the keyboard.
        await tester.tap(find.byKey(search));
        await tester.enterText(find.byKey(search), 'Model 3');
        raiseKeyboard(tester);
        await tester.pumpAndSettle();

        expect(
          tester.getRect(find.byKey(search)).bottom,
          lessThan(keyboardTop),
        );
        expect(find.byKey(search).hitTestable(), findsOneWidget);
        expect(tester.getRect(option('m3')).bottom, lessThan(keyboardTop));
        expect(option('m3').hitTestable(), findsOneWidget);
        expect(option('m39').hitTestable(), findsNothing);
        await tester.drag(
          find.ancestor(of: option('m3'), matching: find.byType(ListView)),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        expect(option('m39').hitTestable(), findsOneWidget);
        expect(tester.getRect(option('m39')).bottom, lessThan(keyboardTop));

        // One match: the short sheet sits on the keyboard, not under it.
        await tester.enterText(find.byKey(search), 'Model 17');
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(search)).bottom,
          lessThan(keyboardTop),
        );
        expect(tester.getRect(option('m17')).bottom, lessThan(keyboardTop));
        expect(option('m17').hitTestable(), findsOneWidget);

        // The choice comes back, and Save is reachable once the keyboard is
        // down.
        await tester.tap(option('m17'));
        lowerKeyboard(tester);
        await tester.pumpAndSettle();
        expect(find.text('Model 17'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('scheduled-task-save')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('scheduled-task-save')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('scheduled-task-save')));
        await tester.pumpAndSettle();

        expect(
          (_body(session.wire, '/update')['data'] as Map)['model_id'],
          'm17',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the last model clears the home indicator when the keyboard is '
        'down', (tester) async {
      await pumpPhone(tester);
      await tester.ensureVisible(find.byKey(const Key('scheduled-task-model')));
      await tester.tap(find.byKey(const Key('scheduled-task-model')));
      await tester.pumpAndSettle();

      await tester.drag(
        find.ancestor(of: option('m0'), matching: find.byType(ListView)),
        const Offset(0, -6000),
      );
      await tester.pumpAndSettle();

      expect(option('m39').hitTestable(), findsOneWidget);
      expect(tester.getRect(option('m39')).bottom, lessThanOrEqualTo(844 - 34));
    });

    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'the schedule and destination choices fit at ${scale}x text',
        (tester) async {
          await pumpPhone(tester);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpAndSettle();

          for (final kind in ['once', 'daily', 'weekly']) {
            final chip = find.byKey(Key('scheduled-task-kind-$kind'));
            await tester.ensureVisible(chip);
            expect(chip.hitTestable(), findsOneWidget, reason: kind);
            expect(tester.getRect(chip).right, lessThanOrEqualTo(390));
          }
          await tester.tap(find.byKey(const Key('scheduled-task-kind-weekly')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('scheduled-task-day-MO')),
            findsOneWidget,
          );
          for (final target in ['chat', 'channel']) {
            final chip = find.byKey(Key('scheduled-task-target-$target'));
            await tester.ensureVisible(chip);
            await tester.pumpAndSettle();
            expect(chip.hitTestable(), findsOneWidget, reason: target);
          }
          // An overflow is reported as an exception, not as a failed finder.
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group('a saved model or destination that is not available now', () {
    testWidgets('keeps the saved model visible and needs a compatible one', (
      tester,
    ) async {
      final session = await _edit(
        tester,
        task: taskJson('a', model: 'retired-model'),
      );
      expect(find.text('retired-model (no longer available)'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('scheduled-task-name')),
        'Renamed',
      );
      await _save(tester);
      expect(
        find.text('Choose a model that is available now.'),
        findsOneWidget,
      );
      expect(session.wire.writes, isEmpty);

      await tester.tap(find.byKey(const Key('scheduled-task-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-option-claude')));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(
        (_body(session.wire, '/update')['data'] as Map)['model_id'],
        'claude',
      );
    });

    testWidgets('a folder that is gone blocks the save until it is cleared', (
      tester,
    ) async {
      final session = await _edit(
        tester,
        task: taskJson('a', folderId: 'gone'),
        folders: [Folder(id: 'f1', name: 'Reports')],
      );
      expect(find.text('Saved folder (no longer available)'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('scheduled-task-name')),
        'Renamed',
      );
      await _save(tester);
      expect(
        find.text('Choose a folder that is available now, or none.'),
        findsOneWidget,
      );
      expect(session.wire.writes, isEmpty);

      await tester.tap(find.byKey(const Key('scheduled-task-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-option-')));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(_body(session.wire, '/update')['folder_id'], isNull);
    });

    testWidgets('only the account\'s own folders are offered', (tester) async {
      await _edit(
        tester,
        folders: [
          Folder(id: 'mine', name: 'Reports'),
          Folder(
            id: 'theirs',
            name: 'Shared',
            shared: true,
            permission: 'write',
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('scheduled-task-folder')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('scheduled-task-option-mine')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('scheduled-task-option-theirs')),
        findsNothing,
      );
    });
  });

  group('a channel destination', () {
    testWidgets('a group channel is chosen without a write check', (
      tester,
    ) async {
      final session = await _edit(
        tester,
        channels: const [Channel(id: 'g1', name: 'team', type: 'group')],
      );

      await tester.tap(find.byKey(const Key('scheduled-task-target-channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-option-g1')));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(
        session.wire.requests.where((r) => r.uri.path.contains('/channels/')),
        isEmpty,
      );
      final body = _body(session.wire, '/update');
      expect(body['folder_id'], isNull);
      expect((body['data'] as Map)['target'], {
        'type': 'channel',
        'channel_id': 'g1',
      });
    });

    testWidgets('a standard channel is read back and refused without write '
        'access', (tester) async {
      final session = await _edit(
        tester,
        channels: const [Channel(id: 'c1', name: 'general')],
      );
      session.wire.channelWrite = false;

      await tester.tap(find.byKey(const Key('scheduled-task-target-channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scheduled-task-option-c1')));
      await tester.pumpAndSettle();

      expect(
        session.wire.requests.where((r) => r.uri.path.endsWith('/channels/c1')),
        hasLength(1),
      );
      expect(find.text('You cannot post to this channel.'), findsOneWidget);
      expect(find.text('Choose a channel'), findsOneWidget);
    });

    testWidgets('a channel task needs a channel before it saves', (
      tester,
    ) async {
      final session = await _edit(tester);

      await tester.tap(find.byKey(const Key('scheduled-task-target-channel')));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(find.text('Choose a channel.'), findsOneWidget);
      expect(session.wire.writes, isEmpty);
    });
  });
}

Map<String, dynamic> _bodyOf(RequestOptions request) =>
    request.data as Map<String, dynamic>;

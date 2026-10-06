import 'dart:async';

import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'calendar_harness.dart';

const _save = Key('calendar-editor-save');

Future<void> openAdd(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('calendar-add-event')));
  await tester.pumpAndSettle();
}

Future<void> openEdit(WidgetTester tester, {String event = 'ev-mine|'}) async {
  await tester.tap(find.byKey(Key('calendar-item-$event')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('calendar-event-edit')));
  await tester.pumpAndSettle();
}

Future<void> typeInto(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

bool saveEnabled(WidgetTester tester) =>
    tester.widget<ConduitButton>(find.byKey(_save)).onPressed != null;

Future<void> tapSave(WidgetTester tester) async {
  await tester.tap(find.byKey(_save));
  await tester.pumpAndSettle();
}

void main() {
  group('creating', () {
    testWidgets('sends the title with the next hour in the device zone and '
        'shows the new event', (tester) async {
      final session = await pumpCalendar(tester);

      await openAdd(tester);
      expect(saveEnabled(tester), isTrue);
      await typeInto(tester, 'calendar-editor-title', '  Standup ');
      await tapSave(tester);

      final write = session.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/events/create');
      // It is 06:00 at UTC-4, so the next hour is 07:00 to 08:00.
      expect(write.data, {
        'calendar_id': 'cal-mine',
        'title': 'Standup',
        'start_at': 1791284400000000000,
        'end_at': 1791288000000000000,
        'all_day': false,
      });
      // The sheet closed and the agenda shows what the server now holds.
      expect(find.byKey(_save), findsNothing);
      expect(find.text('Standup'), findsOneWidget);
    });

    testWidgets('a blank title is explained and nothing is sent', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      await openAdd(tester);
      await tapSave(tester);

      expect(find.text('Enter a title.'), findsOneWidget);
      expect(session.wire.writes, isEmpty);
    });

    testWidgets('an all-day event is written from midnight to 23:59', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      await openAdd(tester);
      await typeInto(tester, 'calendar-editor-title', 'Holiday');
      await tester.tap(find.byKey(const Key('calendar-editor-all-day')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-editor-start-time')), findsNothing);
      await tapSave(tester);

      expect(session.wire.writes.single.data, {
        'calendar_id': 'cal-mine',
        'title': 'Holiday',
        'start_at': 1791259200000000000,
        'end_at': 1791345540000000000,
        'all_day': true,
      });
    });

    testWidgets('an end that was removed is not sent, and adding one again '
        'ends where the event starts', (tester) async {
      final session = await pumpCalendar(tester);

      await openAdd(tester);
      await typeInto(tester, 'calendar-editor-title', 'Reminder');
      await tester.tap(find.byKey(const Key('calendar-editor-remove-end')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-editor-end-date')), findsNothing);
      expect(find.byKey(const Key('calendar-editor-end-time')), findsNothing);
      await tapSave(tester);

      // Written as it is for a timed event with no end: the key is absent.
      expect(session.wire.writes.single.data, {
        'calendar_id': 'cal-mine',
        'title': 'Reminder',
        'start_at': 1791284400000000000,
        'all_day': false,
      });

      await openAdd(tester);
      await typeInto(tester, 'calendar-editor-title', 'Again');
      await tester.tap(find.byKey(const Key('calendar-editor-remove-end')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-editor-add-end')));
      await tester.pumpAndSettle();
      await tapSave(tester);

      expect(
        (session.wire.writes.last.data as Map<String, dynamic>)['end_at'],
        1791284400000000000,
      );
    });

    testWidgets('an all-day event whose end was removed is sent without one', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      await openAdd(tester);
      await typeInto(tester, 'calendar-editor-title', 'Holiday');
      await tester.tap(find.byKey(const Key('calendar-editor-all-day')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-editor-remove-end')));
      await tester.pumpAndSettle();
      await tapSave(tester);

      expect(session.wire.writes.single.data, {
        'calendar_id': 'cal-mine',
        'title': 'Holiday',
        'start_at': 1791259200000000000,
        'all_day': true,
      });
    });

    testWidgets('a repeat is sent as the rule Open WebUI writes', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      await openAdd(tester);
      await typeInto(tester, 'calendar-editor-title', 'Weekly sync');
      await tester.tap(find.byKey(const Key('calendar-editor-repeat-weekly')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('calendar-editor-recurrence-note')),
        findsOneWidget,
      );
      await tapSave(tester);

      expect(
        (session.wire.writes.single.data as Map<String, dynamic>)['rrule'],
        'FREQ=WEEKLY',
      );
    });

    testWidgets('chosen people are invited without any response set', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      await openAdd(tester);
      await typeInto(tester, 'calendar-editor-title', 'Review');
      await tester.tap(find.byKey(const Key('calendar-editor-add-people')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, 'grace');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('workspace-principal-user-user-2')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Grace Hopper'), findsOneWidget);
      await tapSave(tester);

      expect(
        (session.wire.writes.single.data as Map<String, dynamic>)['attendees'],
        [
          {'user_id': 'user-2'},
        ],
      );
    });

    testWidgets('an account with no calendar to write to creates one first', (
      tester,
    ) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) {
          wire.calendars = [
            calendarJson(
              'cal-ro',
              'user-9',
              name: 'Holidays',
              grants: [grant('user', 'user-1', 'read')],
            ),
          ];
          wire.events = [];
        },
      );

      await openAdd(tester);
      expect(
        find.byKey(const Key('calendar-editor-no-calendar')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('calendar-editor-calendar')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('calendar-new-name')),
        'Work',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-create-calendar')));
      await tester.pumpAndSettle();

      final create = session.wire.writes.single;
      expect(create.uri.path, '/api/v1/calendars/create');
      expect(create.data, {'name': 'Work', 'color': '#3b82f6'});
      // The new calendar was chosen for the event.
      expect(
        find.descendant(
          of: find.byKey(const Key('calendar-editor-calendar')),
          matching: find.text('Work'),
        ),
        findsOneWidget,
      );

      await typeInto(tester, 'calendar-editor-title', 'First event');
      await tapSave(tester);
      expect(
        (session.wire.writes.last.data as Map<String, dynamic>)['calendar_id'],
        'cal-new-1',
      );
    });
  });

  group('editing', () {
    testWidgets('a title edit sends only the title and leaves the stored '
        'nanoseconds alone', (tester) async {
      final session = await pumpCalendar(tester);

      await openEdit(tester);
      expect(saveEnabled(tester), isFalse);
      await typeInto(tester, 'calendar-editor-title', 'Renamed');
      await tapSave(tester);

      final write = session.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/events/ev-mine/update');
      expect(write.data, {'title': 'Renamed'});
      final stored = session.wire.stored('ev-mine')!;
      expect(stored['title'], 'Renamed');
      expect(stored['start_at'], 1791320967123456789);
      expect(stored['end_at'], 1791324567987654321);
    });

    testWidgets('removing the end of a saved event clears it and nothing '
        'else', (tester) async {
      final session = await pumpCalendar(tester);

      await openEdit(tester);
      await tester.tap(find.byKey(const Key('calendar-editor-remove-end')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-editor-add-end')), findsOneWidget);
      expect(saveEnabled(tester), isTrue);
      await tapSave(tester);

      final write = session.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/events/ev-mine/update');
      expect(write.data, {'end_at': null});
      final stored = session.wire.stored('ev-mine')!;
      expect(stored['end_at'], isNull);
      expect(stored['start_at'], 1791320967123456789);
    });

    testWidgets('removing the end of an all-day or repeating event leaves '
        'its day and repeat alone', (tester) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson('ev-day', 'cal-mine', title: 'Offsite', allDay: true),
          eventJson('ev-weekly', 'cal-mine', title: 'Sync', rrule: 'FREQ=WEEKLY'),
        ],
      );

      await openEdit(tester, event: 'ev-day|');
      await tester.tap(find.byKey(const Key('calendar-editor-remove-end')));
      await tester.pumpAndSettle();
      await tapSave(tester);
      expect(session.wire.writes.single.data, {'end_at': null});
      session.wire.requests.clear();

      await openEdit(tester, event: 'ev-weekly|');
      expect(
        tester
            .widget<ConduitChip>(
              find.byKey(const Key('calendar-editor-repeat-weekly')),
            )
            .isSelected,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('calendar-editor-remove-end')));
      await tester.pumpAndSettle();
      await tapSave(tester);

      final write = session.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/events/ev-weekly/update');
      expect(write.data, {'end_at': null});
      expect(session.wire.stored('ev-weekly')!['rrule'], 'FREQ=WEEKLY');
    });

    testWidgets('the end cannot be removed while the save is in flight', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);
      await openEdit(tester);
      await typeInto(tester, 'calendar-editor-title', 'Renamed');
      final gate = Completer<void>();
      session.wire.holdWrites = gate;

      await tester.tap(find.byKey(_save));
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.wire.writes, hasLength(1));
      await tester.tap(
        find.byKey(const Key('calendar-editor-remove-end')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.byKey(const Key('calendar-editor-end-date')), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(session.wire.writes.single.data, {'title': 'Renamed'});
      expect(session.wire.stored('ev-mine')!['end_at'], 1791324567987654321);
    });

    testWidgets('a date picker opened and cancelled, or confirmed unchanged, '
        'is not an edit', (tester) async {
      final session = await pumpCalendar(tester);
      await openEdit(tester);

      await tester.tap(find.byKey(const Key('calendar-editor-start-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(saveEnabled(tester), isFalse);

      await tester.tap(find.byKey(const Key('calendar-editor-start-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(saveEnabled(tester), isFalse);
      expect(session.wire.writes, isEmpty);
    });

    testWidgets('moving the start moves the end with it to keep the length', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);
      await openEdit(tester);

      await tester.tap(find.byKey(const Key('calendar-editor-start-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('8'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tapSave(tester);

      // 17:09 and 18:09 on Oct 8 at UTC-4: the minute chosen, no seconds.
      expect(session.wire.writes.single.data, {
        'start_at': 1791493740000000000,
        'end_at': 1791497340000000000,
      });
    });

    testWidgets('a series is edited from its stored record, not the '
        'occurrence, and keeps a rule the editor cannot write', (tester) async {
      const rule = 'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU';
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) {
          wire.events = [
            eventJson('series-1', 'cal-mine', title: 'Sync', rrule: rule),
          ];
          // The occurrence is a week after the series' own start.
          wire.agendaOverride = [
            eventJson(
              'series-1',
              'cal-mine',
              title: 'Sync',
              rrule: rule,
              instanceId: 'series-1_1',
              startAt: 1791320967123456789 + 7 * 86400000000000,
              endAt: 1791324567987654321 + 7 * 86400000000000,
            ),
          ];
        },
      );

      await openEdit(tester, event: 'series-1|series-1_1');

      // The editor shows the series' start (Oct 6), not the occurrence's.
      expect(
        find.descendant(
          of: find.byKey(const Key('calendar-editor-start-date')),
          matching: find.text('Tue, Oct 6'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('calendar-editor-custom-rule')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('calendar-editor-recurrence-note')),
        findsOneWidget,
      );
      await typeInto(tester, 'calendar-editor-title', 'Team sync');
      await tapSave(tester);

      final write = session.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/events/series-1/update');
      expect(write.data, {'title': 'Team sync'});
      expect(session.wire.stored('series-1')!['rrule'], rule);
      expect(session.wire.stored('series-1')!['start_at'], 1791320967123456789);
    });

    testWidgets('moving to a calendar offers only ones the account can write '
        'to', (tester) async {
      final session = await pumpCalendar(tester);
      await openEdit(tester);

      await tester.tap(find.byKey(const Key('calendar-editor-calendar')));
      await tester.pumpAndSettle();
      // Holidays is read-only, so the server would refuse it as a destination.
      expect(find.byKey(const Key('calendar-pick-cal-ro')), findsNothing);
      expect(find.byKey(const Key('calendar-pick-cal-mine')), findsOneWidget);
      await tester.tap(find.byKey(const Key('calendar-pick-cal-rw')));
      await tester.pumpAndSettle();
      await tapSave(tester);

      expect(session.wire.writes.single.data, {'calendar_id': 'cal-rw'});
    });

    testWidgets('an unchanged attendee list is not replaced, and a changed '
        'one keeps what is known about the people', (tester) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson(
            'ev-mine',
            'cal-mine',
            attendees: [
              attendeeJson(
                'ev-mine',
                'user-3',
                status: 'accepted',
                meta: {'role': 'optional'},
              ),
            ],
          ),
        ],
      );

      await openEdit(tester);
      await typeInto(tester, 'calendar-editor-title', 'Renamed');
      await tapSave(tester);
      expect(session.wire.writes.single.data, {'title': 'Renamed'});
      session.wire.requests.clear();

      await openEdit(tester);
      await tester.tap(find.byKey(const Key('calendar-editor-add-people')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, 'grace');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('workspace-principal-user-user-2')),
      );
      await tester.pumpAndSettle();
      await tapSave(tester);

      expect(session.wire.writes.single.data, {
        'attendees': [
          {
            'user_id': 'user-3',
            'meta': {'role': 'optional'},
          },
          {'user_id': 'user-2'},
        ],
      });
      // The invited person's own answer survives the replacement.
      final attendees = session.wire.stored('ev-mine')!['attendees'] as List;
      expect(
        attendees.firstWhere((a) => a['user_id'] == 'user-3')['status'],
        'accepted',
      );
    });
  });

  group('a save that does not go through', () {
    testWidgets('keeps every field, explains in the server\'s words and '
        'makes no second request', (tester) async {
      final session = await pumpCalendar(tester);
      await openEdit(tester);
      await typeInto(tester, 'calendar-editor-title', 'Renamed');
      session.wire.rejectWrites = (
        status: 422,
        detail: 'Recurrence is too frequent',
      );

      await tapSave(tester);

      expect(session.wire.writes, hasLength(1));
      expect(find.text('Recurrence is too frequent'), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('calendar-editor-title')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        'Renamed',
      );
      // Still editable, and nothing was changed on the server.
      expect(saveEnabled(tester), isTrue);
      expect(session.wire.stored('ev-mine')!['title'], 'Planning');
    });

    testWidgets('after the account changed is refused and keeps the form', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);
      await openAdd(tester);
      await typeInto(tester, 'calendar-editor-title', 'Standup');

      session.switchAccount();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_save));
      await tester.pumpAndSettle();

      expect(session.wire.writes, isEmpty);
      expect(
        find.text(
          'The account changed while this was open. Close it and try again.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(_save), findsOneWidget);
    });

    testWidgets('a write refused by the server for lack of access says so', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);
      await openEdit(tester);
      await typeInto(tester, 'calendar-editor-title', 'Renamed');
      session.wire.rejectWrites = (status: 403, detail: 'Access denied');

      await tapSave(tester);

      expect(
        find.text("Your account can't change this in that calendar."),
        findsOneWidget,
      );
      expect(saveEnabled(tester), isTrue);
    });
  });
}

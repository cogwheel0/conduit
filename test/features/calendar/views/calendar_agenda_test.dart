import 'dart:async';

import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'calendar_harness.dart';

Finder item(String key) => find.byKey(Key('calendar-item-$key'));

/// [utc] as the server's epoch nanoseconds.
int ns(DateTime utc) => utc.microsecondsSinceEpoch * 1000;

/// The RSVP segment labelled [label] in the event sheet.
Finder rsvp(String label) => find.descendant(
  of: find.byKey(const Key('calendar-rsvp')),
  matching: find.text(label),
);

Future<void> openCalendars(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('calendar-manage-calendars')));
  await tester.pumpAndSettle();
}

void main() {
  group('the agenda', () {
    testWidgets('groups events by their day in the device zone', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) {
          wire.events = [
            // 2026-10-06 17:09 to 18:09 at UTC-4.
            eventJson('ev-mine', 'cal-mine', title: 'Planning'),
            // 2026-10-12 00:00 to 2026-10-14 23:59 at UTC-4.
            eventJson(
              'ev-trip',
              'cal-ro',
              title: 'Offsite',
              allDay: true,
              startAt: 1791777600000000000,
              endAt: 1792036740000000000,
            ),
          ];
        },
      );

      expect(find.byKey(const Key('calendar-range')), findsOneWidget);
      expect(find.text('Oct 6 – Oct 19'), findsOneWidget);
      expect(find.text('Today · Tue, Oct 6'), findsOneWidget);
      expect(find.text('5:09 PM – 6:09 PM'), findsOneWidget);
      // A span of days is listed on each of them.
      for (final day in ['Mon, Oct 12', 'Tue, Oct 13', 'Wed, Oct 14']) {
        expect(find.text(day), findsOneWidget);
      }
      expect(find.text('Offsite'), findsNWidgets(3));
      expect(find.text('All day'), findsNWidgets(3));
      expect(
        find.text("Times are shown in this device's time zone."),
        findsOneWidget,
      );
    });

    testWidgets('a timed event over several days starts, fills and ends its '
        'days', (tester) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) => wire.events = [
          // 22:00 on Wed Oct 7 to 02:00 on Fri Oct 9 at UTC-4.
          eventJson(
            'ev-night',
            'cal-mine',
            title: 'Night shift',
            startAt: ns(DateTime.utc(2026, 10, 8, 2)),
            endAt: ns(DateTime.utc(2026, 10, 9, 6)),
          ),
          // 22:00 on Sat Oct 10 to midnight at the end of Sun Oct 11.
          eventJson(
            'ev-weekend',
            'cal-mine',
            title: 'Weekend',
            startAt: ns(DateTime.utc(2026, 10, 11, 2)),
            endAt: ns(DateTime.utc(2026, 10, 12, 4)),
          ),
        ],
      );

      // The event is listed under each of its days, in order.
      String label(String key, int day) =>
          tester.getSemantics(item(key).at(day)).label;

      expect(item('ev-night|'), findsNWidgets(3));
      expect(label('ev-night|', 0), 'Night shift. Starts 10:00 PM. Personal');
      expect(label('ev-night|', 1), 'Night shift. All day. Personal');
      expect(label('ev-night|', 2), 'Night shift. Ends 2:00 AM. Personal');
      // The first day's time was once its whole span.
      expect(find.text('10:00 PM – 2:00 AM'), findsNothing);
      expect(item('ev-weekend|'), findsNWidgets(2));
      expect(label('ev-weekend|', 0), 'Weekend. Starts 10:00 PM. Personal');
      expect(label('ev-weekend|', 1), 'Weekend. All day. Personal');
      // Ending at midnight leaves no row on the next day.
      expect(
        find.byKey(const Key('calendar-day-2026-10-12T00:00')),
        findsNothing,
      );
    });

    testWidgets('times follow the device\'s 24-hour setting', (tester) async {
      await pumpCalendar(tester, alwaysUse24HourFormat: true);

      expect(find.text('17:09 – 18:09'), findsOneWidget);
      expect(find.textContaining('PM'), findsNothing);
    });

    testWidgets('day headings are headers that name today and tomorrow', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson('ev-mine', 'cal-mine', title: 'Planning'),
          eventJson(
            'ev-next',
            'cal-mine',
            title: 'Review',
            startAt: ns(DateTime.utc(2026, 10, 7, 14)),
            endAt: ns(DateTime.utc(2026, 10, 7, 15)),
          ),
          eventJson(
            'ev-later',
            'cal-mine',
            title: 'Retro',
            startAt: ns(DateTime.utc(2026, 10, 9, 14)),
            endAt: ns(DateTime.utc(2026, 10, 9, 15)),
          ),
        ],
      );

      expect(find.text('Today · Tue, Oct 6'), findsOneWidget);
      expect(find.text('Tomorrow · Wed, Oct 7'), findsOneWidget);
      expect(find.text('Fri, Oct 9'), findsOneWidget);
      expect(
        tester.getSemantics(
          find.byKey(const Key('calendar-day-2026-10-06T00:00')),
        ),
        isSemantics(isHeader: true),
      );
    });

    testWidgets('a row reads its title, time, calendar and answer', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson('ev-mine', 'cal-mine', title: ''),
          eventJson(
            'ev-invite',
            'cal-ro',
            title: 'Open house',
            owner: 'user-9',
            attendees: [attendeeJson('ev-invite', 'user-1')],
          ),
        ],
      );

      expect(
        tester.getSemantics(item('ev-mine|')).label,
        'Untitled event. 5:09 PM – 6:09 PM. Personal',
      );
      expect(
        tester.getSemantics(item('ev-invite|')).label,
        'Open house. 5:09 PM – 6:09 PM. Holidays. No response yet',
      );
    });

    testWidgets('lists every occurrence of a recurring event', (tester) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) {
          wire.agendaOverride = [
            for (final day in [0, 7])
              eventJson(
                'series-1',
                'cal-mine',
                title: 'Weekly sync',
                rrule: 'FREQ=WEEKLY',
                instanceId: 'series-1_$day',
                startAt: 1791320967123456789 + day * 86400000000000,
              ),
          ];
        },
      );

      expect(find.text('Weekly sync'), findsNWidgets(2));
      expect(item('series-1|series-1_0'), findsOneWidget);
      expect(item('series-1|series-1_7'), findsOneWidget);
      expect(find.text('Tue, Oct 13'), findsOneWidget);
    });

    testWidgets('asks for the range and calendars the user chose', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      expect(session.wire.agendaRequests.last.uri.queryParameters, {
        'start': '2026-10-06T00:00:00-04:00',
        'end': '2026-10-20T00:00:00-04:00',
      });

      await tester.tap(find.byKey(const Key('calendar-later')));
      await tester.pumpAndSettle();
      expect(session.wire.agendaRequests.last.uri.queryParameters, {
        'start': '2026-10-20T00:00:00-04:00',
        'end': '2026-11-03T00:00:00-04:00',
      });
      expect(find.text('Oct 20 – Nov 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('calendar-today')));
      await tester.pumpAndSettle();
      expect(find.text('Oct 6 – Oct 19'), findsOneWidget);

      // Calendars are shown or hidden from the Calendars sheet.
      await openCalendars(tester);
      await tester.tap(find.byKey(const Key('calendar-row-cal-ro')));
      await tester.pumpAndSettle();
      expect(
        session.wire.agendaRequests.last.uri.queryParameters['calendar_ids']!
            .split(',')
            .toSet(),
        {'cal-mine', 'cal-rw'},
      );
      expect(
        tester.getSemantics(find.byKey(const Key('calendar-row-cal-ro'))),
        isSemantics(isSelected: false, hasSelectedState: true),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('calendar-row-cal-mine'))),
        isSemantics(isSelected: true, hasSelectedState: true),
      );

      // Showing every calendar again asks for all of them.
      await tester.tap(find.byKey(const Key('calendar-row-cal-ro')));
      await tester.pumpAndSettle();
      expect(
        session.wire.agendaRequests.last.uri.queryParameters.containsKey(
          'calendar_ids',
        ),
        isFalse,
      );
    });

    testWidgets('the last shown calendar cannot be hidden', (tester) async {
      final session = await pumpCalendar(tester);
      await openCalendars(tester);

      await tester.tap(find.byKey(const Key('calendar-row-cal-ro')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-row-cal-rw')));
      await tester.pumpAndSettle();
      final before = session.wire.agendaRequests.length;
      await tester.tap(find.byKey(const Key('calendar-row-cal-mine')));
      await tester.pumpAndSettle();

      expect(session.wire.agendaRequests.length, before);
      expect(
        session.wire.agendaRequests.last.uri.queryParameters['calendar_ids'],
        'cal-mine',
      );
    });

    testWidgets('the range bar pages with labelled chevrons, shows progress, '
        'and returns to today', (tester) async {
      final session = await pumpCalendar(tester);
      ConduitTextButton today() => tester.widget<ConduitTextButton>(
        find.byKey(const Key('calendar-today')),
      );

      // Already at today, so there is nowhere to return to.
      expect(today().onPressed, isNull);
      expect(find.byTooltip('Previous 14 days'), findsOneWidget);
      expect(find.byTooltip('Next 14 days'), findsOneWidget);

      final gate = Completer<void>();
      session.wire.holdAgenda = gate;
      await tester.tap(find.byKey(const Key('calendar-later')));
      await tester.pump();
      expect(find.byKey(const Key('calendar-paging')), findsOneWidget);
      gate.complete();
      session.wire.holdAgenda = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-paging')), findsNothing);
      expect(find.text('Oct 20 – Nov 2'), findsOneWidget);
      expect(today().onPressed, isNotNull);

      // A range outside this year carries the year.
      for (var page = 0; page < 5; page++) {
        await tester.tap(find.byKey(const Key('calendar-later')));
        await tester.pumpAndSettle();
      }
      expect(find.text('Dec 29, 2026 – Jan 11, 2027'), findsOneWidget);

      await tester.tap(find.byKey(const Key('calendar-earlier')));
      await tester.pumpAndSettle();
      expect(find.text('Dec 15 – Dec 28'), findsOneWidget);
    });

    testWidgets('a quick second page keeps its progress until it loads', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      int agendaReads() => session.wire.requests
          .where((r) => r.uri.path == '/api/v1/calendars/events')
          .length;
      // Taps the chevron and waits until its read reached the server and is
      // held there by [gate].
      Future<void> page(String key, Completer<void> gate) async {
        final reads = agendaReads();
        session.wire.holdAgenda = gate;
        await tester.tap(find.byKey(Key(key)));
        for (var i = 0; i < 20 && agendaReads() == reads; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(agendaReads(), reads + 1);
      }

      final first = Completer<void>();
      await page('calendar-later', first);
      final second = Completer<void>();
      await page('calendar-earlier', second);

      // The first page lands while the second is still loading.
      first.complete();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('calendar-paging')), findsOneWidget);

      second.complete();
      session.wire.holdAgenda = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-paging')), findsNothing);
    });

    testWidgets('a page that fails to load keeps the range bar and offers to '
        'retry', (tester) async {
      final session = await pumpCalendar(tester);
      session.wire.failAgenda = true;

      await tester.tap(find.byKey(const Key('calendar-later')));
      await tester.pumpAndSettle();

      expect(find.text('Oct 20 – Nov 2'), findsOneWidget);
      expect(find.byKey(const Key('calendar-retry')), findsOneWidget);
      expect(find.byKey(const Key('calendar-earlier')), findsOneWidget);

      session.wire.failAgenda = false;
      await tester.tap(find.byKey(const Key('calendar-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-retry')), findsNothing);
      expect(
        session.wire.agendaRequests.last.uri.queryParameters['start'],
        '2026-10-20T00:00:00-04:00',
      );
    });

    testWidgets('says so when there is nothing in the period, and offers a '
        'new event', (tester) async {
      await pumpCalendar(tester, configureWire: (wire) => wire.events = []);

      expect(find.byKey(const Key('calendar-empty')), findsOneWidget);
      await tester.tap(find.byKey(const Key('calendar-empty-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-editor-save')), findsOneWidget);
    });

    testWidgets('a new event starts from the navigation bar', (tester) async {
      await pumpCalendar(tester);

      expect(find.byTooltip('New event'), findsOneWidget);
      await tester.tap(find.byKey(const Key('calendar-add-event')));
      await tester.pumpAndSettle();
      expect(find.text('New event'), findsWidgets);
      expect(find.byKey(const Key('calendar-editor-save')), findsOneWidget);
    });
  });

  group('who may open it', () {
    testWidgets('anyone the server allows, with Advanced off', (tester) async {
      final session = await pumpCalendar(tester);

      expect(
        session.container.read(appSettingsProvider).advancedFeaturesEnabled,
        isFalse,
      );
      expect(find.byKey(const Key('calendar-range')), findsOneWidget);
    });

    testWidgets('a server or account without the calendar sees why', (
      tester,
    ) async {
      final off = await pumpCalendar(tester, serverEnabled: false);
      expect(find.byKey(const Key('calendar-unavailable')), findsOneWidget);
      expect(off.wire.requests, isEmpty);
    });

    testWidgets('an account without the permission sees why', (tester) async {
      final session = await pumpCalendar(
        tester,
        permissions: const {
          'features': {'calendar': false},
        },
      );

      expect(find.byKey(const Key('calendar-unavailable')), findsOneWidget);
      expect(session.wire.requests, isEmpty);
    });
  });

  group('scheduled tasks', () {
    void withScheduled(CalendarWire wire) {
      wire.virtualCalendar = true;
      wire.events = [];
      wire.scheduled = [
        scheduledEntryJson('auto_a1'),
        scheduledEntryJson(
          'run_chan',
          runId: 'r1',
          chatId: 'channel:chan-1',
          status: 'success',
          startAt: 1791300000000000000,
        ),
        scheduledEntryJson(
          'run_chat',
          runId: 'r2',
          chatId: 'chat-9',
          status: 'success',
          startAt: 1791290000000000000,
        ),
        scheduledEntryJson(
          'run_bad',
          runId: 'r3',
          status: 'error',
          startAt: 1791280000000000000,
        ),
      ];
    }

    testWidgets('are listed apart from events, with their state', (
      tester,
    ) async {
      await pumpCalendar(tester, configureWire: withScheduled);

      expect(find.text('Scheduled task'), findsNothing);
      expect(find.textContaining('Scheduled task'), findsOneWidget);
      expect(find.textContaining('Task run finished'), findsNWidgets(2));
      expect(find.textContaining('Task run failed'), findsOneWidget);
    });

    testWidgets('a future entry opens its task and nothing is mutated', (
      tester,
    ) async {
      final session = await pumpCalendar(tester, configureWire: withScheduled);

      await tester.tap(item('auto_a1|'));
      await tester.pumpAndSettle();

      expect(find.byKey(calendarScheduledTaskKey('a1')), findsOneWidget);
      expect(session.wire.writes, isEmpty);
      // Neither the entry nor its id ever reached an event route.
      expect(
        session.wire.requests.where(
          (r) => r.uri.path.contains('auto_') || r.uri.path.contains('run_'),
        ),
        isEmpty,
      );
    });

    // The shell is already mounted under the calendar whatever the user came
    // from. A flat test router would not notice a page pushed into it twice.
    for (final (underneath, shellLocation) in [
      ('chat', Routes.chat),
      ('another channel', '/channel/other'),
    ]) {
      testWidgets('a channel result opens the channel over $underneath', (
        tester,
      ) async {
        final session = await pumpCalendar(
          tester,
          configureWire: withScheduled,
          shellLocation: shellLocation,
        );

        await tester.tap(item('run_chan|'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(calendarShellKey), findsOneWidget);
        expect(find.byKey(calendarChannelKey('chan-1')), findsOneWidget);
        expect(session.wire.writes, isEmpty);
      });
    }

    testWidgets('a chat result opens that chat in the shell', (tester) async {
      await pumpCalendar(tester, configureWire: withScheduled);

      await tester.tap(item('run_chat|'));
      await tester.pumpAndSettle();

      expect(FakeSelection.selected.single.id, 'chat-9');
      expect(find.byKey(calendarShellKey), findsOneWidget);
      expect(find.byKey(calendarChatKey), findsOneWidget);
    });

    testWidgets('a run with no result opens its task', (tester) async {
      await pumpCalendar(tester, configureWire: withScheduled);

      await tester.tap(item('run_bad|'));
      await tester.pumpAndSettle();

      expect(find.byKey(calendarScheduledTaskKey('a1')), findsOneWidget);
    });

    testWidgets('are not offered to an account without scheduled tasks', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        configureWire: withScheduled,
        permissions: const {
          'features': {'calendar': true, 'automations': false},
        },
      );

      expect(item('auto_a1|'), findsNothing);
      expect(find.textContaining('Task run'), findsNothing);
    });
  });

  group('an invitation', () {
    // The agenda lists an event the account only attends even when it has no
    // grant on its calendar; the detail route would refuse it.
    void withInvitation(CalendarWire wire) {
      wire.events = [
        eventJson(
          'ev-invite',
          'cal-hidden',
          title: 'Board meeting',
          owner: 'user-9',
          attendees: [attendeeJson('ev-invite', 'user-1')],
        ),
      ];
    }

    testWidgets('is answered from the agenda copy without a detail read', (
      tester,
    ) async {
      final session = await pumpCalendar(tester, configureWire: withInvitation);
      expect(find.text('No response yet'), findsOneWidget);

      await tester.tap(item('ev-invite|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-title')), findsOneWidget);
      // It cannot be edited or deleted, only answered.
      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
      expect(find.byKey(const Key('calendar-event-delete')), findsNothing);
      expect(find.byKey(const Key('calendar-event-read-only')), findsOneWidget);
      expect(
        find.text(
          "You can't change this event. You can still answer an invitation.",
        ),
        findsOneWidget,
      );
      expect(
        session.wire.requests.where(
          (r) => r.uri.path == '/api/v1/calendars/events/ev-invite',
        ),
        isEmpty,
      );

      await tester.tap(rsvp('Maybe'));
      await tester.pumpAndSettle();

      final write = session.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/events/ev-invite/rsvp');
      expect(write.data, {'status': 'tentative'});
      expect(
        session.wire.stored('ev-invite')!['attendees'][0]['status'],
        'tentative',
      );
      expect(find.text('Maybe'), findsWidgets);
    });

    testWidgets('the answer stays shown and takes no tap while it sends', (
      tester,
    ) async {
      final session = await pumpCalendar(tester, configureWire: withInvitation);
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      CalendarRsvp shown() => tester
          .widget<AdaptiveSegmentedSelector<CalendarRsvp>>(
            find.byKey(const Key('calendar-rsvp')),
          )
          .value;

      await tester.tap(item('ev-invite|'));
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      session.wire.holdWrites = gate;
      await tester.tap(rsvp('Going'));
      await tester.pump();
      expect(find.byKey(const Key('calendar-rsvp-sending')), findsOneWidget);
      expect(shown(), CalendarRsvp.accepted);
      haptics.clear();

      await tester.tap(rsvp('Maybe'));
      await tester.pump();
      expect(haptics, isEmpty);
      expect(shown(), CalendarRsvp.accepted);

      gate.complete();
      await tester.pumpAndSettle();
      expect(session.wire.writes.single.data, {'status': 'accepted'});
    });

    testWidgets('a refused RSVP says so and changes nothing', (tester) async {
      final session = await pumpCalendar(tester, configureWire: withInvitation);
      session.wire.rejectWrites = (status: 404, detail: 'Not an attendee');

      await tester.tap(item('ev-invite|'));
      await tester.pumpAndSettle();
      await tester.tap(rsvp('Going'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-error')), findsOneWidget);
      // The refused answer is not left looking chosen.
      expect(
        tester
            .widget<AdaptiveSegmentedSelector<CalendarRsvp>>(
              find.byKey(const Key('calendar-rsvp')),
            )
            .value,
        CalendarRsvp.pending,
      );
      expect(
        session.wire.stored('ev-invite')!['attendees'][0]['status'],
        'pending',
      );
    });

    testWidgets('an invited person with read-only access can still answer', (
      tester,
    ) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson(
            'ev-ro',
            'cal-ro',
            title: 'Open house',
            owner: 'user-9',
            attendees: [attendeeJson('ev-ro', 'user-1')],
          ),
        ],
      );

      await tester.tap(item('ev-ro|'));
      await tester.pumpAndSettle();
      await tester.tap(rsvp("Can't go"));
      await tester.pumpAndSettle();

      expect(session.wire.writes.single.uri.path, endsWith('/ev-ro/rsvp'));
      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
    });
  });

  group('an event the account may change', () {
    testWidgets('can be edited and deleted', (tester) async {
      await pumpCalendar(tester);

      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-edit')), findsOneWidget);
      expect(find.byKey(const Key('calendar-event-delete')), findsOneWidget);
    });

    testWidgets('an answer on its way holds Edit without showing it as '
        'loading', (tester) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson(
            'ev-mine',
            'cal-mine',
            attendees: [attendeeJson('ev-mine', 'user-1')],
          ),
        ],
      );
      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();
      ConduitButton edit() => tester.widget<ConduitButton>(
        find.byKey(const Key('calendar-event-edit')),
      );
      expect(edit().isLoading, isFalse);

      final gate = Completer<void>();
      session.wire.holdWrites = gate;
      await tester.tap(rsvp('Going'));
      await tester.pump();
      expect(find.byKey(const Key('calendar-rsvp-sending')), findsOneWidget);
      expect(edit().onPressed, isNull);
      expect(edit().isLoading, isFalse);

      gate.complete();
      await tester.pumpAndSettle();
      expect(edit().onPressed, isNotNull);

      // Fetching the event to edit is what shows on Edit.
      final read = Completer<void>();
      session.wire.holdEventReads = read;
      await tester.tap(find.byKey(const Key('calendar-event-edit')));
      await tester.pump();
      expect(edit().isLoading, isTrue);
      read.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-editor-save')), findsOneWidget);
    });

    testWidgets('an event in a read-only calendar can be neither', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) =>
            wire.events = [eventJson('ev-ro', 'cal-ro', title: 'Holiday')],
      );

      await tester.tap(item('ev-ro|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
      expect(find.byKey(const Key('calendar-event-delete')), findsNothing);
      expect(find.text("You can't change this event."), findsOneWidget);
    });

    testWidgets('shows its details as rows and its actions stacked, after a '
        'loading indicator', (tester) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson(
            'ev-mine',
            'cal-mine',
            title: 'Planning',
            attendees: [attendeeJson('ev-mine', 'user-3')],
          ),
        ],
      );
      final gate = Completer<void>();
      session.wire.holdEventReads = gate;

      await tester.tap(item('ev-mine|'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('calendar-event-loading')), findsOneWidget);
      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-loading')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('calendar-event-calendar')),
          matching: find.text('Personal'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('calendar-event-invited')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      final edit = tester.getRect(find.byKey(const Key('calendar-event-edit')));
      final delete = tester.getRect(
        find.byKey(const Key('calendar-event-delete')),
      );
      expect(delete.top, greaterThan(edit.bottom));
      expect(delete.width, edit.width);
    });

    testWidgets('an untitled event is named in the delete question', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) =>
            wire.events = [eventJson('ev-mine', 'cal-mine', title: '')],
      );

      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-event-delete')));
      await tester.pumpAndSettle();

      expect(
        find.text('Delete Untitled event? This cannot be undone.'),
        findsOneWidget,
      );
    });

    testWidgets('a refused detail read keeps the agenda copy, turns editing '
        'off and refreshes the agenda', (tester) async {
      final session = await pumpCalendar(tester);
      final before = session.wire.agendaRequests.length;
      session.wire.denyDetail = true;

      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-title')), findsOneWidget);
      expect(find.text('Planning'), findsWidgets);
      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
      expect(find.byKey(const Key('calendar-event-delete')), findsNothing);
      expect(session.wire.agendaRequests.length, greaterThan(before));
    });

    testWidgets('an event deleted elsewhere says so and refreshes', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);
      session.wire.events.clear();
      final before = session.wire.agendaRequests.length;

      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-gone')), findsOneWidget);
      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
      expect(session.wire.agendaRequests.length, greaterThan(before));
    });

    testWidgets('deleting asks first and then removes the event', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-event-delete')));
      await tester.pumpAndSettle();
      // Declining deletes nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.wire.writes, isEmpty);

      await tester.tap(find.byKey(const Key('calendar-event-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ConduitTextButton, 'Delete'));
      await tester.pumpAndSettle();

      final write = session.wire.writes.single;
      expect(write.method, 'DELETE');
      expect(write.uri.path, '/api/v1/calendars/events/ev-mine/delete');
      expect(session.wire.events, isEmpty);
      expect(item('ev-mine|'), findsNothing);
    });

    testWidgets('a series is edited and deleted as a whole', (tester) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) {
          wire.events = [
            eventJson(
              'series-1',
              'cal-mine',
              title: 'Weekly sync',
              rrule: 'FREQ=WEEKLY',
            ),
          ];
          wire.agendaOverride = [
            eventJson(
              'series-1',
              'cal-mine',
              title: 'Weekly sync',
              rrule: 'FREQ=WEEKLY',
              instanceId: 'series-1_1',
            ),
          ];
        },
      );

      await tester.tap(item('series-1|series-1_1'));
      await tester.pumpAndSettle();

      expect(find.text('Edit series'), findsOneWidget);
      expect(find.text('Delete series'), findsOneWidget);
      expect(find.byKey(const Key('calendar-event-repeat')), findsOneWidget);

      await tester.tap(find.byKey(const Key('calendar-event-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ConduitTextButton, 'Delete series'));
      await tester.pumpAndSettle();

      expect(
        session.wire.writes.single.uri.path,
        '/api/v1/calendars/events/series-1/delete',
      );
    });
  });

  group('calendars', () {
    testWidgets('only the account\'s own calendar can be made its default', (
      tester,
    ) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) => wire.calendars.add(
          calendarJson('cal-work', 'user-1', name: 'Work'),
        ),
      );

      await openCalendars(tester);

      // The other owner's default and a shared calendar get no button, and the
      // account's current default has nothing to offer.
      expect(
        find.byKey(const Key('calendar-make-default-cal-ro')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('calendar-make-default-cal-rw')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('calendar-make-default-cal-mine')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('calendar-make-default-cal-work')));
      await tester.pumpAndSettle();

      final write = session.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/cal-work/default');
      // Another owner's default stays theirs.
      expect(
        session.wire.calendars.firstWhere(
          (c) => c['id'] == 'cal-ro',
        )['is_default'],
        isTrue,
      );
    });

    testWidgets('the scheduled-tasks calendar can be hidden but not made a '
        'default', (tester) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) => wire.virtualCalendar = true,
      );

      await openCalendars(tester);

      expect(
        find.byKey(Key('calendar-row-$scheduledTasksCalendarId')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('calendar-make-default-$scheduledTasksCalendarId')),
        findsNothing,
      );
    });

    testWidgets('a new calendar is behind an add row, and its colours are '
        'named buttons', (tester) async {
      final session = await pumpCalendar(tester);
      await openCalendars(tester);

      expect(find.byKey(const Key('calendar-new-name')), findsNothing);
      await tester.tap(find.byKey(const Key('calendar-new-calendar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-new-name')), findsOneWidget);

      final green = find.byKey(const Key('calendar-new-color-#22c55e'));
      expect(tester.getSize(green).height, greaterThanOrEqualTo(44));
      expect(
        tester.getSemantics(green),
        isSemantics(
          label: 'Green',
          isButton: true,
          isSelected: false,
          hasSelectedState: true,
        ),
      );
      await tester.tap(green);
      await tester.pump();
      expect(
        tester.getSemantics(green),
        isSemantics(isSelected: true, hasSelectedState: true),
      );

      await tester.enterText(find.byKey(const Key('calendar-new-name')), 'Gym');
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-create-calendar')));
      await tester.pumpAndSettle();

      expect(session.wire.writes.single.data, {
        'name': 'Gym',
        'color': '#22c55e',
      });
      // The form folds away again once the calendar exists.
      expect(find.byKey(const Key('calendar-new-name')), findsNothing);
    });
  });
}

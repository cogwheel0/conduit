import 'dart:async';

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/pages/calendar_page_ids.dart';
import 'package:conduit/features/settings/pages/calendar_settings_page_builders.dart';
import 'package:conduit/features/settings/pages/calendar_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../calendar/views/calendar_harness.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

/// 2026-10-06 at 15:00 in the harness's UTC-4: the same day as "today".
const _laterToday = 1791313200000000000;

/// 2026-10-09 at 09:00 in UTC-4.
const _friday = 1791550800000000000;

/// 2026-11-03 at 09:00 in UTC-4.
const _november = 1793710800000000000;

final class _Rig {
  _Rig(this.tester, this.session);

  final WidgetTester tester;
  final CalendarSession session;

  ProviderContainer get container => session.container;
  CalendarWire get wire => session.wire;

  CalendarSettingsPages get module => container
      .read(settingsPageModulesProvider)
      .whereType<CalendarSettingsPages>()
      .single;

  NativeSheetDetailConfig page(String id) =>
      container.read(settingsPagesProvider)[id]!;

  bool has(String id) => container.read(settingsPagesProvider).contains(id);

  List<NativeSheetItemConfig> rows(String id) => [
    ...page(id).items,
    for (final section in page(id).sections) ...section.items,
  ];

  NativeSheetItemConfig row(String pageId, String rowId) =>
      rows(pageId).singleWhere((row) => row.id == rowId);

  Iterable<String> titles(String id) => rows(id).map((row) => row.title);

  List<String> get closed => [
    for (final MapEntry(:key, :value)
        in container.read(settingsPagesProvider).closeRequests.entries)
      for (var i = 0; i < value; i++) key,
  ];

  Future<void> open(String id) => _settle(module.hydrate(id, _l10n));

  Future<void> change(String id, Object? value) =>
      _settle(module.handleChange(id, value, _l10n));

  /// Lets [work], and what it set going, finish.
  Future<void> _settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    for (var i = 0; i < 200 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }
}

Future<_Rig> _open(
  WidgetTester tester, {
  void Function(CalendarWire wire)? configureWire,
  bool serverEnabled = true,
}) async {
  final session = await pumpCalendar(
    tester,
    location: Routes.chat,
    serverEnabled: serverEnabled,
    configureWire: configureWire,
  );
  final rig = _Rig(tester, session);
  rig.container.read(settingsPagesProvider.notifier).register([
    buildNativeLoadingDetail(l10n: _l10n, id: calendarMonthPageId, title: ''),
  ]);
  await rig.open(calendarMonthPageId);
  return rig;
}

void main() {
  group('the month page', () {
    testWidgets('shows the month with today chosen, marks the days that '
        'hold something, and lists today', (tester) async {
      final rig = await _open(tester);

      final calendar = rig.page(calendarMonthPageId).calendar!;
      expect(calendar.id, calendarGridId);
      expect(calendar.month, '2026-10-01');
      expect(calendar.selectedDay, '2026-10-06');
      // Planning is today, in Personal's colour.
      expect(calendar.marks.single.day, '2026-10-06');
      expect(calendar.marks.single.colors, [0xFF3366FF]);
      expect(
        rig.page(calendarMonthPageId).sections[0].title,
        'Today · Tue, Oct 6',
      );
      expect(rig.titles(calendarMonthPageId), contains('Planning'));
      // The month is what is read.
      final read = rig.wire.agendaRequests.last.uri.queryParameters;
      expect(read['start'], startsWith('2026-10-01T00:00:00'));
      expect(read['end'], startsWith('2026-11-01T00:00:00'));
      // At today, no Today row.
      expect(
        rig.rows(calendarMonthPageId).map((row) => row.id),
        isNot(contains(calendarTodayRowId)),
      );
    });

    testWidgets('choosing a day lists that day, and Today goes back', (
      tester,
    ) async {
      final rig = await _open(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson('ev-mine', 'cal-mine', title: 'Planning'),
          eventJson(
            'ev-fri',
            'cal-mine',
            title: 'Review',
            startAt: _friday,
            endAt: _friday + 3600000000000,
          ),
        ],
      );

      await rig.change('$calendarGridId:day', '2026-10-09');

      expect(rig.page(calendarMonthPageId).calendar!.selectedDay, '2026-10-09');
      expect(rig.titles(calendarMonthPageId), contains('Review'));
      expect(rig.titles(calendarMonthPageId), isNot(contains('Planning')));
      expect(rig.page(calendarMonthPageId).calendar!.marks.map((m) => m.day), [
        '2026-10-06',
        '2026-10-09',
      ]);

      await rig.change(calendarTodayRowId, true);
      expect(rig.page(calendarMonthPageId).calendar!.selectedDay, '2026-10-06');
      expect(rig.titles(calendarMonthPageId), contains('Planning'));
    });

    testWidgets('paging to another month chooses its first day and reads it', (
      tester,
    ) async {
      final rig = await _open(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson(
            'ev-nov',
            'cal-mine',
            title: 'Offsite',
            startAt: _november,
            endAt: _november + 3600000000000,
          ),
        ],
      );
      final reads = rig.wire.agendaRequests.length;

      await rig.change('$calendarGridId:month', '2026-11-01');

      final calendar = rig.page(calendarMonthPageId).calendar!;
      expect(calendar.month, '2026-11-01');
      expect(calendar.selectedDay, '2026-11-01');
      expect(calendar.marks.map((m) => m.day), ['2026-11-03']);
      expect(rig.wire.agendaRequests.length, greaterThan(reads));
      expect(
        rig.wire.agendaRequests.last.uri.queryParameters['start'],
        startsWith('2026-11-01T00:00:00'),
      );
      // Away from today, a row goes back to it.
      expect(
        rig.rows(calendarMonthPageId).map((row) => row.id),
        contains(calendarTodayRowId),
      );
    });

    testWidgets('a day with nothing on it says so', (tester) async {
      final rig = await _open(tester);

      await rig.change('$calendarGridId:day', '2026-10-20');

      expect(rig.titles(calendarMonthPageId), contains(_l10n.calendarDayEmpty));
    });

    testWidgets('a month that cannot be read says so, with Retry', (
      tester,
    ) async {
      final rig = await _open(
        tester,
        configureWire: (wire) => wire.failAgenda = true,
      );
      expect(
        rig.rows(calendarMonthPageId).map((row) => row.id),
        contains(calendarRetryRowId),
      );

      rig.wire.failAgenda = false;
      await rig.change(calendarRetryRowId, true);

      expect(
        rig.rows(calendarMonthPageId).map((row) => row.id),
        isNot(contains(calendarRetryRowId)),
      );
      expect(rig.titles(calendarMonthPageId), contains('Planning'));
    });

    testWidgets('a server without the calendar says it is unavailable', (
      tester,
    ) async {
      final rig = await _open(tester, serverEnabled: false);

      expect(rig.page(calendarMonthPageId).calendar, isNull);
      expect(
        rig.titles(calendarMonthPageId),
        contains(_l10n.calendarUnavailable),
      );
    });
  });

  group("an event's page", () {
    String eventPage(_Rig rig) => rig
        .rows(calendarMonthPageId)
        .firstWhere((row) => row.id.startsWith(calendarEventPagePrefix))
        .id;

    testWidgets('shows the event, and Delete removes it and closes the page', (
      tester,
    ) async {
      final rig = await _open(tester);
      final page = eventPage(rig);
      await rig.open(page);

      expect(rig.titles(page), containsAll(['Planning', 'Calendar']));
      final delete = rig
          .rows(page)
          .singleWhere((row) => row.id.startsWith('calendar.event.delete:'));
      expect(delete.confirmMessage, contains('Planning'));

      await rig.change(delete.id, true);

      expect(rig.wire.stored('ev-mine'), isNull);
      expect(rig.closed, contains(page));
    });

    testWidgets('a delete that lands after Settings closed leaves the next '
        'visit alone', (tester) async {
      final rig = await _open(tester);
      final page = eventPage(rig);
      await rig.open(page);
      final delete = rig
          .rows(page)
          .singleWhere((row) => row.id.startsWith('calendar.event.delete:'));
      final hold = rig.wire.holdWrites = Completer<void>();

      final deleting = rig.module.handleChange(delete.id, true, _l10n);
      await tester.pump(const Duration(milliseconds: 10));
      rig.module.settingsClosed();
      hold.complete();
      await rig._settle(deleting);

      expect(rig.closed, isNot(contains(page)));
    });

    testWidgets('an invited event takes an answer', (tester) async {
      final rig = await _open(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson(
            'ev-team',
            'cal-ro',
            title: 'Town Hall',
            owner: 'user-9',
            startAt: _laterToday,
            endAt: _laterToday + 3600000000000,
            attendees: [attendeeJson('ev-team', 'user-1')],
          ),
        ],
      );
      final page = eventPage(rig);
      await rig.open(page);
      final rsvp = rig
          .rows(page)
          .singleWhere((row) => row.id.startsWith('calendar.event.rsvp:'));
      expect(rsvp.kind, NativeSheetItemKind.segment);

      await rig.change(rsvp.id, 'accepted');

      expect(
        (rig.wire.stored('ev-team')!['attendees'] as List).single['status'],
        'accepted',
      );
      expect(
        rig.rows(page).singleWhere((row) => row.id == rsvp.id).value,
        'accepted',
      );
    });
  });

  group('the editor', () {
    final newEditor = calendarEditorPageId(calendarNewEventKey);
    String row(String field) => calendarEditorRowId(field, calendarNewEventKey);

    testWidgets('a new event is saved with its title and closes', (
      tester,
    ) async {
      final rig = await _open(tester);
      await rig.open(newEditor);
      expect(rig.page(newEditor).edited, isFalse);

      await rig.change(row('title'), 'Standup');
      expect(rig.page(newEditor).edited, isTrue);
      await rig.change(row('save'), true);

      final write = rig.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/events/create');
      expect((write.data as Map)['title'], 'Standup');
      expect((write.data as Map)['calendar_id'], 'cal-mine');
      expect(rig.closed, contains(newEditor));
    });

    testWidgets('a missing title is said, and nothing is sent', (tester) async {
      final rig = await _open(tester);
      await rig.open(newEditor);

      await rig.change(row('save'), true);

      expect(rig.wire.writes, isEmpty);
      expect(rig.titles(newEditor), contains(_l10n.calendarTitleRequired));
      expect(rig.closed, isEmpty);
    });

    testWidgets('a start moved past the end takes the end along', (
      tester,
    ) async {
      final rig = await _open(tester);
      await rig.open(newEditor);
      // 07:00–08:00 today, as the next whole hour after 06:00.
      expect(
        rig.row(newEditor, row('end-time')).value,
        '2026-10-06T08:00:00.000',
      );

      await rig.change(row('start-time'), '2000-01-01T10:30:00.000');

      expect(
        rig.row(newEditor, row('start-time')).value,
        '2026-10-06T10:30:00.000',
      );
      expect(
        rig.row(newEditor, row('end-time')).value,
        '2026-10-06T11:30:00.000',
      );
    });

    testWidgets('a person found is added, which marks the editor edited', (
      tester,
    ) async {
      final rig = await _open(tester);
      await rig.open(newEditor);
      final people = calendarPeoplePageId(calendarNewEventKey);
      await rig.open(people);
      expect(rig.page(people).search, isNotNull);

      await rig.change(calendarPeopleSearchId(calendarNewEventKey), 'grace');
      expect(rig.titles(people), ['Grace Hopper']);
      await rig.change(
        calendarPeopleAddId(calendarNewEventKey, 'user-2'),
        true,
      );

      expect(rig.closed, contains(people));
      expect(rig.titles(newEditor), contains('Grace Hopper'));
      expect(rig.page(newEditor).edited, isTrue);
    });

    testWidgets('an editor left keeps nothing of its draft', (tester) async {
      final rig = await _open(tester);
      await rig.open(newEditor);
      await rig.change(row('title'), 'Standup');

      rig.module.pageLeft(newEditor);
      await rig.open(newEditor);

      expect(rig.row(newEditor, row('title')).value, '');
    });
  });

  group('calendars', () {
    testWidgets('hiding a calendar reads the agenda without it', (
      tester,
    ) async {
      final rig = await _open(tester);
      await rig.open(calendarCalendarsPageId);
      final team = rig.row(
        calendarCalendarsPageId,
        calendarToggleRowId('cal-rw'),
      );
      expect(team.checked, isTrue);

      await rig.change(team.id, true);

      expect(
        rig.wire.agendaRequests.last.uri.queryParameters['calendar_ids']!.split(
          ',',
        ),
        unorderedEquals(['cal-mine', 'cal-ro']),
      );
      expect(rig.row(calendarCalendarsPageId, team.id).checked, isFalse);
    });

    testWidgets('a new calendar is made from its form', (tester) async {
      final rig = await _open(tester);
      await rig.open(calendarCalendarsPageId);
      await rig.open(calendarNewCalendarPageId);

      await rig.change(calendarNewCreateId, true);
      expect(
        rig.titles(calendarNewCalendarPageId),
        contains(_l10n.calendarNameRequired),
      );

      await rig.change(calendarNewNameRowId, 'Garden');
      await rig.change(calendarNewCreateId, true);

      expect(rig.wire.calendars.map((c) => c['name']), contains('Garden'));
      expect(rig.closed, contains(calendarNewCalendarPageId));
    });
  });

  test('a month calendar sends days as yyyy-MM-dd', () {
    expect(calendarDayFromKey('2026-02-30'), isNull);
    expect(calendarDayFromKey('2026-10-06')?.day, 6);
  });
}

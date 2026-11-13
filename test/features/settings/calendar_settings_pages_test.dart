import 'dart:async';

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/pages/calendar_page_ids.dart';
import 'package:conduit/features/settings/pages/calendar_settings_page_builders.dart';
import 'package:conduit/features/settings/pages/calendar_settings_pages.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:flutter/widgets.dart';
import 'package:conduit/features/settings/settings_controller.dart';
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

/// The Settings row queue as far as a page reads it: how many changes have
/// joined it, and which one is handled now.
final class _Queue extends SettingsController {
  int queued = 0;
  int? handling;

  @override
  int get controlsQueued => queued;

  @override
  int? get controlHandled => handling;
}

Future<_Rig> _open(
  WidgetTester tester, {
  void Function(CalendarWire wire)? configureWire,
  bool serverEnabled = true,
  SettingsController? controller,
}) async {
  final session = await pumpCalendar(
    tester,
    location: Routes.chat,
    serverEnabled: serverEnabled,
    configureWire: configureWire,
    overrides: [
      if (controller != null)
        settingsControllerProvider.overrideWithValue(controller),
    ],
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
      // Its names in the app's language, which may not be the device's.
      expect(calendar.locale, 'en');
      expect(calendar.toMap()['locale'], 'en');
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
      // New Event is the bar's "+", pushing the editor, not a row.
      final newEvent = calendarEditorPageId(calendarNewEventKey);
      expect(rig.page(calendarMonthPageId).trailingActionDetailId, newEvent);
      expect(rig.page(calendarMonthPageId).trailingActionSfSymbol, 'plus');
      expect(
        rig.rows(calendarMonthPageId).map((row) => row.id),
        isNot(contains(newEvent)),
      );
      expect(rig.has(newEvent), isTrue);
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

    testWidgets('a month paged to shows loading until it is read, not the '
        "last month's day as empty", (tester) async {
      final rig = await _open(tester);

      final paging = rig.module.handleChange(
        '$calendarGridId:month',
        '2026-11-01',
        _l10n,
      );
      expect(
        rig.rows(calendarMonthPageId).map((row) => row.id),
        contains('$calendarMonthPageId-loading'),
      );
      await rig._settle(paging);
    });

    testWidgets('a month paged to is read on its own, so the next change '
        'does not wait for it', (tester) async {
      final rig = await _open(tester);
      final held = rig.wire.holdAgenda = Completer<void>();

      final paging = rig.module.handleChange(
        '$calendarGridId:month',
        '2026-11-01',
        _l10n,
      );
      var handled = false;
      unawaited(paging.then((_) => handled = true));
      await tester.pump(const Duration(milliseconds: 50));
      // Answered while the month is still being read.
      expect(handled, isTrue);

      // The next change, a day chosen while November is still being read,
      // is handled and shown without waiting for that read.
      final choosing = rig.module.handleChange(
        '$calendarGridId:day',
        '2026-11-12',
        _l10n,
      );
      var chosen = false;
      unawaited(choosing.then((_) => chosen = true));
      await tester.pump(const Duration(milliseconds: 50));
      expect(chosen, isTrue);
      expect(rig.page(calendarMonthPageId).calendar!.selectedDay, '2026-11-12');
      expect(held.isCompleted, isFalse);

      held.complete();
      await rig._settle(Future<void>.value());
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

    testWidgets('Calendars says the agenda could not be read, with Retry', (
      tester,
    ) async {
      final rig = await _open(
        tester,
        configureWire: (wire) => wire.failAgenda = true,
      );

      await rig.open(calendarCalendarsPageId);

      expect(
        rig.rows(calendarCalendarsPageId).map((row) => row.id),
        contains(calendarRetryRowId),
      );
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

    testWidgets("shows the event's own record once read, not the agenda's "
        'older copy', (tester) async {
      final rig = await _open(tester);
      final page = eventPage(rig);
      // Changed on the server after the month was read.
      rig.wire.events = [
        eventJson(
          'ev-mine',
          'cal-mine',
          title: 'Planning, moved',
          location: 'Room 4',
        ),
      ];

      await rig.open(page);

      expect(rig.titles(page), contains('Planning, moved'));
      expect(rig.titles(page), isNot(contains('Planning')));
      expect(rig.row(page, '$page-location').subtitle, 'Room 4');
    });

    testWidgets("an account switch leaves the open pages none of the last "
        "account's event, draft or calendars", (tester) async {
      final rig = await _open(tester);
      // Settings keeps its pages' modules followed while it is open.
      final modules = rig.container.listen(
        settingsPageModulesProvider,
        (_, _) {},
      );
      addTearDown(modules.close);
      final page = eventPage(rig);
      await rig.open(page);
      final editor = calendarEditorPageId(calendarEditorKey('ev-mine'));
      await rig.open(editor);
      final title = calendarEditorRowId('title', calendarEditorKey('ev-mine'));
      await rig.change(title, 'Planning, moved');
      await rig.open(calendarCalendarsPageId);
      expect(rig.titles(page), contains('Planning'));

      rig.session.switchAccount();
      await rig._settle(Future<void>.value());

      for (final id in [page, editor, calendarCalendarsPageId]) {
        expect(rig.titles(id), [_l10n.calendarAccountChanged], reason: id);
      }
    });

    testWidgets("while the next account's agenda loads, the month shows none "
        "of the last account's", (tester) async {
      final rig = await _open(tester);
      // Settings keeps its pages' modules followed while it is open.
      final modules = rig.container.listen(
        settingsPageModulesProvider,
        (_, _) {},
      );
      addTearDown(modules.close);
      bool listsEvents() => rig
          .rows(calendarMonthPageId)
          .any((row) => row.id.startsWith(calendarEventPagePrefix));
      expect(listsEvents(), isTrue);
      final held = rig.wire.holdAgenda = Completer<void>();

      rig.session.switchAccount();
      await rig._settle(Future<void>.value());

      expect(listsEvents(), isFalse);
      expect(
        rig.rows(calendarMonthPageId).map((row) => row.id),
        contains('$calendarMonthPageId-loading'),
      );
      held.complete();
      await rig._settle(Future<void>.value());
      // The next account's own, once read.
      expect(listsEvents(), isTrue);
    });

    testWidgets("a read abandoned for a newer one does not pass the last "
        "account's agenda off as the next one's", (tester) async {
      final rig = await _open(tester);
      bool listsEvents() => rig
          .rows(calendarMonthPageId)
          .any((row) => row.id.startsWith(calendarEventPagePrefix));
      expect(listsEvents(), isTrue);
      // Settings closes; the agenda stays read, as something else follows it.
      final agenda = rig.container.listen(calendarAgendaProvider, (_, _) {});
      addTearDown(agenda.close);
      rig.module.settingsClosed();
      // The next account has nothing on its calendar.
      rig.wire.events = [];
      final first = rig.wire.holdAgenda = Completer<void>();
      rig.session.switchAccount();
      await rig._settle(Future<void>.value());
      // The agenda is read again while the next account's first read is
      // still out; that newer read is held on its own.
      final second = rig.wire.holdAgenda = Completer<void>();
      rig.container.invalidate(calendarAgendaProvider);
      await rig._settle(Future<void>.value());
      // The first read lands, for a build Riverpod no longer publishes.
      first.complete();
      await rig._settle(Future<void>.value());

      await rig.open(calendarMonthPageId);

      expect(
        listsEvents(),
        isFalse,
        reason: "the last account's agenda, kept while the next one's loads",
      );
      second.complete();
      await rig._settle(Future<void>.value());
      expect(listsEvents(), isFalse);
    });

    testWidgets("Delete offered from the event's own record is sent from it", (
      tester,
    ) async {
      final rig = await _open(
        tester,
        configureWire: (wire) =>
            wire.events = [eventJson('ev-mine', 'cal-ro', owner: 'user-9')],
      );
      final page = eventPage(rig);
      // Moved since the month was read, to a calendar the account can change.
      rig.wire.events = [eventJson('ev-mine', 'cal-mine')];
      await rig.open(page);
      final delete = rig
          .rows(page)
          .singleWhere((row) => row.id.startsWith('calendar.event.delete:'));

      await rig.change(delete.id, true);

      expect(rig.wire.stored('ev-mine'), isNull);
      expect(rig.closed, contains(page));
    });

    testWidgets("a one-off event's time is its own record's once read", (
      tester,
    ) async {
      final rig = await _open(tester);
      final page = eventPage(rig);
      await rig.open(page);
      final before = rig.row(page, '$page-title').subtitle;
      rig.module.pageLeft(page);
      // Moved two hours later since the month was read.
      const twoHours = 2 * 3600 * 1000000000;
      rig.wire.events = [
        eventJson(
          'ev-mine',
          'cal-mine',
          startAt: 1791320967123456789 + twoHours,
          endAt: 1791324567987654321 + twoHours,
        ),
      ];

      await rig.open(page);

      expect(rig.row(page, '$page-title').subtitle, isNot(before));
    });

    testWidgets('an editor open over its event keeps its rows as the event '
        'is drawn again', (tester) async {
      final rig = await _open(tester);
      final page = eventPage(rig);
      await rig.open(page);
      final editor = calendarEditorPageId(calendarEditorKey('ev-mine'));
      await rig.open(editor);
      final title = calendarEditorRowId('title', calendarEditorKey('ev-mine'));
      await rig.change(title, 'Planning, moved');

      await rig.open(page);

      expect(rig.row(editor, title).value, 'Planning, moved');
    });

    testWidgets('a change whose re-read fails says the month may be out of '
        'date, with Retry', (tester) async {
      final rig = await _open(tester);
      final page = eventPage(rig);
      await rig.open(page);
      final delete = rig
          .rows(page)
          .singleWhere((row) => row.id.startsWith('calendar.event.delete:'));

      rig.wire.failAgenda = true;
      await rig.change(delete.id, true);
      await rig.open(calendarMonthPageId);

      final ids = rig.rows(calendarMonthPageId).map((row) => row.id);
      expect(rig.titles(calendarMonthPageId), contains(_l10n.calendarStale));
      expect(ids, contains(calendarRetryRowId));
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
      // The next visit reads the month afresh: the deleted event is not on
      // it, and its page, asked for again, keeps nothing of the last visit.
      await rig.open(calendarMonthPageId);
      expect(
        rig
            .rows(calendarMonthPageId)
            .where((row) => row.id.startsWith(calendarEventPagePrefix)),
        isEmpty,
      );
      await rig.open(page);
      expect(rig.titles(page), [_l10n.calendarEventGone]);
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

    testWidgets('an invitation the agenda had not read yet takes an answer', (
      tester,
    ) async {
      Map<String, Object?> townHall({required bool invited}) => eventJson(
        'ev-team',
        'cal-ro',
        title: 'Town Hall',
        owner: 'user-9',
        startAt: _laterToday,
        endAt: _laterToday + 3600000000000,
        attendees: [if (invited) attendeeJson('ev-team', 'user-1')],
      );
      final rig = await _open(
        tester,
        configureWire: (wire) => wire.events = [townHall(invited: false)],
      );
      // Invited after the agenda was read; the event's own read has it.
      rig.wire.events = [townHall(invited: true)];
      final page = eventPage(rig);
      await rig.open(page);
      final rsvp = rig
          .rows(page)
          .singleWhere((row) => row.id.startsWith('calendar.event.rsvp:'));

      await rig.change(rsvp.id, 'accepted');

      expect(
        (rig.wire.stored('ev-team')!['attendees'] as List).single['status'],
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

    testWidgets('an all-day span moved past its end keeps its days', (
      tester,
    ) async {
      final rig = await _open(tester);
      await rig.open(newEditor);
      await rig.change(row('all-day'), true);
      await rig.change(row('end-date'), '2026-10-08T00:00:00.000');

      await rig.change(row('start-date'), '2026-10-10T00:00:00.000');

      expect(
        rig.row(newEditor, row('end-date')).value,
        startsWith('2026-10-12'),
      );
    });

    testWidgets('an editor open over the month keeps its rows as the month '
        'is drawn again', (tester) async {
      final rig = await _open(tester);
      await rig.open(newEditor);
      await rig.change(row('title'), 'Standup');

      await rig.open(calendarMonthPageId);

      expect(rig.row(newEditor, row('title')).value, 'Standup');
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

    testWidgets('a change queued on an editor since left does not reach '
        'the one opened in its place', (tester) async {
      final queue = _Queue();
      final rig = await _open(tester, controller: queue);
      final page = calendarEditorPageId(calendarNewEventKey);
      String row(String field) =>
          calendarEditorRowId(field, calendarNewEventKey);
      await rig.open(page);
      // A title typed there waits its turn behind a slower change.
      queue.queued = 1;

      // Left, and New Event opened again, before that turn came.
      rig.module.pageLeft(page);
      await rig.open(page);
      queue.handling = 1;
      await rig.change(row('title'), 'Old title');
      queue.handling = null;

      expect(
        rig.rows(page).singleWhere((r) => r.id == row('title')).value,
        isNot('Old title'),
      );
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

    testWidgets('the last calendar shown stays shown, and keeps its menu', (
      tester,
    ) async {
      final rig = await _open(tester);
      await rig.open(calendarCalendarsPageId);
      await rig.change(calendarToggleRowId('cal-rw'), true);
      await rig.change(calendarToggleRowId('cal-ro'), true);

      final last = rig.row(
        calendarCalendarsPageId,
        calendarToggleRowId('cal-mine'),
      );
      expect(last.checked, isTrue);
      expect(last.disabled, isFalse);
      final reads = rig.wire.agendaRequests.length;
      await rig.change(last.id, true);
      expect(rig.wire.agendaRequests, hasLength(reads));
      expect(rig.row(calendarCalendarsPageId, last.id).checked, isTrue);
    });

    testWidgets('a New Calendar change queued on an earlier visit does not '
        'reach the form opened since', (tester) async {
      final queue = _Queue();
      final rig = await _open(tester, controller: queue);
      await rig.open(calendarCalendarsPageId);
      await rig.open(calendarNewCalendarPageId);
      // A name typed there waits its turn behind a slower change.
      queue.queued = 1;

      // Left, and New Calendar opened again, before that turn came.
      rig.module.pageLeft(calendarNewCalendarPageId);
      await rig.open(calendarNewCalendarPageId);
      queue.handling = 1;
      await rig.change(calendarNewNameRowId, 'Old name');
      await rig.change(calendarNewCreateId, true);
      queue.handling = null;

      expect(
        rig.wire.calendars.map((c) => c['name']),
        isNot(contains('Old name')),
      );
      expect(rig.closed, isNot(contains(calendarNewCalendarPageId)));
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

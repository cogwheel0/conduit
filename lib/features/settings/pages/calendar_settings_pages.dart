import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show automationsAvailableProvider;
import 'package:conduit_core/features/calendar/calendar_draft.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../calendar/calendar_text.dart';
import '../../calendar/views/calendar_format.dart' show calendarErrorText;
import '../../navigation/providers/conversation_selection_provider.dart';
import '../../workspace/widgets/workspace_access_grants.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'calendar_page_ids.dart';
import 'calendar_settings_page_builders.dart';

/// An event's page as it stands.
final class _EventView {
  _EventView(this.event);

  /// The agenda's copy, which is what is shown and answered from.
  final CalendarEventModel event;
  CalendarEventModel? fresh;
  CalendarEventDetail detail = CalendarEventDetail.skipped;
  CalendarRsvp? answer;
  bool responding = false;
  bool deleting = false;
  String? error;
}

/// An event editor as it stands.
final class _Editor {
  _Editor(this.key);

  final String key;
  CalendarEventDraft? draft;

  /// The draft as the editor opened, which a new event is compared with to
  /// tell whether anything was changed.
  CalendarEventDraft? opened;
  String? loadFailure;
  final names = <String, String>{};
  bool titleTouched = false;
  bool saveAttempted = false;
  bool saving = false;
  String? error;

  /// Whether the editor page was last drawn as edited.
  bool shownEdited = false;
}

/// The page adding people to an editor's event, as it stands.
final class _People {
  _People(this.key);

  final String key;
  String query = '';
  List<WorkspacePrincipalPreview>? results;
  bool failed = false;

  /// Counts searches, so only the newest one's answer is shown.
  int searches = 0;
}

/// The Calendar of Settings: the month page with the chosen day's agenda,
/// an event's page and editor, the people added to an event, and the
/// calendars, which ones show, the default, and a new one.
///
/// The native iOS sheet draws these pages; where Flutter draws Settings,
/// Settings's Calendar row opens the Flutter calendar instead.
///
/// The month page's visit holds the account it opened for, and every action
/// is sent for it alone: an answer that arrives after the account changed,
/// or after the page was left, changes nothing on screen and opens nothing.
class CalendarSettingsPages extends SettingsPageModule {
  CalendarSettingsPages(this._ref);

  final Ref _ref;
  AppLocalizations? _l10n;

  /// The account the month page's visit is for; null between visits.
  CalendarOwner? _owner;
  CalendarWallTime? _month;
  CalendarWallTime? _selectedDay;
  String? _failure;

  /// Counts loads, so only the newest one's failure is said.
  int _loads = 0;
  ProviderSubscription<AsyncValue<CalendarAgendaData>>? _following;
  bool _redrawQueued = false;

  final _events = <String, _EventView>{};
  final _editors = <String, _Editor>{};
  final _people = <String, _People>{};
  bool _calendarsShown = false;
  bool _calendarsBusy = false;
  String? _calendarsError;
  CalendarNewState? _newCalendar;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  CalendarAgenda get _notifier => _ref.read(calendarAgendaProvider.notifier);
  CalendarZone get _zone => _ref.read(calendarZoneProvider);
  CalendarAgendaData? get _data => _ref.read(calendarAgendaProvider).value;

  CalendarWallTime _today() {
    final now = _ref.read(calendarClockProvider)().toUtc();
    return wallTimeAt(now.microsecondsSinceEpoch * 1000, _zone).dateOnly;
  }

  /// Whether the visit [owner] was captured for is still on, for the
  /// account still signed in.
  bool _current(CalendarOwner? owner) =>
      owner != null &&
      identical(_owner, owner) &&
      _notifier.isCurrentOwner(owner);

  @override
  bool ownsPage(String detailId) =>
      detailId == calendarMonthPageId ||
      detailId == calendarCalendarsPageId ||
      detailId == calendarNewCalendarPageId ||
      detailId.startsWith(calendarEventPagePrefix) ||
      detailId.startsWith(calendarEditorPagePrefix) ||
      detailId.startsWith(calendarPeoplePagePrefix);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    if (detailId == calendarMonthPageId) {
      await _openMonth(l10n);
      return;
    }
    // A page of a visit that ended (another account, Settings closed) has
    // nothing to show.
    if (_owner == null) return;
    if (detailId.startsWith(calendarEventPagePrefix)) {
      final key = Uri.decodeComponent(
        detailId.substring(calendarEventPagePrefix.length),
      );
      await _openEvent(l10n, key);
    } else if (detailId.startsWith(calendarEditorPagePrefix)) {
      await _openEditor(
        l10n,
        detailId.substring(calendarEditorPagePrefix.length),
      );
    } else if (detailId.startsWith(calendarPeoplePagePrefix)) {
      final key = detailId.substring(calendarPeoplePagePrefix.length);
      final people = _people[key] ??= _People(key);
      await _drawPeople(l10n, people);
      if (people.results == null && !people.failed) {
        unawaited(_search(l10n, people, people.query));
      }
    } else if (detailId == calendarCalendarsPageId) {
      _calendarsShown = true;
      _calendarsError = null;
      await _drawCalendars(l10n);
    } else if (detailId == calendarNewCalendarPageId) {
      _newCalendar ??= const CalendarNewState();
      await _drawNewCalendar(l10n);
    }
  }

  @override
  void pageLeft(String detailId) {
    if (detailId == calendarMonthPageId) {
      _end();
    } else if (detailId.startsWith(calendarEventPagePrefix)) {
      _events.remove(
        Uri.decodeComponent(detailId.substring(calendarEventPagePrefix.length)),
      );
    } else if (detailId.startsWith(calendarEditorPagePrefix)) {
      // A draft left without Done is dropped.
      final key = detailId.substring(calendarEditorPagePrefix.length);
      _editors.remove(key);
      _people.remove(key);
    } else if (detailId.startsWith(calendarPeoplePagePrefix)) {
      _people.remove(detailId.substring(calendarPeoplePagePrefix.length));
    } else if (detailId == calendarCalendarsPageId) {
      _calendarsShown = false;
      _calendarsError = null;
    } else if (detailId == calendarNewCalendarPageId) {
      _newCalendar = null;
    }
  }

  @override
  void settingsClosed() => _end();

  /// Ends the month page's visit: nothing it started shows or acts again.
  void _end() {
    _following?.close();
    _following = null;
    _owner = null;
    _month = null;
    _selectedDay = null;
    _failure = null;
    _loads++;
    _events.clear();
    _editors.clear();
    _people.clear();
    _calendarsShown = false;
    _calendarsBusy = false;
    _calendarsError = null;
    _newCalendar = null;
  }

  // -- The month page ------------------------------------------------------

  Future<void> _openMonth(AppLocalizations l10n) async {
    if (!_ref.read(calendarAvailableProvider)) {
      await _drawMonth(l10n);
      return;
    }
    if (_owner == null) {
      // A new visit: today, for the account signed in now.
      _owner = _notifier.captureOwner();
      final today = _today();
      _selectedDay = today;
      _month = calendarMonthOf(today);
      _failure = null;
    }
    _follow();
    await _drawMonth(l10n);
    // Opened, or back from a page it opened: what the server holds now.
    unawaited(_load(l10n));
  }

  /// Redraws the pages that show the agenda while it changes: a save, a
  /// delete, another account.
  void _follow() {
    if (_following != null) return;
    _following = _ref.listen<AsyncValue<CalendarAgendaData>>(
      calendarAgendaProvider,
      (_, _) => _queueRedraw(),
    );
  }

  void _queueRedraw() {
    if (_redrawQueued) return;
    _redrawQueued = true;
    scheduleMicrotask(() async {
      _redrawQueued = false;
      final l10n = _l10n;
      if (l10n == null || _owner == null) return;
      await _drawMonth(l10n);
      if (_calendarsShown) await _drawCalendars(l10n);
      for (final view in _events.values.toList()) {
        await _drawEvent(l10n, view);
      }
    });
  }

  /// Reads the month the grid shows for the visit's account.
  Future<void> _load(AppLocalizations l10n) async {
    final owner = _owner;
    final month = _month;
    if (owner == null || month == null) return;
    final load = ++_loads;
    String? failure;
    try {
      await _notifier.refresh(
        owner: owner,
        range: CalendarRange.days(
          month,
          calendarDaysInMonth(month),
          zone: _zone,
        ),
      );
      final state = _ref.read(calendarAgendaProvider);
      if (state.hasError && !state.hasValue) {
        failure = calendarErrorText(
          l10n,
          state.error!,
          fallback: l10n.calendarLoadFailed,
        );
      }
    } catch (error) {
      failure = calendarErrorText(
        l10n,
        error,
        fallback: l10n.calendarLoadFailed,
      );
    }
    if (load != _loads || !identical(_owner, owner)) return;
    _failure = failure;
    await _drawMonth(l10n);
  }

  Future<void> _drawMonth(AppLocalizations l10n) async {
    final today = _today();
    final built = buildCalendarMonthPage(
      l10n,
      calendarClockFor(l10n),
      _zone,
      CalendarMonthState(
        available: _ref.read(calendarAvailableProvider),
        month: _month ?? calendarMonthOf(today),
        selectedDay: _selectedDay ?? today,
        today: today,
        // Another account's agenda is never shown on this visit's page.
        data: _current(_owner) ? _data : null,
        failure: _failure,
        scheduledTasksOpen: _ref.read(automationsAvailableProvider),
      ),
    );
    await _surface.applyDetail(built.page, detailSheets: built.leadsTo);
  }

  /// Shows [day], paging the grid to its month when it is in another.
  Future<void> _choose(AppLocalizations l10n, CalendarWallTime day) async {
    if (_owner == null) return;
    final month = calendarMonthOf(day);
    final paged = _month == null || !month.sameDate(_month!);
    _selectedDay = day;
    _month = month;
    if (paged) _failure = null;
    await _drawMonth(l10n);
    if (paged) await _load(l10n);
  }

  /// The grid paged to [month]: today when it is this month, otherwise the
  /// month's first day, is chosen.
  Future<void> _page(AppLocalizations l10n, CalendarWallTime month) async {
    if (_month != null && month.sameDate(_month!)) return;
    final today = _today();
    await _choose(l10n, calendarMonthOf(today).sameDate(month) ? today : month);
  }

  /// Opens what a scheduled task's run made, over the app: Settings closes
  /// first.
  Future<void> _openScheduled(AppLocalizations l10n, String key) async {
    final owner = _owner;
    final entry = _data?.items
        .whereType<ScheduledTaskCalendarEntry>()
        .where((item) => item.key == key)
        .firstOrNull;
    if (entry == null ||
        !_current(owner) ||
        !_ref.read(automationsAvailableProvider)) {
      return;
    }
    final channelId = entry.resultChannelId;
    final chatId = entry.resultChatId;
    if (channelId == null && chatId == null) return;
    final bridge = NativeSheetBridge.instance;
    if (bridge.settingsSheetOpen) await bridge.dismiss();
    if (!_notifier.isCurrentOwner(owner!)) return;
    if (channelId != null) {
      NavigationService.router.goNamed(
        RouteNames.channel,
        pathParameters: {'id': channelId},
      );
      return;
    }
    final originRoute = NavigationService.currentRoute;
    final originRevision = NavigationService.currentRouteRevision;
    final when = DateTime.fromMicrosecondsSinceEpoch(entry.startAtNs ~/ 1000);
    final result = await _ref
        .read(conversationSelectionProvider.notifier)
        .select(
          Conversation(
            id: chatId!,
            title: entry.title,
            createdAt: when,
            updatedAt: when,
          ),
        );
    if (!_notifier.isCurrentOwner(owner) ||
        NavigationService.currentRoute != originRoute ||
        NavigationService.currentRouteRevision != originRevision) {
      return;
    }
    switch (result.disposition) {
      case ConversationSelectionDisposition.committed:
        NavigationService.router.go(Routes.chat);
      case ConversationSelectionDisposition.canceled:
        break;
      case ConversationSelectionDisposition.failed:
        final context = NavigationService.context;
        if (context != null && context.mounted) {
          UiUtils.showMessage(
            context,
            l10n.scheduledTaskOpenResultFailed,
            isError: true,
          );
        }
    }
  }

  // -- An event's page -----------------------------------------------------

  Future<void> _openEvent(AppLocalizations l10n, String key) async {
    var view = _events[key];
    if (view == null) {
      final event = _data?.items
          .whereType<CalendarEventModel>()
          .where((item) => item.key == key)
          .firstOrNull;
      if (event == null) {
        // Gone from the agenda since its row was drawn.
        await _surface.applyDetail(
          NativeSheetDetailConfig(
            id: calendarEventPageId(key),
            title: l10n.calendarEventDetailTitle,
            items: [
              NativeSheetItemConfig(
                id: '${calendarEventPageId(key)}-gone',
                title: l10n.calendarEventGone,
                sfSymbol: 'exclamationmark.triangle',
                kind: NativeSheetItemKind.info,
              ),
            ],
          ),
        );
        return;
      }
      view = _events[key] = _EventView(event);
      // Only a calendar the account can read has a record to read; an
      // invitation seen through the agenda alone stays the agenda's copy.
      final readable =
          _data?.calendars.any((c) => c.id == event.calendarId) ?? false;
      if (readable) {
        view.detail = CalendarEventDetail.loading;
        unawaited(_loadEvent(l10n, view));
      }
    }
    await _drawEvent(l10n, view);
  }

  Future<void> _drawEvent(AppLocalizations l10n, _EventView view) async {
    final built = buildCalendarEventPage(
      l10n,
      calendarClockFor(l10n),
      _zone,
      CalendarEventState(
        event: view.event,
        fresh: view.fresh,
        detail: view.detail,
        data: _current(_owner) ? _data : null,
        answer: view.answer,
        responding: view.responding,
        deleting: view.deleting,
        error: view.error,
      ),
    );
    await _surface.applyDetail(built.page, detailSheets: built.leadsTo);
  }

  /// Reads the event's own record. A refusal keeps only what the agenda
  /// already showed and turns editing off; the agenda is read again so what
  /// the account can see is up to date.
  Future<void> _loadEvent(AppLocalizations l10n, _EventView view) async {
    final owner = _owner;
    if (owner == null) return;
    try {
      final fetched = await _notifier.fetchEvent(view.event.id, owner: owner);
      if (!_current(owner) || !identical(_events[view.event.key], view)) {
        return;
      }
      view
        ..fresh = fetched
        ..detail = CalendarEventDetail.fresh;
    } on DioException catch (error) {
      if (!_current(owner) || !identical(_events[view.event.key], view)) {
        return;
      }
      final status = error.response?.statusCode;
      view.detail = switch (status) {
        403 => CalendarEventDetail.denied,
        404 => CalendarEventDetail.gone,
        _ => CalendarEventDetail.failed,
      };
      if (status == 403 || status == 404) unawaited(_load(l10n));
    } catch (_) {
      if (!identical(_events[view.event.key], view)) return;
      // The account changed or the calendar became unavailable: nothing
      // here may be shown as fresh, and the actions refuse on their own.
      view.detail = CalendarEventDetail.failed;
    }
    await _drawEvent(l10n, view);
  }

  /// Sends [status] as the account's answer. The choice shows at once and
  /// goes back to the earlier answer when the server refuses it.
  Future<void> _respond(
    AppLocalizations l10n,
    _EventView view,
    CalendarRsvp status,
  ) async {
    final owner = _owner;
    if (owner == null || view.responding || view.deleting) return;
    final previous = view.answer;
    view
      ..answer = status
      ..responding = true
      ..error = null;
    await _drawEvent(l10n, view);
    try {
      final stored = await _notifier.respond(view.event, status, owner: owner);
      if (!_current(owner) || !identical(_events[view.event.key], view)) {
        return;
      }
      view.answer = stored;
    } catch (error) {
      if (!_current(owner) || !identical(_events[view.event.key], view)) {
        return;
      }
      view
        ..answer = previous
        ..error = calendarErrorText(
          l10n,
          error,
          fallback: l10n.calendarRsvpFailed,
        );
    } finally {
      view.responding = false;
    }
    await _drawEvent(l10n, view);
  }

  Future<void> _delete(AppLocalizations l10n, _EventView view) async {
    final owner = _owner;
    if (owner == null || view.responding || view.deleting) return;
    view
      ..deleting = true
      ..error = null;
    await _drawEvent(l10n, view);
    try {
      await _notifier.deleteEvent(view.event, owner: owner);
      if (!_current(owner) || !identical(_events[view.event.key], view)) {
        return;
      }
      _events.remove(view.event.key);
      await _surface.closeDetail(calendarEventPageId(view.event.key));
      return;
    } catch (error) {
      if (!_current(owner) || !identical(_events[view.event.key], view)) {
        return;
      }
      view.error = calendarErrorText(
        l10n,
        error,
        fallback: l10n.calendarEventDeleteFailed,
      );
    } finally {
      view.deleting = false;
    }
    await _drawEvent(l10n, view);
  }

  // -- The event editor ----------------------------------------------------

  Future<void> _openEditor(AppLocalizations l10n, String key) async {
    final open = _editors[key];
    if (open != null) {
      // Back from adding people.
      await _drawEditor(l10n, open);
      return;
    }
    final editor = _editors[key] = _Editor(key);
    if (key == calendarNewEventKey) {
      final draft = CalendarEventDraft.create(
        calendarId: _defaultCalendarId() ?? '',
        start: _defaultStart(),
      );
      editor
        ..draft = draft
        ..opened = draft;
      await _drawEditor(l10n, editor);
      return;
    }
    await _drawEditor(l10n, editor);
    await _loadStored(l10n, editor);
  }

  /// The account's own default calendar when it can take events, otherwise
  /// the first calendar that can.
  String? _defaultCalendarId() {
    final data = _data;
    final access = data?.access;
    if (data == null || access == null) return null;
    final writable = data.writableCalendars;
    return (access.defaultCalendar(writable) ?? writable.firstOrNull)?.id;
  }

  /// The next whole hour when the chosen day is today, else 09:00 on it.
  CalendarWallTime _defaultStart() {
    final today = _today();
    final day = _selectedDay;
    if (day == null || day.sameDate(today)) {
      final now = _ref.read(calendarClockProvider)().toUtc();
      final wall = wallTimeAt(now.microsecondsSinceEpoch * 1000, _zone);
      return CalendarWallTime.fromFields(
        DateTime.utc(wall.year, wall.month, wall.day, wall.hour + 1),
      );
    }
    return CalendarWallTime(day.year, day.month, day.day, 9);
  }

  /// Reads the stored event an editor edits: never an occurrence, whose
  /// start is not the series' start, as a series is edited whole.
  Future<void> _loadStored(AppLocalizations l10n, _Editor editor) async {
    final owner = _owner;
    if (owner == null) return;
    editor.loadFailure = null;
    try {
      final stored = await _notifier.fetchEvent(
        Uri.decodeComponent(editor.key),
        owner: owner,
      );
      if (!_current(owner) || !identical(_editors[editor.key], editor)) return;
      final draft = CalendarEventDraft.edit(stored, zone: _zone);
      editor
        ..draft = draft
        ..opened = draft;
    } catch (error) {
      if (!_current(owner) || !identical(_editors[editor.key], editor)) return;
      editor.loadFailure = calendarErrorText(
        l10n,
        error,
        fallback: l10n.calendarEventLoadFailed,
      );
    }
    await _drawEditor(l10n, editor);
  }

  /// Whether leaving would lose something the user changed. An edit counts
  /// what would be sent; a new event counts any field moved from where it
  /// started.
  bool _dirty(_Editor editor) {
    final draft = editor.draft;
    final opened = editor.opened;
    if (draft == null || opened == null) return false;
    if (!draft.isNew) return draft.isChanged(zone: _zone);
    return draft.title != opened.title ||
        draft.description != opened.description ||
        draft.location != opened.location ||
        draft.calendarId != opened.calendarId ||
        draft.allDay != opened.allDay ||
        draft.start != opened.start ||
        draft.end != opened.end ||
        draft.repeat != opened.repeat ||
        draft.attendees.length != opened.attendees.length ||
        !draft.attendees.every(opened.attendees.contains);
  }

  Future<void> _drawEditor(AppLocalizations l10n, _Editor editor) async {
    final dirty = _dirty(editor);
    editor.shownEdited = dirty;
    final built = buildCalendarEditorPage(
      l10n,
      CalendarEditorState(
        key: editor.key,
        draft: editor.draft,
        loadFailure: editor.loadFailure,
        data: _current(_owner) ? _data : null,
        names: editor.names,
        titleTouched: editor.titleTouched,
        saveAttempted: editor.saveAttempted,
        saving: editor.saving,
        dirty: dirty,
        error: editor.error,
      ),
    );
    await _surface.applyDetail(built.page, detailSheets: built.leadsTo);
  }

  /// Moves the start, or the end, to [wall]. A start moved past the end
  /// takes the end along, keeping the event's length.
  CalendarEventDraft _withBoundary(
    CalendarEventDraft draft,
    CalendarWallTime wall, {
    required bool end,
  }) {
    if (end) return draft.copyWith(end: wall);
    var next = draft.copyWith(start: wall);
    final currentEnd = draft.end;
    if (currentEnd != null) {
      final before = draft.allDay
          ? currentEnd.dateOnly.compareTo(wall.dateOnly) < 0
          : currentEnd.compareTo(wall) < 0;
      if (before) {
        final length = draft.allDay
            ? Duration.zero
            : currentEnd.fields.difference(draft.start.fields).abs();
        next = next.copyWith(
          end: draft.allDay
              ? wall.dateOnly
              : CalendarWallTime.fromFields(wall.fields.add(length)),
        );
      }
    }
    return next;
  }

  Future<void> _changeEditor(
    AppLocalizations l10n,
    String field,
    String key,
    Object? value,
  ) async {
    final editor = _editors[key];
    if (editor == null) return;
    if (field == 'retry') {
      if (editor.draft == null) {
        await _drawEditor(l10n, editor);
        await _loadStored(l10n, editor);
      }
      return;
    }
    final draft = editor.draft;
    if (draft == null || editor.saving) return;
    CalendarEventDraft? next;
    switch (field) {
      case 'title' when value is String:
        next = draft.copyWith(title: value);
        editor.titleTouched = true;
      case 'location' when value is String:
        next = draft.copyWith(location: value);
      case 'description' when value is String:
        next = draft.copyWith(description: value);
      case 'all-day' when value is bool:
        next = draft.copyWith(allDay: value);
      case 'start-date' || 'start-time' || 'end-date' || 'end-time':
        final picked = value is String ? DateTime.tryParse(value) : null;
        if (picked == null) return;
        final isEnd = field.startsWith('end');
        final base = isEnd ? (draft.end ?? draft.start) : draft.start;
        final wall = field.endsWith('date')
            ? CalendarWallTime(
                picked.year,
                picked.month,
                picked.day,
                base.hour,
                base.minute,
              )
            : CalendarWallTime(
                base.year,
                base.month,
                base.day,
                picked.hour,
                picked.minute,
              );
        next = _withBoundary(draft, wall, end: isEnd);
      case 'add-end':
        next = draft.copyWith(end: draft.start);
      case 'remove-end':
        next = draft.copyWith(clearEnd: true);
      case 'repeat' when value is String:
        final repeat = CalendarRepeat.values
            .where((r) => r.name == value)
            .firstOrNull;
        if (repeat == null) return;
        next = draft.copyWith(repeat: repeat);
      case 'calendar' when value is String:
        next = draft.copyWith(calendarId: value);
      case 'save':
        await _save(l10n, editor);
        return;
    }
    if (next == null) return;
    editor
      ..draft = next
      ..error = null;
    await _drawEditor(l10n, editor);
  }

  Future<void> _removePerson(
    AppLocalizations l10n,
    String key,
    String userId,
  ) async {
    final editor = _editors[key];
    final draft = editor?.draft;
    if (editor == null || draft == null || editor.saving) return;
    editor.draft = draft.copyWith(
      attendees: [
        for (final person in draft.attendees)
          if (person.userId != userId) person,
      ],
    );
    await _drawEditor(l10n, editor);
  }

  Future<void> _save(AppLocalizations l10n, _Editor editor) async {
    final owner = _owner;
    final draft = editor.draft;
    if (owner == null || draft == null || editor.saving) return;
    if (draft.issues.isNotEmpty) {
      editor.saveAttempted = true;
      await _drawEditor(l10n, editor);
      return;
    }
    editor
      ..saving = true
      ..error = null;
    await _drawEditor(l10n, editor);
    try {
      final stored = draft.original;
      if (stored == null) {
        await _notifier.createEvent(
          draft.toCreateForm(zone: _zone),
          owner: owner,
        );
      } else {
        await _notifier.updateEvent(
          stored,
          draft.toUpdate(zone: _zone),
          owner: owner,
        );
      }
      // A save accepted for an earlier visit or account stays accepted, but
      // it must not close what is open now.
      if (!_current(owner) || !identical(_editors[editor.key], editor)) return;
      _editors.remove(editor.key);
      _people.remove(editor.key);
      if (stored == null) {
        await _surface.closeDetail(calendarEditorPageId(editor.key));
      } else {
        // The event's page goes too: what it showed is the old event.
        final view = _events.values
            .where((v) => v.event.id == stored.id)
            .firstOrNull;
        if (view != null) {
          _events.remove(view.event.key);
          await _surface.closeDetail(calendarEventPageId(view.event.key));
        } else {
          await _surface.closeDetail(calendarEditorPageId(editor.key));
        }
      }
      return;
    } catch (error) {
      if (!_current(owner) || !identical(_editors[editor.key], editor)) return;
      // The form keeps everything that was typed, whatever the reason.
      editor.error = calendarErrorText(
        l10n,
        error,
        fallback: l10n.calendarSaveFailed,
      );
    } finally {
      editor.saving = false;
    }
    await _drawEditor(l10n, editor);
  }

  // -- Adding people -------------------------------------------------------

  Future<void> _drawPeople(AppLocalizations l10n, _People people) async {
    final invited = {
      for (final person
          in _editors[people.key]?.draft?.attendees ??
              const <CalendarDraftAttendee>[])
        person.userId,
    };
    await _surface.applyDetail(
      buildCalendarPeoplePage(
        l10n,
        CalendarPeopleState(
          key: people.key,
          query: people.query,
          results: people.results,
          failed: people.failed,
          invited: invited,
        ),
      ),
    );
  }

  /// Searches people for [query]; only the newest search's answer shows.
  Future<void> _search(
    AppLocalizations l10n,
    _People people,
    String query,
  ) async {
    final owner = _owner;
    final directory = _ref.read(workspacePrincipalDirectoryProvider);
    final search = ++people.searches;
    people.query = query;
    if (directory == null || owner == null) {
      people.failed = true;
      await _drawPeople(l10n, people);
      return;
    }
    try {
      final found = await directory.searchUsers(query.trim());
      if (!_current(owner) ||
          !identical(_people[people.key], people) ||
          search != people.searches) {
        return;
      }
      people
        ..results = [
          for (final person in found)
            if (person.type == WorkspacePrincipalType.user) person,
        ]
        ..failed = false;
    } catch (error, stackTrace) {
      if (!identical(_people[people.key], people) ||
          search != people.searches) {
        return;
      }
      DebugLogger.error(
        'calendar-people-search-failed',
        scope: 'settings/calendar',
        error: error,
        stackTrace: stackTrace,
      );
      people.failed = true;
    }
    await _drawPeople(l10n, people);
  }

  /// Adds the person found as [userId] to the editor's event and goes back
  /// to the editor, which is drawn edited.
  Future<void> _addPerson(
    AppLocalizations l10n,
    String key,
    String userId,
  ) async {
    final editor = _editors[key];
    final draft = editor?.draft;
    final person = _people[key]?.results
        ?.where((p) => p.id == userId)
        .firstOrNull;
    if (editor == null || draft == null || person == null) return;
    if (!_current(_owner)) return;
    if (!draft.attendees.any((a) => a.userId == userId)) {
      editor.names[userId] = person.name;
      editor.draft = draft.copyWith(
        attendees: [
          ...draft.attendees,
          CalendarDraftAttendee(userId: userId, name: person.name),
        ],
      );
    }
    _people.remove(key);
    await _surface.closeDetail(calendarPeoplePageId(key));
    await _drawEditor(l10n, editor);
  }

  // -- Calendars -----------------------------------------------------------

  Future<void> _drawCalendars(AppLocalizations l10n) async {
    final built = buildCalendarCalendarsPage(
      l10n,
      CalendarCalendarsState(
        data: _current(_owner) ? _data : null,
        busy: _calendarsBusy,
        error: _calendarsError,
      ),
    );
    await _surface.applyDetail(built.page, detailSheets: built.leadsTo);
  }

  /// Shows or hides calendar [id]'s events. At least one calendar stays
  /// shown, and showing every one clears the filter, so calendars added
  /// later show too.
  Future<void> _toggle(AppLocalizations l10n, String id) async {
    final owner = _owner;
    final data = _data;
    if (owner == null || data == null || data.calendars.length < 2) return;
    final all = {for (final c in data.calendars) c.id};
    final next = {...calendarVisibleIds(data)};
    if (!next.remove(id)) next.add(id);
    if (next.isEmpty) return;
    final filter = next.containsAll(all) ? <String>{} : next;
    await _notifier.refresh(owner: owner, filter: filter);
  }

  Future<void> _makeDefault(AppLocalizations l10n, String id) async {
    final owner = _owner;
    final calendar = _data?.calendars.where((c) => c.id == id).firstOrNull;
    if (owner == null || calendar == null || _calendarsBusy) return;
    _calendarsBusy = true;
    _calendarsError = null;
    await _drawCalendars(l10n);
    try {
      await _notifier.makeDefault(calendar, owner: owner);
    } catch (error) {
      if (_current(owner)) {
        _calendarsError = calendarErrorText(
          l10n,
          error,
          fallback: l10n.calendarMakeDefaultFailed,
        );
      }
    } finally {
      _calendarsBusy = false;
    }
    if (_current(owner) && _calendarsShown) await _drawCalendars(l10n);
  }

  Future<void> _drawNewCalendar(AppLocalizations l10n) async {
    final state = _newCalendar;
    if (state == null) return;
    await _surface.applyDetail(buildCalendarNewPage(l10n, state));
  }

  Future<void> _changeNewCalendar(
    AppLocalizations l10n,
    String id,
    Object? value,
  ) async {
    final state = _newCalendar;
    if (state == null || state.creating) return;
    switch (id) {
      case calendarNewNameRowId when value is String:
        _newCalendar = CalendarNewState(
          name: value,
          color: state.color,
          nameMissing: state.nameMissing,
        );
      case calendarNewColorRowId when value is String:
        _newCalendar = CalendarNewState(
          name: state.name,
          color: value,
          nameMissing: state.nameMissing,
        );
      case calendarNewCreateId:
        await _createCalendar(l10n, state);
        return;
      default:
        return;
    }
    await _drawNewCalendar(l10n);
  }

  Future<void> _createCalendar(
    AppLocalizations l10n,
    CalendarNewState state,
  ) async {
    final owner = _owner;
    if (owner == null) return;
    final name = state.name.trim();
    if (name.isEmpty) {
      _newCalendar = CalendarNewState(
        name: state.name,
        color: state.color,
        nameMissing: true,
      );
      await _drawNewCalendar(l10n);
      return;
    }
    final creating = _newCalendar = CalendarNewState(
      name: state.name,
      color: state.color,
      creating: true,
    );
    await _drawNewCalendar(l10n);
    try {
      await _notifier.createCalendar(
        CalendarForm(name: name, color: state.color),
        owner: owner,
      );
      if (!_current(owner) || !identical(_newCalendar, creating)) return;
      _newCalendar = null;
      await _surface.closeDetail(calendarNewCalendarPageId);
    } catch (error) {
      if (!_current(owner) || !identical(_newCalendar, creating)) return;
      _newCalendar = CalendarNewState(
        name: state.name,
        color: state.color,
        error: calendarErrorText(
          l10n,
          error,
          fallback: l10n.calendarCreateFailed,
        ),
      );
      await _drawNewCalendar(l10n);
    }
  }

  // -- Row changes ---------------------------------------------------------

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (!id.startsWith(calendarRowPrefix)) return false;
    _l10n = l10n;
    final rest = id.substring(calendarRowPrefix.length);
    if (id == '$calendarGridId:month') {
      final month = calendarDayFromKey(value);
      if (month != null) await _page(l10n, calendarMonthOf(month));
    } else if (id == '$calendarGridId:day') {
      final day = calendarDayFromKey(value);
      if (day != null) await _choose(l10n, day);
    } else if (id == calendarTodayRowId) {
      await _choose(l10n, _today());
    } else if (id == calendarRetryRowId) {
      _failure = null;
      await _drawMonth(l10n);
      await _load(l10n);
    } else if (rest.startsWith('scheduled:')) {
      await _openScheduled(
        l10n,
        Uri.decodeComponent(rest.substring('scheduled:'.length)),
      );
    } else if (rest.startsWith('event.')) {
      final action = rest.substring('event.'.length);
      final split = action.indexOf(':');
      if (split < 0) return true;
      final key = Uri.decodeComponent(action.substring(split + 1));
      final view = _events[key];
      if (view == null || !_current(_owner)) return true;
      switch (action.substring(0, split)) {
        case 'rsvp':
          final status = CalendarRsvp.values
              .where((s) => s.name == value)
              .firstOrNull;
          if (status != null && status != CalendarRsvp.pending) {
            await _respond(l10n, view, status);
          }
        case 'delete':
          await _delete(l10n, view);
      }
    } else if (rest.startsWith('editor.person-remove:')) {
      final parts = rest.substring('editor.person-remove:'.length).split(':');
      if (parts.length == 2) {
        await _removePerson(l10n, parts[0], Uri.decodeComponent(parts[1]));
      }
    } else if (rest.startsWith('editor.')) {
      final field = rest.substring('editor.'.length);
      final split = field.indexOf(':');
      if (split < 0) return true;
      await _changeEditor(
        l10n,
        field.substring(0, split),
        field.substring(split + 1),
        value,
      );
    } else if (rest.startsWith('people.search:')) {
      final people = _people[rest.substring('people.search:'.length)];
      if (people != null && value is String) {
        await _search(l10n, people, value);
      }
    } else if (rest.startsWith('people.add:')) {
      final parts = rest.substring('people.add:'.length).split(':');
      if (parts.length == 2) {
        await _addPerson(l10n, parts[0], Uri.decodeComponent(parts[1]));
      }
    } else if (rest.startsWith('calendars.toggle:')) {
      await _toggle(
        l10n,
        Uri.decodeComponent(rest.substring('calendars.toggle:'.length)),
      );
    } else if (rest.startsWith('calendars.default:')) {
      await _makeDefault(
        l10n,
        Uri.decodeComponent(rest.substring('calendars.default:'.length)),
      );
    } else if (rest.startsWith('new.')) {
      await _changeNewCalendar(l10n, id, value);
    }
    return true;
  }
}

import 'dart:async';
import 'dart:math';

import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show automationErrorDetail;
import 'package:conduit_core/features/calendar/calendar_agenda_layout.dart'
    hide CalendarAgendaDay;
import 'package:conduit_core/features/calendar/calendar_draft.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart' as time;
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart'
    as cal;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// `calendar.*`: the account's Open WebUI calendars and the agenda over them,
/// through core's [CalendarAgenda], as the phone's Calendar page uses it.
///
/// Times go out as wall clocks in the Mac's zone (core's device zone), so the
/// window only writes them. Every change is admitted for the account it was
/// asked for: an editor holds the account it was opened for, and a Save after
/// a switch is refused before anything is sent.
final class CalendarService {
  CalendarService(this._container, {EventBus? events}) : _events = events;

  final ProviderContainer _container;
  final EventBus? _events;

  /// Held from the first `calendar.agenda` on, so the agenda is not read
  /// before a window asks for it, and each change after that is announced.
  ProviderSubscription<AsyncValue<cal.CalendarAgendaData>>? _watch;

  /// Open editors by token, oldest first; only the last few are kept.
  final Map<String, _EditorSession> _editors = <String, _EditorSession>{};
  static const int _maxEditors = 8;
  final Random _random = Random.secure();

  cal.CalendarAgenda get _notifier =>
      _container.read(cal.calendarAgendaProvider.notifier);
  time.CalendarZone get _zone => _container.read(cal.calendarZoneProvider);

  void dispose() {
    _watch?.close();
    _watch = null;
  }

  void _ensureWatching() {
    _watch ??= _container.listen<AsyncValue<cal.CalendarAgendaData>>(
      cal.calendarAgendaProvider,
      (previous, next) {
        if (next.isLoading && !next.hasValue) return;
        _events?.emit(ConduitEventSpecs.calendarChanged, null);
      },
    );
  }

  // ── The agenda ─────────────────────────────────────────────────────────

  Future<CalendarAgenda> agenda(CalendarAgendaQuery query) async {
    if (!await _available()) {
      return const CalendarAgenda(failure: 'unavailable');
    }
    _ensureWatching();
    cal.CalendarAgendaData? data;
    try {
      data = await readSettled(_container, cal.calendarAgendaProvider.future);
    } on Object {
      // Shown as the failure below; the window's Try Again is the retry.
    }
    final owner = _notifier.captureOwner();
    if (owner == null) {
      return const CalendarAgenda(failure: 'accountChanged');
    }
    final zone = _zone;
    time.CalendarRange? range;
    final shown = data?.range;
    final days = shown?.dayCount ?? cal.calendarAgendaDays;
    if (query.today) {
      range = time.CalendarRange.days(_today(zone), days, zone: zone);
    } else if (query.firstDay case final first?) {
      range = time.CalendarRange.days(_wall(first), days, zone: zone);
    } else if (query.shift != 0 && shown != null) {
      range = shown.shifted(query.shift * shown.dayCount, zone: zone);
    }
    if (range != null || query.refresh || data == null) {
      await _notifier.refresh(owner: owner, range: range);
    }
    return _agendaOf(_container.read(cal.calendarAgendaProvider));
  }

  Future<CalendarAgenda> setVisible(CalendarVisibility edit) async {
    final data = await _requireData();
    final shown = calendarVisibleIds(data).contains(edit.calendarId);
    if (shown != edit.visible) {
      final filter = toggledCalendarFilter(data, edit.calendarId);
      if (filter != null) {
        await _notifier.refresh(owner: _owner(), filter: filter);
      }
    }
    return _agendaOf(_container.read(cal.calendarAgendaProvider));
  }

  Future<CalendarAgenda> makeDefault(CalendarRef ref) async {
    final data = await _requireData();
    final calendar = _calendar(data, ref.calendarId);
    await _guard(() => _notifier.makeDefault(calendar, owner: _owner()));
    return _agendaOf(_container.read(cal.calendarAgendaProvider));
  }

  Future<CalendarDto> createCalendar(CalendarCreate create) async {
    final name = create.name.trim();
    if (name.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'nameRequired'},
        debugMessage: 'a calendar needs a name',
      );
    }
    final created = await _guard(
      () => _notifier.createCalendar(
        CalendarForm(name: name, color: _hex(create.color)),
        owner: _owner(),
      ),
    );
    final data = _container.read(cal.calendarAgendaProvider).asData?.value;
    return _calendarDto(created, data);
  }

  // ── Events ─────────────────────────────────────────────────────────────

  Future<CalendarEventDetail> event(CalendarItemRef ref) async {
    final data = await _requireData();
    final item = _item(data, ref.key);
    final day = _firstDayOf(item, data);
    final dto = _itemDto(item, day, data);
    switch (item) {
      case ScheduledTaskCalendarEntry():
        return CalendarEventDetail(item: dto, status: 'skipped');
      case final CalendarEventModel event:
        var status = 'skipped';
        CalendarEventModel? fresh;
        final readable = data.calendars.any((c) => c.id == event.calendarId);
        if (readable) {
          try {
            fresh = await _notifier.fetchEvent(event.id, owner: _owner());
            status = 'fresh';
          } on DioException catch (error) {
            final code = error.response?.statusCode;
            status = switch (code) {
              403 => 'denied',
              404 => 'gone',
              _ => 'failed',
            };
            if (code == 403 || code == 404) unawaited(_reloadQuietly());
          } on Object {
            status = 'failed';
          }
        }
        return _detail(event, dto, data, fresh: fresh, status: status);
    }
  }

  CalendarEventDetail _detail(
    CalendarEventModel event,
    CalendarItemDto dto,
    cal.CalendarAgendaData data, {
    CalendarEventModel? fresh,
    required String status,
    CalendarRsvp? answer,
  }) {
    final access = data.access;
    final shown = fresh ?? event;
    final calendar = _calendarOrNull(data, event.calendarId);
    final invited = access?.canRsvp(shown) ?? false;
    final own = answer ?? access?.ownAnswer(shown);
    final canEdit =
        access != null &&
        access.canEdit(event, data.calendars) &&
        status != 'denied' &&
        status != 'gone';
    return CalendarEventDetail(
      item: dto.copyWith(
        invited: invited,
        answer: invited ? (own ?? CalendarRsvp.pending).wire : null,
        editable: canEdit,
      ),
      description: event.description ?? fresh?.description,
      calendarName: calendar?.name,
      calendarColor: calendar?.color,
      repeat: CalendarRepeat.fromRule(event.rrule).name,
      organizer: event.organizerName,
      attendeeCount: shown.attendees.length,
      canEdit: canEdit,
      status: status,
    );
  }

  Future<CalendarAgenda> deleteEvent(CalendarItemRef ref) async {
    final data = await _requireData();
    final event = _storedEvent(data, ref.key);
    await _guard(() => _notifier.deleteEvent(event, owner: _owner()));
    return _agendaOf(_container.read(cal.calendarAgendaProvider));
  }

  Future<CalendarEventDetail> respond(CalendarRsvpEdit edit) async {
    final data = await _requireData();
    final event = _storedEvent(data, edit.key);
    final status = switch (edit.answer) {
      'accepted' => CalendarRsvp.accepted,
      'tentative' => CalendarRsvp.tentative,
      'declined' => CalendarRsvp.declined,
      _ => throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'no answer "${edit.answer}"',
      ),
    };
    final stored = await _guard(
      () => _notifier.respond(event, status, owner: _owner()),
    );
    // A declined invitation leaves the agenda, so the sheet keeps the event
    // it was opened on, with the answer the server stored.
    final dto = _itemDto(event, _firstDayOf(event, data), data);
    return _detail(event, dto, data, status: 'fresh', answer: stored);
  }

  // ── The editor ─────────────────────────────────────────────────────────

  Future<CalendarEditor> editor(CalendarEditorOpen open) async {
    final data = await _requireData();
    final owner = _owner();
    final zone = _zone;
    final CalendarEventDraft draft;
    final key = open.key;
    if (key == null) {
      draft = CalendarEventDraft.create(
        calendarId: calendarDefaultCalendarId(data) ?? '',
        start: calendarDefaultStart(
          day: open.day == null ? null : _wall(open.day!),
          now: _now(zone),
        ),
      );
    } else {
      final item = _storedEvent(data, key);
      // The series as stored, not the occurrence the agenda showed.
      final stored = await _guard(
        () => _notifier.fetchEvent(item.id, owner: owner),
      );
      draft = CalendarEventDraft.edit(stored, zone: zone);
    }
    final token = _newToken();
    final session = _EditorSession(owner, draft, zone);
    _editors[token] = session;
    while (_editors.length > _maxEditors) {
      _editors.remove(_editors.keys.first);
    }
    return CalendarEditor(
      token: token,
      isNew: draft.isNew,
      series: draft.original?.isRecurring ?? false,
      rule: draft.repeat == CalendarRepeat.custom
          ? draft.original?.rrule
          : null,
      fields: session.fieldsOf(draft),
      calendars: [
        for (final calendar in data.writableCalendars)
          _calendarDto(calendar, data),
      ],
    );
  }

  Future<CalendarDraftState> checkDraft(CalendarDraftEdit edit) async {
    final session = _session(edit.token);
    var draft = session.apply(edit.fields);
    if (edit.movedStart case final start?) {
      draft = draft.withStart(_wall(start));
    }
    return session.stateOf(draft);
  }

  Future<CalendarDraftState> save(CalendarDraftEdit edit) async {
    final session = _session(edit.token);
    var draft = session.apply(edit.fields);
    if (edit.movedStart case final start?) {
      draft = draft.withStart(_wall(start));
    }
    final state = session.stateOf(draft);
    if (state.issues.isNotEmpty) return state;
    final original = draft.original;
    final saved = await _guard(() async {
      if (original == null) {
        return _notifier.createEvent(
          draft.toCreateForm(zone: session.zone),
          owner: session.owner,
        );
      }
      return _notifier.updateEvent(
        original,
        draft.toUpdate(zone: session.zone),
        owner: session.owner,
      );
    });
    // The editor goes on as an edit of the event saved: what the window typed
    // while this save was out is saved to it next, never made again.
    if (_editors.containsKey(edit.token)) {
      _editors[edit.token] = session.continued(
        CalendarEventDraft.edit(saved, zone: session.zone),
      );
    }
    return state.copyWith(saved: true);
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Whether the account may use the calendar, once the server's config and
  /// the account's permissions have loaded (both read as no while loading).
  Future<bool> _available() async {
    if (_container.read(cal.calendarAvailableProvider)) return true;
    if (_container.read(apiServiceProvider) == null) return false;
    // The config answers with its cached copy first and refreshes behind
    // it, so right after a sign-in the rule can still read the old one.
    try {
      await _container
          .read(backendConfigProvider.notifier)
          .refresh()
          .timeout(const Duration(seconds: 10));
      await readSettled(
        _container,
        userPermissionsProvider.future,
      ).timeout(const Duration(seconds: 10));
    } on Object {
      // A failed read leaves the rule at its answer, which is no.
    }
    return _container.read(cal.calendarAvailableProvider);
  }

  _EditorSession _session(String token) =>
      _editors[token] ??
      (throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: const <String, String>{'reason': 'editorClosed'},
        debugMessage: 'no open event editor "$token"',
      ));

  String _newToken() =>
      List.generate(12, (_) => _random.nextInt(36).toRadixString(36)).join();

  Future<cal.CalendarAgendaData> _requireData() async {
    if (!await _available()) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        args: <String, String>{'reason': 'unavailable'},
      );
    }
    _ensureWatching();
    try {
      return await readSettled(_container, cal.calendarAgendaProvider.future);
    } on Object catch (error) {
      throw _rpcError(error);
    }
  }

  cal.CalendarOwner _owner() =>
      _notifier.captureOwner() ??
      (throw const RpcError(
        code: ConduitErrorCodes.conflict,
        args: <String, String>{'reason': 'accountChanged'},
        debugMessage: 'no Open WebUI account holds a calendar now',
      ));

  Future<void> _reloadQuietly() async {
    final owner = _notifier.captureOwner();
    if (owner == null) return;
    try {
      await _notifier.refresh(owner: owner);
    } on Object {
      // The agenda marks itself stale.
    }
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RpcError {
      rethrow;
    } on Object catch (error) {
      throw _rpcError(error);
    }
  }

  /// [error] as a refusal the window can word: `reason` names it.
  static RpcError _rpcError(Object error) {
    if (error is cal.CalendarOwnerChangedException) {
      return const RpcError(
        code: ConduitErrorCodes.conflict,
        args: <String, String>{'reason': 'accountChanged'},
      );
    }
    if (error is cal.CalendarUnavailableException) {
      return const RpcError(
        code: ConduitErrorCodes.unsupported,
        args: <String, String>{'reason': 'unavailable'},
      );
    }
    if (error is cal.CalendarPermissionException) {
      return RpcError(
        code: ConduitErrorCodes.unauthorized,
        args: <String, String>{'reason': error.denial.name},
      );
    }
    if (error is DioException) {
      final status = error.response?.statusCode;
      final detail = automationErrorDetail(error);
      return switch (status) {
        403 => RpcError(
          code: ConduitErrorCodes.unauthorized,
          args: const <String, String>{'reason': 'notWritable'},
          debugMessage: detail,
        ),
        404 => RpcError(
          code: ConduitErrorCodes.notFound,
          args: const <String, String>{'reason': 'notFound'},
          debugMessage: detail,
        ),
        null => RpcError(
          code: ConduitErrorCodes.connectionFailed,
          debugMessage: error.message,
          retryable: true,
        ),
        _ => RpcError(
          code: ConduitErrorCodes.serverError,
          args: <String, String>{'status': '$status', 'detail': ?detail},
          debugMessage: detail,
          retryable: true,
        ),
      };
    }
    return RpcError(
      code: ConduitErrorCodes.internal,
      debugMessage: error.toString(),
    );
  }

  CalendarAgendaItem _item(cal.CalendarAgendaData data, String key) {
    for (final item in data.items) {
      if (item.key == key) return item;
    }
    throw RpcError(
      code: ConduitErrorCodes.notFound,
      args: const <String, String>{'reason': 'notFound'},
      debugMessage: 'no agenda item "$key"',
    );
  }

  CalendarEventModel _storedEvent(cal.CalendarAgendaData data, String key) {
    final item = _item(data, key);
    if (item is CalendarEventModel) return item;
    throw RpcError(
      code: ConduitErrorCodes.unauthorized,
      args: <String, String>{
        'reason': cal.CalendarDenial.scheduledTaskEntry.name,
      },
      debugMessage: 'a scheduled task entry is not an event',
    );
  }

  CalendarModel _calendar(cal.CalendarAgendaData data, String id) =>
      _calendarOrNull(data, id) ??
      (throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: const <String, String>{'reason': 'notFound'},
        debugMessage: 'no calendar "$id"',
      ));

  static CalendarModel? _calendarOrNull(
    cal.CalendarAgendaData data,
    String id,
  ) {
    for (final calendar in data.calendars) {
      if (calendar.id == id) return calendar;
    }
    return null;
  }

  time.CalendarWallTime _today(time.CalendarZone zone) => _now(zone).dateOnly;

  time.CalendarWallTime _now(time.CalendarZone zone) {
    final now = _container.read(cal.calendarClockProvider)().toUtc();
    return time.wallTimeAt(now.microsecondsSinceEpoch * 1000, zone);
  }

  /// The first day of the range [item] is listed under.
  time.CalendarWallTime _firstDayOf(
    CalendarAgendaItem item,
    cal.CalendarAgendaData data,
  ) {
    for (final day in groupAgendaByDay([item], data.range, _zone)) {
      return day.day;
    }
    return time.wallTimeAt(item.startAtNs, _zone).dateOnly;
  }

  CalendarAgenda _agendaOf(AsyncValue<cal.CalendarAgendaData> state) {
    final data = state.asData?.value;
    if (data == null) {
      final error = state.error;
      return CalendarAgenda(
        available: true,
        failure: error is cal.CalendarOwnerChangedException
            ? 'accountChanged'
            : error is cal.CalendarUnavailableException
            ? 'unavailable'
            : 'failed',
      );
    }
    final zone = _zone;
    return CalendarAgenda(
      available: true,
      stale: data.stale,
      firstDay: _dto(data.range.firstDay),
      endDay: _dto(data.range.endDay),
      dayCount: data.range.dayCount,
      today: _dto(_today(zone)),
      calendars: [
        for (final calendar in data.calendars) _calendarDto(calendar, data),
      ],
      filterable: calendarsFilterable(data),
      scheduledTasks: data.scheduledTasksVisible,
      canCreate: data.writableCalendars.isNotEmpty,
      days: [
        for (final day in groupAgendaByDay(data.items, data.range, zone))
          CalendarAgendaDay(
            day: _dto(day.day),
            items: [
              for (final item in day.items) _itemDto(item, day.day, data),
            ],
          ),
      ],
    );
  }

  CalendarDto _calendarDto(
    CalendarModel calendar,
    cal.CalendarAgendaData? data,
  ) {
    final access = data?.access;
    final owned = access?.owns(calendar) ?? false;
    return CalendarDto(
      id: calendar.id,
      name: calendar.name,
      color: calendar.color,
      isDefault: owned && calendar.isDefault,
      scheduled: calendar.isVirtual,
      owned: owned,
      writable: access?.canWrite(calendar) ?? false,
      canMakeDefault:
          (access?.canMakeDefault(calendar) ?? false) && !calendar.isDefault,
      visible: data == null || calendarVisibleIds(data).contains(calendar.id),
    );
  }

  CalendarItemDto _itemDto(
    CalendarAgendaItem item,
    time.CalendarWallTime day,
    cal.CalendarAgendaData data,
  ) {
    final zone = _zone;
    switch (item) {
      case final CalendarEventModel event:
        final access = data.access;
        final calendar = _calendarOrNull(data, event.calendarId);
        final invited = access?.canRsvp(event) ?? false;
        final span = time.daySpan(
          startNs: event.startAtNs,
          endNs: event.endAtNs,
          zone: zone,
        );
        return CalendarItemDto(
          key: event.key,
          kind: 'event',
          id: event.id,
          calendarId: event.calendarId,
          title: event.title,
          location: event.location,
          color: event.color ?? calendar?.color,
          recurring: event.isRecurring,
          allDay: event.allDay,
          cancelled: event.isCancelled,
          start: _dto(time.wallTimeAt(event.startAtNs, zone)),
          end: event.endAtNs == null
              ? null
              : _dto(time.wallTimeAt(event.endAtNs!, zone)),
          lastDay: _dto(span.last),
          time: _rowTime(
            calendarRowTime(
              startNs: event.startAtNs,
              endNs: event.endAtNs,
              allDay: event.allDay,
              zone: zone,
              day: day,
            ),
          ),
          invited: invited,
          answer: invited
              ? (access?.ownAnswer(event) ?? CalendarRsvp.pending).wire
              : null,
          editable: access?.canEdit(event, data.calendars) ?? false,
        );
      case final ScheduledTaskCalendarEntry entry:
        final calendar = data.calendars.where((c) => c.isVirtual).firstOrNull;
        final start = time.wallTimeAt(entry.startAtNs, zone);
        return CalendarItemDto(
          key: entry.key,
          kind: 'scheduled',
          id: entry.id,
          calendarId: scheduledTasksCalendarId,
          title: entry.title,
          color: calendar?.color,
          start: _dto(start),
          lastDay: _dto(start.dateOnly),
          time: _rowTime(CalendarRowAt(start)),
          automationId: entry.automationId,
          runId: entry.runId,
          resultChatId: entry.resultChatId,
          resultChannelId: entry.resultChannelId,
          scheduledState: !entry.isRun
              ? 'upcoming'
              : entry.failed
              ? 'failed'
              : 'finished',
        );
    }
  }

  static CalendarRowTimeDto _rowTime(CalendarRowTime row) => switch (row) {
    CalendarRowAllDay() => const CalendarRowTimeDto(kind: 'allDay'),
    CalendarRowAt(:final start) => CalendarRowTimeDto(
      kind: 'at',
      start: _dto(start),
    ),
    CalendarRowRange(:final start, :final end) => CalendarRowTimeDto(
      kind: 'range',
      start: _dto(start),
      end: _dto(end),
    ),
    CalendarRowStartsAt(:final start) => CalendarRowTimeDto(
      kind: 'startsAt',
      start: _dto(start),
    ),
    CalendarRowEndsAt(:final end) => CalendarRowTimeDto(
      kind: 'endsAt',
      end: _dto(end),
    ),
  };

  static CalendarWallTime _dto(time.CalendarWallTime wall) => CalendarWallTime(
    year: wall.year,
    month: wall.month,
    day: wall.day,
    hour: wall.hour,
    minute: wall.minute,
  );

  static time.CalendarWallTime _wall(CalendarWallTime dto) =>
      time.CalendarWallTime(dto.year, dto.month, dto.day, dto.hour, dto.minute);

  /// `#rrggbb`, or null for anything else (the server stores what it is
  /// sent).
  static String? _hex(String? color) {
    final value = color?.trim() ?? '';
    final match = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(value);
    return match == null ? null : '#${match.group(1)!.toLowerCase()}';
  }
}

/// One open event editor: the account it was opened for and the draft it
/// started from, which every later check and the Save build on.
final class _EditorSession {
  _EditorSession(this.owner, this.opened, this.zone);

  final cal.CalendarOwner owner;
  final CalendarEventDraft opened;
  final time.CalendarZone zone;

  /// Names the editor was given for people it invited.
  final Map<String, String> names = <String, String>{};

  /// The same editor, now editing [saved].
  _EditorSession continued(CalendarEventDraft saved) =>
      _EditorSession(owner, saved, zone)..names.addAll(names);

  CalendarEventFields fieldsOf(CalendarEventDraft draft) => CalendarEventFields(
    title: draft.title,
    description: draft.description,
    location: draft.location,
    calendarId: draft.calendarId,
    allDay: draft.allDay,
    start: CalendarService._dto(draft.start),
    end: draft.end == null ? null : CalendarService._dto(draft.end!),
    repeat: draft.repeat.name,
    attendees: [
      for (final person in draft.attendees)
        CalendarAttendeeDto(
          userId: person.userId,
          name: person.name ?? names[person.userId],
        ),
    ],
  );

  /// [fields] over the draft this editor opened with, so what the user did
  /// not touch keeps its stored value.
  CalendarEventDraft apply(CalendarEventFields fields) {
    final repeat =
        CalendarRepeat.values
            .where((r) => r.name == fields.repeat)
            .firstOrNull ??
        opened.repeat;
    final metaOf = {
      for (final person in opened.attendees) person.userId: person.meta,
    };
    for (final person in fields.attendees) {
      final name = person.name;
      if (name != null && name.isNotEmpty) names[person.userId] = name;
    }
    final end = fields.end;
    return opened.copyWith(
      title: fields.title,
      description: fields.description,
      location: fields.location,
      calendarId: fields.calendarId,
      allDay: fields.allDay,
      start: CalendarService._wall(fields.start),
      end: end == null ? null : CalendarService._wall(end),
      clearEnd: end == null,
      // A custom rule cannot be chosen, only kept.
      repeat: repeat == CalendarRepeat.custom ? opened.repeat : repeat,
      attendees: [
        for (final person in fields.attendees)
          CalendarDraftAttendee(
            userId: person.userId,
            name: person.name ?? names[person.userId],
            meta: metaOf[person.userId],
          ),
      ],
    );
  }

  CalendarDraftState stateOf(CalendarEventDraft draft) => CalendarDraftState(
    fields: fieldsOf(draft),
    issues: [for (final issue in draft.issues) issue.name],
    changed: draft.isNew
        ? fieldsOf(draft) != fieldsOf(opened)
        : draft.isChanged(zone: zone),
  );
}

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show automationsPermitted;
import 'package:conduit_core/features/calendar/calendar_access.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';

part 'calendar_providers.g.dart';

/// Thrown when the signed-in account may not use the calendar: the server has
/// it off, or the account lacks the `features.calendar` permission. Nothing was
/// sent.
final class CalendarUnavailableException implements Exception {
  const CalendarUnavailableException();

  @override
  String toString() =>
      'CalendarUnavailableException: the calendar is not available for this '
      'account';
}

/// Thrown when the account an agenda, event or editor was opened for is no
/// longer the signed-in one. Nothing was sent, so a form can keep its input.
final class CalendarOwnerChangedException extends StateError {
  CalendarOwnerChangedException()
    : super('The account changed since this calendar was opened');
}

/// Why an operation was refused before any request was made.
enum CalendarDenial {
  /// The event's calendar is not one the account can write to.
  notWritable,

  /// A move's destination calendar is not one the account can write to. The
  /// server requires write access at both ends.
  destinationNotWritable,

  /// The account is not one of the event's invited people, so there is no
  /// answer of its own to give.
  notInvited,

  /// The entry is the server's projection of a scheduled task, not a stored
  /// event.
  scheduledTaskEntry,

  /// Only the account's own stored calendars can be its default.
  notOwnCalendar,

  /// The calendars have not been loaded, so nothing can be checked against
  /// them.
  notLoaded,
}

final class CalendarPermissionException implements Exception {
  const CalendarPermissionException(this.denial);

  final CalendarDenial denial;

  @override
  String toString() => 'CalendarPermissionException(${denial.name})';
}

/// The account an agenda, event or editor was opened for.
///
/// The notifier outlives account switches and the [ApiService] can stay the
/// same across them, so holding either says nothing about whose calendars a
/// later Save, Delete or RSVP would touch. Capture the owner synchronously when
/// the surface opens, before any await, and pass it to every operation. An
/// operation is refused before any request once the API, auth session or server
/// no longer match, and its request is bound to the captured [ApiAuthSnapshot]
/// so a credential change that lands later cannot redirect it.
@immutable
final class CalendarOwner {
  const CalendarOwner._(this._api, this._auth, this._ownership, this.userId);

  final ApiService _api;
  final ApiAuthSnapshot _auth;
  final OpenWebUiCacheOwnershipSnapshot _ownership;

  /// The signed-in account's id when the surface opened.
  final String userId;
}

/// The agenda for one stretch of days, with the calendars it came from.
@immutable
final class CalendarAgendaData {
  const CalendarAgendaData({
    required this.range,
    this.calendars = const <CalendarModel>[],
    this.access,
    this.filter = const <String>{},
    this.items = const <CalendarAgendaItem>[],
    this.scheduledTasksVisible = false,
    this.stale = false,
  });

  final CalendarRange range;

  /// Every calendar the server lists for the account, the virtual
  /// scheduled-tasks calendar included when it is allowed.
  final List<CalendarModel> calendars;

  /// What the account may do with them. Null before the first load.
  final CalendarAccess? access;

  /// The calendars the agenda is limited to; empty means all of them.
  final Set<String> filter;

  /// Events and scheduled-task entries in the range, by start.
  final List<CalendarAgendaItem> items;

  /// Whether the scheduled-task entries are offered: the account may also use
  /// scheduled tasks, so each entry has a task to open.
  final bool scheduledTasksVisible;

  /// True when a change went through but reading the agenda back failed, so
  /// [items] may not show it yet.
  final bool stale;

  /// The stored calendars an event may be created in or moved to.
  List<CalendarModel> get writableCalendars =>
      access?.writable(calendars) ?? const <CalendarModel>[];

  CalendarAgendaData copyWith({bool? stale}) => CalendarAgendaData(
    range: range,
    calendars: calendars,
    access: access,
    filter: filter,
    items: items,
    scheduledTasksVisible: scheduledTasksVisible,
    stale: stale ?? this.stale,
  );
}

/// Whether [user] may use the calendar on [serverId].
///
/// Open WebUI offers it only when the server's `calendar.enable` is on and the
/// account is an admin or holds `features.calendar`. A missing permission means
/// denied. [config] counts only when it was fetched from [serverId].
bool calendarPermitted({
  required BackendConfig? config,
  required String serverId,
  required User? user,
  required Map<String, dynamic> permissions,
}) {
  if (config == null ||
      config.serverId != serverId ||
      config.enableCalendar != true) {
    return false;
  }
  if (user?.role == 'admin') return true;
  final features = permissions['features'];
  return features is Map && features['calendar'] == true;
}

/// Whether the signed-in account can use the calendar right now, for surfaces
/// deciding whether to show it. False while the inputs load. Flutter Settings
/// and the native iOS sheet both read this, so they cannot disagree about when
/// the entry exists.
///
/// This only reads [userPermissionsProvider] and [backendConfigProvider]. The
/// operations recheck the same rule themselves.
final calendarAvailableProvider = Provider<bool>((ref) {
  final api = ref.watch(apiServiceProvider);
  ref.watch(openWebUiAuthSessionEpochProvider);
  final user = ref.watch(currentUserProvider2);
  final config = ref.watch(backendConfigProvider).asData?.value;
  final permissions =
      ref.watch(userPermissionsProvider).asData?.value ??
      (user?.role == 'admin' ? const <String, dynamic>{} : null);
  if (api == null || permissions == null) return false;
  return calendarPermitted(
    config: config,
    serverId: api.serverConfig.id,
    user: user,
    permissions: permissions,
  );
});

/// The zone the calendar shows and edits in: the device's, which the user chose
/// over the account's.
final calendarZoneProvider = Provider<CalendarZone>(
  (ref) => const DeviceCalendarZone(),
);

/// The current time, replaceable so a test can fix "today".
final calendarClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// How many days one agenda page spans.
const int calendarAgendaDays = 14;

// A refused or failed load is shown as it is. Riverpod's default would send
// the same authenticated request again, up to ten times, behind the user's
// back; the user's own refresh is the retry.
Duration? _doNotRetryCalendarLoad(int retryCount, Object error) => null;

/// The signed-in account's Open WebUI calendars and the agenda over them, kept
/// on the server.
///
/// Use is online only: the server owns events and expands recurring ones, so
/// nothing here stores, queues or expands anything on the device. Every
/// operation, loads included, is admitted for a [CalendarOwner] and rechecks
/// that account's capability before it sends.
@Riverpod(keepAlive: true, retry: _doNotRetryCalendarLoad)
class CalendarAgenda extends _$CalendarAgenda {
  int _loadGeneration = 0;
  late CalendarRange _range;
  Set<String> _filter = const <String>{};

  @override
  Future<CalendarAgendaData> build() async {
    ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
    // A same-server account switch keeps the same ApiService, so the auth
    // session is what retires one account's calendar for the next.
    ref.watch(openWebUiAuthSessionEpochProvider);
    ref.watch(calendarAvailableProvider);
    final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
    _range = _defaultRange();
    _filter = const <String>{};
    final owner = apiAlive ? captureOwner() : null;
    if (owner == null) return CalendarAgendaData(range: _range);

    final data = await _load(owner);
    if (!_isCurrent(owner)) return CalendarAgendaData(range: _range);
    return data;
  }

  /// The account that is signed in now, for a surface to hold until it acts.
  /// Null when no signed-in account can own a calendar at the moment.
  CalendarOwner? captureOwner() {
    final api = ref.read(apiServiceProvider);
    final user = ref.read(currentUserProvider2);
    if (api == null || user == null) return null;
    final ownership = captureOpenWebUiCacheOwnership(ref, api: api);
    if (ownership == null) return null;
    return CalendarOwner._(api, api.captureAuthSnapshot(), ownership, user.id);
  }

  /// Whether [owner] is still the signed-in account.
  bool isCurrentOwner(CalendarOwner owner) => _isCurrent(owner);

  /// Reloads the agenda for [owner], optionally over another [range] or limited
  /// to other calendars. A result that arrives after the account has changed is
  /// dropped.
  Future<void> refresh({
    required CalendarOwner owner,
    CalendarRange? range,
    Set<String>? filter,
  }) async {
    if (!_isCurrent(owner)) return;
    final changed =
        (range != null && range != _range) ||
        (filter != null && !_sameSet(filter, _filter));
    _range = range ?? _range;
    _filter = filter ?? _filter;
    if (!state.hasValue) state = const AsyncLoading<CalendarAgendaData>();
    await _reload(owner, restart: changed);
  }

  /// One stored event, read from the server. It needs read access to the
  /// event's calendar, so an invitation the account can only see through the
  /// agenda is a 403 here that the caller must not treat as the event being
  /// gone. An answer that arrives after the account changed is dropped.
  Future<CalendarEventModel> fetchEvent(
    String eventId, {
    required CalendarOwner owner,
  }) async {
    final operation = await _admit(owner);
    final event = await operation.api.getCalendarEvent(
      eventId,
      authSnapshot: operation.owner._auth,
    );
    return _stillOwned(owner, event);
  }

  /// Creates [form]'s event. The destination calendar has to be one the account
  /// can write to.
  Future<CalendarEventModel> createEvent(
    CalendarEventForm form, {
    required CalendarOwner owner,
  }) async {
    final operation = await _admit(owner);
    final access = _requireAccess();
    if (form.calendarId == scheduledTasksCalendarId ||
        !_canWriteTo(access, form.calendarId)) {
      throw const CalendarPermissionException(CalendarDenial.notWritable);
    }
    final created = await operation.api.createCalendarEvent(
      form,
      authSnapshot: operation.owner._auth,
    );
    await _reload(owner);
    return created;
  }

  /// Applies [update] to [event], which is the event as the editor loaded it.
  ///
  /// The server requires write access to the event's calendar, and to the
  /// destination as well when [update] moves it, so both are checked here from
  /// the calendars the account can see. Only an ordinary event can be edited;
  /// an attendee who can only see the event through an invitation cannot.
  Future<CalendarEventModel> updateEvent(
    CalendarEventModel event,
    CalendarEventUpdate update, {
    required CalendarOwner owner,
  }) async {
    final operation = await _admit(owner);
    final access = _requireAccess();
    _requireStored(event);
    if (!_canWriteEvent(access, event)) {
      throw const CalendarPermissionException(CalendarDenial.notWritable);
    }
    final destination = update.destinationCalendarId;
    if (destination != null &&
        destination != event.calendarId &&
        (destination == scheduledTasksCalendarId ||
            !_canWriteTo(access, destination))) {
      throw const CalendarPermissionException(
        CalendarDenial.destinationNotWritable,
      );
    }
    final updated = await operation.api.updateCalendarEvent(
      event.id,
      update,
      authSnapshot: operation.owner._auth,
    );
    await _reload(owner);
    return updated;
  }

  /// Deletes [event], a recurring event's whole series included: the server has
  /// no way to delete one occurrence.
  Future<void> deleteEvent(
    CalendarEventModel event, {
    required CalendarOwner owner,
  }) async {
    final operation = await _admit(owner);
    final access = _requireAccess();
    _requireStored(event);
    if (!_canWriteEvent(access, event)) {
      throw const CalendarPermissionException(CalendarDenial.notWritable);
    }
    await operation.api.deleteCalendarEvent(
      event.id,
      authSnapshot: operation.owner._auth,
    );
    await _reload(owner);
  }

  /// Records the account's own answer to [event]'s invitation. This is open to
  /// any invited person: it needs no calendar access, and it is the only change
  /// an attendee can make.
  Future<CalendarRsvp> respond(
    CalendarEventModel event,
    CalendarRsvp status, {
    required CalendarOwner owner,
  }) async {
    final operation = await _admit(owner);
    final access = _requireAccess();
    _requireStored(event);
    if (!access.canRsvp(event)) {
      throw const CalendarPermissionException(CalendarDenial.notInvited);
    }
    final stored = await operation.api.rsvpCalendarEvent(
      event.id,
      status,
      authSnapshot: operation.owner._auth,
    );
    await _reload(owner);
    return stored;
  }

  /// Creates a private calendar for the account, so a user who has none to
  /// write to can still create an event.
  Future<CalendarModel> createCalendar(
    CalendarForm form, {
    required CalendarOwner owner,
  }) async {
    final operation = await _admit(owner);
    final created = await operation.api.createCalendar(
      form,
      authSnapshot: operation.owner._auth,
    );
    await _reload(owner);
    return created;
  }

  /// Makes [calendar] the account's default. Only the account's own stored
  /// calendars qualify: the server clears every default the account has before
  /// it looks the calendar up, so a shared or virtual one must never be sent.
  Future<CalendarModel> makeDefault(
    CalendarModel calendar, {
    required CalendarOwner owner,
  }) async {
    final operation = await _admit(owner);
    final access = _requireAccess();
    if (!access.canMakeDefault(calendar)) {
      throw const CalendarPermissionException(CalendarDenial.notOwnCalendar);
    }
    final updated = await operation.api.setDefaultCalendar(
      calendar.id,
      authSnapshot: operation.owner._auth,
    );
    await _reload(owner);
    return updated;
  }

  /// A page of events matching [query] in the calendars the account can read.
  Future<CalendarEventSearchPage> search(
    String query, {
    int skip = 0,
    int limit = 30,
    required CalendarOwner owner,
  }) async {
    final operation = await _admit(owner);
    final page = await operation.api.searchCalendarEvents(
      query: query,
      skip: skip,
      limit: limit,
      authSnapshot: operation.owner._auth,
    );
    return _stillOwned(owner, page);
  }

  CalendarAccess _requireAccess() {
    final access = state.asData?.value.access;
    if (access == null) {
      throw const CalendarPermissionException(CalendarDenial.notLoaded);
    }
    return access;
  }

  void _requireStored(CalendarEventModel event) {
    if (event.calendarId == scheduledTasksCalendarId ||
        event.id.startsWith('auto_') ||
        event.id.startsWith('run_')) {
      throw const CalendarPermissionException(
        CalendarDenial.scheduledTaskEntry,
      );
    }
  }

  bool _canWriteEvent(CalendarAccess access, CalendarEventModel event) =>
      access.canEdit(event, state.asData?.value.calendars ?? const []);

  bool _canWriteTo(CalendarAccess access, String calendarId) {
    for (final calendar in state.asData?.value.calendars ?? const []) {
      if (calendar.id == calendarId) return access.canWrite(calendar);
    }
    return false;
  }

  CalendarRange _defaultRange() {
    final zone = ref.read(calendarZoneProvider);
    final now = ref.read(calendarClockProvider)().toUtc();
    final today = wallTimeAt(now.microsecondsSinceEpoch * 1000, zone);
    return CalendarRange.days(today, calendarAgendaDays, zone: zone);
  }

  bool _isCurrent(CalendarOwner owner) =>
      ref.mounted && openWebUiCacheOwnershipIsCurrent(ref, owner._ownership);

  /// [answer] for a read, once [owner] is confirmed to still be signed in.
  /// Writes do not use this: a request already accepted for the account stays
  /// accepted, and the surface decides what to show the new one.
  T _stillOwned<T>(CalendarOwner owner, T answer) {
    if (!_isCurrent(owner)) throw CalendarOwnerChangedException();
    return answer;
  }

  /// Admits one operation for [owner]: the account must still be the signed-in
  /// one, and still be allowed the calendar, both checked after the permission
  /// lookup so a change during it is caught.
  Future<_Admitted> _admit(CalendarOwner owner) async {
    if (!_isCurrent(owner)) throw CalendarOwnerChangedException();

    // Read through the shared providers rather than fetching again. A failed
    // read is a denial: the calendar defaults to off, not on.
    final permissions = await _settled(userPermissionsProvider);
    final config = await _settled(backendConfigProvider);
    if (!_isCurrent(owner)) throw CalendarOwnerChangedException();
    final user = ref.read(currentUserProvider2);
    if (permissions == null ||
        config == null ||
        !calendarPermitted(
          config: config.value,
          serverId: owner._ownership.serverId,
          user: user,
          permissions: permissions.value,
        )) {
      throw const CalendarUnavailableException();
    }
    return _Admitted(
      owner,
      owner._api,
      isAdmin: user?.role == 'admin',
      scheduledTasksAllowed: automationsPermitted(
        config: config.value,
        serverId: owner._ownership.serverId,
        user: user,
        permissions: permissions.value,
      ),
    );
  }

  /// The first settled value of [provider], or null when it failed or this
  /// notifier rebuilt first.
  ///
  /// Awaiting `provider.future` instead can wait forever: a build that an
  /// account switch replaced may never complete, and a Save would spin with no
  /// way out. This notifier rebuilds on every session change, and that also
  /// drops listeners made through its ref, so the rebuild itself ends the wait.
  /// The caller's ownership check then decides what it means.
  Future<({T value})?> _settled<T>(
    ProviderListenable<AsyncValue<T>> provider,
  ) async {
    final settled = Completer<({T value})?>();
    final subscription = ref.listen<AsyncValue<T>>(
      provider,
      fireImmediately: true,
      (_, next) {
        if (next.isLoading || settled.isCompleted) return;
        settled.complete(next.hasError ? null : (value: next.requireValue));
      },
    );
    final stopWatchingRebuild = ref.onDispose(() {
      if (!settled.isCompleted) settled.complete(null);
    });
    try {
      return await settled.future;
    } finally {
      subscription.close();
      stopWatchingRebuild();
    }
  }

  /// Reads the calendars and the agenda for the current range and filter.
  Future<CalendarAgendaData> _load(CalendarOwner owner) async {
    final operation = await _admit(owner);
    final auth = owner._auth;
    final range = _range;
    final listed = await operation.api.getCalendars(authSnapshot: auth);
    // The server hides the virtual calendar from an account without scheduled
    // tasks; drop it here too if the two answers ever disagree.
    final calendars = [
      for (final calendar in listed)
        if (!calendar.isVirtual || operation.scheduledTasksAllowed) calendar,
    ];
    var groups = const <String>{};
    if (!operation.isAdmin) {
      try {
        groups = await operation.api.getCalendarMemberGroupIds(
          authSnapshot: auth,
        );
      } catch (_) {
        // Without the groups, a grant given to one of them cannot be seen, so
        // that calendar reads as read-only. The server still decides.
      }
    }
    final known = {for (final calendar in calendars) calendar.id};
    final filter = {
      for (final id in _filter)
        if (known.contains(id)) id,
    };
    final fetched = await operation.api.getCalendarEvents(
      startIso: range.startIso,
      endIso: range.endIso,
      calendarIds: filter,
      authSnapshot: auth,
    );
    // An occurrence of a recurring event shares its event id with the others;
    // the pair of ids is what tells them apart.
    final byKey = <String, CalendarAgendaItem>{};
    for (final item in fetched) {
      if (item is ScheduledTaskCalendarEntry &&
          !operation.scheduledTasksAllowed) {
        continue;
      }
      byKey[item.key] = item;
    }
    final items = byKey.values.toList()
      ..sort((a, b) {
        final byStart = a.startAtNs.compareTo(b.startAtNs);
        return byStart != 0 ? byStart : a.key.compareTo(b.key);
      });
    return CalendarAgendaData(
      range: range,
      calendars: List<CalendarModel>.unmodifiable(calendars),
      access: CalendarAccess(
        userId: owner.userId,
        isAdmin: operation.isAdmin,
        groupIds: groups,
      ),
      filter: Set<String>.unmodifiable(filter),
      items: List<CalendarAgendaItem>.unmodifiable(items),
      scheduledTasksVisible: operation.scheduledTasksAllowed,
    );
  }

  /// Replaces the agenda with the server's, unless a newer load started or the
  /// account changed. A failure keeps the agenda that was showing, marked
  /// stale, unless the range or filter moved, in which case it is the error.
  Future<void> _reload(CalendarOwner owner, {bool restart = false}) async {
    final generation = ++_loadGeneration;
    final shown = state.asData?.value;
    try {
      final data = await _load(owner);
      if (generation != _loadGeneration || !_isCurrent(owner)) return;
      state = AsyncData(data);
    } catch (error, stackTrace) {
      if (generation != _loadGeneration || !_isCurrent(owner)) return;
      state = shown == null || restart
          ? AsyncError<CalendarAgendaData>(error, stackTrace)
          : AsyncData(shown.copyWith(stale: true));
    }
  }

  bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

/// One admitted operation: the owner, its API, and the capability facts read
/// when it was admitted.
final class _Admitted {
  const _Admitted(
    this.owner,
    this.api, {
    required this.isAdmin,
    required this.scheduledTasksAllowed,
  });

  final CalendarOwner owner;
  final ApiService api;
  final bool isAdmin;
  final bool scheduledTasksAllowed;
}

import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

/// The most events a room keeps on screen; older ones drop off the top.
const int kMaxHermesRoomEventsShown = 2000;

/// How often an open room reads its log again; Hermes pushes no room
/// events.
const Duration kHermesRoomPollInterval = Duration(seconds: 2);

/// What this gateway can do with Group Chats. Null on the API server and on
/// a gateway without rooms, which hides the sidebar section.
final hermesRoomCapabilitiesProvider = FutureProvider<HermesRoomCapabilities?>(
  (ref) async {
    final service = ref.watch(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) return null;
    ref.watch(hermesDesktopContractProvider);
    try {
      return await service.roomCapabilities();
    } catch (_) {
      return null;
    }
  },
);

/// Whether the Hermes sidebar tab shows its Rooms section expanded.
class HermesShowRoomsNotifier extends Notifier<bool> {
  @override
  bool build() =>
      PreferencesStore.getBool(PreferenceKeys.hermesShowRooms) ?? true;

  void toggle() {
    state = !state;
    PreferencesStore.put(PreferenceKeys.hermesShowRooms, state);
  }
}

final hermesShowRoomsProvider =
    NotifierProvider<HermesShowRoomsNotifier, bool>(
      HermesShowRoomsNotifier.new,
    );

/// The room on screen, which the sidebar marks as selected.
class HermesOpenRoomNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? roomId) => state = roomId;

  /// Forgets [roomId] unless another room opened since.
  void clear(String roomId) {
    if (ref.mounted && state == roomId) state = null;
  }
}

final hermesOpenRoomProvider =
    NotifierProvider<HermesOpenRoomNotifier, String?>(
      HermesOpenRoomNotifier.new,
    );

/// The gateway's live Group Chats, most recently active first. Empty on
/// the API server.
final hermesRoomsProvider = FutureProvider<List<HermesRoom>>((ref) async {
  final service = ref.watch(hermesApiServiceProvider);
  if (service is! HermesDesktopApiService) return const [];
  ref.watch(hermesDesktopContractProvider);
  final rooms = await service.listRooms();
  return [
    for (final room in rooms)
      if (!room.disbanded) room,
  ];
});

/// An open room: what Hermes last reported, and its log so far.
class HermesRoomView {
  const HermesRoomView({
    this.snapshot,
    this.events = const [],
    this.loaded = false,
    this.readError,
    this.gone = false,
    this.sending = false,
    this.unsentText,
  });

  final HermesRoomState? snapshot;
  final List<HermesRoomEvent> events;

  /// Whether the room has been read once.
  final bool loaded;

  /// Why the last read failed; the last good read stays shown.
  final Object? readError;

  /// The room is no longer on the gateway (disbanded, or not this user's).
  final bool gone;
  final bool sending;

  /// A message Hermes may or may not have; sending the same words again
  /// sends this same message, which Hermes posts at most once.
  final String? unsentText;

  HermesRoom? get room => snapshot?.room;
  HermesRoomContext? get context => snapshot?.context;
  HermesRoomDriverStatus? get driver => snapshot?.driver;

  HermesRoomView copyWith({
    HermesRoomState? snapshot,
    List<HermesRoomEvent>? events,
    bool? loaded,
    Object? readError = _keep,
    bool? gone,
    bool? sending,
    Object? unsentText = _keep,
  }) => HermesRoomView(
    snapshot: snapshot ?? this.snapshot,
    events: events ?? this.events,
    loaded: loaded ?? this.loaded,
    readError: identical(readError, _keep) ? this.readError : readError,
    gone: gone ?? this.gone,
    sending: sending ?? this.sending,
    unsentText: identical(unsentText, _keep)
        ? this.unsentText
        : unsentText as String?,
  );
}

const Object _keep = Object();

/// Reads one room and acts in it. The room's page polls [refresh] while it
/// is on screen.
class HermesRoomController extends Notifier<HermesRoomView> {
  HermesRoomController(this.roomId);

  final String roomId;

  HermesDesktopApiService? _service;
  Future<void>? _refreshing;
  int? _epoch;
  int _seq = 0;
  HermesRoomSend? _unsent;
  String? _stopId;
  DateTime? _listRefreshedAt;

  @override
  HermesRoomView build() {
    final service = ref.watch(hermesApiServiceProvider);
    _service = service is HermesDesktopApiService ? service : null;
    _refreshing = null;
    _epoch = null;
    _seq = 0;
    _unsent = null;
    _stopId = null;
    _listRefreshedAt = null;
    return const HermesRoomView();
  }

  HermesDesktopApiService get _api =>
      _service ?? (throw StateError('Group Chats need a Desktop Gateway.'));

  bool _current(HermesDesktopApiService service) =>
      ref.mounted && identical(_service, service);

  /// Reads what changed; overlapping calls share one read.
  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() {
    _refreshing = null;
  });

  Future<void> _refresh() async {
    final service = _service;
    if (service == null) {
      state = state.copyWith(loaded: true, gone: true);
      return;
    }
    try {
      final snapshot = await service.roomState(roomId);
      if (!_current(service)) return;
      final room = snapshot.room;
      final latest = room.latestSeq;
      // A new authority epoch, or a log shorter than what was read, starts
      // the log again.
      final fresh =
          !state.loaded ||
          room.authorityEpoch != _epoch ||
          (latest != null && latest < _seq);
      final since = fresh ? 0 : _seq;
      final events = await service.roomEventsSince(
        roomId,
        sinceSeq: since,
        latestSeq: latest,
      );
      if (!_current(service)) return;
      var merged = fresh
          ? events
          : events.isEmpty
          ? state.events
          : [...state.events, ...events.where((event) => event.seq > since)];
      if (merged.length > kMaxHermesRoomEventsShown) {
        merged = merged.sublist(merged.length - kMaxHermesRoomEventsShown);
      }
      _epoch = room.authorityEpoch;
      _seq = merged.isEmpty ? since : merged.last.seq;
      state = state.copyWith(
        snapshot: snapshot,
        // An unchanged log keeps its identity, so nothing re-projects it.
        events: identical(merged, state.events)
            ? state.events
            : List.unmodifiable(merged),
        loaded: true,
        readError: null,
        gone: room.disbanded,
      );
      _refreshListIfStale(room);
    } catch (error) {
      if (!_current(service)) return;
      final gone = await _roomGone(service);
      if (!_current(service)) return;
      state = state.copyWith(loaded: true, readError: error, gone: gone);
    }
  }

  /// Reads the sidebar's room list again, at most every 30 seconds, when
  /// it shows this room under an older name or last activity.
  void _refreshListIfStale(HermesRoom room) {
    final listed = ref
        .read(hermesRoomsProvider)
        .value
        ?.where((entry) => entry.id == roomId)
        .firstOrNull;
    if (listed == null ||
        (listed.name == room.name && listed.updatedAt == room.updatedAt)) {
      return;
    }
    final now = DateTime.now();
    final last = _listRefreshedAt;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _listRefreshedAt = now;
    ref.invalidate(hermesRoomsProvider);
  }

  /// Whether the room left the gateway's list: the reason a read fails
  /// after a disband from another app.
  Future<bool> _roomGone(HermesDesktopApiService service) async {
    try {
      final rooms = await service.listRooms();
      return rooms.every((room) => room.id != roomId);
    } catch (_) {
      return false;
    }
  }

  /// Posts [text]. Words Hermes refused before posting anything come back
  /// for editing; after an unclear answer the message is kept, and sending
  /// the same words again sends it again under the same id.
  Future<void> send(String text) async {
    final unsent = _unsent;
    final send = unsent != null && unsent.text == text
        ? unsent
        : HermesRoomSend(text: text);
    _unsent = send;
    state = state.copyWith(sending: true, unsentText: text);
    try {
      await _api.sendRoomMessage(roomId, send);
      if (identical(_unsent, send)) _unsent = null;
    } catch (error) {
      if (hermesRoomSendAdmittedNothing(error) && identical(_unsent, send)) {
        _unsent = null;
      }
      rethrow;
    } finally {
      if (ref.mounted) {
        state = state.copyWith(sending: false, unsentText: _unsent?.text);
      }
    }
    unawaited(refresh());
  }

  /// Stops the room's work; how many tasks stopped. A stop whose answer
  /// was lost is repeated as the same stop.
  Future<int> stop() async {
    final cancelId = _stopId ??= const Uuid().v4();
    final stopped = await _api.stopRoom(roomId, cancelId: cancelId);
    if (_stopId == cancelId) _stopId = null;
    unawaited(refresh());
    return stopped;
  }

  Future<void> continueDiscussion(String discussionEventId) async {
    await _api.continueRoomDiscussion(roomId, discussionEventId);
    unawaited(refresh());
  }

  /// Answers an approval (`once` / `deny`) or retries uncertain work.
  Future<void> answer(HermesRoomPendingAction action, {String? choice}) async {
    await _api.answerRoomAction(roomId, action, choice: choice);
    unawaited(refresh());
  }

  Future<void> rename(String name) async {
    await _api.renameRoom(roomId, name);
    ref.invalidate(hermesRoomsProvider);
    await refresh();
  }

  Future<void> saveContext(HermesRoomContext context) async {
    await _api.setRoomContext(roomId, context);
    await refresh();
  }

  /// Ends the room for good.
  Future<void> disband() async {
    await _api.disbandRoom(roomId);
    ref.invalidate(hermesRoomsProvider);
    if (ref.mounted) state = state.copyWith(gone: true);
  }
}

final hermesRoomProvider = NotifierProvider.autoDispose
    .family<HermesRoomController, HermesRoomView, String>(
      HermesRoomController.new,
    );

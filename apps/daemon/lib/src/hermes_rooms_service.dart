import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/features/hermes/models/hermes_bot.dart' as core;
import 'package:conduit_core/features/hermes/models/hermes_room.dart' as core;
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart'
    as core;
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart'
    as core;
import 'package:conduit_core/features/hermes/services/hermes_bot_chat.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart'
    as core;
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_markdown/conduit_markdown.dart'
    show normalizeTextForPlainMarkdown;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'hermes_connection.dart';
import 'hermes_service.dart';
import 'settled.dart';

/// The scope a room's `hermes.rooms.changed` goes out under: windows that
/// show room [roomId] subscribe to it.
String hermesRoomScope(String roomId) => 'hermes-room:$roomId';

/// How often an open room is read (the phone's page reads it as often).
const Duration kHermesRoomWatchInterval = core.kHermesRoomPollInterval;

/// How often a room nobody shows any more is read while its bots still
/// work, so its row's working dot and unread mark stay true.
const Duration kHermesRoomLingerInterval = Duration(seconds: 5);

/// How often the room list is read again while a window lists it: Hermes
/// pushes nothing, so news in a room nobody has open shows this late.
const Duration kHermesRoomListInterval = Duration(seconds: 15);

/// Implements `hermes.bots.*` and `hermes.rooms.*` over the core's Bot Mode
/// and Group Chat providers -- the roster, the room list, and each open
/// room's controller, which mobile's room page reads every two seconds.
///
/// * **Bots.** `hermes.bots.open` resolves a bot's permanent Bot Chat (made
///   when it has none) through the phone's own call, which binds the
///   session to the bot's profile; the chat then opens as any Hermes
///   session, titled with the bot ([botOf]).
/// * **Rooms.** A window that shows a room watches it: the room's
///   controller is held and read every 2 s, and what the room's page shows
///   -- its timeline projected as the phone projects it, each bot's state,
///   the approvals it waits on -- goes out as `hermes.rooms.changed`,
///   scoped to the room, whenever it changed. A room left while its bots
///   still work is read every 5 s until they stop, so its sidebar row
///   stays true. The list carries an unread mark per room: something was
///   said since this device last showed it (`latest_seq` against the last
///   one shown, kept across launches).
final class HermesRoomsService implements HermesBotChats {
  HermesRoomsService(
    this._container,
    this._events, {
    HermesConnectionKey? connection,
  }) : connection = connection ?? HermesConnectionKey(_container) {
    _seen = _readSeen();
    // Another connection (or none): what was known of the last one goes.
    _connectionWatch = _container.listen<Object?>(hermesApiServiceProvider, (
      previous,
      next,
    ) {
      if (identical(previous, next)) return;
      _botSessions.clear();
      _flags.clear();
      _rooms.clear();
      for (final watch in _watches.values.toList()) {
        _close(watch);
      }
      _lastList = null;
      if (_listWindows.isNotEmpty) unawaited(_announceList());
    });
  }

  final ProviderContainer _container;
  final EventBus _events;

  /// The connection every room request and answer is bound to.
  final HermesConnectionKey connection;
  late final ProviderSubscription<Object?> _connectionWatch;

  void dispose() {
    _connectionWatch.close();
    for (final hold in _unsentHolds.values.toList()) {
      hold.close();
    }
    _unsentHolds.clear();
    for (final watch in _watches.values.toList()) {
      _close(watch);
    }
    _listTimer?.cancel();
    _listTimer = null;
    _seenWrite?.cancel();
  }

  HermesDesktopApiService? get _desktop {
    final service = _container.read(hermesApiServiceProvider);
    return service is HermesDesktopApiService ? service : null;
  }

  HermesDesktopApiService _requireDesktop() =>
      _desktop ??
      (throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'Bots and Group Chats need a Hermes Desktop Gateway',
      ));

  // ---------------------------------------------------------------------------
  // Bots
  // ---------------------------------------------------------------------------

  /// The Bot Chats this daemon opened, by session: the bot each is.
  final Map<String, ({core.HermesBot bot, String? avatar})> _botSessions =
      <String, ({core.HermesBot bot, String? avatar})>{};

  Future<List<core.HermesBot>> _roster({bool fresh = false}) async {
    if (_desktop == null) return const <core.HermesBot>[];
    if (fresh) _container.invalidate(hermesBotsProvider);
    return readSettled(_container, hermesBotsProvider.future);
  }

  Future<HermesBots> bots() => _guard(() async {
    final began = connection.current;
    final roster = await _roster(fresh: true);
    connection.stillCurrent(began);
    return HermesBots(
      available: roster.isNotEmpty,
      bots: <HermesBotDto>[for (final bot in roster) botDto(bot)],
      connection: began,
    );
  });

  Future<HermesBotAvatar> avatar(String name, {String? connection}) =>
      _guard(() async {
        this.connection.require(connection);
        final began = this.connection.current;
        final service = _requireDesktop();
        final image = await service
            .botAvatar(name)
            .catchError((Object _) => null);
        this.connection.stillCurrent(began);
        return HermesBotAvatar(name: name, image: image);
      });

  /// Bot [name]'s Bot Chat, made when it has none, as a session to open.
  Future<HermesSessionDto> openBot(
    String name,
    HermesService hermes, {
    String? connection,
  }) => _guard(() async {
    this.connection.require(connection);
    final began = this.connection.current;
    final service = _requireDesktop();
    var bot = _botNamed(await _roster(), name);
    bot ??= _botNamed(await _roster(fresh: true), name);
    if (bot == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'bot': name},
        debugMessage: 'no such bot',
      );
    }
    this.connection.stillCurrent(began);
    final storedId = await service.openBotChat(bot);
    // A connection edit during the open: the id belongs to another one.
    this.connection.stillCurrent(began);
    String? avatar;
    if (bot.hasAvatar) {
      // The shape face stands in when the picture cannot be read.
      avatar = await service.botAvatar(bot.name).catchError((Object _) {
        return null;
      });
      // Nor is the last connection's bot kept, or its session adopted.
      this.connection.stillCurrent(began);
    }
    _botSessions[storedId] = (bot: bot, avatar: avatar);
    return hermes.adopt(
      HermesSessionSummary(
        id: storedId,
        title: bot.title,
        updatedAt: bot.lastActive,
      ),
    );
  });

  static core.HermesBot? _botNamed(List<core.HermesBot> bots, String name) =>
      bots.where((b) => b.name == name).firstOrNull;

  @override
  HermesBotDto? botOf(String sessionId) {
    final bot = _botFor(sessionId);
    return bot == null ? null : botDto(bot.bot, sessionId: sessionId);
  }

  @override
  Map<String, Object> botMetadataOf(String sessionId) {
    final bot = _botFor(sessionId);
    return bot == null
        ? const <String, Object>{}
        : hermesBotChatMetadata(bot: bot.bot, avatar: bot.avatar);
  }

  /// The bot whose Bot Chat session [sessionId] is: one opened here, or
  /// one the roster names as a bot's chat.
  ({core.HermesBot bot, String? avatar})? _botFor(String sessionId) {
    if (_botSessions[sessionId] case final opened?) return opened;
    final roster = _container.read(hermesBotsProvider).value;
    final bot = roster?.where((b) => b.chatSessionId == sessionId).firstOrNull;
    return bot == null ? null : (bot: bot, avatar: null);
  }

  /// [bot] as the windows see it; [sessionId] is its Bot Chat's when known
  /// beyond what the roster says.
  HermesBotDto botDto(core.HermesBot bot, {String? sessionId}) {
    final opened = _botSessions.entries
        .where((e) => e.value.bot.name == bot.name)
        .map((e) => e.key)
        .lastOrNull;
    return HermesBotDto(
      name: bot.name,
      title: bot.title,
      description: bot.description,
      preview: bot.preview,
      sessionId: sessionId ?? opened ?? bot.chatSessionId,
      hasAvatar: bot.hasAvatar,
      shape: bot.avatarShape,
      color: bot.avatarColor,
      lastActiveMs: bot.lastActive?.millisecondsSinceEpoch,
    );
  }

  // ---------------------------------------------------------------------------
  // The room list
  // ---------------------------------------------------------------------------

  /// Windows that list the rooms: while any does, the list is read again
  /// every [kHermesRoomListInterval].
  final Set<String> _listWindows = <String>{};
  Timer? _listTimer;
  HermesRooms? _lastList;

  /// What the last read of each room said of its work, for its row.
  final Map<String, ({bool working, bool needsYou})> _flags =
      <String, ({bool working, bool needsYou})>{};

  Future<HermesRooms> rooms(String sessionId) async {
    _listWindows.add(sessionId);
    _listTimer ??= Timer.periodic(
      kHermesRoomListInterval,
      (_) => unawaited(_announceList()),
    );
    final began = connection.current;
    final list = await _list(fresh: true);
    connection.stillCurrent(began);
    _lastList = list;
    return list;
  }

  /// Reads the list again and tells the windows when it changed.
  Future<void> _announceList({bool fresh = true}) async {
    if (_listWindows.isEmpty) return;
    try {
      final began = connection.current;
      final list = await _list(fresh: fresh);
      // Read across a connection edit: the edit's own announcement follows.
      if (connection.current != began) return;
      if (list == _lastList) return;
      _lastList = list;
      _events.emit(ConduitEventSpecs.hermesRoomsListChanged, list);
    } on Object {
      // The next read tries again.
    }
  }

  Future<HermesRooms> _list({bool fresh = false}) async {
    final key = connection.current;
    if (_desktop == null) return HermesRooms(connection: key);
    if (fresh) {
      _container
        ..invalidate(core.hermesRoomCapabilitiesProvider)
        ..invalidate(core.hermesRoomsProvider);
    }
    core.HermesRoomCapabilities? capabilities;
    try {
      capabilities = await readSettled(
        _container,
        core.hermesRoomCapabilitiesProvider.future,
      );
    } on Object {
      // A failed read hides the section until the list is read again.
      return HermesRooms(failed: true, connection: key);
    }
    if (capabilities == null) return HermesRooms(connection: key);
    final bots = await _roster().catchError((Object _) => <core.HermesBot>[]);
    final seatable = core.hermesSeatableBots(bots, capabilities);
    final canCreate = core.hermesRoomsCanCreate(capabilities, bots);
    List<core.HermesRoom> rooms;
    var failed = false;
    try {
      rooms = await readSettled(_container, core.hermesRoomsProvider.future);
    } on Object {
      failed = true;
      rooms = <core.HermesRoom>[
        for (final room in _lastList?.rooms ?? const <HermesRoomDto>[])
          ?_rooms[room.id],
      ];
    }
    // Read across a connection edit: the next connection keeps none of it.
    if (connection.current != key) {
      return HermesRooms(failed: true, connection: key);
    }
    for (final room in rooms) {
      _rooms[room.id] = room;
      _baseline(room);
    }
    return HermesRooms(
      available: rooms.isNotEmpty || canCreate,
      canCreate: canCreate,
      seatable: <String>[for (final bot in seatable) bot.name],
      rooms: <HermesRoomDto>[for (final room in rooms) _roomDto(room)],
      failed: failed,
      connection: key,
    );
  }

  /// The rooms as last read, by id.
  final Map<String, core.HermesRoom> _rooms = <String, core.HermesRoom>{};

  HermesRoomDto _roomDto(core.HermesRoom room) {
    final flags = _flags[room.id];
    final latest = room.latestSeq;
    final seen = _seen[room.id];
    return HermesRoomDto(
      id: room.id,
      name: room.name,
      members: <HermesRoomMemberDto>[
        for (final member in room.members) _memberDto(member),
      ],
      updatedAtMs: room.updatedAt?.millisecondsSinceEpoch,
      // A room on screen has been read as it is said.
      unread:
          !_shown(room.id) && latest != null && seen != null && latest > seen,
      working: flags?.working ?? false,
      needsYou: flags?.needsYou ?? false,
    );
  }

  static HermesRoomMemberDto _memberDto(core.HermesRoomMember member) =>
      HermesRoomMemberDto(
        memberId: member.memberId,
        profile: member.profile,
        handle: member.handle,
        name: member.name,
      );

  bool _shown(String roomId) => _watches[roomId]?.windows.isNotEmpty ?? false;

  // ---------------------------------------------------------------------------
  // Unread
  // ---------------------------------------------------------------------------

  static const String _seenKey = 'desktop_hermes_room_seen_v1';

  /// The newest event this device showed, by room.
  late Map<String, int> _seen;
  Timer? _seenWrite;

  static Map<String, int> _readSeen() {
    try {
      final raw = PreferencesStore.getString(_seenKey);
      if (raw == null) return <String, int>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      return <String, int>{
        for (final MapEntry(:key, :value) in decoded.entries)
          if (key is String && value is int) key: value,
      };
    } on Object {
      return <String, int>{};
    }
  }

  /// A room first listed here counts as read up to where it is: only what
  /// is said after reads as new.
  void _baseline(core.HermesRoom room) {
    final latest = room.latestSeq;
    if (latest != null && !_seen.containsKey(room.id)) {
      _markSeen(room.id, latest);
    }
  }

  void _markSeen(String roomId, int seq) {
    if ((_seen[roomId] ?? -1) >= seq) return;
    _seen[roomId] = seq;
    _seenWrite?.cancel();
    _seenWrite = Timer(const Duration(milliseconds: 500), () {
      unawaited(PreferencesStore.put(_seenKey, jsonEncode(_seen)));
    });
  }

  // ---------------------------------------------------------------------------
  // An open room
  // ---------------------------------------------------------------------------

  final Map<String, _RoomWatch> _watches = <String, _RoomWatch>{};

  Future<HermesRoomView> watch(
    String sessionId,
    String roomId, {
    String? connection,
  }) => _guard(() async {
    this.connection.require(connection);
    final began = this.connection.current;
    _requireDesktop();
    final watch = _watchFor(roomId);
    final first = watch.windows.add(sessionId);
    watch.lingering = false;
    _schedule(watch);
    // The first read before answering, so the pane opens on the room;
    // it is the answer, not an event.
    watch.opening++;
    HermesRoomView view;
    try {
      await _controller(roomId).refresh();
    } finally {
      watch.opening--;
    }
    // The connection changed during the read: the edit closed the watch,
    // and what was read belongs to the last connection.
    this.connection.stillCurrent(began);
    view = _snapshot(watch);
    watch.last = view;
    if (first) unawaited(_announceList(fresh: false));
    return view;
  });

  OkResult unwatch(String sessionId, String roomId) {
    final watch = _watches[roomId];
    if (watch != null && watch.windows.remove(sessionId)) _left(watch);
    return const OkResult(ok: true);
  }

  /// A window went away: it shows no room and lists none any more.
  void forgetWindow(String sessionId) {
    _listWindows.remove(sessionId);
    if (_listWindows.isEmpty) {
      _listTimer?.cancel();
      _listTimer = null;
    }
    for (final watch in _watches.values.toList()) {
      if (watch.windows.remove(sessionId)) _left(watch);
    }
  }

  _RoomWatch _watchFor(String roomId) {
    final existing = _watches[roomId];
    if (existing != null) return existing;
    final watch = _RoomWatch(roomId);
    watch.subscription = _container.listen<core.HermesRoomView>(
      core.hermesRoomProvider(roomId),
      (_, _) => _changed(watch),
    );
    _watches[roomId] = watch;
    return watch;
  }

  /// No window shows [watch] now: it goes, or, while its bots work, is
  /// read now and then until they stop.
  void _left(_RoomWatch watch) {
    if (watch.windows.isNotEmpty) return;
    final view = watch.subscription.read();
    if (_working(view) && !view.gone) {
      watch.lingering = true;
      _schedule(watch);
    } else {
      _close(watch);
    }
    unawaited(_announceList(fresh: false));
  }

  core.HermesRoomController _controller(String roomId) =>
      _container.read(core.hermesRoomProvider(roomId).notifier);

  /// Rooms kept alive for words Hermes may have, by room.
  final Map<String, ProviderSubscription<core.HermesRoomView>> _unsentHolds =
      <String, ProviderSubscription<core.HermesRoomView>>{};

  /// Keeps room [roomId]'s controller -- and with it the id its words went
  /// out under -- while it sends, or holds words Hermes may have: nothing
  /// that shows or acts on the room may let it go before then, or sending
  /// the words again would post them twice. Let go once they are settled
  /// (posted, refused, or seen in the log).
  void _holdWhileUnsent(String roomId) {
    if (_unsentHolds.containsKey(roomId)) return;
    bool unsettled(core.HermesRoomView view) =>
        view.sending || view.unsentText != null;
    if (!unsettled(_container.read(core.hermesRoomProvider(roomId)))) return;
    late final ProviderSubscription<core.HermesRoomView> hold;
    hold = _container.listen<core.HermesRoomView>(
      core.hermesRoomProvider(roomId),
      (_, next) {
        if (unsettled(next)) return;
        if (identical(_unsentHolds[roomId], hold)) _unsentHolds.remove(roomId);
        hold.close();
      },
    );
    _unsentHolds[roomId] = hold;
  }

  void _schedule(_RoomWatch watch) {
    watch.timer?.cancel();
    watch.timer = Timer.periodic(
      watch.lingering ? kHermesRoomLingerInterval : kHermesRoomWatchInterval,
      (_) => unawaited(_controller(watch.roomId).refresh()),
    );
  }

  void _close(_RoomWatch watch) {
    if (_watches[watch.roomId] != watch) return;
    _watches.remove(watch.roomId);
    watch.timer?.cancel();
    _holdWhileUnsent(watch.roomId);
    watch.subscription.close();
    watch.closed = true;
  }

  /// Sends the room's view once whatever changed together has.
  void _changed(_RoomWatch watch) {
    if (watch.scheduled || watch.closed) return;
    watch.scheduled = true;
    scheduleMicrotask(() {
      watch.scheduled = false;
      if (watch.closed) return;
      final state = watch.subscription.read();
      _noteRoom(watch, state);
      if (watch.lingering && (!_working(state) || state.gone)) {
        _close(watch);
        return;
      }
      if (watch.windows.isEmpty || watch.opening > 0) return;
      final view = _snapshot(watch);
      if (view == watch.last) return;
      watch.last = view;
      _events.emit(
        ConduitEventSpecs.hermesRoomsChanged,
        view,
        scope: hermesRoomScope(watch.roomId),
      );
    });
  }

  /// What a read of the room tells its sidebar row: its work, what it
  /// waits on, what was said; a change goes out with the list.
  void _noteRoom(_RoomWatch watch, core.HermesRoomView state) {
    final room = state.room;
    if (room == null) return;
    if (_shown(watch.roomId)) {
      final latest = room.latestSeq;
      if (latest != null) _markSeen(room.id, latest);
    }
    final flags = (
      working: _working(state) && !state.gone,
      needsYou:
          !state.gone &&
          (state.driver?.pendingActions.any((a) => a.isApproval) ?? false),
    );
    final listed = _rooms[room.id];
    final before = _flags[room.id];
    _rooms[room.id] = room;
    _flags[room.id] = flags;
    final listChanged =
        before != flags ||
        listed == null ||
        listed.name != room.name ||
        listed.latestSeq != room.latestSeq ||
        listed.updatedAt != room.updatedAt ||
        state.gone;
    if (listChanged && _lastList != null) unawaited(_refreshListFromRooms());
  }

  /// The list as it was last read, with what the rooms' own reads said
  /// since: their names, their news, their work.
  Future<void> _refreshListFromRooms() async {
    final last = _lastList;
    if (last == null || _listWindows.isEmpty) return;
    final gone = <String>{
      for (final watch in _watches.values)
        if (watch.subscription.read().gone) watch.roomId,
    };
    final list = last.copyWith(
      rooms: <HermesRoomDto>[
        for (final row in last.rooms)
          if (!gone.contains(row.id))
            if (_rooms[row.id] case final room?) _roomDto(room) else row,
      ],
    );
    if (list == last) return;
    _lastList = list;
    _events.emit(ConduitEventSpecs.hermesRoomsListChanged, list);
  }

  static bool _working(core.HermesRoomView state) {
    final driver = state.driver;
    return (driver?.working ?? false) ||
        (driver?.memberActivity.isNotEmpty ?? false);
  }

  HermesRoomView _snapshot(_RoomWatch watch) => projectRoomView(
    watch.roomId,
    watch.subscription.read(),
    DateTime.now(),
  ).copyWith(connection: connection.current);

  /// [state] as the room's pane shows it at [now]: what the phone's room
  /// page draws, in its words' order.
  static HermesRoomView projectRoomView(
    String roomId,
    core.HermesRoomView state,
    DateTime now,
  ) {
    final room = state.room;
    if (room == null) {
      return HermesRoomView(
        roomId: roomId,
        loaded: state.loaded,
        gone: state.gone,
        readFailed: state.readError != null,
        sending: state.sending,
        unsentText: state.unsentText,
      );
    }
    final driver = state.driver;
    final items = core.projectHermesRoomTimeline(
      state.events,
      room,
      maxContinues: driver?.maxContinues,
    );
    final statuses = core.hermesRoomMemberStatuses(
      state.events,
      room.members,
      driver?.memberActivity ?? const <core.HermesRoomMemberActivity>[],
      now,
    );
    final context = state.context;
    final routing = context?.routing;
    final offersAuto =
        routing == core.HermesRoomRouting.auto ||
        (driver?.routingModes?.contains(core.HermesRoomRouting.auto) ?? false);
    return HermesRoomView(
      roomId: roomId,
      loaded: state.loaded,
      room: HermesRoomDto(
        id: room.id,
        name: room.name,
        members: <HermesRoomMemberDto>[
          for (final member in room.members) _memberDto(member),
        ],
        updatedAtMs: room.updatedAt?.millisecondsSinceEpoch,
        working: _working(state),
        needsYou:
            driver?.pendingActions.any((action) => action.isApproval) ?? false,
      ),
      context: context == null ? null : _contextDto(context),
      gone: state.gone,
      readFailed: state.readError != null,
      running: driver != null,
      working: _working(state),
      sending: state.sending,
      unsentText: state.unsentText,
      routingModes: routing == null
          ? const <HermesRoomRouting>[]
          : <HermesRoomRouting>[
              HermesRoomRouting.everyone,
              HermesRoomRouting.lead,
              if (offersAuto) HermesRoomRouting.auto,
            ],
      items: <HermesRoomItemDto>[
        for (final (index, item) in items.indexed)
          _itemDto(item, index == 0 ? null : items[index - 1]),
      ],
      members: <HermesRoomMemberStatusDto>[
        for (final member in room.members)
          if (statuses[member.memberId] case final status?)
            HermesRoomMemberStatusDto(
              memberId: member.memberId,
              state: HermesRoomMemberState.values.byName(status.kind.name),
              elapsedMs: status.elapsed?.inMilliseconds,
              tool: status.tool,
              reason: status.reason,
            ),
      ],
      actions: <HermesRoomActionDto>[
        for (final action
            in driver?.pendingActions ?? const <core.HermesRoomPendingAction>[])
          _actionDto(action, room),
      ],
    );
  }

  static HermesRoomContextDto _contextDto(core.HermesRoomContext context) =>
      HermesRoomContextDto(
        purpose: context.purpose,
        notes: context.notes,
        routing: context.routing == null
            ? null
            : HermesRoomRouting.values.byName(context.routing!.name),
        leadMemberId: context.leadMemberId,
      );

  static HermesRoomItemDto _itemDto(
    core.HermesRoomTimelineItem item,
    core.HermesRoomTimelineItem? previous,
  ) => switch (item) {
    core.HermesRoomMessageItem() => HermesRoomItemDto(
      kind: HermesRoomItemKind.message,
      key: item.key,
      seq: item.seq,
      own: item.own,
      scheduled: item.scheduled,
      author: item.author,
      memberId: item.member?.memberId,
      // As the windows draw a reply's markdown (the phone's renderer
      // normalizes the same).
      text: item.own
          ? item.text
          : normalizeTextForPlainMarkdown(item.text, hasSources: false),
      continued: !item.own && _sameAuthor(previous, item),
      createdAtMs: item.event.createdAt?.millisecondsSinceEpoch,
    ),
    core.HermesRoomNoticeItem() => HermesRoomItemDto(
      kind: HermesRoomItemKind.notice,
      key: item.key,
      seq: item.seq,
      notice: HermesRoomNoticeKind.values.byName(item.kind.name),
      memberId: item.member?.memberId,
      memberName: item.memberName,
      detail: item.detail,
    ),
    core.HermesRoomRouteItem() => HermesRoomItemDto(
      kind: HermesRoomItemKind.route,
      key: item.key,
      seq: item.seq,
      route: HermesRoomRouteKind.values.byName(item.kind.name),
      names: item.names,
      lead: item.lead,
    ),
    core.HermesRoomPauseItem() => HermesRoomItemDto(
      kind: HermesRoomItemKind.pause,
      key: item.key,
      seq: item.seq,
      discussionEventId: item.discussionEventId,
      messageCount: item.messageCount,
      actionable: item.actionable,
    ),
  };

  /// Two bots may share a name, so the seat and the poster decide (the
  /// phone's timeline groups a bot's messages the same way).
  static bool _sameAuthor(
    core.HermesRoomTimelineItem? previous,
    core.HermesRoomMessageItem item,
  ) =>
      previous is core.HermesRoomMessageItem &&
      !previous.own &&
      previous.member?.memberId == item.member?.memberId &&
      previous.event.actor?.kind == item.event.actor?.kind &&
      previous.event.actor?.id == item.event.actor?.id &&
      previous.author == item.author &&
      previous.scheduled == item.scheduled;

  /// An approval with what it would allow and the answers this app may
  /// give, or work to retry, as the phone's decision card shows it.
  static HermesRoomActionDto _actionDto(
    core.HermesRoomPendingAction action,
    core.HermesRoom room,
  ) {
    final approval = action.approval;
    return HermesRoomActionDto(
      kind: action.kind,
      memberId: action.memberId,
      taskId: action.taskId,
      executionGeneration: action.executionGeneration,
      summary: action.isApproval
          ? action.command ?? approval?.description ?? approval?.command
          : null,
      choices: <String>[
        if (action.canAllowOnce) 'once',
        if (action.canDeny) 'deny',
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Acting in a room
  // ---------------------------------------------------------------------------

  /// Runs [body] on room [roomId]'s controller, held for as long as it
  /// runs (a room acted on from the sidebar is not open).
  ///
  /// Asked under [asked]: refused once another connection is in use, and
  /// when the connection changes during the room's first read, the action
  /// is not done at all (the controller would act on the next connection).
  Future<T> _withRoom<T>(
    String roomId,
    String? asked,
    Future<T> Function(core.HermesRoomController controller, String began) body,
  ) => _guard(() async {
    connection.require(asked);
    final began = connection.current;
    _requireDesktop();
    final hold = _container.listen<core.HermesRoomView>(
      core.hermesRoomProvider(roomId),
      (_, _) {},
    );
    try {
      final controller = _controller(roomId);
      // A room not read yet is read first: its actions need what it waits
      // on, and Stop and Disband its driver.
      if (!hold.read().loaded) await controller.refresh();
      connection.stillCurrent(began);
      return await body(controller, began);
    } finally {
      _holdWhileUnsent(roomId);
      hold.close();
    }
  });

  Future<HermesRoomDto> create(HermesRoomCreate request) => _guard(() async {
    connection.require(request.connection);
    final began = connection.current;
    final service = _requireDesktop();
    final name = request.name.trim();
    if (name.isEmpty || name.length > core.kMaxHermesRoomNameInput) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a room needs a name of at most 200 characters',
      );
    }
    final picked = request.bots.toSet().toList();
    if (picked.length < core.kMinHermesRoomSeats ||
        picked.length > core.kMaxHermesRoomSeats) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a room seats two to six bots',
      );
    }
    _container.invalidate(core.hermesRoomCapabilitiesProvider);
    final capabilities = await readSettled(
      _container,
      core.hermesRoomCapabilitiesProvider.future,
    );
    if (capabilities == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'this Hermes has no Group Chats',
      );
    }
    final roster = await _roster(fresh: true);
    // Bots checked on one connection never seat a room on another.
    connection.stillCurrent(began);
    // Every pick must still be listed and seatable: a room is never made
    // with fewer members than were picked.
    final members = core.hermesRoomMembersFor(
      core.hermesSeatableBots(roster, capabilities),
      picked,
    );
    if (members == null) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'a picked bot is no longer listed',
      );
    }
    final room = await service.createRoom(name: name, members: members);
    // Made on the connection it was asked on; the next one lists its own.
    connection.stillCurrent(began);
    _rooms[room.id] = room;
    _container.invalidate(core.hermesRoomsProvider);
    unawaited(_announceList());
    return _roomDto(room);
  });

  Future<HermesRoomSendResult> send(HermesRoomMessage request) {
    final text = request.text.trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'nothing to send',
      );
    }
    return _withRoom(request.roomId, request.connection, (controller, _) async {
      try {
        await controller.send(text);
        return const HermesRoomSendResult(sent: true);
      } on Object catch (error) {
        // A refusal gives the words back with Hermes's reason; an unclear
        // answer keeps them, and the room says so (its unsent text).
        final detail = core.hermesRoomRefusalDetail(error);
        final refused = core.hermesRoomSendAdmittedNothing(error);
        if (!refused && detail == null && error is! HermesDesktopRpcException) {
          return const HermesRoomSendResult();
        }
        return HermesRoomSendResult(
          refused: refused || detail != null,
          detail: detail,
        );
      }
    });
  }

  Future<HermesRoomStopped> stop(String roomId, {String? connection}) =>
      _withRoom(
        roomId,
        connection,
        (controller, _) async =>
            HermesRoomStopped(stopped: await controller.stop()),
      );

  Future<OkResult> continueDiscussion(HermesRoomContinue request) =>
      _withRoom(request.roomId, request.connection, (controller, _) async {
        await controller.continueDiscussion(request.discussionEventId);
        return const OkResult(ok: true);
      });

  Future<OkResult> answer(HermesRoomAnswer request) =>
      _withRoom(request.roomId, request.connection, (controller, _) async {
        final action = _container
            .read(core.hermesRoomProvider(request.roomId))
            .driver
            ?.pendingActions
            .where(
              (a) =>
                  a.taskId == request.taskId &&
                  a.executionGeneration == request.executionGeneration,
            )
            .firstOrNull;
        if (action == null) {
          throw const RpcError(
            code: ConduitErrorCodes.conflict,
            debugMessage: 'the room no longer waits on that',
          );
        }
        await controller.answer(action, choice: request.choice);
        return const OkResult(ok: true);
      });

  Future<HermesRoomDto> rename(HermesRoomRename request) {
    final name = request.name.trim();
    if (name.isEmpty || name.length > core.kMaxHermesRoomNameInput) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a room needs a name of at most 200 characters',
      );
    }
    return _withRoom(request.roomId, request.connection, (
      controller,
      began,
    ) async {
      await controller.rename(name);
      connection.stillCurrent(began);
      final room = _container
          .read(core.hermesRoomProvider(request.roomId))
          .room;
      if (room != null) _rooms[room.id] = room;
      unawaited(_announceList());
      return room == null
          ? HermesRoomDto(id: request.roomId, name: name)
          : _roomDto(room);
    });
  }

  Future<HermesRoomContextDto> saveContext(HermesRoomContextEdit request) {
    final edit = request.context;
    if (core.hermesRoomNotesBytes(edit.notes) > core.kMaxHermesRoomNotesBytes ||
        edit.purpose.trim().length > core.kMaxHermesRoomPurposeCharacters) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'the purpose or the notes are too long',
      );
    }
    if (edit.routing == HermesRoomRouting.lead && edit.leadMemberId == null) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a lead answers only with a lead bot',
      );
    }
    return _withRoom(request.roomId, request.connection, (controller, _) async {
      final saved = await controller.saveContext(
        core.HermesRoomContext(
          purpose: edit.purpose.trim(),
          notes: edit.notes.trim(),
          routing: edit.routing == null
              ? null
              : core.HermesRoomRouting.values.byName(edit.routing!.name),
          leadMemberId: edit.routing == HermesRoomRouting.lead
              ? edit.leadMemberId
              : null,
        ),
      );
      return _contextDto(saved);
    });
  }

  Future<OkResult> disband(String roomId, {String? connection}) =>
      _withRoom(roomId, connection, (controller, began) async {
        await controller.disband();
        this.connection.stillCurrent(began);
        _rooms.remove(roomId);
        _flags.remove(roomId);
        unawaited(_announceList());
        return const OkResult(ok: true);
      });

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  /// Hermes's refusals as the windows read them: its own words, when it
  /// gave any, in `detail`.
  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on RpcError {
      rethrow;
    } on HermesDesktopRpcException catch (error) {
      final detail = core.hermesRoomRefusalDetail(error);
      throw RpcError(
        code: error.disconnected || error.timedOut || error.notReady
            ? ConduitErrorCodes.connectionFailed
            : ConduitErrorCodes.conflict,
        retryable: error.disconnected || error.timedOut || error.notReady,
        args: <String, String>{'detail': ?detail},
        debugMessage: 'Hermes refused: ${error.message}',
      );
    } on StateError catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        retryable: true,
        debugMessage: error.message,
      );
    }
  }
}

/// The bots whose Bot Chats a Hermes session is, for its chat.
abstract interface class HermesBotChats {
  /// The bot whose Bot Chat session [sessionId] is, if it is one.
  HermesBotDto? botOf(String sessionId);

  /// The conversation metadata that marks the chat as the bot's (empty for
  /// any other session).
  Map<String, Object> botMetadataOf(String sessionId);
}

final class _RoomWatch {
  _RoomWatch(this.roomId);

  final String roomId;

  /// The windows showing it.
  final Set<String> windows = <String>{};
  late final ProviderSubscription<core.HermesRoomView> subscription;
  Timer? timer;

  /// Nobody shows it, but its bots still work.
  bool lingering = false;

  /// Windows waiting for their first read, which answers them.
  int opening = 0;
  bool scheduled = false;
  bool closed = false;
  HermesRoomView? last;
}

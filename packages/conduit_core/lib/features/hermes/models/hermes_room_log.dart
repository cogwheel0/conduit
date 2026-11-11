/// What a Group Chat's log and live state say, as `groups.log`,
/// `groups.state` and `groups.capabilities` report them.
library;

import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/utils/hermes_time_parsing.dart';

/// The most text one room message is shown with (Hermes caps posts at
/// 64 KiB).
const int kMaxHermesRoomTextCharacters = 64 * 1024;

/// Hermes stamps every `groups.send` with this user actor, whichever app
/// sent it; scheduled posts carry a `cron:` actor of their own.
const String kHermesRoomUserActorId = 'desktop';

String? _id(Object? value) => validateHermesOpaqueIdentifier(value);

String? _label(Object? value, [int max = 512]) =>
    validateHermesBoundedString(value, maxCharacters: max);

int? _positive(Object? value) => value is int && value >= 1 ? value : null;

/// Who wrote a log event.
class HermesRoomActor {
  const HermesRoomActor({required this.kind, this.id, this.displayName});

  /// `user`, `member`, `gateway` or `system`.
  final String kind;
  final String? id;
  final String? displayName;

  static HermesRoomActor? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = _label(json['kind'], 32);
    if (kind == null) return null;
    return HermesRoomActor(
      kind: kind,
      id: _label(json['id'], 128),
      displayName: _label(json['display_name'], 200),
    );
  }
}

/// One event of a room's append-only log.
class HermesRoomEvent {
  const HermesRoomEvent({
    required this.seq,
    required this.kind,
    this.eventId,
    this.actor,
    this.payload = const {},
    this.createdAt,
  });

  final int seq;
  final String kind;
  final String? eventId;
  final HermesRoomActor? actor;
  final Map<String, Object?> payload;
  final DateTime? createdAt;

  bool get isUserMessage => kind == 'message.user' || kind == 'message';
  bool get isMemberMessage => kind == 'message.member';
  bool get isMessage => isUserMessage || isMemberMessage;

  /// A message the user sent from any app.
  bool get isOwnMessage =>
      isUserMessage &&
      actor?.kind == 'user' &&
      actor?.id == kHermesRoomUserActorId &&
      actor?.displayName == null;

  /// A scheduled job's post (or its failure notice) in the room.
  bool get isScheduledPost {
    final id = actor?.id ?? '';
    return isUserMessage &&
        (id.startsWith('cron:') || id.startsWith('cron-notice:'));
  }

  String get text =>
      _text(payload['text']) ?? _text(payload['content']) ?? '';

  String? get threadId => _id(payload['thread_id']);
  String? get discussionEventId => _id(payload['discussion_event_id']);

  /// The member a turn event is about.
  String? get memberId => _id(payload['member_id']);

  /// The member who wrote a member message.
  String? get authorMemberId => actor?.kind == 'member' ? actor?.id : null;

  /// `room.activity`'s `bounded`: the discussion paused at its limit.
  bool get isBoundedActivity =>
      kind == 'room.activity' && payload['status'] == 'bounded';

  String? stringField(String key, [int max = 2048]) =>
      _label(payload[key], max);

  /// A message body as written: a reply that opens with an indented code
  /// block keeps its indentation.
  static String? _text(Object? value) => validateHermesBoundedString(
    value,
    maxCharacters: kMaxHermesRoomTextCharacters,
    trim: false,
  );

  static HermesRoomEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final seq = _positive(json['seq']);
    final kind = _label(json['kind'], 64);
    if (seq == null || kind == null) return null;
    final payload = json['payload'];
    return HermesRoomEvent(
      seq: seq,
      kind: kind,
      eventId: _label(json['event_id'], 128),
      actor: HermesRoomActor.fromJson(json['actor']),
      payload: payload is Map
          ? Map<String, Object?>.unmodifiable(
              payload.map((key, value) => MapEntry('$key', value)),
            )
          : const {},
      createdAt: parseHermesTimestamp(json['created_at']),
    );
  }
}

/// One `groups.log` page.
class HermesRoomLogPage {
  const HermesRoomLogPage({
    required this.events,
    required this.cursor,
    this.latestSeq,
    this.hasMore = false,
  });

  final List<HermesRoomEvent> events;

  /// The last event read, or the request's `since_seq` when none was.
  final int cursor;
  final int? latestSeq;
  final bool hasMore;

  static HermesRoomLogPage fromJson(Map<String, dynamic> json, int since) {
    final rows = json['events'];
    final events = <HermesRoomEvent>[];
    var last = since;
    if (rows is List) {
      for (final row in rows) {
        final event = HermesRoomEvent.fromJson(row);
        // The log only grows: a row at or before the cursor is not new.
        if (event == null || event.seq <= last) continue;
        events.add(event);
        last = event.seq;
      }
    }
    final cursor = json['cursor'];
    final latest = json['latest_seq'];
    return HermesRoomLogPage(
      events: events,
      cursor: cursor is int && cursor >= last ? cursor : last,
      latestSeq: latest is int && latest >= 0 ? latest : null,
      hasMore: json['has_more'] == true,
    );
  }
}

/// A member at work right now (`driver_status.member_activity`).
class HermesRoomMemberActivity {
  const HermesRoomMemberActivity({
    required this.memberId,
    required this.status,
    this.startedAt,
    this.progressAt,
    this.tool,
    this.threadId,
    this.roundIndex,
  });

  final String memberId;

  /// `queued`, `running` or `stopping`.
  final String status;
  final DateTime? startedAt;

  /// When the member last did anything (Hermes 0.22.5 and later).
  final DateTime? progressAt;

  /// The tool it is in right now.
  final String? tool;
  final String? threadId;
  final int? roundIndex;

  bool get queued => status == 'queued';

  static HermesRoomMemberActivity? fromJson(Object? json) {
    if (json is! Map) return null;
    final member = _id(json['member_id']);
    final status = _label(json['status'], 32);
    if (member == null || status == null) return null;
    final round = json['round_index'];
    return HermesRoomMemberActivity(
      memberId: member,
      status: status,
      startedAt: parseHermesTimestamp(json['started_at']),
      progressAt: parseHermesTimestamp(json['progress_at']),
      tool: _label(json['tool'], 128),
      threadId: _id(json['thread_id']),
      roundIndex: round is int && round >= 0 ? round : null,
    );
  }
}

/// What a bot asks permission for.
class HermesRoomApproval {
  const HermesRoomApproval({
    this.requestId,
    this.command,
    this.description,
    this.choices = const [],
  });

  final String? requestId;
  final String? command;
  final String? description;

  /// What Hermes lets the user answer: `once` and/or `deny`.
  final List<String> choices;

  static HermesRoomApproval? fromJson(Object? json) {
    if (json is! Map) return null;
    final choices = json['choices'];
    return HermesRoomApproval(
      requestId: _id(json['request_id']) ?? _id(json['prompt_id']),
      command: _label(json['command'], 8 * 1024),
      description: _label(json['description'], 8 * 1024),
      choices: [
        if (choices is List)
          for (final choice in choices)
            if (choice == 'once' || choice == 'deny') choice as String,
      ],
    );
  }
}

/// A decision the room waits on (`driver_status.pending_actions`): an
/// approval, or work that ended uncertainly and may be retried.
class HermesRoomPendingAction {
  const HermesRoomPendingAction({
    required this.kind,
    required this.memberId,
    required this.taskId,
    required this.executionGeneration,
    this.requestId,
    this.approval,
  });

  /// `approval` or `retry`.
  final String kind;
  final String memberId;
  final String taskId;
  final int executionGeneration;
  final String? requestId;
  final HermesRoomApproval? approval;

  bool get isApproval => kind == 'approval';
  bool get isRetry => kind == 'retry';

  /// The command the approval would run, unless Hermes sent a tool label
  /// (`<tool> (…)`) in its place.
  String? get command {
    final command = approval?.command;
    if (command == null || _labelledTool(command)) return null;
    return command;
  }

  /// Allow once is offered only for this exact request, and only when the
  /// card shows what it allows: a command, or the operation a tool label
  /// stands for.
  bool get canAllowOnce {
    final approval = this.approval;
    if (!isApproval || approval == null || requestId == null) return false;
    if (!approval.choices.contains('once')) return false;
    if (approval.requestId != null && approval.requestId != requestId) {
      return false;
    }
    final raw = approval.command;
    return command != null ||
        (raw != null && _labelledTool(raw) && approval.description != null);
  }

  bool get canDeny =>
      isApproval &&
      requestId != null &&
      (approval?.choices.contains('deny') ?? false);

  static bool _labelledTool(String command) =>
      RegExp(r'^<[^>]+> \(').hasMatch(command);

  static HermesRoomPendingAction? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = _label(json['kind'], 32);
    final member = _id(json['member_id']);
    final task = _id(json['task_id']);
    final generation = _positive(json['execution_generation']);
    if (kind == null || member == null || task == null || generation == null) {
      return null;
    }
    final approval = HermesRoomApproval.fromJson(json['approval']);
    return HermesRoomPendingAction(
      kind: kind,
      memberId: member,
      taskId: task,
      executionGeneration: generation,
      requestId: _id(json['request_id']) ?? approval?.requestId,
      approval: approval,
    );
  }
}

/// What the room's driver is doing (`groups.state.driver_status`).
class HermesRoomDriverStatus {
  const HermesRoomDriverStatus({
    this.working = false,
    this.blocked = false,
    this.pendingActions = const [],
    this.memberActivity = const [],
    this.maxRounds,
    this.maxContinues,
    this.routingModes,
    this.lastError,
  });

  final bool working;
  final bool blocked;
  final List<HermesRoomPendingAction> pendingActions;
  final List<HermesRoomMemberActivity> memberActivity;
  final int? maxRounds;

  /// How often one discussion may be continued; null on a Hermes without
  /// Continue (before 0.23.0).
  final int? maxContinues;

  /// Who-answers modes Hermes offers; null before 0.22.7.
  final Set<HermesRoomRouting>? routingModes;
  final String? lastError;

  static HermesRoomDriverStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    List<T> rows<T>(Object? value, T? Function(Object?) parse) => [
      if (value is List)
        for (final row in value.take(64)) ?parse(row),
    ];
    final modes = json['routing_modes'];
    final maxRounds = json['max_rounds'];
    final maxContinues = json['max_continues'];
    return HermesRoomDriverStatus(
      working: json['working'] == true,
      blocked: json['blocked'] == true,
      pendingActions: rows(
        json['pending_actions'],
        HermesRoomPendingAction.fromJson,
      ),
      memberActivity: rows(
        json['member_activity'],
        HermesRoomMemberActivity.fromJson,
      ),
      maxRounds: maxRounds is int && maxRounds > 0 ? maxRounds : null,
      maxContinues: maxContinues is int && maxContinues >= 0
          ? maxContinues
          : null,
      routingModes: modes is List
          ? {for (final mode in modes) ?HermesRoomRouting.parse(mode)}
          : null,
      lastError: _label(json['last_error'], 2048),
    );
  }
}

/// One `groups.state` answer.
class HermesRoomState {
  const HermesRoomState({required this.room, this.context, this.driver});

  final HermesRoom room;

  /// Purpose, notes and routing; null on a disbanded room.
  final HermesRoomContext? context;

  /// Null when the room's driver is not running: the room reads, but
  /// nothing can be sent.
  final HermesRoomDriverStatus? driver;

  static HermesRoomState? fromJson(Map<String, dynamic> json) {
    final room = HermesRoom.fromJson(json['room']);
    if (room == null) return null;
    return HermesRoomState(
      room: room,
      context: HermesRoomContext.fromJson(json['context']),
      driver: HermesRoomDriverStatus.fromJson(json['driver_status']),
    );
  }
}

/// What `groups.capabilities` says this gateway can do with rooms.
class HermesRoomCapabilities {
  const HermesRoomCapabilities({
    this.driver = false,
    this.methods,
    this.seatableProfiles,
  });

  /// Whether the gateway runs rooms (sends, turns, approvals).
  final bool driver;

  /// The `groups.*` methods offered; null when Hermes did not list them.
  final Set<String>? methods;

  /// Profiles a new room may seat; null when Hermes did not say.
  final Set<String>? seatableProfiles;

  bool offers(String method) => methods == null || methods!.contains(method);

  static HermesRoomCapabilities fromJson(Map<String, dynamic> json) {
    Set<String>? names(Object? value) => value is List
        ? {
            for (final item in value.take(256))
              if (item is String && item.isNotEmpty) item,
          }
        : null;
    return HermesRoomCapabilities(
      driver: json['driver'] == true,
      methods: names(json['methods']),
      seatableProfiles: names(json['seatable_profiles']),
    );
  }
}

/// How a Group Chat reads: its log as a chat timeline, each bot's live
/// status, and @mention completion. Pure functions of what Hermes reported.
library;

import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

/// One row of a room's timeline.
sealed class HermesRoomTimelineItem {
  const HermesRoomTimelineItem(this.seq);

  /// The log event the row belongs to (or follows).
  final int seq;

  /// A key that stays with the row across polls.
  String get key;
}

/// A message: the user's own, a scheduled job's, or a bot's.
final class HermesRoomMessageItem extends HermesRoomTimelineItem {
  HermesRoomMessageItem({
    required this.event,
    required this.author,
    this.member,
  }) : super(event.seq);

  final HermesRoomEvent event;

  /// The bot that wrote it; null for the user's and scheduled posts.
  final HermesRoomMember? member;

  /// Who wrote it; empty for the user's own messages.
  final String author;

  bool get own => event.isOwnMessage;
  bool get scheduled => event.isScheduledPost;
  String get text => event.text;

  @override
  String get key => 'message:$seq';
}

enum HermesRoomNoticeKind {
  turnFailed,
  turnCancelled,
  turnDeferred,
  memberUnavailable,
  stopped,
  disbanded,
  authorityLost,
  workLimit,
}

/// A quiet line about what happened to the room's work.
final class HermesRoomNoticeItem extends HermesRoomTimelineItem {
  HermesRoomNoticeItem({
    required this.event,
    required this.kind,
    this.member,
    this.memberName,
    this.detail,
  }) : super(event.seq);

  final HermesRoomEvent event;
  final HermesRoomNoticeKind kind;
  final HermesRoomMember? member;
  final String? memberName;
  final String? detail;

  @override
  String get key => 'notice:$seq';
}

enum HermesRoomRouteKind {
  /// Hermes picked who answers ([names]).
  routedTo,
  routedEveryone,

  /// Hermes could not pick, so everyone answers.
  routedFallback,

  /// The lead ([lead]) gave the message to [names].
  assigned,

  /// The lead ([lead]) takes the message itself.
  leadTaking,

  /// The user continued a paused discussion.
  continued,

  /// [lead] asked [names] (one) in its reply.
  handoff,
}

/// Who a message went to, as the room decided it.
final class HermesRoomRouteItem extends HermesRoomTimelineItem {
  HermesRoomRouteItem({
    required int seq,
    required this.kind,
    this.names = const [],
    this.lead,
    String? keySuffix,
  }) : _suffix = keySuffix,
       super(seq);

  final HermesRoomRouteKind kind;
  final List<String> names;
  final String? lead;
  final String? _suffix;

  @override
  String get key => 'route:$seq:${kind.name}${_suffix ?? ''}';
}

/// A discussion paused at its limit, with Continue while that still means
/// something.
final class HermesRoomPauseItem extends HermesRoomTimelineItem {
  HermesRoomPauseItem({
    required this.event,
    required this.discussionEventId,
    required this.messageCount,
    required this.actionable,
  }) : super(event.seq);

  final HermesRoomEvent event;
  final String discussionEventId;

  /// Bot messages the discussion produced before it paused.
  final int messageCount;

  /// Nothing has moved the discussion on since: Continue and Stop apply.
  final bool actionable;

  @override
  String get key => 'pause:$seq';
}

/// A paused discussion's place in the log.
typedef HermesRoomPause = ({int messageCount, bool actionable});

const _noticeKinds = {
  'turn.failed': HermesRoomNoticeKind.turnFailed,
  'turn.cancelled': HermesRoomNoticeKind.turnCancelled,
  'turn.deferred': HermesRoomNoticeKind.turnDeferred,
  'member.unavailable': HermesRoomNoticeKind.memberUnavailable,
  'room.stop_requested': HermesRoomNoticeKind.stopped,
  'room.disbanded': HermesRoomNoticeKind.disbanded,
  'authority.lost': HermesRoomNoticeKind.authorityLost,
};

const _terminalKinds = {
  'turn.settled',
  'turn.failed',
  'turn.cancelled',
  'turn.deferred',
};

List<String> _ids(Object? value) => [
  if (value is List)
    for (final item in value.take(64)) ?validateHermesOpaqueIdentifier(item),
];

/// The room's log as a chat: messages, notices, routing lines and pauses,
/// in log order. Without [maxContinues] (Hermes before 0.23.0) a paused
/// discussion reads as a plain "work limit" notice.
List<HermesRoomTimelineItem> projectHermesRoomTimeline(
  List<HermesRoomEvent> events,
  HermesRoom room, {
  int? maxContinues,
}) {
  String nameOf(String id) => room.member(id)?.name ?? id;
  final pauses = maxContinues == null
      ? const <int, HermesRoomPause>{}
      : hermesRoomPauses(events, maxContinues);
  final handoffs = <int, List<(String, String)>>{};
  for (final handoff in _handoffs(events, room.members)) {
    (handoffs[handoff.$1] ??= []).add((handoff.$2, handoff.$3));
  }
  final items = <HermesRoomTimelineItem>[];
  for (final event in events) {
    final item = _item(event, room, nameOf, pauses);
    if (item != null) items.add(item);
    final after = handoffs[event.seq] ?? const <(String, String)>[];
    for (final (from, to) in after) {
      items.add(
        HermesRoomRouteItem(
          seq: event.seq,
          kind: HermesRoomRouteKind.handoff,
          lead: nameOf(from),
          names: [nameOf(to)],
          keySuffix: ':$to',
        ),
      );
    }
  }
  return items;
}

HermesRoomTimelineItem? _item(
  HermesRoomEvent event,
  HermesRoom room,
  String Function(String) nameOf,
  Map<int, HermesRoomPause> pauses,
) {
  if (event.isMessage) {
    final memberId = event.authorMemberId;
    final member = room.member(memberId);
    final author = event.isOwnMessage
        ? ''
        : event.actor?.displayName ??
              member?.name ??
              event.actor?.id ??
              memberId ??
              '';
    return HermesRoomMessageItem(event: event, author: author, member: member);
  }
  switch (event.kind) {
    case 'room.routed':
      final ids = _ids(event.payload['member_ids']);
      final names = [
        for (final id in ids)
          if (room.member(id) case final member?) member.name,
      ];
      if (event.payload['fallback'] == true) {
        return HermesRoomRouteItem(
          seq: event.seq,
          kind: HermesRoomRouteKind.routedFallback,
        );
      }
      if (event.payload['everyone'] == true) {
        return HermesRoomRouteItem(
          seq: event.seq,
          kind: HermesRoomRouteKind.routedEveryone,
        );
      }
      // Every pick left the roster: say nothing rather than show an id.
      return names.isEmpty
          ? null
          : HermesRoomRouteItem(
              seq: event.seq,
              kind: HermesRoomRouteKind.routedTo,
              names: names,
            );
    case 'room.assignment':
      final lead = validateHermesOpaqueIdentifier(
        event.payload['lead_member_id'],
      );
      return HermesRoomRouteItem(
        seq: event.seq,
        kind: event.payload['fallback'] == true
            ? HermesRoomRouteKind.leadTaking
            : HermesRoomRouteKind.assigned,
        lead: lead == null ? null : nameOf(lead),
        names: [for (final id in _ids(event.payload['member_ids'])) nameOf(id)],
      );
    case 'room.continued':
      return HermesRoomRouteItem(
        seq: event.seq,
        kind: HermesRoomRouteKind.continued,
      );
  }
  if (event.isBoundedActivity) {
    final pause = pauses[event.seq];
    final discussion = event.discussionEventId;
    if (pause != null && discussion != null) {
      return HermesRoomPauseItem(
        event: event,
        discussionEventId: discussion,
        messageCount: pause.messageCount,
        actionable: pause.actionable,
      );
    }
    return HermesRoomNoticeItem(
      event: event,
      kind: HermesRoomNoticeKind.workLimit,
    );
  }
  final kind = _noticeKinds[event.kind];
  if (kind == null) return null;
  final memberId = event.memberId;
  final member = room.member(memberId);
  return HermesRoomNoticeItem(
    event: event,
    kind: kind,
    member: member,
    memberName: memberId == null ? null : (member?.name ?? memberId),
    detail:
        event.stringField('error') ??
        event.stringField('reason') ??
        event.stringField('reason_code'),
  );
}

/// Every pause in the log by its seq: how much its discussion said before
/// it, and whether Continue still applies. A Stop retires every earlier
/// pause; a Continue or a later pause retires its own discussion's; a new
/// message retires its thread's.
Map<int, HermesRoomPause> hermesRoomPauses(
  List<HermesRoomEvent> events,
  int maxContinues,
) {
  final ordered = [...events]..sort((a, b) => a.seq.compareTo(b.seq));
  final said = <String, int>{};
  final grants = <String, int>{};
  final counts = <int, int>{};
  final sources = <String, int>{};
  var lastStop = 0;
  for (final event in ordered) {
    if (event.isUserMessage && event.eventId != null) {
      sources[event.eventId!] = event.seq;
    }
    if (event.kind == 'room.stop_requested') lastStop = event.seq;
    final discussion = event.discussionEventId;
    if (discussion == null) continue;
    if (event.isMemberMessage) said[discussion] = (said[discussion] ?? 0) + 1;
    // The shown log may have lost earlier Continues; each one names its
    // number (`grant`, from 1), and a pause's id ends in how many came
    // before it (`:c2`), so neither count rests on what is still shown.
    if (event.kind == 'room.continued') {
      final grant = event.payload['grant'];
      final counted = (grants[discussion] ?? 0) + 1;
      grants[discussion] = grant is int && grant > counted ? grant : counted;
    }
    if (event.isBoundedActivity) {
      counts[event.seq] = said[discussion] ?? 0;
      final before = _continuesBefore(event);
      if (before > (grants[discussion] ?? 0)) grants[discussion] = before;
    }
  }

  final moved = <int>{};
  final laterDiscussions = <String>{};
  final laterThreads = <String>{};
  var laterStop = false;
  for (final event in ordered.reversed) {
    final discussion = event.discussionEventId;
    final thread = event.threadId;
    if (event.isBoundedActivity &&
        (laterStop ||
            laterDiscussions.contains(discussion) ||
            (thread != null && laterThreads.contains(thread)))) {
      moved.add(event.seq);
    }
    if (event.kind == 'room.stop_requested') laterStop = true;
    if (discussion != null &&
        (event.kind == 'room.continued' || event.isBoundedActivity)) {
      laterDiscussions.add(discussion);
    }
    if (event.isUserMessage && thread != null) laterThreads.add(thread);
  }

  return {
    for (final event in ordered)
      if (event.isBoundedActivity)
        event.seq: (
          messageCount: counts[event.seq] ?? 0,
          actionable: () {
            final discussion = event.discussionEventId;
            if (discussion == null) return false;
            // A Stop after the discussion's own message fences it for good.
            final fenced = lastStop > (sources[discussion] ?? event.seq);
            return !fenced &&
                !moved.contains(event.seq) &&
                (grants[discussion] ?? 0) < maxContinues;
          }(),
        ),
  };
}

/// How many Continues a discussion had when it paused: Hermes files each
/// pause after one under `dactivity:<discussion>:<reason>:c<count>`.
int _continuesBefore(HermesRoomEvent pause) {
  final match = RegExp(r':c(\d{1,3})$').firstMatch(pause.eventId ?? '');
  return match == null ? 0 : int.parse(match.group(1)!);
}

/// A bot's reply that @mentions a teammate who then took a turn in the
/// same discussion: (after seq, from, to).
Iterable<(int, String, String)> _handoffs(
  List<HermesRoomEvent> events,
  List<HermesRoomMember> members,
) sync* {
  final lastTurn = <String, int>{};
  for (var index = 0; index < events.length; index++) {
    final event = events[index];
    final member = event.memberId;
    if (member == null || !_terminalKinds.contains(event.kind)) continue;
    lastTurn['$member\u0000${event.discussionEventId ?? ''}'] = index;
  }
  for (var index = 0; index < events.length; index++) {
    final event = events[index];
    final from = event.isMemberMessage ? event.authorMemberId : null;
    final text = event.text;
    if (from == null || text.isEmpty) continue;
    final discussion = event.discussionEventId ?? '';
    for (final member in members) {
      if (member.memberId == from) continue;
      final turnAt = lastTurn['${member.memberId}\u0000$discussion'];
      if (turnAt != null &&
          turnAt > index &&
          hermesRoomTextMentions(text, member.handle)) {
        yield (event.seq, from, member.memberId);
      }
    }
  }
}

/// Whether [text] @mentions [handle].
bool hermesRoomTextMentions(String text, String handle) =>
    handle.isNotEmpty &&
    RegExp(
      '(^|[^\\w@])@${RegExp.escape(handle)}(?![\\w-])',
      caseSensitive: false,
    ).hasMatch(text);

enum HermesRoomMemberStatusKind {
  idle,
  queued,
  working,

  /// Working, but silent for [kHermesRoomStallAfter].
  stalled,
  replied,
  passed,
  failed,
  cancelled,
  unavailable,
}

/// A running member silent this long reads as stalled.
const Duration kHermesRoomStallAfter = Duration(minutes: 2);

/// One bot's state in the room right now.
class HermesRoomMemberStatus {
  const HermesRoomMemberStatus(
    this.kind, {
    this.elapsed,
    this.tool,
    this.reason,
  });

  final HermesRoomMemberStatusKind kind;

  /// How long its current turn has run.
  final Duration? elapsed;

  /// The tool it is in.
  final String? tool;

  /// Why its last turn failed.
  final String? reason;

  bool get busy =>
      kind == HermesRoomMemberStatusKind.working ||
      kind == HermesRoomMemberStatusKind.stalled;
}

/// Each member's status: a live task (running before queued) wins over
/// its last outcome, which is read in its own thread's current discussion.
Map<String, HermesRoomMemberStatus> hermesRoomMemberStatuses(
  List<HermesRoomEvent> events,
  List<HermesRoomMember> members,
  List<HermesRoomMemberActivity> activity,
  DateTime now,
) {
  final discussions = <String, String>{};
  for (final event in events) {
    if (event.isUserMessage && event.eventId != null) {
      discussions[event.threadId ?? ''] = event.eventId!;
    }
  }
  final outcomes = <String, HermesRoomMemberStatus>{};
  for (final event in events) {
    final member = event.memberId;
    // A thread whose message left the shown log keeps its last outcome.
    final current = discussions[event.threadId ?? ''];
    if (member == null ||
        !_terminalKinds.contains(event.kind) ||
        (current != null && event.discussionEventId != current)) {
      continue;
    }
    final outcome = switch (event.kind) {
      'turn.settled' => HermesRoomMemberStatus(
        event.payload['passed'] == true
            ? HermesRoomMemberStatusKind.passed
            : HermesRoomMemberStatusKind.replied,
      ),
      'turn.failed' => HermesRoomMemberStatus(
        HermesRoomMemberStatusKind.failed,
        reason:
            event.stringField('reason_code', 128) ??
            _firstLine(event.stringField('error')),
      ),
      'turn.cancelled' => const HermesRoomMemberStatus(
        HermesRoomMemberStatusKind.cancelled,
      ),
      _ =>
        event.payload['reason'] == 'member_unavailable'
            ? const HermesRoomMemberStatus(
                HermesRoomMemberStatusKind.unavailable,
              )
            : null,
    };
    if (outcome != null) outcomes[member] = outcome;
  }

  HermesRoomMemberStatus statusOf(String memberId) {
    final rows = activity.where((row) => row.memberId == memberId).toList();
    final running = rows.where((row) => !row.queued).firstOrNull;
    if (running != null) {
      final started = running.startedAt;
      final lastSign = running.progressAt ?? started;
      final quiet = lastSign == null ? null : now.difference(lastSign);
      return HermesRoomMemberStatus(
        quiet != null && quiet >= kHermesRoomStallAfter
            ? HermesRoomMemberStatusKind.stalled
            : HermesRoomMemberStatusKind.working,
        elapsed: started == null ? null : _notNegative(now.difference(started)),
        tool: running.tool,
      );
    }
    if (rows.isNotEmpty) {
      return const HermesRoomMemberStatus(HermesRoomMemberStatusKind.queued);
    }
    return outcomes[memberId] ??
        const HermesRoomMemberStatus(HermesRoomMemberStatusKind.idle);
  }

  return {
    for (final member in members)
      member.memberId: statusOf(member.memberId),
  };
}

Duration _notNegative(Duration value) =>
    value.isNegative ? Duration.zero : value;

String? _firstLine(String? text) => text
    ?.split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .firstOrNull;

/// `45s`, `1m20s`, `1h05m`.
String formatHermesRoomElapsed(Duration value) {
  final seconds = value.inSeconds;
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) {
    return '${seconds ~/ 60}m${(seconds % 60).toString().padLeft(2, '0')}s';
  }
  final minutes = (seconds % 3600) ~/ 60;
  return '${seconds ~/ 3600}h${minutes.toString().padLeft(2, '0')}m';
}

/// The @mention being typed at [caret]: where its `@` is and what follows.
typedef HermesRoomMentionQuery = ({int start, String query});

final _mentionAtCaret = RegExp(r'(^|\s)@([A-Za-z0-9._:-]*)$');

/// The mention being typed just before [caret], or null.
HermesRoomMentionQuery? hermesRoomMentionQuery(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  final match = _mentionAtCaret.firstMatch(text.substring(0, caret));
  if (match == null) return null;
  return (start: match.start + match.group(1)!.length, query: match.group(2)!);
}

/// Members [query] could mean: handle or name prefixes first, then any
/// other handle or name containing it.
List<HermesRoomMember> hermesRoomMentionCandidates(
  List<HermesRoomMember> members,
  String query,
) {
  final needle = query.toLowerCase();
  bool starts(HermesRoomMember member) =>
      member.handle.toLowerCase().startsWith(needle) ||
      member.name.toLowerCase().startsWith(needle);
  bool contains(HermesRoomMember member) =>
      member.handle.toLowerCase().contains(needle) ||
      member.name.toLowerCase().contains(needle);
  return [
    ...members.where(starts),
    ...members.where((member) => !starts(member) && contains(member)),
  ];
}

/// [text] with the mention [query] (typed up to [caret]) replaced by
/// `@handle `, and where the caret goes after it.
({String text, int caret}) insertHermesRoomMention(
  String text,
  HermesRoomMentionQuery query,
  int caret,
  String handle,
) {
  final end = caret.clamp(query.start, text.length);
  final after = text.substring(end);
  final spacer = after.startsWith(' ') ? '' : ' ';
  final inserted = '@$handle$spacer';
  return (
    text: text.substring(0, query.start) + inserted + after,
    caret: query.start + inserted.length + (spacer.isEmpty ? 1 : 0),
  );
}

/// Whether Hermes refused a `groups.send` before posting anything of it:
/// only then may its words be edited and sent as a new message.
bool hermesRoomSendAdmittedNothing(Object error) {
  if (error is! HermesDesktopRpcException) return false;
  final data = error.data;
  return data is Map && data['admitted'] == false;
}

/// Hermes' own words for why it refused a room request, when it gave any
/// beyond a bare reason code.
String? hermesRoomRefusalDetail(Object error) {
  if (error is! HermesDesktopRpcException) return null;
  final data = error.data;
  final detail = data is Map
      ? validateHermesBoundedString(data['detail'], maxCharacters: 512)
      : null;
  if (detail != null) return detail;
  final message = error.message.trim();
  // A reason code alone (`invalid_params`) says nothing to the reader.
  if (RegExp(r'^[a-z_]+$').hasMatch(message) || message.isEmpty) return null;
  return message.length > 512 ? message.substring(0, 512) : message;
}

part of 'hermes_desktop_api_service.dart';

/// Events read per `groups.log` page, and the most a room opens with: the
/// newest of a long log, so a busy room opens in a few pages.
const int _kHermesRoomLogPageSize = 200;
const int _kHermesRoomLogWindow = 1000;

/// One send of a room message: the event id Hermes deduplicates it by, so
/// sending it again after an unclear answer never posts it twice.
final class HermesRoomSend {
  HermesRoomSend({required this.text, String? eventId, String? threadId})
    : eventId = eventId ?? const Uuid().v4(),
      _threadId = threadId;

  final String text;
  final String eventId;
  final String? _threadId;

  /// A message starts its own thread unless it continues one.
  String get threadId => _threadId ?? eventId;

  /// The id the message has in the room's log once Hermes posted it:
  /// Hermes files a user's message under `user:` and the SHA-256 of the
  /// id it was sent with (`user_event_id` in gateway/hosted_rooms.py).
  String get logEventId => 'user:${sha256.convert(utf8.encode(eventId))}';

  /// [text] sent in place of these words, under the same id and thread:
  /// Hermes posts at most one message per id, so an edit sent after an
  /// unclear answer can never post next to the words it replaced.
  HermesRoomSend withText(String text) =>
      HermesRoomSend(text: text, eventId: eventId, threadId: _threadId);
}

/// The Group Chat calls (`groups.*`). Both Desktop Gateway wires serve
/// them with the same parameters; the canonical one refuses unknown keys,
/// so each call sends only the keys its method takes.
extension _HermesDesktopRooms on HermesDesktopApiService {
  Future<Map<String, dynamic>> _groups(
    String method,
    Map<String, Object?> params,
  ) async {
    await _ensureConnected();
    return _object(await _rpc.request<Object?>(method, params: params));
  }

  Future<HermesRoomCapabilities> _roomCapabilities() async =>
      HermesRoomCapabilities.fromJson(
        await _groups('groups.capabilities', const {}),
      );

  Future<HermesRoomState> _roomState(String roomId) async {
    final state = HermesRoomState.fromJson(
      await _groups('groups.state', {'room_id': roomId}),
    );
    if (state == null || state.room.id != roomId) {
      throw StateError('Hermes did not report this Group Chat.');
    }
    return state;
  }

  Future<HermesRoomLogPage> _roomLog(
    String roomId, {
    required int sinceSeq,
    int limit = _kHermesRoomLogPageSize,
  }) async => HermesRoomLogPage.fromJson(
    await _groups('groups.log', {
      'room_id': roomId,
      'since_seq': sinceSeq,
      'limit': limit,
    }),
    sinceSeq,
  );

  /// Every event after [sinceSeq], page by page; from the start of a long
  /// log only its newest [_kHermesRoomLogWindow].
  Future<List<HermesRoomEvent>> _roomEventsSince(
    String roomId, {
    required int sinceSeq,
    int? latestSeq,
  }) async {
    var cursor = sinceSeq;
    if (cursor == 0 && latestSeq != null) {
      cursor = max(0, latestSeq - _kHermesRoomLogWindow);
    }
    final events = <HermesRoomEvent>[];
    for (var page = 0; page < 64; page++) {
      final result = await _roomLog(roomId, sinceSeq: cursor);
      events.addAll(result.events);
      if (!result.hasMore) break;
      if (result.cursor <= cursor) {
        throw StateError('Hermes returned an invalid Group Chat cursor.');
      }
      cursor = result.cursor;
    }
    return events;
  }

  Future<HermesRoom> _createRoom({
    required String name,
    required List<HermesRoomMember> members,
  }) async {
    final result = await _groups('groups.create', {
      'room_id': const Uuid().v4(),
      'name': name,
      'members': [for (final member in members) member.toCreateJson()],
    });
    return HermesRoom.fromJson(result['room']) ??
        (throw StateError('Hermes did not return the new Group Chat.'));
  }

  Future<void> _sendRoomMessage(String roomId, HermesRoomSend send) async {
    final result = await _groups('groups.send', {
      'room_id': roomId,
      'event_id': send.eventId,
      'payload': {'text': send.text, 'thread_id': send.threadId},
    });
    // Delivered only on a receipt for this exact message.
    if (result['client_event_id'] != send.eventId ||
        (result.containsKey('accepted') && result['accepted'] != true)) {
      throw StateError('Hermes did not confirm the message.');
    }
  }

  Future<void> _renameRoom(String roomId, String name) => _groups(
    'groups.rename',
    {'room_id': roomId, 'event_id': const Uuid().v4(), 'name': name},
  );

  Future<HermesRoomContext?> _setRoomContext(
    String roomId,
    HermesRoomContext context,
  ) async {
    final routing = context.routing;
    final result = await _groups('groups.context', {
      'room_id': roomId,
      'event_id': const Uuid().v4(),
      'purpose': context.purpose.trim(),
      'notes': context.notes.trim(),
      // A Hermes without routing takes only purpose and notes.
      if (routing != null) 'routing': routing.name,
      if (routing != null)
        'lead_member_id': routing == HermesRoomRouting.lead
            ? context.leadMemberId ?? ''
            : '',
    });
    return HermesRoomContext.fromJson(result['context']);
  }

  Future<void> _disbandRoom(String roomId) => _groups('groups.disband', {
    'room_id': roomId,
    'cancel_id': const Uuid().v4(),
  });

  Future<int> _stopRoom(String roomId, String cancelId) async {
    final result = await _groups('groups.stop', {
      'room_id': roomId,
      'cancel_id': cancelId,
    });
    final cancelled = result['cancelled'];
    if (cancelled is! int || cancelled < 0) {
      throw StateError('Hermes did not confirm the stop.');
    }
    return cancelled;
  }

  Future<void> _continueRoomDiscussion(
    String roomId,
    String discussionEventId,
  ) => _groups('groups.continue', {
    'room_id': roomId,
    'discussion_event_id': discussionEventId,
  });

  Future<void> _answerRoomAction(
    String roomId,
    HermesRoomPendingAction action, {
    String? choice,
  }) async {
    final params = <String, Object?>{
      'room_id': roomId,
      'member_id': action.memberId,
      'task_id': action.taskId,
      'execution_generation': action.executionGeneration,
    };
    if (action.isApproval) {
      final allowed = choice == 'once'
          ? action.canAllowOnce
          : choice == 'deny' && action.canDeny;
      if (!allowed) {
        throw StateError('Hermes no longer offers this answer.');
      }
      await _groups('groups.approve', {
        ...params,
        'choice': choice,
        'request_id': action.requestId,
      });
      return;
    }
    if (!action.isRetry) {
      throw StateError('Hermes asked for an action this app cannot take.');
    }
    await _groups('groups.retry', params);
  }
}

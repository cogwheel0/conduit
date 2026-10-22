part of 'hermes_desktop_api_service.dart';

extension _HermesDesktopGroupStream on HermesDesktopApiService {
  Stream<HermesGroupLiveReply> _watchGroupReplies(HermesBotGroup group) {
    if (group.raw['hosted'] != true || group.hasScopedMembers) {
      return const Stream.empty();
    }
    late StreamController<HermesGroupLiveReply> output;
    StreamSubscription<HermesDesktopEvent>? events;
    Timer? timer;
    final members = <String, _GroupMemberLiveState>{};
    final early = Queue<HermesDesktopEvent>();
    var disposed = false, synchronizing = false;
    var generation = -1;

    void emit(_GroupMemberLiveState state) {
      if (!disposed && !output.isClosed && state.active) {
        output.add(state.reply);
      }
    }

    Future<void> synchronize() async {
      if (disposed || synchronizing || _closed) return;
      synchronizing = true;
      try {
        await _ensureConnected();
        if (disposed || _closed) return;
        if (generation != _rpc.socketGeneration) {
          members.clear();
          early.clear();
          generation = _rpc.socketGeneration;
        }
        for (final profile in group.memberProfiles) {
          if (disposed || _closed) return;
          final current = members[profile];
          if (current != null && !current.snapshots) continue;
          try {
            final stored =
                current?.storedId ??
                await findGroupMemberSession(group, profile);
            if (stored == null || disposed) continue;
            // A lazy, history-free attachment observes the existing native
            // worker. It never submits a prompt or takes ownership of its turn.
            final resumed = _object(
              await _rpc.request<Object?>(
                'session.resume',
                params: {
                  'session_id': stored,
                  'profile': profile,
                  'lazy': true,
                  'omit_messages': true,
                },
              ),
            );
            if (disposed) return;
            final runtime = validateHermesOpaqueIdentifier(
              resumed['session_id'],
            );
            if (runtime == null) continue;
            final state = current != null && current.runtimeId == runtime
                ? current
                : _GroupMemberLiveState(profile, stored, runtime);
            members[profile] = state;
            if (current == state && state.snapshots) {
              state.restoreSnapshot(resumed);
              emit(state);
              continue;
            }
            Map<String, dynamic> replay;
            try {
              replay = _object(
                await _rpc.request<Object?>(
                  'session.events.since',
                  params: {
                    'session_id': runtime,
                    'profile': profile,
                    'last_seen': 0,
                  },
                ),
              );
            } on HermesDesktopRpcException catch (error) {
              if (error.code != -32601) rethrow;
              replay = {'truncated': true};
            }
            if (disposed) return;
            final frames = <HermesDesktopEvent>[];
            for (final row in _objects(replay['events'])) {
              final data = row['params'] is Map ? _object(row['params']) : row;
              if (data['session_id'] != runtime || data['type'] is! String) {
                continue;
              }
              frames.add(
                HermesDesktopEvent(
                  type: data['type'] as String,
                  sessionId: runtime,
                  sequence: data['seq'] is int ? data['seq'] as int : null,
                  payload: _object(data['payload']),
                ),
              );
            }
            state.epoch = replay['epoch']?.toString() ?? '';
            final start = frames.lastIndexWhere(
              (event) => event.type == 'message.start',
            );
            if (replay['truncated'] == true || start < 0) {
              // A replay ring can evict the beginning of a long reply. Restore
              // full in-flight snapshots until the next turn boundary instead
              // of appending an overlapping or incomplete replay tail.
              state.snapshots = true;
              state.restoreSnapshot(resumed);
              emit(state);
            } else {
              final currentFrames = frames.skip(start).toList();
              final settled = currentFrames.any(
                (e) =>
                    e.type == 'message.complete' ||
                    e.type == 'session.info' && e.payload['running'] == false,
              );
              if (resumed['running'] == true || !settled) {
                for (final frame in currentFrames) {
                  state.apply(frame);
                }
                emit(state);
              }
            }
            final latest = replay['latest_seq'];
            if (latest is int && latest > state.sequence) {
              state.sequence = latest;
            }
            state.ready = true;
            for (final frame
                in early.where((e) => e.sessionId == runtime).toList()) {
              if (state.apply(frame)) emit(state);
            }
            early.removeWhere((e) => e.sessionId == runtime);
          } catch (_) {
            // Observing is optional. Durable log recovery continues independently
            // if the gateway reconnects or does not expose live session frames.
            members.remove(profile);
          }
        }
      } catch (_) {
        members.clear();
      } finally {
        synchronizing = false;
      }
    }

    output = StreamController<HermesGroupLiveReply>(
      onListen: () {
        events = _rpc.events.listen((event) {
          if (disposed) return;
          final state = members.values
              .where((m) => m.runtimeId == event.sessionId)
              .firstOrNull;
          if (state == null || !state.ready) {
            if (synchronizing) {
              early.addLast(event);
              if (early.length > 512) early.removeFirst();
            }
            return;
          }
          if (state.apply(event)) emit(state);
        });
        timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (_closed) {
            timer?.cancel();
            unawaited(output.close());
          } else {
            unawaited(synchronize());
          }
        });
        unawaited(synchronize());
      },
      onCancel: () async {
        disposed = true;
        timer?.cancel();
        await events?.cancel();
        members.clear();
        early.clear();
        // No session.close/interrupt: these turns belong to the persistent driver.
      },
    );
    return output.stream;
  }
}

class _GroupMemberLiveState {
  _GroupMemberLiveState(this.profile, this.storedId, this.runtimeId);
  final String profile, storedId, runtimeId;
  String epoch = '', id = '', text = '', reasoning = '';
  int sequence = 0;
  bool ready = false, active = false, complete = false, snapshots = false;
  final tools = <HermesToolProgress>[];
  HermesGroupLiveReply get reply => HermesGroupLiveReply(
    id: id,
    profile: profile,
    text: text,
    reasoning: reasoning,
    tools: List.unmodifiable(tools),
    complete: complete,
  );

  void restoreSnapshot(Map<String, dynamic> resumed) {
    final inflight = resumed['inflight'];
    if (inflight is! Map || resumed['running'] != true) {
      if (active) complete = true;
      snapshots = false;
      return;
    }
    final identity =
        '${resumed['turn_started_at'] ?? ''}:${inflight['user'] ?? ''}';
    final next =
        '$runtimeId:$epoch:snapshot:${sha256.convert(utf8.encode(identity))}';
    if (id != next) {
      tools.clear();
      reasoning = '';
    }
    id = next;
    active = true;
    complete = false;
    text = (inflight['assistant'] is String
        ? inflight['assistant'] as String
        : '');
  }

  bool apply(HermesDesktopEvent event) {
    if (event.sequence != null && event.sequence! <= sequence) return false;
    if (event.sequence != null) sequence = event.sequence!;
    if (event.type == 'message.start') {
      id = '$runtimeId:$epoch:${event.sequence ?? sequence}';
      text = '';
      reasoning = '';
      tools.clear();
      active = true;
      complete = false;
      snapshots = false;
      return true;
    }
    if (!active) return false;
    // Full snapshot recovery owns text until a new message.start provides an
    // unambiguous sequence boundary. Tool events still arrive immediately.
    if (snapshots &&
        (event.type == 'message.delta' || event.type == 'message.interim')) {
      return false;
    }
    String value(String key) => event.payload[key]?.toString() ?? '';
    var changed = false;
    if (_projectHermesTurnEvent(
      event,
      value: value,
      firstValue: (keys) =>
          keys.map(value).firstWhere((s) => s.isNotEmpty, orElse: () => ''),
      add: (update) {
        if (update is HermesTokenDelta) {
          text += update.content;
          changed = true;
        }
        if (update is HermesReasoningDelta) {
          reasoning += update.content;
          changed = true;
        }
        if (update is HermesToolProgress) {
          final index = tools.lastIndexWhere(
            (t) => t.toolName == update.toolName && !t.done,
          );
          if (index >= 0) {
            tools[index] = update;
          } else if (tools.length < 200) {
            tools.add(update);
          }
          changed = true;
        }
      },
    )) {
      if (text.length > 240000) {
        text = text.substring(0, 240000);
      }
      if (reasoning.length > 64000) {
        reasoning = reasoning.substring(0, 64000);
      }
      return changed;
    }
    if (event.type == 'message.complete') {
      final full = value('content').isNotEmpty
          ? value('content')
          : value('text');
      if (full.isNotEmpty) text = full;
      complete = true;
      return true;
    }
    if (event.type == 'session.info' && event.payload['running'] == false) {
      complete = true;
      return true;
    }
    return false;
  }
}

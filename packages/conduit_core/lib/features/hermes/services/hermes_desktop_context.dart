part of 'hermes_desktop_api_service.dart';

/// The most sessions whose last turn usage is kept.
const int _kMaxHermesRememberedUsage = 64;

extension _HermesDesktopContext on HermesDesktopApiService {
  void _rememberTurnUsage(String storedId, Map<dynamic, dynamic> usage) {
    _lastTurnUsage.remove(storedId);
    if (_lastTurnUsage.length >= _kMaxHermesRememberedUsage) {
      _lastTurnUsage.remove(_lastTurnUsage.keys.first);
    }
    _lastTurnUsage[storedId] = Map<String, dynamic>.from(usage);
  }

  /// Reads [storedId]'s usage (`session.usage`, or `session.stats` from a
  /// session authority), its context breakdown, the account's usage bars
  /// and the provider's plan row. A read the gateway refuses is left out;
  /// the report fails only when neither usage nor breakdown answers.
  Future<HermesContextReport> _contextReport(String storedId) async {
    final binding = await _resume(storedId);
    final scope = _sessionScope(binding.storedId);
    final session = {'session_id': binding.runtimeId, ...scope};
    Object? failure;
    Future<Map<String, dynamic>?> read(
      String method,
      Map<String, Object?> params,
    ) async {
      try {
        return _object(await _rpc.request<Object?>(method, params: params));
      } on HermesDesktopRpcException catch (error) {
        failure ??= error;
        return null;
      }
    }

    final usage = await read(
      _canonical ? 'session.stats' : 'session.usage',
      session,
    );
    final breakdown = await read('session.context_breakdown', session);
    if (usage == null && breakdown == null) throw failure!;
    final bars = await read('usage.bars', scope);
    final options = await read('model.options', session);
    return hermesDesktopContextReport(
      usage: _canonical ? null : usage,
      stats: _canonical ? usage : null,
      breakdown: breakdown,
      bars: bars,
      modelOptions: options,
      lastTurnUsage: _lastTurnUsage[binding.storedId],
    );
  }

  /// Compacts [storedId]: `session.compress` on the legacy wire, a fenced
  /// `compress` edit on a session authority. A changed transcript is read
  /// again by the chat showing it.
  Future<HermesCompactResult> _compactSession(
    String storedId, {
    String? focus,
  }) async {
    final binding = await _resume(storedId);
    final topic = focus?.trim();
    final hasTopic = topic != null && topic.isNotEmpty;
    final Map<String, dynamic> result;
    if (_canonical) {
      result = await _canonicalMutate(binding, 'compress', {
        if (hasTopic) 'focus': topic,
      });
    } else {
      result = _object(
        await _rpc.request<Object?>(
          'session.compress',
          params: {
            'session_id': binding.runtimeId,
            if (hasTopic) 'focus_topic': topic,
            ..._sessionScope(binding.storedId),
          },
        ),
      );
    }
    final compacted = HermesCompactResult.fromJson(result);
    if (compacted.changed) {
      _compactedTranscript(binding, storedId);
    } else if (compacted.outcome == HermesCompactOutcome.pending) {
      _watchPendingCompaction(binding, storedId);
    }
    return compacted;
  }

  /// [binding]'s transcript was compacted: what was read of it is stale,
  /// and its chat reads it again, even if shorter.
  void _compactedTranscript(HermesSessionBinding binding, String storedId) {
    _lastTranscripts
      ..remove(storedId)
      ..remove(binding.storedId);
    _lastTurnUsage.remove(binding.storedId);
    for (final id in {binding.storedId, storedId}) {
      _compactedTranscripts.add(id);
      _emitTranscriptChange(id);
    }
  }

  /// A compaction Hermes finishes in the background (a turn-isolated
  /// session's host outlasting the wait) ends with a `compacted` status,
  /// or with its own error ("compression failed: …"). Compacted, its chat
  /// and report are read again; failed, or not heard from by the deadline,
  /// only its report is, and a shorter read of the chat is not taken. Other
  /// session info, and an ordinary turn's error, say nothing about it.
  void _watchPendingCompaction(
    HermesSessionBinding binding,
    String storedId,
  ) {
    final runtimeId = binding.runtimeId;
    unawaited(_pendingCompactions.remove(runtimeId)?.cancel());
    late final _PendingCompaction watch;
    void end() {
      if (identical(_pendingCompactions[runtimeId], watch)) {
        _pendingCompactions.remove(runtimeId);
      }
      unawaited(watch.cancel());
    }

    final subscription = _rpc.events
        .where(
          (event) =>
              event.sessionId == runtimeId &&
              ((event.type == 'error' &&
                      '${event.payload['message']}'.startsWith(
                        'compression failed',
                      )) ||
                  (event.type == 'status.update' &&
                      event.payload['kind'] == 'compacted')),
        )
        .listen((event) {
          end();
          if (event.type == 'status.update') {
            _compactedTranscript(binding, storedId);
          } else {
            _emitTranscriptChange(storedId);
          }
        });
    watch = _PendingCompaction(
      subscription,
      Timer(pendingCompactionDeadline, () {
        end();
        _emitTranscriptChange(storedId);
      }),
    );
    _pendingCompactions[runtimeId] = watch;
  }

  /// Turns on a window plan's "Keep going on credits"; false when Hermes
  /// could not (no billing access, a portal error).
  Future<bool> _keepGoingOnCredits() async {
    await _ensureConnected();
    final Map<String, dynamic> result;
    try {
      result = _object(
        await _rpc.request<Object?>(
          'billing.keep_going_on_credits',
          params: const {'enabled': true},
        ),
      );
    } on HermesDesktopRpcException catch (error) {
      // A refusal (no billing access, a portal error) is a no, so the card
      // can offer the billing page instead. A lost answer is not one.
      if (error.deliveryAmbiguous) rethrow;
      return false;
    }
    return result['ok'] != false && result['error'] == null;
  }
}

/// A compaction Hermes is finishing in the background: its watch and its
/// deadline.
final class _PendingCompaction {
  _PendingCompaction(this._subscription, this._deadline);

  final StreamSubscription<HermesDesktopEvent> _subscription;
  final Timer _deadline;

  Future<void> cancel() {
    _deadline.cancel();
    return _subscription.cancel();
  }
}

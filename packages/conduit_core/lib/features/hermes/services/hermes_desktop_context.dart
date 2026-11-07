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
    final pending = compacted.outcome == HermesCompactOutcome.pending;
    if (compacted.changed || pending) {
      _lastTranscripts
        ..remove(storedId)
        ..remove(binding.storedId);
      _lastTurnUsage.remove(binding.storedId);
      _emitTranscriptChange(binding.storedId);
    }
    return compacted;
  }

  /// Turns on a window plan's "Keep going on credits"; false when Hermes
  /// could not (no billing access, a portal error).
  Future<bool> _keepGoingOnCredits() async {
    await _ensureConnected();
    final result = _object(
      await _rpc.request<Object?>(
        'billing.keep_going_on_credits',
        params: const {'enabled': true},
      ),
    );
    return result['ok'] != false && result['error'] == null;
  }
}

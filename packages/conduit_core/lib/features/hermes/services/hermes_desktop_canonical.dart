part of 'hermes_desktop_api_service.dart';

/// A session's fences on the canonical wire (a gateway's own Webapp
/// listener): the revision an edit must name, the execution generation of
/// its turn (what a stop, a steer or an answer must name), and this
/// socket's subscription to its events.
final class _HermesCanonicalSession {
  int? revision;
  int? generation;
  String? subscriptionId;
  int? subscriptionSocket;
}

/// The most sessions whose fences are kept; the least recently used go.
const int _kMaxHermesCanonicalSessions = 256;

/// Steer refusals that say the text never reached the turn, so it is safe
/// to send as the next prompt instead.
const Set<String> _kHermesCanonicalUndeliveredSteer = {
  'execution_not_ready',
  'stale_generation',
  'unsupported_control',
};

/// Refusals of an edit that named fences Hermes has moved past. Nothing
/// changed, and the refusal names the current fences.
const Set<String> _kHermesCanonicalFenceRefusals = {
  'revision_conflict',
  'stale_generation',
};

/// `session.create`'s parameters on the canonical wire: only keys a session
/// authority takes, the options under their canonical names (`reasoning`,
/// `service_tier`), as a GUI session. [requestId] makes a retried create
/// answer with the session the first attempt made.
@visibleForTesting
Map<String, Object?> hermesCanonicalCreateParams({
  required String requestId,
  String? model,
  String? provider,
  String? reasoning,
  bool? fast,
  String? profile,
  bool hidden = false,
  String? title,
}) => {
  'request_id': requestId,
  'source': 'gui',
  'model': ?model,
  'provider': ?provider,
  'reasoning': ?reasoning,
  if (fast != null) 'service_tier': fast ? 'priority' : 'normal',
  'profile': ?profile,
  if (hidden) 'hidden': true,
  'title': ?title,
};

/// The session edit a typed slash command stands for on the canonical wire,
/// which runs `/model <name>`, `/branch [title]` and `/compress [focus]` as
/// edits rather than commands. Null for any other command, and for `/model`
/// with flags, which the gateway refuses by name.
@visibleForTesting
({String operation, Map<String, Object?> payload})?
hermesCanonicalSlashMutation(String command) {
  final words = command
      .trim()
      .replaceFirst(RegExp(r'^/+'), '')
      .split(RegExp(r'\s+'));
  final name = words.first;
  final argument = words.skip(1).join(' ').trim();
  switch (name) {
    case 'model':
      final parts = argument.split(' ');
      if (argument.isEmpty || argument.startsWith('-') || parts.length > 1) {
        return null;
      }
      return (operation: 'model', payload: {'model': argument});
    case 'branch':
      return (
        operation: 'branch',
        payload: {if (argument.isNotEmpty) 'title': argument},
      );
    case 'compress':
      return (
        operation: 'compress',
        payload: {if (argument.isNotEmpty) 'focus': argument},
      );
  }
  return null;
}

/// What a canonical slash edit's receipt says, shown as the command's
/// output.
@visibleForTesting
String hermesCanonicalMutationSummary(
  String operation,
  Map<String, dynamic> receipt,
) {
  String text(String key) => receipt[key]?.toString() ?? '';
  if (receipt['status'] == 'confirmation_required') {
    return text('confirm_message').isNotEmpty
        ? text('confirm_message')
        : '$operation: confirmation required';
  }
  switch (operation) {
    case 'model':
      if (text('note').isNotEmpty) return text('note');
      final provider = text('provider');
      return 'model: ${text('model')}${provider.isEmpty ? '' : ' ($provider)'}';
    case 'branch':
      return 'branch: ${text('branched_session_id')}';
    case 'compress':
      final lines = receipt['lines'];
      if (receipt['status'] == 'preview' && lines is List) {
        return lines.join('\n');
      }
      final target = text('target_session_id');
      return 'compress: ${target.isEmpty ? text('session_id') : target}';
  }
  return '$operation: ok';
}

extension _HermesDesktopCanonical on HermesDesktopApiService {
  /// Whether this socket speaks the canonical wire.
  bool get _canonical => _rpc.sessionAuthority;

  _HermesCanonicalSession _canonicalSession(String sessionId) {
    final session =
        _canonicalSessions.remove(sessionId) ?? _HermesCanonicalSession();
    if (_canonicalSessions.length >= _kMaxHermesCanonicalSessions) {
      _canonicalSessions.remove(_canonicalSessions.keys.first);
    }
    return _canonicalSessions[sessionId] = session;
  }

  /// Raises [sessionId]'s fences to [revision] and [generation]; they never
  /// move back, so a replayed event or an older receipt changes nothing.
  void _adoptCanonicalFences(
    String sessionId, {
    Object? revision,
    Object? generation,
  }) {
    if (revision is! int && generation is! int) return;
    final session = _canonicalSession(sessionId);
    if (revision is int && revision > (session.revision ?? -1)) {
      session.revision = revision;
    }
    if (generation is int && generation > (session.generation ?? -1)) {
      session.generation = generation;
    }
  }

  /// Adopts a `session.create` / `session.resume` snapshot: its fences, the
  /// socket's subscription, and the approvals and questions still open.
  void _adoptCanonicalSnapshot(
    String sessionId,
    Map<String, dynamic> snapshot,
  ) {
    _adoptCanonicalFences(
      sessionId,
      revision: snapshot['revision'],
      generation: snapshot['execution_generation'],
    );
    final subscription = validateHermesOpaqueIdentifier(
      snapshot['subscription_id'],
    );
    if (subscription != null) {
      _canonicalSession(sessionId)
        ..subscriptionId = subscription
        ..subscriptionSocket = _rpc.socketGeneration;
    }
    _rpc.replayCanonicalPrompts(sessionId, snapshot['prompts']);
  }

  /// Tracks the fences events carry: every turn event names its execution
  /// generation, and `session.info` / `session.updated` the revision too.
  void _observeCanonicalEvent(HermesDesktopEvent event) {
    final sessionId = event.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    final fences =
        event.type == 'session.info' || event.type == 'session.updated';
    final payload = event.payload;
    _adoptCanonicalFences(
      sessionId,
      revision: fences ? payload['revision'] : null,
      generation:
          event.executionGeneration ??
          (fences ? payload['execution_generation'] : null),
    );
  }

  /// [binding]'s fences, read from a fresh snapshot when not known yet (a
  /// branch made by another call) or when [refresh] asks.
  Future<_HermesCanonicalSession> _canonicalFences(
    HermesSessionBinding binding, {
    bool refresh = false,
  }) async {
    var session = _canonicalSessions[binding.runtimeId];
    if (refresh || session?.revision == null || session?.generation == null) {
      await _resumeSnapshot(binding.storedId, refresh: true);
      session = _canonicalSessions[binding.runtimeId];
    }
    if (session == null ||
        session.revision == null ||
        session.generation == null) {
      throw StateError('Hermes did not report the state of this chat.');
    }
    return session;
  }

  /// One fenced session edit (`session.mutate`). A refusal for stale fences
  /// changed nothing and names the current ones, so it is sent once more
  /// at those. A request whose answer was lost is kept, so a retry of the
  /// same edit is the same request and Hermes applies it once.
  Future<Map<String, dynamic>> _canonicalMutate(
    HermesSessionBinding binding,
    String operation,
    Map<String, Object?> payload, {
    bool fenceGeneration = true,
    bool retried = false,
  }) async {
    final sessionId = binding.runtimeId;
    final key = jsonEncode([sessionId, operation, payload]);
    var params = _canonicalMutations.remove(key);
    if (params == null) {
      final fences = await _canonicalFences(binding);
      params = {
        'session_id': sessionId,
        'request_id': const Uuid().v4(),
        'expected_revision': fences.revision,
        if (fenceGeneration) 'expected_generation': fences.generation,
        'operation': operation,
        'payload': payload,
      };
    }
    try {
      final result = _object(
        await _rpc.request<Object?>(
          'session.mutate',
          params: {...params, ..._sessionScope(binding.storedId)},
        ),
      );
      _adoptCanonicalFences(
        sessionId,
        revision: result['revision'],
        generation: result['execution_generation'],
      );
      return result;
    } on HermesDesktopRpcException catch (error) {
      if (error.deliveryAmbiguous) {
        if (_canonicalMutations.length >= 32) {
          _canonicalMutations.remove(_canonicalMutations.keys.first);
        }
        _canonicalMutations[key] = params;
        rethrow;
      }
      final data = error.data;
      if (data is Map) {
        _adoptCanonicalFences(
          sessionId,
          revision: data['revision'],
          generation: data['execution_generation'],
        );
      }
      if (retried || !_kHermesCanonicalFenceRefusals.contains(error.reason)) {
        rethrow;
      }
      if (data is! Map || data['revision'] is! int) {
        await _canonicalFences(binding, refresh: true);
      }
      return _canonicalMutate(
        binding,
        operation,
        payload,
        fenceGeneration: fenceGeneration,
        retried: true,
      );
    }
  }

  /// Leaves [binding]'s event stream on this socket (`session.detach`).
  Future<void> _canonicalDetach(HermesSessionBinding binding) async {
    final session = _canonicalSessions[binding.runtimeId];
    final subscription = session?.subscriptionId;
    if (session == null ||
        subscription == null ||
        session.subscriptionSocket != _rpc.socketGeneration ||
        !_rpc.isReady) {
      return;
    }
    await _rpc.request<Object?>(
      'session.detach',
      params: {
        'session_id': binding.runtimeId,
        'subscription_id': subscription,
        ..._sessionScope(binding.storedId),
      },
    );
    session.subscriptionId = null;
  }

  /// Stops [binding]'s turn. The admission a prompt was given is retired
  /// whether it is still queued or already running; otherwise the turn is
  /// interrupted at its execution generation, read again once when Hermes
  /// says it moved on.
  Future<void> _canonicalInterrupt(
    HermesSessionBinding binding, {
    String? admissionId,
  }) async {
    final scope = _sessionScope(binding.storedId);
    if (admissionId != null) {
      await _rpc.request<Object?>(
        'prompt.cancel',
        params: {
          'session_id': binding.runtimeId,
          'admission_id': admissionId,
          ...scope,
        },
      );
      return;
    }
    for (var attempt = 0; ; attempt++) {
      final fences = await _canonicalFences(binding, refresh: attempt > 0);
      try {
        await _rpc.request<Object?>(
          'session.interrupt',
          params: {
            'session_id': binding.runtimeId,
            'execution_generation': fences.generation,
            ...scope,
          },
        );
        return;
      } on HermesDesktopRpcException catch (error) {
        if (attempt > 0 || error.reason != 'stale_generation') rethrow;
      }
    }
  }

  /// Answers the canonical approval or question [promptId] (a `choice` for
  /// an approval, an `answer` for a question). False when Hermes no longer
  /// lists it: it was settled elsewhere or timed out.
  Future<bool> _answerCanonicalPrompt(
    String runtimeId,
    String promptId, {
    required String value,
  }) async {
    var prompt = _rpc.canonicalPrompt(promptId);
    if (prompt == null) {
      // After a restart or a new socket only a fresh snapshot lists it.
      await _resumeSnapshot(
        _storedIdForRuntime(runtimeId) ?? runtimeId,
        refresh: true,
      );
      prompt = _rpc.canonicalPrompt(promptId);
      if (prompt == null) return false;
    }
    await _rpc.request<Object?>(
      '${prompt.kind}.respond',
      params: {
        'session_id': prompt.sessionId,
        'execution_generation': prompt.generation,
        'prompt_id': promptId,
        prompt.kind == 'approval' ? 'choice' : 'answer': value,
        ..._runtimeScope(prompt.sessionId),
      },
    );
    return true;
  }
}

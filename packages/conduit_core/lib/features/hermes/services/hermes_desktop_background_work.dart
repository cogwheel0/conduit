part of 'hermes_desktop_api_service.dart';

/// Tools whose calls start, check on or stop background processes.
const _kHermesProcessTools = {'terminal', 'process'};

extension _HermesDesktopBackgroundWorkEvents on HermesDesktopApiService {
  /// Tells [HermesDesktopBackgroundWork.backgroundWorkHints] listeners that
  /// [event] suggests a chat's background work changed: a subagent event,
  /// a terminal or process tool call, or a process completion notice.
  void _observeBackgroundWorkEvent(HermesDesktopEvent event) {
    final type = event.type;
    final payload = event.payload;
    final tool = payload['name'] ?? payload['tool_name'];
    final hint =
        type.startsWith('subagent.') ||
        (type == 'tool.complete' && _kHermesProcessTools.contains(tool)) ||
        (type == 'tool.start' && tool == 'delegate_task') ||
        (type == 'status.update' && payload['kind'] == 'process');
    final id = event.sessionId;
    if (!hint || id == null || id.isEmpty || _closed) return;
    _backgroundWorkHints.add(_storedIdForRuntime(id) ?? id);
  }

  /// [storedId]'s binding on the open socket, without resuming it: a list
  /// poll must not reattach a chat the app has let go.
  HermesSessionBinding? _liveBindingFor(String storedId) {
    final binding = _bindings[storedId];
    if (binding == null ||
        !_rpc.isReady ||
        _bindingSocketGenerations[storedId] != _rpc.socketGeneration) {
      return null;
    }
    return binding;
  }

  Map<String, dynamic> _backgroundWorkParams(HermesSessionBinding binding) =>
      {'session_id': binding.runtimeId, ..._sessionScope(binding.storedId)};

  /// [method]'s result, or null when the gateway does not serve it.
  Future<Object?> _optionalBackgroundRead(
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      return await _rpc.request<Object?>(method, params: params);
    } on HermesDesktopRpcException catch (error) {
      if (error.code == -32601) return null;
      rethrow;
    }
  }
}

/// The background work of a Desktop Gateway chat: the subagents its agent
/// delegated to and the processes it left running. Both wires serve it; a
/// session authority answers for its own sessions only.
extension HermesDesktopBackgroundWork on HermesDesktopApiService {
  /// Ids of chats whose background work may have changed (stored ids when
  /// known, else runtime ids). Match them with [isSameChat].
  Stream<String> get backgroundWorkHints => _backgroundWorkHints.stream;

  /// Whether [changedId] names the chat [storedId].
  bool isSameChat(String storedId, String changedId) {
    final binding = _bindings[storedId];
    return changedId == storedId ||
        changedId == binding?.storedId ||
        changedId == binding?.runtimeId;
  }

  /// [storedId]'s subagents and processes, or null while the chat is not
  /// attached on this socket (it attaches when it is opened).
  Future<HermesBackgroundWork?> backgroundWorkFor(String storedId) async {
    final binding = _liveBindingFor(storedId);
    if (binding == null) return null;
    final params = _backgroundWorkParams(binding);
    final results = await Future.wait([
      _optionalBackgroundRead('subagent.list', params),
      _optionalBackgroundRead('process.list', params),
    ]);
    return HermesBackgroundWork.fromResults(
      subagents: results[0],
      processes: results[1],
    );
  }

  /// The end of [subagentId]'s live transcript, or null while the chat is
  /// not attached on this socket: an output poll must not reattach it.
  Future<HermesSubagentTail?> subagentTail(
    String storedId,
    String subagentId,
  ) async {
    final binding = _liveBindingFor(storedId);
    if (binding == null) return null;
    return HermesSubagentTail.fromJson(
      await _rpc.request<Object?>(
        'subagent.tail',
        params: {
          ..._backgroundWorkParams(binding),
          'subagent_id': subagentId,
        },
      ),
    );
  }

  /// Queues [text] for [subagentId] to read at its next step. True when
  /// Hermes queued it, which is not yet delivered: a child past its last
  /// step never reads it.
  Future<bool> steerSubagent(
    String storedId,
    String subagentId,
    String text,
  ) async {
    final binding = await _resume(storedId);
    final result = _object(
      await _rpc.request<Object?>(
        'subagent.steer',
        params: {
          ..._backgroundWorkParams(binding),
          'subagent_id': subagentId,
          'text': text,
        },
      ),
    );
    return result['status'] == 'queued';
  }

  /// Stops [subagentId]. False when it had already finished.
  Future<bool> stopSubagent(String storedId, String subagentId) async {
    final binding = await _resume(storedId);
    final result = _object(
      await _rpc.request<Object?>(
        'subagent.interrupt',
        params: {
          ..._backgroundWorkParams(binding),
          'subagent_id': subagentId,
        },
      ),
    );
    return result['found'] == true;
  }

  /// Kills one of [storedId]'s background processes. Another chat's
  /// process, or one already gone, is [HermesProcessKillStatus.notFound].
  Future<HermesProcessKillResult> killBackgroundProcess(
    String storedId,
    String processId,
  ) async {
    final binding = await _resume(storedId);
    try {
      return HermesProcessKillResult.fromJson(
        await _rpc.request<Object?>(
          'process.kill',
          params: {
            ..._backgroundWorkParams(binding),
            'process_id': processId,
          },
        ),
      );
    } on HermesDesktopRpcException catch (error) {
      // The dashboard answers 4044; a session authority names the reason.
      if (error.code == 4044 || error.reason == 'process_not_found') {
        return const HermesProcessKillResult(
          status: HermesProcessKillStatus.notFound,
        );
      }
      rethrow;
    }
  }
}

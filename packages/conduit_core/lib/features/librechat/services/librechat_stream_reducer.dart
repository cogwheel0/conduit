import 'package:conduit_core/features/librechat/models/librechat_stream_event.dart';

/// Builds a LibreChat reply's parts from its stream, for display while it
/// streams.
///
/// A port of the parts of the web client's step handler
/// (`client/src/hooks/SSE/useStepHandler.ts`, v0.8.8) that shape what the
/// reply shows: run steps open a part at a content index; message and
/// reasoning deltas append text to it; tool-call steps, their argument deltas
/// and their completions fill in a tool call. Deltas that arrive before their
/// step are held until it does. A resumed stream starts from the server's
/// snapshot and replays the events since.
///
/// It is for display only. The final frame's saved reply, or the reply
/// fetched again after a `reconcile` frame, replaces whatever was built here.
final class LibreChatStreamReducer {
  LibreChatStreamReducer({this.responseMessageId});

  /// The reply's message id, once a step or the snapshot names it.
  String? responseMessageId;

  /// The user's message as the server saved it, from the `created` frame.
  Map<String, dynamic>? userMessage;

  /// Files tools produced, in arrival order.
  final List<Map<String, dynamic>> attachments = <Map<String, dynamic>>[];

  /// The approval or question the run is paused on, if any.
  Map<String, dynamic>? pendingAction;

  /// The conversation title the server generated, if it sent one.
  String? title;

  /// The terminal frame, once it arrived.
  LibreChatStreamFinal? finalFrame;

  /// What a failed stream said.
  String? error;

  final List<Map<String, dynamic>?> _parts = <Map<String, dynamic>?>[];
  final Map<String, _Step> _steps = <String, _Step>{};
  final Map<String, List<LibreChatStreamStep>> _held =
      <String, List<LibreChatStreamStep>>{};

  static const String _prelimResponseId = 'USE_PRELIM_RESPONSE_MESSAGE_ID';

  /// The reply's parts so far, in content order.
  List<Map<String, dynamic>> get parts => [
    for (final part in _parts)
      if (part != null) Map<String, dynamic>.of(part),
  ];

  bool get isDone => finalFrame != null || error != null;

  /// Folds [event] in. Returns whether what the reply shows changed.
  bool apply(LibreChatStreamEvent event) {
    switch (event) {
      case LibreChatStreamCreated(:final userMessage):
        this.userMessage = userMessage;
        return false;
      case LibreChatStreamStep():
        return _applyStep(event);
      case LibreChatStreamAttachment(:final attachment):
        attachments.add(attachment);
        return true;
      case LibreChatStreamTitle(title: final value):
        if (value.trim().isEmpty) return false;
        title = value;
        return false;
      case LibreChatStreamPendingAction(:final action):
        pendingAction = action;
        return true;
      case LibreChatStreamSync():
        return _applySync(event);
      case LibreChatStreamFinal():
        return _applyFinal(event);
      case LibreChatStreamFailed(:final message):
        error = message;
        return true;
      case LibreChatStreamIgnored():
        return false;
    }
  }

  /// Forgets the pause once the user answered it.
  void clearPendingAction() => pendingAction = null;

  bool _applySync(LibreChatStreamSync sync) {
    final state = sync.resumeState;
    var changed = false;
    if (state != null) {
      final responseId = state['responseMessageId'];
      if (responseId is String && responseId.isNotEmpty) {
        responseMessageId = responseId;
      }
      final user = state['userMessage'];
      if (user is Map) userMessage = Map<String, dynamic>.from(user);
      final steps = state['runSteps'];
      if (steps is List) {
        for (final step in steps) {
          if (step is Map) _remember(Map<String, dynamic>.from(step));
        }
      }
      // The snapshot replaces what was built, unless it is empty and there
      // is already something to show (the web client's rule).
      final content = state['aggregatedContent'];
      if (content is List && (content.isNotEmpty || _parts.isEmpty)) {
        _parts
          ..clear()
          ..addAll([
            for (final part in content)
              part is Map ? Map<String, dynamic>.from(part) : null,
          ]);
        changed = true;
      }
      // The snapshot carries the live pause, if any: one missing from it
      // was answered meanwhile (on another device, say). A pause that
      // landed after the snapshot comes back among the pending events.
      final action = state['pendingAction'];
      if (action is Map) {
        pendingAction = Map<String, dynamic>.from(action);
        changed = true;
      } else if (pendingAction != null) {
        pendingAction = null;
        changed = true;
      }
      final titleEvent = state['titleEvent'];
      if (titleEvent is Map && titleEvent['data'] is Map) {
        final value = (titleEvent['data'] as Map)['title'];
        if (value is String && value.trim().isNotEmpty) title = value;
      }
    }
    for (final pending in sync.pendingEvents) {
      changed = apply(pending) || changed;
    }
    return changed;
  }

  bool _applyFinal(LibreChatStreamFinal frame) {
    finalFrame = frame;
    pendingAction = null;
    final response = frame.responseMessage;
    if (response == null) return false;
    final id = response['messageId'];
    if (id is String && id.isNotEmpty) responseMessageId = id;
    final content = response['content'];
    if (content is List) {
      _parts
        ..clear()
        ..addAll([
          for (final part in content)
            part is Map ? Map<String, dynamic>.from(part) : null,
        ]);
    }
    final title = frame.title;
    if (title != null) this.title = title;
    return true;
  }

  _Step? _remember(Map<String, dynamic> runStep) {
    final id = runStep['id'];
    final index = runStep['index'];
    if (id is! String || index is! int) return null;
    final details = runStep['stepDetails'];
    final runId = runStep['runId'];
    final step = _Step(
      id: id,
      index: index,
      isToolCalls: details is Map && details['type'] == 'tool_calls',
    );
    _steps[id] = step;
    if (runId is String && runId.isNotEmpty && runId != _prelimResponseId) {
      responseMessageId ??= runId;
    }
    return step;
  }

  bool _applyStep(LibreChatStreamStep event) {
    final data = event.data;
    switch (event.name) {
      case 'on_run_step':
        final step = _remember(data);
        if (step == null) return false;
        var changed = false;
        final details = data['stepDetails'];
        if (step.isToolCalls && details is Map) {
          final calls = details['tool_calls'];
          if (calls is List) {
            for (final call in calls) {
              if (call is! Map) continue;
              final callId = call['id'];
              if (callId is String && callId.isNotEmpty) {
                step.toolCallId = callId;
              }
              changed =
                  _updateToolCall(step.index, {
                    'id': callId,
                    'name': call['name'],
                    'args': call['args'],
                    'stepId': step.id,
                  }) ||
                  changed;
            }
          }
        }
        final held = _held.remove(step.id);
        if (held != null) {
          for (final heldEvent in held) {
            changed = _applyStep(heldEvent) || changed;
          }
        }
        return changed;
      case 'on_agent_update':
        final update = data['agent_update'];
        if (update is! Map || update['index'] is! int) return false;
        _setPart(update['index'] as int, {
          'type': 'agent_update',
          'agent_update': Map<String, dynamic>.from(update),
        });
        return true;
      case 'on_message_delta':
      case 'on_reasoning_delta':
        final step = _stepFor(event);
        if (step == null) return false;
        final delta = data['delta'];
        final content = delta is Map ? delta['content'] : null;
        final pieces = content is List
            ? content
            : content == null
            ? const <Object?>[]
            : [content];
        var changed = false;
        for (final piece in pieces) {
          if (piece is! Map) continue;
          changed = _appendDelta(step.index, piece) || changed;
        }
        return changed;
      case 'on_run_step_delta':
        final step = _stepFor(event);
        if (step == null) return false;
        final delta = data['delta'];
        if (delta is! Map || delta['type'] != 'tool_calls') return false;
        final calls = delta['tool_calls'];
        if (calls is! List) return false;
        var changed = false;
        for (final call in calls) {
          if (call is! Map) continue;
          final callId = call['id'];
          changed =
              _updateToolCall(step.index, {
                'id': callId is String && callId.isNotEmpty
                    ? callId
                    : step.toolCallId,
                'name': call['name'],
                'args': call['args'] ?? '',
                'stepId': step.id,
                'auth': ?delta['auth'],
                'expires_at': ?delta['expires_at'],
              }) ||
              changed;
        }
        return changed;
      case 'on_run_step_completed':
        final result = data['result'];
        if (result is! Map) return false;
        final step = _steps[result['id']];
        final call = result['tool_call'];
        if (step == null || call is! Map) return false;
        return _updateToolCall(step.index, {
          ...Map<String, dynamic>.from(call),
          'stepId': step.id,
        }, finalUpdate: true);
    }
    return false;
  }

  /// The step a delta belongs to, or null after holding the delta until
  /// that step arrives.
  _Step? _stepFor(LibreChatStreamStep event) {
    final id = event.data['id'];
    if (id is! String) return null;
    final step = _steps[id];
    if (step == null) {
      (_held[id] ??= <LibreChatStreamStep>[]).add(event);
    }
    return step;
  }

  void _setPart(int index, Map<String, dynamic> part) {
    while (_parts.length <= index) {
      _parts.add(null);
    }
    _parts[index] = part;
  }

  bool _appendDelta(int index, Map<dynamic, dynamic> piece) {
    final type = piece['type'];
    if (type is! String) return false;
    final existing = index < _parts.length ? _parts[index] : null;
    final existingType = existing?['type'] as String?;
    if (existingType != null && !_compatible(existingType, type)) return false;
    if (type.startsWith('text') && piece['text'] is String) {
      final current = _textOf(existing?['text']);
      _setPart(index, {
        ...?existing,
        'type': 'text',
        'text': current + (piece['text'] as String),
      });
      return true;
    }
    if (type.startsWith('think') && piece['think'] is String) {
      final current = _textOf(existing?['think']);
      _setPart(index, {
        ...?existing,
        'type': 'think',
        'think': current + (piece['think'] as String),
      });
      return true;
    }
    if (existing == null) {
      _setPart(index, Map<String, dynamic>.from(piece));
      return true;
    }
    return false;
  }

  bool _updateToolCall(
    int index,
    Map<String, dynamic> incoming, {
    bool finalUpdate = false,
  }) {
    final existing = index < _parts.length ? _parts[index] : null;
    if (existing != null && existing['type'] != 'tool_call') return false;
    final current = existing?['tool_call'] is Map
        ? Map<String, dynamic>.from(existing!['tool_call'] as Map)
        : <String, dynamic>{};
    final incomingArgs = incoming['args'];
    final currentArgs = current['args'];
    Object? args;
    if (finalUpdate || currentArgs is Map || incomingArgs is Map) {
      args = incomingArgs ?? currentArgs;
    } else {
      args = '${currentArgs ?? ''}${incomingArgs ?? ''}';
    }
    String? firstNonEmpty(Object? a, Object? b) {
      if (a is String && a.isNotEmpty) return a;
      if (b is String && b.isNotEmpty) return b;
      return null;
    }

    final next = <String, dynamic>{
      ...current,
      'type': 'tool_call',
      'id': firstNonEmpty(incoming['id'], current['id']) ?? '',
      'name': firstNonEmpty(incoming['name'], current['name']) ?? '',
      'args': args,
      'stepId': ?firstNonEmpty(incoming['stepId'], current['stepId']),
      'auth': ?incoming['auth'],
      'expires_at': ?incoming['expires_at'],
    };
    if (finalUpdate) {
      next['progress'] = 1;
      next['output'] = incoming['output'];
    }
    _setPart(index, {'type': 'tool_call', 'tool_call': next});
    return true;
  }

  static bool _compatible(String existing, String incoming) =>
      existing == incoming ||
      existing.startsWith(incoming) ||
      incoming.startsWith(existing);

  static String _textOf(Object? value) {
    if (value is String) return value;
    if (value is Map && value['value'] is String) {
      return value['value'] as String;
    }
    return '';
  }
}

final class _Step {
  _Step({required this.id, required this.index, required this.isToolCalls});

  final String id;
  final int index;
  final bool isToolCalls;
  String? toolCallId;
}

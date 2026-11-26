part of 'deepseek_harness_client.dart';

class HarnessMessage {
  const HarnessMessage(this.role, this.text, {this.streaming = false});
  final String role;
  final String text;
  final bool streaming;
}

class HarnessTranscript {
  const HarnessTranscript({
    required this.messages,
    required this.running,
    required this.needsWorkspace,
    this.hasPendingRequest = false,
    this.lastTurnFailed = false,
    required this.hasMore,
    this.title,
    this.modelId,
    this.modelProvider,
  });
  final List<HarnessMessage> messages;
  final bool running;
  final bool needsWorkspace;
  final bool hasPendingRequest;
  final bool lastTurnFailed;
  final bool hasMore;
  final String? title;
  final String? modelId;
  final String? modelProvider;
}

/// Combines the durable message journal with the current, process-local
/// assistant attempt. Tool requests remain owned by Harness: this observer
/// shows the workspace action and never replies to an approval or question.
class _TranscriptProjection {
  _TranscriptProjection(this.sessionId);
  final String sessionId;
  final _messages = <int, HarnessMessage>{};
  final _pending = <String>{};
  bool _opened = false;
  bool _running = false;
  bool _hasMore = false;
  bool _otherContent = false;
  bool _pendingState = false;
  String? _title;
  String? _modelId;
  String? _modelProvider;
  bool _hasState = false;
  bool _lastTurnFailed = false;
  String? _attemptId;
  int _revision = 0;
  int _nextIndex = 0;
  StringBuffer _streaming = StringBuffer();

  HarnessTranscript? update(MapEntry<String, _Json> item) {
    final frame = item.value;
    final changed = switch (item.key) {
      'events' => _interaction(frame),
      'state' => _state(frame),
      'journal' => _journal(frame),
      _ => false,
    };
    if (!_opened || !changed) return null;
    return HarnessTranscript(
      messages: List.unmodifiable([
        ..._messages.values,
        if (_streaming.isNotEmpty)
          HarnessMessage('assistant', _streaming.toString(), streaming: true),
      ]),
      running: _running,
      needsWorkspace: _otherContent || _pendingState || _pending.isNotEmpty,
      hasPendingRequest: _pendingState || _pending.isNotEmpty,
      lastTurnFailed: _lastTurnFailed,
      hasMore: _hasMore,
      title: _title,
      modelId: _modelId,
      modelProvider: _modelProvider,
    );
  }

  bool _interaction(_Json frame) {
    if (frame
        case {
          'type': 'waterfall',
          'agentId': final String agent,
          'eventId': final String id,
        }
        when agent == sessionId) {
      return _pending.add(id);
    }
    if (frame case {'type': 'cancel', 'eventId': final String id}
        when _pending.remove(id)) {
      _pendingState = false;
      return true;
    }
    return false;
  }

  bool _state(_Json frame) {
    if (frame case {
      'running': final bool running,
      'pendingInput': final List pending,
    }) {
      final changed =
          running != _running || pending.isNotEmpty != _pendingState;
      _running = running;
      _pendingState = pending.isNotEmpty;
      _hasState = true;
      return changed;
    }
    throw _invalid;
  }

  bool _journal(_Json frame) {
    switch (frame['type']) {
      case 'snapshot':
        if (_opened || frame['header']?['id'] != sessionId) throw _invalid;
        _hasMore = frame['hasMore'] == true;
        for (final row in _objects(frame['records'])) {
          _event(row['event'] as _Json);
        }
        _title = _titleProjection(frame);
        final selection = _modelSelection(frame);
        _modelId = selection?['model'] as String?;
        _modelProvider = selection?['provider'] as String?;
        final stream = frame['assistantStream'];
        if (stream is! _Json || stream['revision'] is! int) throw _invalid;
        _revision = stream['revision'] as int;
        if (stream['activeAttempt'] case final _Json attempt) {
          _attemptId = attempt['attemptId'] as String;
          _nextIndex = attempt['nextIndex'] as int;
          for (final piece in _objects(attempt['stream'])) {
            if (piece case {'type': 'text-chunks', 'texts': final List texts}) {
              for (final text in texts) {
                _streaming.write(text as String);
              }
            } else if (piece['chunk'] case {
              'type': 'text-delta',
              'text': final String text,
            }) {
              _streaming.write(text);
            }
          }
        }
        _opened = true;
        return true;
      case 'event':
        if (!_opened) throw _invalid;
        return _event(frame['event'] as _Json);
      case 'assistant-stream':
        if (!_opened) throw _invalid;
        return _chunk(frame['frame'] as _Json);
      default:
        throw _invalid;
    }
  }

  bool _event(_Json event) {
    final type = event['type'];
    final data = event['data'];
    if (type == 'turn/start' || type == 'turn/end') {
      final reason = data?['reason'];
      _lastTurnFailed =
          type == 'turn/end' &&
          switch (reason) {
            {'kind': 'error' || 'interrupted'} => true,
            {
              'kind': 'aborted',
              'reason': {
                'kind': 'hook',
                'reason': 'deepseek-account/signed-out',
              },
            } =>
              true,
            _ => false,
          };
      if (_lastTurnFailed) _otherContent = true;
      // The state stream is authoritative when it has already sent a baseline.
      if (!_opened && _hasState) return false;
      _running = type == 'turn/start';
      if (!_running) _streaming.clear();
      return true;
    }
    if (type == 'session/title') {
      _title = data['title'] as String;
      return true;
    }
    if (type == 'model/selection' ||
        (type == 'request/header' && _modelId == null)) {
      final route = type == 'model/selection'
          ? data
          : data?['header']?['config'];
      if (route case {
        'model': final String model,
        'provider': final String provider,
      }) {
        _modelId = model;
        _modelProvider = provider;
        return true;
      }
      return false;
    }
    if (type != 'user/message' && type != 'assistant/message') return false;
    final assistant = type == 'assistant/message';
    // Replacements compact the model's context. The human transcript keeps
    // append-origin messages in journal order, even after their replacement.
    if (event['surfaceOp'] != 'append') return false;
    if (data is! _Json) throw _invalid;
    if (!assistant && data['source']?['kind'] != 'user') return false;
    if (assistant) _streaming.clear();
    final message = assistant ? data['message'] : data;
    final content = message is _Json ? message['content'] : null;
    if (content is! List) throw _invalid;
    final text = StringBuffer();
    for (final part in content) {
      if (part case {'type': 'text', 'text': final String value}) {
        text.write(value);
      } else {
        _otherContent = true;
      }
    }
    if (text.isNotEmpty) {
      _messages[event['seq'] as int] = HarnessMessage(
        assistant ? 'assistant' : 'user',
        text.toString(),
      );
    }
    return true;
  }

  bool _chunk(_Json frame) {
    final revision = frame['revision'];
    if (revision != _revision + 1) throw _invalid;
    _revision = revision as int;
    switch (frame['type']) {
      case 'start':
        _attemptId = frame['attemptId'] as String;
        _nextIndex = 0;
        _streaming = StringBuffer();
        return false;
      case 'chunk':
        if (frame['attemptId'] != _attemptId ||
            frame['index'] != _nextIndex++) {
          throw _invalid;
        }
        if (frame['chunk'] case {
          'type': 'text-delta',
          'text': final String text,
        }) {
          _streaming.write(text);
          return true;
        }
        return false;
      case 'end':
        if (frame['attemptId'] != _attemptId || frame['index'] != _nextIndex) {
          throw _invalid;
        }
        _attemptId = null;
        _streaming.clear();
        return true;
      default:
        throw _invalid;
    }
  }
}

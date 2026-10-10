import 'dart:convert';

import 'realtime_call_prompt.dart';

/// A realtime call broke its protocol: a malformed or out-of-order command,
/// or a provider event that cannot belong to this call. The call ends.
final class RealtimeProtocolException implements Exception {
  const RealtimeProtocolException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The `session.update` a Direct call configures its voice with.
///
/// The voice never answers on its own (`create_response: false`): the call
/// asks for every reply once the user's words are transcribed, which gives
/// each delegation the input it answers. Audio is PCM16 at 24 kHz both ways.
Map<String, Object?> directRealtimeSessionUpdate({
  required String voice,
  required String transcriptionModel,
  String? instructions,
}) => {
  'type': 'session.update',
  'session': {
    'type': 'realtime',
    'output_modalities': ['audio'],
    'instructions': instructions ?? kRealtimeCallInstructions,
    'audio': {
      'input': {
        'format': {'type': 'audio/pcm', 'rate': 24000},
        'transcription': {'model': transcriptionModel},
        'turn_detection': {
          'type': 'server_vad',
          'interrupt_response': true,
          'create_response': false,
        },
      },
      'output': {
        'format': {'type': 'audio/pcm', 'rate': 24000},
        'voice': voice,
      },
    },
    'tools': [delegateFunctionTool()],
    'tool_choice': 'auto',
  },
};

/// The bridge Open WebUI runs on its server, run on the device for a Direct
/// call: it checks every command the call sends and turns it into the raw
/// Realtime API events the provider understands.
///
/// It keeps the same rules, so the shared engine behaves the same against
/// either: an input is answered once, a delegation's result is spoken once,
/// a truncation never passes what was received, and the chat snapshot
/// replaces the previous one.
final class RealtimeCallProtocol {
  static const _maxTracked = 4096;
  static const _maxAppendBytes = 48000;
  static const _maxSnapshotMessages = 100;
  static const _maxSnapshotMessage = 32000;
  static const _maxSnapshot = 64000;
  static const _maxRequest = 32000;
  static const _maxAnswer = 100000;
  static const _turnStatuses = {'completed', 'failed', 'cancelled', 'deferred'};

  final _transcripts = <String>{};
  final _requested = <String>{};
  final _responses = <String>{};
  final _functions = <String>{};
  final _results = <String, String>{};
  final _audioSamples = <(String, int), int>{};
  var _contextRevision = 0;

  /// Records what a provider [event] means for later commands.
  void observe(Map<String, Object?> event) {
    switch (event['type']) {
      case 'conversation.item.input_audio_transcription.completed':
        final transcript = event['transcript'];
        if (transcript is String && transcript.trim().isNotEmpty) {
          _transcripts.add(_string(event['item_id']));
        }
      case 'response.created':
        _responses.add(_string(_map(event['response'])['id']));
      case 'response.output_item.done':
        final item = _map(event['item']);
        if (item['type'] == 'function_call' && item['status'] == 'completed') {
          if (item['name'] != kDelegateFunctionName) {
            throw const RealtimeProtocolException('Unexpected voice function');
          }
          _checkDelegation(item['arguments']);
          _functions.add(_string(item['call_id']));
        }
      case 'response.output_audio.delta':
        final key = (_string(event['item_id']), _int(event['content_index']));
        final bytes = _pcm(event['delta']);
        _audioSamples[key] = (_audioSamples[key] ?? 0) + bytes ~/ 2;
    }
    if ([
      _transcripts.length,
      _responses.length,
      _audioSamples.length,
      _functions.length,
    ].any((count) => count > _maxTracked)) {
      throw const RealtimeProtocolException(
        'Call limit reached. Start a new call.',
      );
    }
  }

  /// The provider events [command] stands for.
  List<Map<String, Object?>> command(Map<String, Object?> command) {
    final keys = command.keys.toSet();
    bool shaped(Set<String> expected) =>
        keys.length == expected.length && keys.containsAll(expected);

    switch (command['type']) {
      case 'input_audio_buffer.append' when shaped({'type', 'audio'}):
        final bytes = _pcm(command['audio']);
        if (bytes == 0 || bytes > _maxAppendBytes) {
          throw const RealtimeProtocolException('Invalid microphone audio');
        }
        return [command];
      case 'input_audio_buffer.commit' || 'input_audio_buffer.clear'
          when shaped({'type'}):
        return [command];
      case 'response.cancel' when shaped({'type', 'response_id'}):
        if (!_responses.contains(command['response_id'])) {
          throw const RealtimeProtocolException('Unknown response');
        }
        return [command];
      case 'conversation.item.truncate'
          when shaped({'type', 'item_id', 'content_index', 'audio_end_ms'}):
        final samples =
            _audioSamples[(command['item_id'], command['content_index'])];
        final end = command['audio_end_ms'];
        if (samples == null ||
            end is! int ||
            end < 0 ||
            end > samples * 1000 ~/ 24000) {
          throw const RealtimeProtocolException('Invalid playback position');
        }
        return [command];
      case 'bridge.context' when shaped({'type', 'messages'}):
        return _replaceContext(command['messages']);
      case 'bridge.result' when shaped({'type', 'call_id', 'status', 'answer'}):
        final callId = command['call_id'];
        final status = command['status'];
        final answer = command['answer'];
        if (callId is! String || !_functions.contains(callId)) {
          throw const RealtimeProtocolException(
            'Unknown or resolved function call',
          );
        }
        if (status is! String || !_turnStatuses.contains(status)) {
          throw const RealtimeProtocolException('Invalid function result');
        }
        if (answer is! String || answer.length > _maxAnswer) {
          throw const RealtimeProtocolException('Invalid function answer');
        }
        _functions.remove(callId);
        _results[callId] = status;
        _requested.add('result:$callId');
        return [
          {
            'type': 'conversation.item.create',
            'item': {
              'type': 'function_call_output',
              'call_id': callId,
              'output': jsonEncode({'status': status, 'answer': answer}),
            },
          },
        ];
      case 'bridge.respond' when shaped({'type', 'item_id'}):
        final itemId = command['item_id'];
        if (itemId is! String ||
            !_transcripts.contains(itemId) ||
            !_requested.add(itemId)) {
          throw const RealtimeProtocolException(
            'Unknown or already answered input',
          );
        }
        return [
          {
            'type': 'response.create',
            'response': {
              'metadata': {'input_item_id': itemId},
            },
          },
        ];
      case 'bridge.respond' when shaped({'type', 'call_id'}):
        // A result is spoken once, without the delegation tool, so speaking
        // it can never start the same work again.
        final callId = command['call_id'];
        if (callId is! String ||
            _functions.contains(callId) ||
            !_requested.remove('result:$callId')) {
          throw const RealtimeProtocolException('Function result is not ready');
        }
        final failed = _results.remove(callId) == 'failed';
        return [
          {
            'type': 'response.create',
            'response': {
              'tools': <Object>[],
              'tool_choice': 'none',
              if (failed) 'instructions': kFailedResultInstructions,
              'metadata': {'call_id': callId},
            },
          },
        ];
      case 'bridge.status' when shaped({'type', 'status'}):
        final status = command['status'];
        final line = kRealtimeCallStatusLines[status];
        if (line == null) break;
        // Spoken outside the conversation, so it never becomes part of it.
        return [
          {
            'type': 'response.create',
            'response': {
              'conversation': 'none',
              'input': <Object>[],
              'tools': <Object>[],
              'tool_choice': 'none',
              'instructions': "Say this briefly in the user's language: $line",
              'metadata': {'status': status},
            },
          },
        ];
    }
    throw const RealtimeProtocolException('Unsupported call command');
  }

  List<Map<String, Object?>> _replaceContext(Object? messages) {
    if (messages is! List || messages.length > _maxSnapshotMessages) {
      throw const RealtimeProtocolException('Invalid call history');
    }
    var size = 0;
    for (final message in messages) {
      if (message is! Map ||
          message.length != 2 ||
          (message['role'] != 'user' && message['role'] != 'assistant') ||
          message['content'] is! String ||
          (message['content'] as String).length > _maxSnapshotMessage) {
        throw const RealtimeProtocolException('Invalid history message');
      }
      size += (message['content'] as String).length;
    }
    if (size > _maxSnapshot) {
      throw const RealtimeProtocolException('Call history is too large');
    }
    return [
      if (_contextRevision > 0)
        {
          'type': 'conversation.item.delete',
          'item_id': 'chat_context_$_contextRevision',
        },
      {
        'type': 'conversation.item.create',
        'item': {
          'id': 'chat_context_${++_contextRevision}',
          'type': 'message',
          'role': 'system',
          'content': [
            {
              'type': 'input_text',
              'text': '$kChatSnapshotPreamble${jsonEncode(messages)}',
            },
          ],
        },
      },
    ];
  }

  static void _checkDelegation(Object? arguments) {
    Object? decoded;
    try {
      decoded = arguments is String ? jsonDecode(arguments) : null;
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map ||
        decoded.length != 1 ||
        decoded['request'] is! String) {
      throw const RealtimeProtocolException('Invalid voice function arguments');
    }
    final request = (decoded['request'] as String).trim();
    if (request.isEmpty || request.length > _maxRequest) {
      throw const RealtimeProtocolException('Invalid voice function request');
    }
  }

  /// The byte length of base64 PCM16 [value], which must be whole samples.
  static int _pcm(Object? value) {
    try {
      final bytes = base64.decode(_string(value)).length;
      if (bytes.isOdd) throw const FormatException();
      return bytes;
    } on FormatException {
      throw const RealtimeProtocolException('Invalid PCM audio');
    }
  }

  static String _string(Object? value) {
    if (value is String) return value;
    throw const RealtimeProtocolException('Invalid voice event');
  }

  static int _int(Object? value) {
    if (value is int) return value;
    throw const RealtimeProtocolException('Invalid voice event');
  }

  static Map<Object?, Object?> _map(Object? value) {
    if (value is Map) return value;
    throw const RealtimeProtocolException('Invalid voice event');
  }
}

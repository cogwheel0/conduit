import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'bridge_call_host.dart';
import 'bridge_commands.dart';
import 'realtime_bridge_transport.dart';
import 'realtime_call_ports.dart';
import 'realtime_call_prompt.dart';
import 'realtime_call_protocol.dart';
import 'realtime_call_state.dart';

const _maxAnswerCharacters = 100000;
const _maxSnapshotMessages = 100;
const _maxSnapshotMessageCharacters = 32000;
const _maxSnapshotCharacters = 64000;

/// A call whose voice runs behind a bridge: Open WebUI's server, or the
/// on-device one Direct calls use. Both speak the same commands, so this one
/// engine runs both.
///
/// Follows Open WebUI's web client (`src/lib/utils/realtime.ts`): one command
/// at a time, sent only while nobody is speaking and no reply is pending; the
/// chat snapshot refreshed before each; barge-in cancels the reply and tells
/// the voice how much of it was heard; a request the voice delegates runs as
/// an ordinary chat turn, and its result is handed back to be spoken.
///
/// Unlike the web client, the user's words are saved with what answered
/// them, not as soon as they are transcribed: a reply the voice gives itself
/// is saved with them as one turn, and a delegation saves them through the
/// chat's own send. Words nothing answered stay in the call's captions.
final class BridgeCallEngine implements RealtimeCallEngine {
  BridgeCallEngine({
    required RealtimeBridgeTransport transport,
    required RealtimePcmAudioPort audio,
    required BridgeCallHost host,
    String? callId,
    this.pingInterval = const Duration(seconds: 10),
    this.pongTimeout = const Duration(seconds: 45),
  }) : _transport = transport,
       _audio = audio,
       _host = host,
       callId = callId ?? const Uuid().v4();

  final RealtimeBridgeTransport _transport;
  final RealtimePcmAudioPort _audio;
  final BridgeCallHost _host;

  /// Identifies this call in the `meta.voice` of what it saves.
  final String callId;
  final Duration pingInterval;
  final Duration pongTimeout;

  final _states = StreamController<RealtimeCallState>.broadcast();
  var _state = const RealtimeCallState();

  var _connected = false;
  var _ended = false;
  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _pingTimer;
  var _pingsSincePong = 0;

  var _receivingSpeech = '';
  var _activeResponse = '';
  var _responseRequested = false;
  var _cancelRequested = false;
  var _speaking = false;
  var _sentSamples = 0;
  var _chatContext = '';
  var _clearId = 0;
  final _clears = <int, Set<String>>{};
  final _commands = <Map<String, Object?>>[];
  final _speakingResponses = <String>{};
  final _interrupted = <String>{};
  final _animationCalls = <String>{};
  final _responses = <String, _Response>{};
  final _inputs = <String, _Input>{};
  final _calls = <String, _Turn>{};
  _Turn? _pending;

  Future<void> _delegation = Future.value();
  Future<void> _writes = Future.value();
  final _heldExchanges = <RealtimeVoiceExchange>[];

  @override
  RealtimeCallState get state => _state;

  @override
  Stream<RealtimeCallState> get states => _states.stream;

  String get _voiceModel => _state.voiceModel ?? '';

  void _update(RealtimeCallState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  Future<void> connect() async {
    if (_connected || _ended) return;
    try {
      await _audio.start();
      final ready = await _transport.open();
      if (_ended) return;
      _connected = true;
      _subscriptions
        ..add(_transport.events.listen(_onEvent))
        ..add(_audio.captureFrames.listen(_onCapture))
        ..add(_audio.reports.listen(_onReport))
        ..add(_audio.failures.listen(_fail));
      unawaited(
        _transport.closed.then((message) {
          if (!_ended) _fail(message ?? 'Voice connection closed.');
        }),
      );
      _pingTimer = Timer.periodic(pingInterval, (_) => _ping());
      _update(
        _state.copyWith(
          phase: RealtimeCallPhase.live,
          voiceModel: ready.model,
          voice: ready.voice,
        ),
      );
      _syncContext();
      _audio.setCaptureEnabled(!_state.muted);
    } on RealtimeBridgeException catch (error) {
      await _fail(error.message);
      rethrow;
    } on Object {
      const message = 'Could not start the microphone.';
      await _fail(message);
      throw const RealtimeBridgeException(message);
    }
  }

  void _send(Map<String, Object?> command) {
    if (_connected) _transport.send(command);
  }

  void _ping() {
    if (!_connected) return;
    if (++_pingsSincePong * pingInterval.inMilliseconds >
        pongTimeout.inMilliseconds) {
      _fail('Voice connection stopped responding.');
      return;
    }
    _send(BridgeCommands.ping);
  }

  void _onCapture(Uint8List frame) {
    if (!_connected || _state.muted) return;
    _send(BridgeCommands.appendAudio(base64.encode(frame)));
  }

  void _onReport(RealtimePlaybackReport report) {
    // Reports queued before an interruption cleared the audio are stale.
    if (report.clearId < _clearId) return;
    _speaking =
        report.queuedSamples > 0 || _sentSamples > report.receivedSamples;
    if (!_speaking && _activeResponse.isEmpty && !_responseRequested) {
      _speakingResponses.clear();
    }
    _update(
      _state.copyWith(
        assistantSpeaking: _speaking,
        inputLevel: _state.muted ? 0 : report.inputLevel,
        outputLevel: report.outputLevel,
      ),
    );
    _flush();
  }

  void _onCleared(int id, List<RealtimeRenderedItem> rendered) {
    final responses = _clears.remove(id) ?? const <String>{};
    final latencyMs = _audio.outputLatency.inMilliseconds;
    for (final item in rendered) {
      if (!responses.contains(item.responseId)) continue;
      final heardMs = item.samples ~/ 24 - latencyMs;
      _send(
        BridgeCommands.truncate(
          itemId: item.itemId,
          contentIndex: item.contentIndex,
          audioEndMs: heardMs < 0 ? 0 : heardMs,
        ),
      );
    }
    // An item may have been queued but never played.
    for (final responseId in responses) {
      for (final (itemId, contentIndex)
          in _responses[responseId]?.audio ?? const <(String, int)>{}) {
        final played = rendered.any(
          (item) => item.itemId == itemId && item.contentIndex == contentIndex,
        );
        if (!played) {
          _send(
            BridgeCommands.truncate(
              itemId: itemId,
              contentIndex: contentIndex,
              audioEndMs: 0,
            ),
          );
        }
      }
    }
    _flush();
  }

  void _enqueue(Map<String, Object?> command) {
    if (command['type'] == 'bridge.status' &&
        _commands.any(
          (queued) =>
              queued['type'] == 'bridge.status' &&
              queued['status'] == command['status'],
        )) {
      return;
    }
    if (command['type'] == 'bridge.respond' && command.containsKey('item_id')) {
      // Answering the user comes before speaking statuses and results.
      final index = _commands.indexWhere(
        (queued) => !queued.containsKey('item_id'),
      );
      _commands.insert(index < 0 ? _commands.length : index, command);
    } else {
      _commands.add(command);
    }
    _flush();
  }

  /// Sends the next command once nobody is speaking and no reply is pending,
  /// so the voice is never asked for two replies at once.
  void _flush() {
    if (!_connected ||
        _receivingSpeech.isNotEmpty ||
        _activeResponse.isNotEmpty ||
        _responseRequested ||
        _speaking ||
        _clears.isNotEmpty ||
        _commands.isEmpty) {
      return;
    }
    final command = _commands.removeAt(0);
    _syncContext();
    _responseRequested = true;
    _send(command);
  }

  /// Replaces the voice's chat snapshot when the chat changed, newest
  /// messages kept within the bridge's bounds.
  void _syncContext() {
    if (!_connected) return;
    var budget = _maxSnapshotCharacters;
    final messages = <Map<String, String>>[];
    final chat = _host.chatSnapshot();
    final start = chat.length > _maxSnapshotMessages
        ? chat.length - _maxSnapshotMessages
        : 0;
    for (var index = chat.length - 1; index >= start && budget > 0; index--) {
      final message = chat[index];
      final role = message['role'];
      final content = message['content'] ?? '';
      if (role != 'user' && role != 'assistant') continue;
      final limit = budget < _maxSnapshotMessageCharacters
          ? budget
          : _maxSnapshotMessageCharacters;
      final kept = content.length > limit
          ? content.substring(0, limit)
          : content;
      if (kept.isEmpty) continue;
      budget -= kept.length;
      messages.insert(0, {'role': role!, 'content': kept});
    }
    final snapshot = jsonEncode(messages);
    if (snapshot == _chatContext) return;
    _chatContext = snapshot;
    _send(BridgeCommands.context(messages));
  }

  void _onEvent(Map<String, Object?> event) {
    try {
      _handle(event);
    } on Object {
      _fail('Invalid voice event. The call has ended.');
    }
  }

  void _handle(Map<String, Object?> event) {
    switch (event['type']) {
      case 'bridge.pong':
        _pingsSincePong = 0;
        return;
      case 'input_audio_buffer.speech_started':
        _receivingSpeech = _string(event['item_id']);
        _update(_state.copyWith(userSpeaking: !_state.muted));
        _stopSpeaking();
      case 'input_audio_buffer.speech_stopped':
        if (_receivingSpeech == event['item_id']) {
          _update(_state.copyWith(userSpeaking: false));
        }
      case 'conversation.item.input_audio_transcription.completed' ||
          'conversation.item.input_audio_transcription.failed':
        _onTranscript(event);
      case 'response.created':
        final response = _map(event['response']);
        final id = _string(response['id']);
        _responseRequested = false;
        _activeResponse = id;
        if (_cancelRequested) {
          _cancelRequested = false;
          _interrupted.add(id);
          _send(BridgeCommands.cancelResponse(id));
        }
        final metadata = response['metadata'];
        _responses[id] = _Response(
          id,
          metadata is Map ? Map<String, Object?>.from(metadata) : const {},
          statusCallId: _pending?.callId,
        );
      case 'response.output_audio.delta':
        final responseId = _string(event['response_id']);
        if (_interrupted.contains(responseId)) return;
        final pcm = base64.decode(_string(event['delta']));
        if (pcm.length.isOdd) {
          throw const RealtimeProtocolException('Invalid PCM');
        }
        final itemId = _string(event['item_id']);
        final contentIndex = _int(event['content_index']);
        _responses[responseId]?.audio.add((itemId, contentIndex));
        _sentSamples += pcm.length ~/ 2;
        _speakingResponses.add(responseId);
        _speaking = true;
        _audio.enqueue(
          responseId: responseId,
          itemId: itemId,
          contentIndex: contentIndex,
          pcm: pcm,
        );
        if (!_state.assistantSpeaking) {
          _update(_state.copyWith(assistantSpeaking: true));
        }
      case 'response.output_audio_transcript.delta':
        final response = _responses[event['response_id']];
        if (response == null) return;
        final itemId = _string(event['item_id']);
        final text = (response.speech[itemId] ?? '') + _string(event['delta']);
        response.speech[itemId] = text;
        _update(_state.copyWith(assistantCaption: text));
      case 'response.output_audio_transcript.done':
        final response = _responses[event['response_id']];
        final transcript = event['transcript'];
        if (response == null || transcript is! String) return;
        response.speech[_string(event['item_id'])] = transcript;
        _update(_state.copyWith(assistantCaption: transcript));
      case 'response.output_item.done':
        final item = _map(event['item']);
        if (item['type'] == 'function_call' && item['status'] == 'completed') {
          _onFunctionCall(_string(event['response_id']), item, event);
        }
      case 'response.done':
        final response = _map(event['response']);
        _onResponseDone(_string(response['id']), response['status']);
    }
  }

  void _onTranscript(Map<String, Object?> event) {
    final itemId = _string(event['item_id']);
    // A segment's transcript can arrive while newer speech is under way.
    if (_receivingSpeech == itemId) {
      _receivingSpeech = '';
      _update(_state.copyWith(userSpeaking: false));
    }
    if (_inputs.containsKey(itemId)) return;
    final failed =
        event['type'] == 'conversation.item.input_audio_transcription.failed';
    final transcript = event['transcript'];
    final text = !failed && transcript is String ? transcript.trim() : '';
    if (text.isEmpty) {
      // Silence is not a request, and must not get a reply.
      if (failed) {
        _host.notice(
          'A voice segment could not be transcribed. Please try again.',
        );
      }
      _flush();
      return;
    }
    _inputs[itemId] = _Input(itemId, text);
    _update(_state.copyWith(userCaption: text));
    _enqueue(BridgeCommands.respondToInput(itemId));
  }

  void _onFunctionCall(
    String responseId,
    Map<Object?, Object?> item,
    Map<String, Object?> event,
  ) {
    final callId = _string(item['call_id']);
    final response = _responses[responseId];
    if (item['name'] == 'play_animation') {
      // Conduit draws no avatar; a gesture never interrupts the call.
      if (!_animationCalls.add(callId)) return;
      final cancelled =
          response == null ||
          _interrupted.contains(responseId) ||
          _receivingSpeech.isNotEmpty;
      if (response != null && !cancelled) response.animationFailed = true;
      _send(
        BridgeCommands.animationResult(
          callId: callId,
          status: cancelled
              ? BridgeAnimationStatus.cancelled
              : BridgeAnimationStatus.unavailable,
        ),
      );
      return;
    }
    if (response == null ||
        item['name'] != kDelegateFunctionName ||
        _calls.containsKey(callId)) {
      return;
    }
    final input = _inputs[response.inputId];
    if (input == null) {
      throw const RealtimeProtocolException('Function has no input');
    }
    response.delegated = true;
    if (_calls.values.any((turn) => turn.inputId == input.itemId)) {
      _send(
        BridgeCommands.result(
          callId: callId,
          status: BridgeTurnStatus.cancelled,
          answer: 'This request is already being handled.',
        ),
      );
      return;
    }
    final turn = _Turn(callId, input.itemId);
    _calls[callId] = turn;
    // A newer delegation replaces any older result still waiting to be said.
    _commands.removeWhere((command) => command.containsKey('call_id'));
    _delegation = _delegation
        .then((_) => _runTurn(turn, input))
        .catchError(
          (Object _) => _fail(
            'Could not hand the request to the chat. Check the chat for it.',
          ),
        );
  }

  Future<void> _runTurn(_Turn turn, _Input input) async {
    if (_ended) return;
    final previous = _pending;
    if (previous != null && !previous.finished && previous.handle != null) {
      previous.finished = true;
      await previous.handle!.cancel();
      _result(
        previous,
        BridgeTurnStatus.cancelled,
        'Superseded by a newer request.',
        speak: false,
      );
    }
    // The chat model's history must hold what was said before this request.
    input.persisted = true;
    await _writes;
    if (_ended) return;
    _pending = turn;
    _update(_state.copyWith(working: true, approval: false));
    final handle = await _host.delegate(
      input.text,
      userVoice: _userVoice(input),
    );
    if (_ended) {
      await handle.cancel();
      return;
    }
    turn.handle = handle;
    if (handle.state == DelegatedTurnState.deferred ||
        handle.assistantMessageId == null) {
      _result(
        turn,
        BridgeTurnStatus.deferred,
        'Finish what the chat is asking for, then try again.',
      );
      return;
    }
    turn.subscription = handle.changes.listen((_) => _onTurnChanged(turn));
    _onTurnChanged(turn);
  }

  void _onTurnChanged(_Turn turn) {
    final handle = turn.handle;
    if (handle == null || turn.finished || !_connected) return;
    _syncContext();
    final state = handle.state;
    final approval = state == DelegatedTurnState.approval;
    if (approval && !turn.approval) {
      _enqueue(BridgeCommands.status(BridgeCallStatus.approval));
    }
    turn.approval = approval;
    if (_pending == turn) _update(_state.copyWith(approval: approval));
    switch (state) {
      case DelegatedTurnState.completed:
        _result(turn, BridgeTurnStatus.completed, handle.answer);
      case DelegatedTurnState.failed:
        _result(
          turn,
          BridgeTurnStatus.failed,
          'The request did not complete successfully.',
        );
      case DelegatedTurnState.cancelled:
        _result(
          turn,
          BridgeTurnStatus.cancelled,
          'The request was stopped. Anything it already did stays done.',
        );
      case DelegatedTurnState.deferred:
        _result(
          turn,
          BridgeTurnStatus.deferred,
          'Finish what the chat is asking for, then try again.',
        );
      case DelegatedTurnState.working || DelegatedTurnState.approval:
        break;
    }
  }

  void _result(
    _Turn turn,
    BridgeTurnStatus status,
    String answer, {
    bool speak = true,
  }) {
    turn.finished = true;
    unawaited(turn.subscription?.cancel());
    _send(
      BridgeCommands.result(
        callId: turn.callId,
        status: status,
        answer: answer.length <= _maxAnswerCharacters
            ? answer
            : 'The full answer is in the chat; it is too long to read out.',
      ),
    );
    _commands.removeWhere((command) => command['type'] == 'bridge.status');
    if (speak) _enqueue(BridgeCommands.respondToResult(turn.callId));
    if (_pending == turn) {
      _update(_state.copyWith(working: false, approval: false));
      // Exchanges held back while the answer ran come after it.
      for (final exchange in _heldExchanges) {
        _write(() => _host.recordExchange(exchange));
      }
      _heldExchanges.clear();
    }
    _mergeTurnSpeech(turn);
  }

  void _onResponseDone(String id, Object? status) {
    if (_activeResponse == id) _activeResponse = '';
    _responseRequested = false;
    _audio.endResponse(id);
    final response = _responses[id];
    if (response != null) {
      response.done = true;
      _saveSpeech(response);
      // A gesture that could not play leaves the reply to be given in words.
      if (response.animationFailed &&
          !response.delegated &&
          status == 'completed' &&
          !_interrupted.contains(id)) {
        _enqueue(BridgeCommands.animationRespond(id));
      }
    }
    if (status == 'failed' || status == 'incomplete') {
      _host.notice('The voice response did not complete.');
    }
    _flush();
  }

  /// Files what a reply said: into its delegated turn's answer, or into the
  /// chat as an exchange with the words it answered.
  void _saveSpeech(_Response response) {
    final speech = [
      for (final MapEntry(key: itemId, value: transcript)
          in response.speech.entries)
        if (transcript.trim().isNotEmpty)
          <String, Object?>{
            'item_id': itemId,
            'transcript': transcript,
            'response_id': response.id,
            'model': _voiceModel,
            'interrupted': _interrupted.contains(response.id),
          },
    ];
    final turn = response.status != null
        ? _calls[response.statusCallId]
        : response.callId != null
        ? _calls[response.callId]
        : _calls.values
              .where((turn) => turn.inputId == response.inputId)
              .firstOrNull;
    if (turn != null) {
      for (final entry in speech) {
        turn.speech[entry['item_id']! as String] = entry;
      }
      if (turn.finished) _mergeTurnSpeech(turn);
      return;
    }
    if (response.delegated || !response.done && !_ended) return;
    final input = _inputs[response.inputId];
    if (input == null || input.persisted || speech.isEmpty) return;
    input.persisted = true;
    _record(
      RealtimeVoiceExchange(
        userText: input.text,
        userVoice: _userVoice(input),
        voiceModel: _voiceModel,
        replyText: speech.map((entry) => entry['transcript']).join('\n'),
        replyVoice: {
          'call_id': callId,
          'input_item_id': input.itemId,
          'model': _voiceModel,
          'speech': speech,
        },
      ),
    );
  }

  void _record(RealtimeVoiceExchange exchange) {
    // A delegated answer still running must stay the chat's last message.
    final pending = _pending;
    if (!_ended && pending != null && !pending.finished) {
      _heldExchanges.add(exchange);
    } else {
      _write(() => _host.recordExchange(exchange));
    }
  }

  void _mergeTurnSpeech(_Turn turn) {
    final assistantId = turn.handle?.assistantMessageId;
    if (assistantId == null || turn.speech.isEmpty) return;
    final voice = <String, Object?>{
      'call_id': callId,
      'input_item_id': turn.inputId,
      'function_call_id': turn.callId,
      'model': _voiceModel,
      'speech': turn.speech.values.toList(growable: false),
    };
    _write(() => _host.mergeSpeech(assistantId, voice));
  }

  void _write(Future<void> Function() write) {
    _writes = _writes.then((_) => write()).catchError((Object _) {
      _host.notice('Could not save the voice transcript.');
    });
  }

  Map<String, Object?> _userVoice(_Input input) => {
    'call_id': callId,
    'input_item_id': input.itemId,
    'model': _voiceModel,
  };

  /// Stops the voice: cancels its reply, drops what is queued, and has the
  /// played length reported for truncation.
  void _stopSpeaking() {
    if (_responseRequested) _cancelRequested = true;
    final responses = _speakingResponses
        .where((id) => !_interrupted.contains(id))
        .toSet();
    if (_activeResponse.isNotEmpty && !_interrupted.contains(_activeResponse)) {
      responses.add(_activeResponse);
      _send(BridgeCommands.cancelResponse(_activeResponse));
    }
    _interrupted.addAll(responses);
    _speakingResponses.clear();
    _speaking = false;
    final id = ++_clearId;
    _clears[id] = responses;
    unawaited(
      _audio
          .clear(id)
          .then(
            (rendered) => _onCleared(id, rendered),
            onError: (Object _) => _onCleared(id, const []),
          ),
    );
    _commands.removeWhere(
      (command) =>
          command['type'] == 'bridge.status' ||
          command['type'] == 'bridge.animation.respond',
    );
    _update(_state.copyWith(assistantSpeaking: false, outputLevel: 0));
  }

  @override
  void interrupt() {
    if (_connected) _stopSpeaking();
  }

  @override
  void setMuted(bool muted) {
    if (_state.muted == muted) return;
    _update(
      _state.copyWith(
        muted: muted,
        inputLevel: muted ? 0 : null,
        userSpeaking: muted ? false : null,
      ),
    );
    _audio.setCaptureEnabled(_connected && !muted);
    if (muted) _send(BridgeCommands.clearInput);
  }

  Future<void> _fail(String message) {
    if (_ended) return Future.value();
    _update(_state.copyWith(error: message));
    return end();
  }

  @override
  Future<void> end() async {
    if (_ended) return;
    _ended = true;
    if (_connected) {
      _stopSpeaking();
      // A reply cut off by the end of the call is saved as far as it got.
      for (final response in _responses.values) {
        if (!response.done) _saveSpeech(response);
      }
    }
    _connected = false;
    for (final exchange in _heldExchanges) {
      _write(() => _host.recordExchange(exchange));
    }
    _heldExchanges.clear();
    _pingTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final turn in _calls.values) {
      unawaited(turn.subscription?.cancel());
    }
    _update(
      _state.copyWith(
        phase: RealtimeCallPhase.ended,
        userSpeaking: false,
        assistantSpeaking: false,
        working: false,
        approval: false,
        inputLevel: 0,
        outputLevel: 0,
      ),
    );
    await _transport.close();
    await _audio.stop();
    await _writes.timeout(const Duration(seconds: 10), onTimeout: () {});
    await _states.close();
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

/// One reply the voice gave, or is giving.
final class _Response {
  _Response(this.id, this.metadata, {this.statusCallId});

  final String id;
  final Map<String, Object?> metadata;

  /// For a status line, the delegated turn it was about.
  final String? statusCallId;

  /// What each spoken item said, in order.
  final speech = <String, String>{};
  final audio = <(String, int)>{};
  var delegated = false;
  var done = false;
  var animationFailed = false;

  String? get inputId => metadata['input_item_id'] as String?;
  String? get callId => metadata['call_id'] as String?;
  String? get status => metadata['status'] as String?;
}

/// The user's transcribed words.
final class _Input {
  _Input(this.itemId, this.text);

  final String itemId;
  final String text;

  /// Saved into the chat, or handed to it as a turn.
  var persisted = false;
}

/// A request the voice handed to the chat's model.
final class _Turn {
  _Turn(this.callId, this.inputId);

  final String callId;
  final String inputId;
  DelegatedTurn? handle;
  StreamSubscription<DelegatedTurnState>? subscription;
  var finished = false;
  var approval = false;

  /// What the voice said about this turn, by item.
  final speech = <String, Map<String, Object?>>{};
}

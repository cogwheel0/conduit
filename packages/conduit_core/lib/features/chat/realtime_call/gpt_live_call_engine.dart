import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'bridge_call_host.dart';
import 'realtime_bridge_transport.dart' show RealtimeBridgeException;
import 'realtime_call_ports.dart';
import 'realtime_call_state.dart';

/// Opens a GPT-Live session for a WebRTC offer, seeded with [history], and
/// returns the answer SDP.
typedef GptLiveSessionOpener = Future<String> Function(
  String offer,
  List<Map<String, Object?>> history,
);

/// The longest text one `session.commentary.append` carries; OpenAI's cap is
/// 500 tokens. Hermes's desktop client uses the same bound.
const kGptLiveCommentaryCharacters = 1400;

/// [text] in pieces of at most [limit] characters, cut after a sentence
/// where it can be and at the limit where it cannot.
List<String> chunkForCommentary(
  String text, {
  int limit = kGptLiveCommentaryCharacters,
}) {
  if (limit <= 0) throw ArgumentError.value(limit, 'limit', 'must be positive');
  final chunks = <String>[];
  var rest = text.trim();
  while (rest.length > limit) {
    var cut = -1;
    for (final match in RegExp(r'[.!?。！？](\s|$)|\n').allMatches(rest)) {
      if (match.end > limit) break;
      cut = match.end;
    }
    if (cut <= 0) cut = limit;
    chunks.add(rest.substring(0, cut).trim());
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) chunks.add(rest);
  return chunks;
}

/// One stretch of speech heard in the call, until a pause ends it.
final class _Fragment {
  _Fragment(this.user, this.text, this.at);

  final bool user;
  String text;

  /// When its latest words were heard.
  DateTime at;
  var ended = false;
}

/// A call whose voice is OpenAI's GPT-Live, opened by a Hermes gateway that
/// keeps the key; the audio flows over WebRTC and the voice's events over a
/// data channel.
///
/// Follows Hermes's own desktop client: GPT-Live takes its own turns, and a
/// request it delegates carries no text, so the request is the user's latest
/// words and the spoken conversation of the last few minutes goes with it as
/// context. What the chat's model answers is handed back as commentary for
/// the voice to say, and its progress as quiet thinking.
final class GptLiveCallEngine implements RealtimeCallEngine {
  GptLiveCallEngine({
    required RealtimeWebRtcMediaPort media,
    required GptLiveSessionOpener open,
    required BridgeCallHost host,
    this.history = const [],
    String? callId,
    DateTime Function()? clock,
    this.startTimeout = const Duration(seconds: 15),
    this.closeTimeout = const Duration(seconds: 15),
  }) : _media = media,
       _open = open,
       _host = host,
       _clock = clock ?? DateTime.now,
       callId = callId ?? const Uuid().v4();

  final RealtimeWebRtcMediaPort _media;
  final GptLiveSessionOpener _open;
  final BridgeCallHost _host;
  final DateTime Function() _clock;

  /// The chat the voice starts with.
  final List<Map<String, Object?>> history;

  /// Identifies this call in the `meta.voice` of what it hands over.
  final String callId;
  final Duration startTimeout;
  final Duration closeTimeout;

  static const _contextWindow = Duration(minutes: 5);
  static const _contextFragments = 80;
  static const _speechSettle = Duration(milliseconds: 1200);

  final _states = StreamController<RealtimeCallState>.broadcast();
  var _state = const RealtimeCallState();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _started = Completer<void>();
  final _closed = Completer<void>();
  final _fragments = <_Fragment>[];
  var _eventCount = 0;
  var _ended = false;
  Timer? _speechTimer;
  _Delegation? _running;

  /// Replaced requests stopping, in order: the chat takes a new request only
  /// once every older answer has stopped.
  Future<void> _stopping = Future.value();

  @override
  RealtimeCallState get state => _state;

  @override
  Stream<RealtimeCallState> get states => _states.stream;

  void _update(RealtimeCallState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  Future<void> connect() async {
    try {
      final offer = await _media.createOffer();
      // Hung up while the microphone opened: no session is opened for it.
      if (_ended) return;
      _subscriptions
        ..add(_media.messages.listen(_onMessage))
        ..add(
          _media.states.listen((state) {
            if (state == RealtimeMediaState.failed ||
                state == RealtimeMediaState.closed) {
              unawaited(_fail('Voice connection closed.'));
            }
          }),
        );
      final answer = await _open(offer, history);
      if (_ended) return;
      await _media.acceptAnswer(answer);
      await _started.future.timeout(startTimeout);
      if (_ended) return;
      _update(_state.copyWith(phase: RealtimeCallPhase.live));
    } on TimeoutException {
      if (_ended) return;
      await _fail('Voice connection timed out.');
      throw const RealtimeBridgeException('Voice connection timed out.');
    } on Object catch (error) {
      // An ending call's own teardown is not a failure to start.
      if (_ended) return;
      final message = error is StateError
          ? error.message
          : 'Could not start the voice call.';
      await _fail(message);
      throw RealtimeBridgeException(message);
    }
  }

  void _send(String type, Map<String, Object?> fields) {
    if (_ended && type != 'session.close') return;
    _media.send(
      jsonEncode({
        'type': type,
        'event_id': 'conduit_${++_eventCount}_$callId',
        ...fields,
      }),
    );
  }

  void _onMessage(String message) {
    final Object? event;
    try {
      event = jsonDecode(message);
    } on FormatException {
      return;
    }
    if (event is! Map) return;
    switch (event['type']) {
      case 'session.started':
        if (!_started.isCompleted) _started.complete();
      case 'session.input_transcript.delta':
        _heard(user: true, event['delta']);
      case 'session.output_transcript.delta':
        _heard(user: false, event['delta']);
      case 'session.delegation.created':
        final delegation = event['delegation'];
        final id = delegation is Map ? delegation['id'] : null;
        if (id is String) unawaited(_delegate(id));
      case 'session.closed':
        if (!_closed.isCompleted) _closed.complete();
        final reason = event['reason'];
        if (!_ended) {
          unawaited(
            reason == 'close_requested' || reason == 'remote_hangup'
                ? end()
                : _fail(
                    reason == 'expired'
                        ? 'The call reached its time limit. Start a new call.'
                        : 'The voice call ended.',
                  ),
          );
        }
      case 'error':
        final error = event['error'];
        final code = error is Map ? error['code'] : null;
        // An update that did not fully land; the call goes on.
        if (code == 'context_injection_incomplete') return;
        DebugLogger.warning(
          'gpt-live-error',
          scope: 'realtime/gpt_live',
          data: {'code': code},
        );
    }
  }

  void _heard(Object? delta, {required bool user}) {
    if (delta is! String || delta.isEmpty) return;
    final last = _fragments.isEmpty ? null : _fragments.last;
    if (last != null && last.user == user && !last.ended) {
      last
        ..text += delta
        ..at = _clock();
    } else {
      _fragments.add(_Fragment(user, delta, _clock()));
    }
    final text = _fragments.last.text.trim();
    _update(
      user
          ? _state.copyWith(userCaption: text, userSpeaking: true)
          : _state.copyWith(assistantCaption: text, assistantSpeaking: true),
    );
    // Transcripts come without turn ends; quiet means the turn is over.
    _speechTimer?.cancel();
    _speechTimer = Timer(_speechSettle, () {
      if (_fragments.isNotEmpty) _fragments.last.ended = true;
      if (!_ended) {
        _update(_state.copyWith(userSpeaking: false, assistantSpeaking: false));
      }
    });
  }

  /// What was said in the last few minutes, as Hermes's client keeps it.
  List<_Fragment> _recent() {
    final since = _clock().subtract(_contextWindow);
    return _fragments
        .where((fragment) => !fragment.at.isBefore(since))
        .toList();
  }

  /// The user's latest words: what they said, in the last few minutes, since
  /// the voice last spoke.
  String _latestRequest() {
    final words = <String>[];
    for (final fragment in _recent().reversed) {
      if (!fragment.user) {
        if (words.isNotEmpty) break;
        continue;
      }
      words.insert(0, fragment.text.trim());
    }
    return words.join(' ').trim();
  }

  /// The spoken conversation of the last few minutes, as Hermes reads it.
  String _recentConversation() {
    final recent = _recent();
    final kept = recent.length > _contextFragments
        ? recent.sublist(recent.length - _contextFragments)
        : recent;
    // One line per turn, however many pauses it had.
    final turns = <(bool, String)>[];
    for (final fragment in kept) {
      final text = fragment.text.trim();
      if (turns.isNotEmpty && turns.last.$1 == fragment.user) {
        turns.last = (fragment.user, '${turns.last.$2} $text');
      } else {
        turns.add((fragment.user, text));
      }
    }
    return turns
        .map((turn) => '${turn.$1 ? 'User' : 'Voice assistant'}: ${turn.$2}')
        .join('\n');
  }

  Future<void> _delegate(String delegationId) async {
    final request = _latestRequest();
    final previous = _running;
    final delegation = _running = _Delegation(delegationId);
    if (previous != null && !previous.settled) {
      previous.settled = true;
      _stopAfter(() async {
        await previous.subscription?.cancel();
        await previous.turn?.cancel();
      });
    }
    // Until nothing more is stopping, including stops chained meanwhile.
    for (var stopping = _stopping; ; stopping = _stopping) {
      await stopping;
      if (identical(stopping, _stopping)) break;
    }
    // A newer request came while the older one stopped; this one is over.
    if (delegation.settled) return;
    if (_ended || request.isEmpty) {
      _settle(delegation, "I didn't catch the request. Ask me again.");
      return;
    }
    _send('session.thinking.append', {
      'delegation_id': delegationId,
      'content': 'The chat is working on this. It is not done yet.',
    });
    _update(_state.copyWith(working: true, approval: false));
    final DelegatedTurn turn;
    try {
      turn = await _host.delegate(
        request,
        userVoice: {'call_id': callId, 'delegation_id': delegationId},
        spokenContext: _recentConversation(),
      );
    } on Object {
      _settle(delegation, 'That request could not be sent to the chat.');
      return;
    }
    if (delegation.settled) {
      _stopAfter(turn.cancel);
      return;
    }
    // The call ended meanwhile; the answer goes on in the chat.
    if (_ended) return;
    delegation.turn = turn;
    if (turn.state == DelegatedTurnState.deferred) {
      _settle(
        delegation,
        'The chat is busy with another answer. Ask again when it finishes.',
      );
      return;
    }
    delegation.subscription = turn.changes.listen(
      (_) => _onTurnChanged(delegation),
    );
    _onTurnChanged(delegation);
  }

  void _stopAfter(Future<void> Function() stop) {
    _stopping = _stopping.then((_) => stop()).catchError((Object _) {});
  }

  void _onTurnChanged(_Delegation delegation) {
    final turn = delegation.turn;
    if (turn == null || delegation.settled) return;
    switch (turn.state) {
      case DelegatedTurnState.approval:
        if (!delegation.askedForApproval) {
          delegation.askedForApproval = true;
          _send('session.commentary.append', {
            'delegation_id': delegation.id,
            'content':
                'Something needs the user in the chat: an approval or a '
                'question. The work waits until they answer there.',
          });
        }
        _update(_state.copyWith(approval: true));
      case DelegatedTurnState.completed:
        _settle(
          delegation,
          turn.answer.trim().isEmpty
              ? 'The chat finished that without anything to say.'
              : turn.answer,
        );
      case DelegatedTurnState.failed:
        _settle(delegation, 'That request failed. Nothing is running now.');
      case DelegatedTurnState.cancelled:
        _settle(delegation, 'That request was stopped.');
      case DelegatedTurnState.deferred:
        _settle(
          delegation,
          'The chat is busy with another answer. Ask again when it finishes.',
        );
      case DelegatedTurnState.working:
        _update(_state.copyWith(approval: false));
    }
  }

  /// Hands the voice what to say about [delegation], and closes it.
  void _settle(_Delegation delegation, String result) {
    delegation.settled = true;
    unawaited(delegation.subscription?.cancel());
    for (final chunk in chunkForCommentary(result)) {
      _send('session.commentary.append', {
        'delegation_id': delegation.id,
        'content': chunk,
      });
    }
    if (identical(_running, delegation)) {
      _update(_state.copyWith(working: false, approval: false));
    }
  }

  @override
  void setMuted(bool muted) {
    if (_state.muted == muted) return;
    _media.setMicrophoneEnabled(!muted);
    _send(
      muted ? 'session.input_audio.mute' : 'session.input_audio.unmute',
      const {},
    );
    _update(_state.copyWith(muted: muted, userSpeaking: muted ? false : null));
  }

  @override
  void interrupt() {
    _send('session.instructions.append', {
      'delegation_id': null,
      'content': 'Stop speaking now and listen to the user.',
    });
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
    _speechTimer?.cancel();
    // Nothing more is heard while the session confirms its close.
    _media.setMicrophoneEnabled(false);
    // A request still running finishes in the chat.
    final running = _running;
    if (running != null) unawaited(running.subscription?.cancel());
    if (_started.isCompleted && !_closed.isCompleted) {
      _send('session.close', const {});
      await _closed.future.timeout(closeTimeout, onTimeout: () {});
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _update(
      _state.copyWith(
        phase: RealtimeCallPhase.ended,
        userSpeaking: false,
        assistantSpeaking: false,
        working: false,
        approval: false,
      ),
    );
    await _media.close();
    await _states.close();
  }
}

/// A request GPT-Live delegated.
final class _Delegation {
  _Delegation(this.id);

  final String id;
  DelegatedTurn? turn;
  StreamSubscription<DelegatedTurnState>? subscription;
  var settled = false;
  var askedForApproval = false;
}

/// How a request Open WebUI relayed to one of the user's devices through
/// Tether failed, read from the server's own words (Open WebUI 0.13.4,
/// `utils/tether.py`).
///
/// Read once, where the failure arrives, and kept with the message's error
/// (`ChatMessageError.relay`): what shows the error reads that field.
library;

import 'dart:convert';

import 'package:conduit_core/models/chat_message.dart';

export 'package:conduit_core/models/chat_message.dart' show TetherRelayFailure;

/// What Open WebUI 0.13.4's completion router reports for any failure before
/// the model's answer began, a relay's included: the relay's own words never
/// reach the client then (`routers/openai.py`, `generate_chat_completion`).
const String _serverConnectionError = 'Open WebUI: Server Connection Error';

/// The relay failure [error] reports, or null when it is not one.
///
/// [error] is a message, or a body such as a tool's result or a terminal's
/// 502 (`{"error": ..., "code": "tether_interrupted"}`), or a message's saved
/// error (`{"content": ...}`). A relay's code anywhere in it decides over any
/// words in it ([tetherRelayFailureByCode]).
///
/// [viaTether] says the request went to one of the user's devices, as the
/// request recorded when it was sent. The server's generic connection error
/// then stands for a relay that failed before the device answered. Whether
/// the device ran it cannot be told from that, so it reads as
/// [TetherRelayFailure.interrupted].
TetherRelayFailure? tetherRelayFailureOf(
  Object? error, {
  bool viaTether = false,
}) =>
    tetherRelayFailureByCode(error) ??
    _relayFailureInWordsOf(error, viaTether: viaTether);

/// The relay failure a code in [error] names (`tether_interrupted`), however
/// deep in it the code is, or null. Unlike words, a code cannot be another
/// failure that quotes a relay's.
TetherRelayFailure? tetherRelayFailureByCode(Object? error) {
  final body = _decoded(error);
  if (body is! Map) return null;
  if (body['code'] == 'tether_interrupted') {
    return TetherRelayFailure.interrupted;
  }
  for (final key in _nestedErrorKeys) {
    final failure = tetherRelayFailureByCode(body[key]);
    if (failure != null) return failure;
  }
  return null;
}

/// Where an error object keeps the error it wraps, or its words.
const List<String> _nestedErrorKeys = ['error', 'detail', 'message', 'content'];

TetherRelayFailure? _relayFailureInWordsOf(
  Object? error, {
  required bool viaTether,
}) {
  final body = _decoded(error);
  if (body is Map) {
    for (final key in _nestedErrorKeys) {
      final failure = _relayFailureInWordsOf(body[key], viaTether: viaTether);
      if (failure != null) return failure;
    }
    return null;
  }
  if (body is! String) return null;
  final trimmed = body.trim();
  if (viaTether && trimmed == _serverConnectionError) {
    return TetherRelayFailure.interrupted;
  }
  return _relayFailureInWords(trimmed);
}

/// [error], or the JSON object its words are.
Object? _decoded(Object? error) {
  if (error is! String) return error;
  final trimmed = error.trim();
  if (!trimmed.startsWith('{')) return error;
  try {
    final body = jsonDecode(trimmed);
    return body is Map ? body : error;
  } on FormatException {
    // Words that start with a brace.
    return error;
  }
}

/// Whether [answer]'s request went to a model one of the user's devices
/// offers, as the answer recorded when the request was made
/// ([kCompletionViaTetherKey]). An answer that records nothing, as one from
/// before Conduit recorded it, reads as any other.
bool answerViaTether(ChatMessage answer) =>
    answer.metadata?[kCompletionViaTetherKey] == true;

/// [answer] recording that its request went to a model one of the user's
/// devices offers ([kCompletionViaTetherKey]), its error read with that when
/// it records no relay.
ChatMessage withTetherRecord(ChatMessage answer) {
  final error = answer.error;
  final relay =
      error?.relay ??
      (error == null
          ? null
          : tetherRelayFailureOf(error.content, viaTether: true));
  if (answerViaTether(answer) && relay == error?.relay) return answer;
  return answer.copyWith(
    metadata: <String, dynamic>{
      ...?answer.metadata,
      kCompletionViaTetherKey: true,
    },
    error: error?.copyWith(relay: relay),
  );
}

/// [incoming], a copy of an answer the server saved, with what this device
/// recorded on its own copy of it: that the request went to one of the
/// user's devices ([viaTether]), and the relay failure the same error was
/// read as ([localError]). Open WebUI saves neither.
ChatMessage withTetherRecordOf(
  ChatMessage incoming, {
  ChatMessageError? localError,
  bool viaTether = false,
}) {
  final error = _withRelayOf(incoming.error, localError);
  final kept = identical(error, incoming.error)
      ? incoming
      : incoming.copyWith(error: error);
  return viaTether || answerViaTether(incoming) ? withTetherRecord(kept) : kept;
}

/// [incoming], an answer the server's copy keeps among another answer's
/// versions, as [withTetherRecordOf] keeps an answer: a version records no
/// request of its own, so [viaTether] is what this device recorded on its
/// copy of the answer.
ChatMessageVersion withTetherRecordOfVersion(
  ChatMessageVersion incoming, {
  ChatMessageError? localError,
  bool viaTether = false,
}) {
  var error = _withRelayOf(incoming.error, localError);
  if (viaTether && error != null && error.relay == null) {
    final relay = tetherRelayFailureOf(error.content, viaTether: true);
    if (relay != null) error = error.copyWith(relay: relay);
  }
  return identical(error, incoming.error)
      ? incoming
      : incoming.copyWith(error: error);
}

/// [incoming] with the relay failure [local], this device's copy of the same
/// error, was read as, when [incoming] records none. Another error, though
/// it replaced that one, does not take it.
ChatMessageError? _withRelayOf(
  ChatMessageError? incoming,
  ChatMessageError? local,
) =>
    incoming != null &&
        incoming.relay == null &&
        local?.relay != null &&
        local!.content == incoming.content
    ? incoming.copyWith(relay: local.relay)
    : incoming;

/// [payload], a stored answer, as [withTetherRecord] makes it, its error
/// read from the whole of what the server saved.
Map<String, dynamic> payloadWithTetherRecord(Map<String, dynamic> payload) {
  final error = payload['error'];
  final relay = error is Map && error[kTetherRelayErrorKey] == null
      ? tetherRelayFailureOf(error, viaTether: true)
      : null;
  if (_payloadViaTether(payload) && relay == null) return payload;
  final metadata = payload['metadata'];
  return <String, dynamic>{
    ...payload,
    'metadata': <String, dynamic>{
      if (metadata is Map)
        for (final entry in metadata.entries) entry.key.toString(): entry.value,
      kCompletionViaTetherKey: true,
    },
    if (relay != null)
      'error': <String, dynamic>{
        for (final entry in (error as Map).entries)
          entry.key.toString(): entry.value,
        kTetherRelayErrorKey: relay.name,
      },
  };
}

/// [incoming], the next stored copy of a message, with what the store
/// recorded on the copy it replaces ([stored], that copy's JSON), as
/// [withTetherRecordOf] keeps it on screen. The next copy may be the
/// server's, from a pull, or one rebuilt from the screen; either may have
/// lost it.
Map<String, dynamic> withStoredTetherRecord(
  Map<String, dynamic> incoming,
  String? stored,
) {
  Map<String, dynamic> recorded(Map<String, dynamic> payload, bool viaTether) =>
      viaTether || _payloadViaTether(payload)
      ? payloadWithTetherRecord(payload)
      : payload;

  final error = incoming['error'];
  final unread = error is Map && error[kTetherRelayErrorKey] == null;
  // Most rows record neither; those are not decoded.
  if (stored == null ||
      !(stored.contains('"$kCompletionViaTetherKey"') ||
          (unread && stored.contains('"$kTetherRelayErrorKey"')))) {
    return recorded(incoming, false);
  }
  final Object? earlier;
  try {
    earlier = jsonDecode(stored);
  } on FormatException {
    return recorded(incoming, false);
  }
  if (earlier is! Map) return recorded(incoming, false);
  final earlierError = earlier['error'];
  final earlierRelay = earlierError is Map
      ? tetherRelayFailureFromJson(earlierError[kTetherRelayErrorKey])
      : null;
  final kept =
      unread &&
          earlierRelay != null &&
          earlierError['content'] == error['content']
      ? <String, dynamic>{
          ...incoming,
          'error': <String, dynamic>{
            for (final entry in error.entries)
              entry.key.toString(): entry.value,
            kTetherRelayErrorKey: earlierRelay.name,
          },
        }
      : incoming;
  return recorded(kept, _payloadViaTether(earlier));
}

bool _payloadViaTether(Map<dynamic, dynamic> payload) {
  final metadata = payload['metadata'];
  return metadata is Map && metadata[kCompletionViaTetherKey] == true;
}

/// The status Starlette puts before an `HTTPException`'s detail when the
/// exception is written as text ("503: Tether is offline.").
final RegExp _statusPrefix = RegExp(r'^\d{3}: ');

/// The relay failure [words] are, in Open WebUI 0.13.4's own words for it
/// (`utils/tether.py`), or null. Those are the whole message: as the server
/// sends them, after the status a written `HTTPException` starts with, or
/// after a terminal proxy's "Terminal proxy error: " (`routers/terminals.py`).
/// Words that only quote them, such as another model's error, are not one.
TetherRelayFailure? _relayFailureInWords(String words) {
  var text = words.toLowerCase();
  const proxied = 'terminal proxy error: ';
  if (text.startsWith(proxied)) text = text.substring(proxied.length);
  text = text.replaceFirst(_statusPrefix, '');
  // RelayInterrupted: "Tether connection interrupted: <reason>. The
  // operation may have completed. ..."
  if (text.startsWith('tether connection interrupted:')) {
    return TetherRelayFailure.interrupted;
  }
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return switch (text) {
    'tether has too many active operations' => TetherRelayFailure.busy,
    'tether service is unavailable' ||
    'tether is offline' => TetherRelayFailure.unavailable,
    _ => null,
  };
}

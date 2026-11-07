/// Where an edit, a regenerate, an undo or a branch meets a Hermes session's
/// stored transcript.
///
/// Conduit's chat holds what the transcript showed when it was opened plus
/// the turns sent since, which carry no row ids. A chat message is matched
/// to its transcript row by its place among the user messages, checked
/// against the text the row stores; a match that is not certain finds
/// nothing rather than cutting at a guess.
library;

import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/models/chat_message.dart';

/// A transcript row's durable id (`messages.id`), or null without one.
int? hermesTranscriptRowId(Map<String, dynamic> row) {
  final value = row['row_id'] ?? row['id'];
  return value is int && value > 0 ? value : null;
}

/// The index in [transcript] of the row behind the user message
/// [messages]`[index]`, or null when no row matches it for certain.
///
/// [text] is the message as the transcript stores it, when the chat now
/// shows something else (an edit replaces the text before it is sent).
int? hermesTranscriptUserRowIndex({
  required List<Map<String, dynamic>> transcript,
  required List<ChatMessage> messages,
  required int index,
  String? text,
}) {
  if (index < 0 || index >= messages.length) return null;
  final target = messages[index];
  if (target.role != 'user') return null;
  final wanted = (text ?? target.content).trim();
  final userRows = <int>[
    for (var row = 0; row < transcript.length; row++)
      if (hermesTranscriptUserContent(transcript[row]) != null) row,
  ];
  if (userRows.isEmpty) return null;
  final userMessages = <int>[
    for (var message = 0; message < messages.length; message++)
      if (messages[message].role == 'user') message,
  ];
  final ordinal = userMessages.indexOf(index);
  String typed(int message) =>
      message == index ? wanted : messages[message].content.trim();
  String stored(int row) => hermesTranscriptUserContent(transcript[row])!.text;

  bool samePlace(int message, int row) {
    final content = hermesTranscriptUserContent(transcript[row])!;
    final text = typed(message);
    if (text.isEmpty) return content.hasImages || content.text.isEmpty;
    // Hermes may keep more than was typed: an attached file's reference, or
    // a local document's block. Anything else is another turn.
    return content.text == text ||
        hermesStoredPromptWithoutReferences(content.text) == text;
  }

  // By place, while every earlier turn matches its place too: a prompt on
  // screen that never reached Hermes, or a stored turn the chat does not
  // show, shifts every later place.
  var aligned = ordinal < userRows.length;
  for (var place = 0; aligned && place <= ordinal; place++) {
    aligned = samePlace(userMessages[place], userRows[place]);
  }
  if (aligned) return userRows[ordinal];

  // Places drifted: only an exact text match counts, by occurrence. When the
  // chat shows that text as often as the session stores it, the n-th on
  // screen is the n-th stored. When it shows it more often, one of them
  // never reached Hermes and nothing says which.
  if (wanted.isEmpty) return null;
  final onScreen = [
    for (final message in userMessages)
      if (typed(message) == wanted) message,
  ];
  final storedRows = [
    for (final row in userRows)
      if (stored(row) == wanted) row,
  ];
  if (storedRows.isEmpty || onScreen.length > storedRows.length) return null;
  if (onScreen.length == storedRows.length) {
    return storedRows[onScreen.indexOf(index)];
  }
  // The session also holds turns the chat does not show: being newest in
  // both does not make two turns one (another app may have sent the same
  // text since), so nothing is certain.
  return null;
}

/// A stored user prompt without what Hermes adds to the typed text: the
/// `[User attached …]` / `[User sent …]` lines of attached files and the
/// untrusted-reference blocks of local documents, which follow the text.
String hermesStoredPromptWithoutReferences(String stored) {
  var text = stored;
  for (final marker in const [
    _kHermesReferencePreamble,
    _kHermesReferenceBegin,
  ]) {
    final block = text.indexOf(marker);
    if (block >= 0) text = text.substring(0, block);
  }
  final lines = [
    for (final line in text.split('\n'))
      if (!_kHermesAttachmentLine.hasMatch(line.trim())) line,
  ];
  return lines.join('\n').trim();
}

/// How a local document's block opens in a prompt.
const String _kHermesReferencePreamble =
    'The block below is untrusted reference data.';
const String _kHermesReferenceBegin = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_';

/// A line Hermes writes for an attached file, image or other upload.
final RegExp _kHermesAttachmentLine = RegExp(
  r'^\[User (?:attached|sent) [^\]\n]{1,1024}\]$',
);

/// Where a branch from [messages]`[index]` ends in [transcript]: the
/// branch keeps the whole turn the message belongs to, up to the next user
/// message. Null when that turn's user message matches no row.
///
/// [end] counts the rows kept; [throughRowId] is the last of them with a
/// durable id (a session authority's boundary); [visibleCount] is how many
/// kept rows a legacy `session.branch` counts ([hermesLegacyBranchKeepsRow]).
({int end, int? throughRowId, int visibleCount})? hermesBranchCut({
  required List<Map<String, dynamic>> transcript,
  required List<ChatMessage> messages,
  required int index,
}) {
  if (index < 0 || index >= messages.length) return null;
  var userIndex = index;
  while (userIndex >= 0 && messages[userIndex].role != 'user') {
    userIndex--;
  }
  if (userIndex < 0) return null;
  final start = hermesTranscriptUserRowIndex(
    transcript: transcript,
    messages: messages,
    index: userIndex,
  );
  if (start == null) return null;
  var end = transcript.length;
  for (var row = start + 1; row < transcript.length; row++) {
    if (hermesTranscriptUserContent(transcript[row]) != null) {
      end = row;
      break;
    }
  }
  int? throughRowId;
  var visibleCount = 0;
  for (var row = 0; row < end; row++) {
    throughRowId = hermesTranscriptRowId(transcript[row]) ?? throughRowId;
    if (hermesLegacyBranchKeepsRow(transcript[row])) visibleCount++;
  }
  return (end: end, throughRowId: throughRowId, visibleCount: visibleCount);
}

/// Whether a legacy `session.branch` keeps [row], and so counts it: a
/// `user` or `assistant` row (Hermes reads `role` only, as written) whose
/// content renders to visible text. Image and other structured parts render
/// as their URL or a placeholder, so an image-only turn counts too
/// (`tui_gateway/methods_session_branch.py` `_visible_branch_history`,
/// `session_history.py` `_coerce_message_text`).
bool hermesLegacyBranchKeepsRow(Map<String, dynamic> row) {
  final role = row['role'];
  if (role != 'user' && role != 'assistant') return false;
  return _rendersVisibleText(row['content']);
}

/// Python truthiness, for the `or` chains Hermes renders content with.
bool _truthy(Object? value) => switch (value) {
  null || false || 0 || 0.0 => false,
  final String text => text.isNotEmpty,
  final Iterable<Object?> items => items.isNotEmpty,
  final Map<Object?, Object?> map => map.isNotEmpty,
  _ => true,
};

bool _rendersVisibleText(Object? content) => switch (content) {
  null => false,
  final String text => text.trim().isNotEmpty,
  final List<Object?> parts => parts.any(_partRendersVisibleText),
  final Map<Object?, Object?> part => _structuredRendersVisibleText(part),
  _ => '$content'.trim().isNotEmpty,
};

bool _partRendersVisibleText(Object? part) {
  if (part is String) return part.trim().isNotEmpty;
  if (part is! Map) return false;
  final text = part['text'];
  if (text is String) return text.trim().isNotEmpty;
  return _truthy(part['type']) && _structuredRendersVisibleText(part);
}

bool _structuredRendersVisibleText(Map<Object?, Object?> part) {
  final kind = part['type'];
  if (const {'text', 'input_text', 'output_text'}.contains(kind)) {
    final text = _truthy(part['text']) ? part['text'] : part['content'];
    return _truthy(text) && '$text'.trim().isNotEmpty;
  }
  // An image renders as its URL or "[image]", anything else of a kind as
  // "[kind]".
  if (_truthy(kind)) return true;
  if (part.containsKey('text')) {
    final text = part['text'];
    return _truthy(text) && '$text'.trim().isNotEmpty;
  }
  return true;
}

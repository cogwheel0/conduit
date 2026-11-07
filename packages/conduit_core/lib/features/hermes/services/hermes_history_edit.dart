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

  bool matches(int row) {
    final stored = hermesTranscriptUserContent(transcript[row])!;
    if (wanted.isEmpty) return stored.hasImages || stored.text.isEmpty;
    // Hermes may keep more than was typed (an attached file's reference).
    return stored.text == wanted || stored.text.contains(wanted);
  }

  var ordinal = 0;
  for (var earlier = 0; earlier < index; earlier++) {
    if (messages[earlier].role == 'user') ordinal++;
  }
  if (ordinal < userRows.length && matches(userRows[ordinal])) {
    return userRows[ordinal];
  }
  final candidates = userRows.where(matches).toList(growable: false);
  if (candidates.length == 1) return candidates.single;
  // Several turns asked the same thing: only the newest is certain, and only
  // when the message is the chat's newest too.
  final isNewest = !messages
      .skip(index + 1)
      .any((message) => message.role == 'user');
  if (candidates.length > 1 && isNewest && candidates.last == userRows.last) {
    return candidates.last;
  }
  return null;
}

/// Where a branch from [messages]`[index]` ends in [transcript]: the
/// branch keeps the whole turn the message belongs to, up to the next user
/// message. Null when that turn's user message matches no row.
///
/// [end] counts the rows kept; [throughRowId] is the last of them with a
/// durable id (a session authority's boundary); [visibleCount] is how many
/// kept rows a legacy `session.branch` counts, which are the user and
/// assistant rows with text.
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
    final role = transcript[row]['role'];
    if (role != 'user' && role != 'assistant') continue;
    final text = hermesMessageTextContent(transcript[row]['content']);
    if (text != null && text.trim().isNotEmpty) visibleCount++;
  }
  return (end: end, throughRowId: throughRowId, visibleCount: visibleCount);
}

import 'dart:convert';

import 'package:conduit_core/features/direct_connections/services/direct_mcp_client.dart';

/// [content] put in place of the selection of [text], and where the caret
/// lands after it.
///
/// [selectionStart] and [selectionEnd] are UTF-16 offsets (start not after
/// end); either being null means the field has no valid selection, and the
/// content is appended. Offsets outside the text are clamped.
({String text, int caret}) insertContentAtSelection(
  String text, {
  required int? selectionStart,
  required int? selectionEnd,
  required String content,
}) {
  final start = _clamp(selectionStart, text.length);
  final end = _clamp(selectionEnd, text.length);
  final before = text.substring(0, start);
  return (
    text: '$before$content${text.substring(end < start ? start : end)}',
    caret: before.length + content.length,
  );
}

int _clamp(int? offset, int length) =>
    offset == null || offset < 0 ? length : offset.clamp(0, length);

/// Whether the composer text that inserting [content] would leave is within
/// the size a Direct MCP insertion may reach.
bool directMcpInsertionFitsComposer(
  String text, {
  required int? selectionStart,
  required int? selectionEnd,
  required String content,
}) {
  final inserted = insertContentAtSelection(
    text,
    selectionStart: selectionStart,
    selectionEnd: selectionEnd,
    content: content,
  );
  return utf8.encode(inserted.text).length <= kDirectMcpMaxInsertionBytes;
}

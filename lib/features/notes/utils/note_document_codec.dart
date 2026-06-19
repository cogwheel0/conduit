import 'package:fleather/fleather.dart';
import 'package:parchment/codecs.dart';

import '../../../core/utils/debug_logger.dart';

/// Conversion helpers between a note's canonical markdown (`content.md`, the
/// interchange format shared with the Open WebUI web client) and the
/// [ParchmentDocument] model edited by Fleather.
///
/// Markdown stays the source of truth: notes are stored as `content.md` (+ a
/// derived `content.html`) and `content.json` is left null so notes authored or
/// edited on the web (TipTap) remain fully compatible. These helpers wrap the
/// `parchment` codecs and centralise the best-effort failure handling, since
/// decoding is lossy and may choke on markdown constructs the codec does not
/// model (e.g. web-authored content or AI-enhanced output).

/// Decodes [markdown] into a [ParchmentDocument].
///
/// Falls back to a plain-text document (and ultimately an empty document) if the
/// markdown cannot be parsed, so the editor never fails to open a note.
ParchmentDocument documentFromMarkdown(String markdown) {
  if (markdown.trim().isEmpty) {
    return ParchmentDocument();
  }
  try {
    return parchmentMarkdown.decode(markdown);
  } catch (e, st) {
    DebugLogger.error(
      'Failed to decode note markdown to document; falling back to plain text',
      scope: 'notes/codec',
      error: e,
      stackTrace: st,
    );
    return _plainTextDocument(markdown);
  }
}

/// Encodes [document] back to markdown for `content.md`.
String markdownFromDocument(ParchmentDocument document) {
  try {
    return parchmentMarkdown.encode(document);
  } catch (e, st) {
    DebugLogger.error(
      'Failed to encode note document to markdown; falling back to plain text',
      scope: 'notes/codec',
      error: e,
      stackTrace: st,
    );
    return document.toPlainText();
  }
}

/// Encodes [document] to HTML for `content.html`.
///
/// Returns an empty string on failure; `content.md` remains the source of truth,
/// so a missing HTML representation is non-fatal.
String htmlFromDocument(ParchmentDocument document) {
  try {
    return parchmentHtml.encode(document);
  } catch (e, st) {
    DebugLogger.error(
      'Failed to encode note document to HTML',
      scope: 'notes/codec',
      error: e,
      stackTrace: st,
    );
    return '';
  }
}

/// Builds a document containing [text] as a single unformatted block.
///
/// A Parchment delta must always end with a line break, so one is appended when
/// missing.
ParchmentDocument _plainTextDocument(String text) {
  final normalized = text.endsWith('\n') ? text : '$text\n';
  return ParchmentDocument.fromDelta(Delta()..insert(normalized));
}

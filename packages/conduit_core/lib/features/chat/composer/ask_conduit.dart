/// The "Ask Conduit" selection action: text the reader selected in an answer
/// goes into the chat composer, at the caret, for them to edit and send.
///
/// The insertion itself is `composerTextInsertionProvider` (which the
/// composer listens to) and `insertContentAtSelection`; this is only the
/// decision of what, if anything, an action puts there.
library;

/// The text an Ask Conduit action inserts for [selectedText], or null when the
/// action must not be offered.
///
/// The action shows only for a non-blank selection and only where a
/// composer is waiting for it ([composerTargetId] is the id the composer
/// listens for, `chatComposerTextInsertionTargetId` in the chat). The text is
/// inserted as selected: it is not trimmed, so the reader's own whitespace and
/// line breaks survive.
String? askConduitInsertionText({
  required String? selectedText,
  required String? composerTargetId,
}) {
  final text = selectedText;
  if (composerTargetId == null || composerTargetId.isEmpty) return null;
  if (text == null || text.trim().isEmpty) return null;
  return text;
}

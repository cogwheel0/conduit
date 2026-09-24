import 'package:parchment/parchment.dart';

import 'note_document_codec.dart';

/// Notes between the stored markdown and a Quill 2 editor.
///
/// Quill and Parchment both describe a document as a Delta -- inserts with
/// attributes, line formats on the newline that ends the line -- but they
/// name the formats differently: Parchment's `b` is Quill's `bold`, its
/// `block: ul` is Quill's `list: bullet`, and so on. This maps one onto the
/// other so the desktop edits the same document mobile's Fleather does,
/// through the same markdown codec, with no second converter to drift.
///
/// Only what markdown can hold is mapped. Anything else (colours,
/// alignment) would be lost on the next save regardless, so it is dropped
/// here rather than shown and then silently discarded. Parchment's markdown
/// reads `---` and images as text, so they reach Quill as text too.

/// The Quill ops for [markdown].
List<Map<String, Object?>> quillOpsFromMarkdown(String markdown) =>
    quillOpsFromParchment(<Object?>[
      // `Delta.toJson` hands back the operations themselves; each one's own
      // JSON is the plain map this reads.
      for (final operation in documentFromMarkdown(markdown).toDelta().toList())
        operation.toJson(),
    ]);

/// The markdown for a Quill document's [ops].
String markdownFromQuillOps(List<Object?> ops) => markdownFromDocument(
  ParchmentDocument.fromDelta(Delta.fromJson(parchmentOpsFromQuill(ops))),
);

/// Parchment delta JSON to Quill ops.
List<Map<String, Object?>> quillOpsFromParchment(List<Object?> ops) {
  final out = <Map<String, Object?>>[];
  for (final raw in ops) {
    if (raw is! Map) continue;
    final insert = raw['insert'];
    final attributes = raw['attributes'];
    final Object? quillInsert = switch (insert) {
      final String text => text,
      {'_type': 'hr'} => const <String, Object?>{'divider': true},
      {'_type': 'image', 'source': final String source} => <String, Object?>{
        'image': source,
      },
      // An embed Quill has no blot for: kept as its text so nothing
      // vanishes from the note.
      _ => null,
    };
    if (quillInsert == null) continue;
    final quillAttributes = <String, Object?>{};
    if (attributes is Map) {
      attributes.forEach((key, value) {
        switch (key) {
          case 'b':
            quillAttributes['bold'] = true;
          case 'i':
            quillAttributes['italic'] = true;
          case 'u':
            quillAttributes['underline'] = true;
          case 's':
            quillAttributes['strike'] = true;
          case 'c':
            quillAttributes['code'] = true;
          case 'a':
            quillAttributes['link'] = value;
          case 'heading':
            quillAttributes['header'] = value;
          case 'indent':
            quillAttributes['indent'] = value;
          case 'block':
            switch (value) {
              case 'ul':
                quillAttributes['list'] = 'bullet';
              case 'ol':
                quillAttributes['list'] = 'ordered';
              case 'cl':
                quillAttributes['list'] = attributes['checked'] == true
                    ? 'checked'
                    : 'unchecked';
              case 'quote':
                quillAttributes['blockquote'] = true;
              case 'code':
                quillAttributes['code-block'] = 'plain';
            }
        }
      });
    }
    out.add(<String, Object?>{
      'insert': quillInsert,
      if (quillAttributes.isNotEmpty) 'attributes': quillAttributes,
    });
  }
  return out;
}

/// Quill ops to Parchment delta JSON.
List<Map<String, Object?>> parchmentOpsFromQuill(List<Object?> ops) {
  final out = <Map<String, Object?>>[];
  for (final raw in ops) {
    if (raw is! Map) continue;
    final insert = raw['insert'];
    final attributes = raw['attributes'];
    // Embeds become the markdown that means them. Parchment's markdown
    // codec has no form for an embed -- it writes a placeholder character --
    // so a divider or an image pasted into Quill is kept as its text, which
    // is also how the stored note reads everywhere else.
    final Object? parchmentInsert = switch (insert) {
      final String text => text,
      {'divider': _} => '---\n',
      {'image': final String source} => '![]($source)',
      _ => null,
    };
    if (parchmentInsert == null) continue;
    final parchmentAttributes = <String, Object?>{};
    if (attributes is Map) {
      attributes.forEach((key, value) {
        switch (key) {
          case 'bold' when value == true:
            parchmentAttributes['b'] = true;
          case 'italic' when value == true:
            parchmentAttributes['i'] = true;
          case 'underline' when value == true:
            parchmentAttributes['u'] = true;
          case 'strike' when value == true:
            parchmentAttributes['s'] = true;
          case 'code' when value == true:
            parchmentAttributes['c'] = true;
          case 'link' when value is String:
            parchmentAttributes['a'] = value;
          case 'header' when value is int:
            parchmentAttributes['heading'] = value;
          case 'indent' when value is int:
            parchmentAttributes['indent'] = value;
          case 'list':
            switch (value) {
              case 'bullet':
                parchmentAttributes['block'] = 'ul';
              case 'ordered':
                parchmentAttributes['block'] = 'ol';
              case 'checked':
                parchmentAttributes['block'] = 'cl';
                parchmentAttributes['checked'] = true;
              case 'unchecked':
                parchmentAttributes['block'] = 'cl';
            }
          case 'blockquote' when value == true:
            parchmentAttributes['block'] = 'quote';
          case 'code-block' when value != null && value != false:
            parchmentAttributes['block'] = 'code';
        }
      });
    }
    out.add(<String, Object?>{
      'insert': parchmentInsert,
      if (parchmentAttributes.isNotEmpty) 'attributes': parchmentAttributes,
    });
  }
  // A Parchment document must end with a newline; an empty Quill editor
  // still sends one, but a hand-built delta might not.
  final last = out.lastOrNull?['insert'];
  if (last is! String || !last.endsWith('\n')) {
    out.add(const <String, Object?>{'insert': '\n'});
  }
  return out;
}

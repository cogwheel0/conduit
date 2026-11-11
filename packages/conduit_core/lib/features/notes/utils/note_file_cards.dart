import 'package:parchment/parchment.dart';

import 'package:conduit_core/features/notes/utils/note_document_codec.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';

/// Embed type of a file card in a note: a file attached by a link on a line
/// of its own, as an Open WebUI 0.12.5 note attaches files. The web editor
/// shows such a link as a file card where it sits; so does Conduit.
const String kNoteFileEmbedType = 'note_file';

/// A file card for file [id] named [name].
BlockEmbed noteFileEmbed({required String id, required String name}) =>
    BlockEmbed(
      kNoteFileEmbedType,
      data: <String, dynamic>{'id': id, 'name': name},
    );

/// The file a card shows, or null for any other embed.
NoteFileLink? noteFileOfEmbed(EmbeddableObject embed) {
  if (embed.type != kNoteFileEmbedType) return null;
  final Object? id = embed.data['id'];
  final Object? name = embed.data['name'];
  if (id is! String || id.isEmpty) return null;
  return NoteFileLink(
    id: id,
    name: name is String && name.isNotEmpty ? name : id,
  );
}

/// Decodes a note page's [markdown] for the editor, with each file link on a
/// line of its own as a card.
ParchmentDocument noteDocumentFromMarkdown(String markdown) =>
    _withFileCards(documentFromMarkdown(markdown));

/// Encodes [document] as a note page's markdown, each card as the link on a
/// line of its own it was read from. The markdown codec leaves out block
/// embeds, so the cards are turned back into links first.
String noteMarkdownFromDocument(ParchmentDocument document) =>
    markdownFromDocument(_withFileLinks(document));

/// The files [document] shows as cards, in order.
List<NoteFileLink> noteFileCardsIn(ParchmentDocument document) =>
    <NoteFileLink>[for (final (_, NoteFileLink file) in _cards(document)) file];

/// The offsets of the cards for file [id] in [document], last first, so
/// each can be removed without moving the others.
List<int> noteFileCardOffsets(ParchmentDocument document, String id) => <int>[
  for (final (int offset, NoteFileLink file) in _cards(
    document,
  ).toList().reversed)
    if (file.id == id) offset,
];

/// Each card in [document] with its offset.
Iterable<(int, NoteFileLink)> _cards(ParchmentDocument document) sync* {
  for (final LineNode line in _lines(document.root)) {
    if (!line.hasBlockEmbed) continue;
    final file = noteFileOfEmbed((line.children.single as EmbedNode).value);
    if (file != null) yield (line.documentOffset, file);
  }
}

Iterable<LineNode> _lines(ContainerNode<Node> container) sync* {
  for (final Node node in container.children) {
    if (node is LineNode) {
      yield node;
    } else if (node is ContainerNode<Node>) {
      yield* _lines(node);
    }
  }
}

/// [document] with each plain line that holds nothing but a link to a file
/// as a card. Rebuilt line by line, so the card takes the line the link held
/// and nothing else moves.
ParchmentDocument _withFileCards(ParchmentDocument document) {
  final lines = <(List<Operation>, Map<String, dynamic>?)>[];
  var current = <Operation>[];
  for (final Operation op in document.toDelta().toList()) {
    final data = op.data;
    if (data is! String) {
      current.add(op);
      continue;
    }
    final parts = data.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) {
        current.add(Operation.insert(parts[i], op.attributes));
      }
      if (i < parts.length - 1) {
        lines.add((current, op.attributes));
        current = <Operation>[];
      }
    }
  }
  var changed = false;
  final out = Delta();
  for (final (List<Operation> ops, Map<String, dynamic>? lineStyle) in lines) {
    // Only a plain paragraph: a link in a list, quote, heading or code block
    // stays a link.
    final file = lineStyle == null || lineStyle.isEmpty
        ? _fileOfLine(ops)
        : null;
    if (file != null) {
      changed = true;
      out
        ..insert(noteFileEmbed(id: file.id, name: file.name).toJson())
        ..insert('\n');
      continue;
    }
    for (final op in ops) {
      out.push(op);
    }
    out.insert('\n', lineStyle);
  }
  for (final op in current) {
    out.push(op);
  }
  return changed ? ParchmentDocument.fromDelta(out) : document;
}

/// The file a line links, when the line holds nothing else.
NoteFileLink? _fileOfLine(List<Operation> ops) {
  if (ops.isEmpty) return null;
  String? href;
  // Text between two links, if only a space, makes them two links, each with
  // its own label, not one card.
  var afterLink = false;
  final text = StringBuffer();
  for (final op in ops) {
    final data = op.data;
    if (data is! String) return null;
    // Code is text, however much it looks like a link.
    if (op.attributes?.containsKey(ParchmentAttribute.inlineCode.key) ??
        false) {
      return null;
    }
    final link = op.attributes?[ParchmentAttribute.link.key];
    if (link is! String) {
      if (data.trim().isNotEmpty) return null;
      afterLink = href != null;
      continue;
    }
    if (href != null && (href != link || afterLink)) return null;
    href = link;
    text.write(data);
  }
  if (href == null || text.toString().trim().isEmpty) return null;
  final links = noteFileLinksInMarkdown('[${text.toString().trim()}]($href)');
  return links.length == 1 ? links.single : null;
}

/// A copy of [document] with each card as a link to its file, on its line.
ParchmentDocument _withFileLinks(ParchmentDocument document) {
  if (_cards(document).isEmpty) return document;
  final links = Delta();
  for (final Operation op in document.toDelta().toList()) {
    final data = op.data;
    final NoteFileLink? file = data is Map<String, dynamic>
        ? noteFileOfEmbed(EmbeddableObject.fromJson(data))
        : null;
    if (file == null) {
      links.push(op);
      continue;
    }
    final label = noteFileLinkMarkdown(id: file.id, name: file.name);
    links.insert(label.substring(1, label.indexOf('](')), <String, dynamic>{
      ParchmentAttribute.link.key: '/api/v1/files/${file.id}/content',
    });
  }
  return ParchmentDocument.fromDelta(links);
}

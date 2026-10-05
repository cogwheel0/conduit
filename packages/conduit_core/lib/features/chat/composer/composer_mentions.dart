// Mention tracking for the chat composer
// (lib/features/chat/widgets/mention_text_controller.dart).
//
// A mention is a range of the draft that stands for an entity (an `@model`)
// or an Open WebUI skill (`$skill`). The ranges follow edits around them and
// disappear when an edit touches them; on send the draft becomes Open WebUI's
// wire format (`<@M:id|label>`, `<$id|label>`).
import 'package:meta/meta.dart';

/// What a mention stands for.
enum ComposerMentionKind {
  /// A model (`M`), user (`U`) or channel (`C`), per [ComposerMention.idType].
  entity,

  /// An Open WebUI workspace skill.
  skill,
}

/// A tracked mention: [start] to [end] (UTF-16 offsets, end exclusive).
@immutable
final class ComposerMention {
  const ComposerMention({
    required this.start,
    required this.end,
    required this.id,
    required this.label,
    this.idType = 'M',
    this.kind = ComposerMentionKind.entity,
  });

  final int start;
  final int end;

  /// 'M' for a model, 'U' for a user, 'C' for a channel.
  final String idType;

  /// The entity id (a model id, a skill id).
  final String id;

  /// The display label (the model or skill name).
  final String label;

  final ComposerMentionKind kind;

  ComposerMention _shifted(int delta) => ComposerMention(
    start: start + delta,
    end: end + delta,
    id: id,
    label: label,
    idType: idType,
    kind: kind,
  );

  /// The Open WebUI wire token for this mention.
  String get wireToken => kind == ComposerMentionKind.skill
      ? '<\$$id|$label>'
      : '<@$idType:$id|$label>';

  @override
  bool operator ==(Object other) =>
      other is ComposerMention &&
      other.start == start &&
      other.end == end &&
      other.idType == idType &&
      other.id == id &&
      other.label == label &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(start, end, idType, id, label, kind);

  @override
  String toString() =>
      'ComposerMention($kind $idType:$id "$label" $start..$end)';
}

/// The mentions in a composer draft, kept in step with its edits.
///
/// Mentions are added explicitly (when a suggestion is picked). Call
/// [reconcile] with the text before and after every edit: a mention after
/// the edit shifts, one before it stays, and one the edit touches is dropped.
class ComposerMentionTracker {
  final List<ComposerMention> _mentions = <ComposerMention>[];

  /// The tracked mentions, sorted by start.
  List<ComposerMention> get mentions => List.unmodifiable(_mentions);

  bool get isEmpty => _mentions.isEmpty;

  /// Tracks a mention spanning [start] to [end].
  void add(
    int start,
    int end, {
    String idType = 'M',
    String id = '',
    String label = '',
    ComposerMentionKind kind = ComposerMentionKind.entity,
  }) {
    _mentions
      ..add(
        ComposerMention(
          start: start,
          end: end,
          idType: idType,
          id: id,
          label: label,
          kind: kind,
        ),
      )
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Forgets every mention.
  void clear() => _mentions.clear();

  /// Moves or drops mentions for the edit that turned [oldText] into
  /// [newText].
  ///
  /// The edit spans from the first differing character to the last, measured
  /// from both ends of the text. Whitespace typed right after a mention keeps
  /// it (the space that ends it); a mention wholly after the edited range
  /// shifts, and any other change that touches a mention drops it, including
  /// one that starts before the mention and runs into it.
  void reconcile(String oldText, String newText) {
    if (_mentions.isEmpty || oldText == newText) return;

    final delta = newText.length - oldText.length;
    var changeStart = 0;
    final minLength = oldText.length < newText.length
        ? oldText.length
        : newText.length;
    while (changeStart < minLength &&
        oldText.codeUnitAt(changeStart) == newText.codeUnitAt(changeStart)) {
      changeStart++;
    }

    // Where the edited range ends in the old text: what both texts share at
    // their ends is not part of the edit.
    var commonSuffix = 0;
    while (commonSuffix < minLength - changeStart &&
        oldText.codeUnitAt(oldText.length - 1 - commonSuffix) ==
            newText.codeUnitAt(newText.length - 1 - commonSuffix)) {
      commonSuffix++;
    }
    final oldChangeEnd = oldText.length - commonSuffix;

    final updated = <ComposerMention>[];
    for (final mention in _mentions) {
      final boundaryInsertionIsDelimiter =
          changeStart == mention.end &&
          delta > 0 &&
          newText.substring(changeStart, changeStart + delta).trim().isEmpty;
      if (changeStart > mention.end ||
          (changeStart == mention.end &&
              (delta <= 0 || boundaryInsertionIsDelimiter))) {
        // After this mention: unchanged.
        updated.add(mention);
      } else if (mention.start >= oldChangeEnd) {
        // The edited range ends before this mention: shift it.
        updated.add(mention._shifted(delta));
      }
      // The edited range touches the mention: drop it.
    }
    _mentions
      ..clear()
      ..addAll(updated);
  }

  /// [text] with each tracked mention replaced by its wire token
  /// (`@GPT-4` becomes `<@M:gpt-4|GPT-4>`).
  String toWireFormat(String text) {
    if (_mentions.isEmpty) return text;
    final buffer = StringBuffer();
    var cursor = 0;
    for (final mention in _mentions) {
      final start = mention.start.clamp(cursor, text.length);
      final end = mention.end.clamp(start, text.length);
      if (start == end) continue;
      buffer
        ..write(text.substring(cursor, start))
        ..write(mention.wireToken);
      cursor = end;
    }
    if (cursor < text.length) buffer.write(text.substring(cursor));
    return buffer.toString();
  }

  /// The mention ranges clamped to [text], in order, skipping empty ones:
  /// what a text field styles.
  List<({int start, int end, ComposerMentionKind kind})> rangesIn(String text) {
    final ranges = <({int start, int end, ComposerMentionKind kind})>[];
    var cursor = 0;
    for (final mention in _mentions) {
      final start = mention.start.clamp(cursor, text.length);
      final end = mention.end.clamp(start, text.length);
      if (start == end) continue;
      ranges.add((start: start, end: end, kind: mention.kind));
      cursor = end;
    }
    return ranges;
  }
}

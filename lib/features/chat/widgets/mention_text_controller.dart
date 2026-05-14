import 'package:flutter/material.dart';

/// Metadata for a tracked mention (range + identity).
class MentionData {
  MentionData({
    required this.range,
    required this.idType,
    required this.id,
    required this.label,
  });

  TextRange range;

  /// 'M' for model, 'U' for user, 'C' for channel.
  final String idType;

  /// The entity ID (e.g. model ID).
  final String id;

  /// Display label (e.g. model name).
  final String label;
}

/// A [TextEditingController] that renders tracked `@mention` spans
/// with distinct styling inside the text field.
///
/// Mentions are registered explicitly via [addMention] (typically
/// when the user selects a model from the `@` overlay). The
/// controller keeps the ranges in sync as the user edits surrounding
/// text — if a mention's text is modified it is automatically
/// removed from tracking.
class MentionTextEditingController extends TextEditingController {
  MentionTextEditingController({super.text});

  /// Active mention data, sorted by [TextRange.start].
  final List<MentionData> _mentionData = <MentionData>[];

  /// The color used for mention text. Updated by the widget that
  /// owns this controller whenever the theme changes.
  Color mentionColor = const Color(0xFF1976D2);

  /// Background highlight for mention tokens.
  Color mentionBackground = const Color(0x1A1976D2);

  /// Registers a new mention spanning [start] to [end].
  ///
  /// [idType] is 'M' for model, 'U' for user, 'C' for
  /// channel. [id] is the entity ID and [label] is the
  /// display name.
  void addMention(
    int start,
    int end, {
    String idType = 'M',
    String id = '',
    String label = '',
  }) {
    _mentionData
      ..add(
        MentionData(
          range: TextRange(start: start, end: end),
          idType: idType,
          id: id,
          label: label,
        ),
      )
      ..sort((a, b) => a.range.start.compareTo(b.range.start));
  }

  /// Removes all tracked mentions.
  void clearMentions() => _mentionData.clear();

  /// Converts display text to the OpenWebUI wire format.
  ///
  /// Replaces each tracked mention span (e.g. `@GPT-4`)
  /// with `<@M:model_id|GPT-4>`.
  String toWireFormat() {
    final String plainText = text;
    if (_mentionData.isEmpty) return plainText;

    final buf = StringBuffer();
    int cursor = 0;

    for (final m in _mentionData) {
      final start = m.range.start.clamp(0, plainText.length);
      final end = m.range.end.clamp(start, plainText.length);
      if (start == end) continue;

      buf.write(plainText.substring(cursor, start));
      buf.write('<@${m.idType}:${m.id}|${m.label}>');
      cursor = end;
    }

    if (cursor < plainText.length) {
      buf.write(plainText.substring(cursor));
    }
    return buf.toString();
  }

  @override
  set value(TextEditingValue newValue) {
    // Adjust mention ranges when text length changes.
    if (_mentionData.isNotEmpty) {
      _reconcileMentions(text, newValue.text);
    }
    super.value = newValue;
  }

  /// Walks the diff between [oldText] and [newText] and
  /// shifts / invalidates mention ranges accordingly.
  void _reconcileMentions(String oldText, String newText) {
    if (oldText == newText) return;

    final int delta = newText.length - oldText.length;
    int changeStart = 0;
    final int minLen = oldText.length < newText.length
        ? oldText.length
        : newText.length;
    while (changeStart < minLen &&
        oldText[changeStart] == newText[changeStart]) {
      changeStart++;
    }

    final List<MentionData> updated = <MentionData>[];
    for (final MentionData m in _mentionData) {
      if (changeStart >= m.range.end) {
        // After this mention — keep as-is.
        updated.add(m);
      } else if (changeStart <= m.range.start) {
        // Before this mention — shift it.
        m.range = TextRange(
          start: m.range.start + delta,
          end: m.range.end + delta,
        );
        updated.add(m);
      }
      // Overlaps the mention — drop it.
    }
    _mentionData
      ..clear()
      ..addAll(updated);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final String plainText = text;
    if (plainText.isEmpty || _mentionData.isEmpty) {
      return TextSpan(style: style, text: plainText);
    }

    final mentionStyle = style?.copyWith(
      color: mentionColor,
      fontWeight: FontWeight.w600,
      backgroundColor: mentionBackground,
    );

    final List<InlineSpan> children = <InlineSpan>[];
    int cursor = 0;

    for (final MentionData m in _mentionData) {
      final int start = m.range.start.clamp(0, plainText.length);
      final int end = m.range.end.clamp(start, plainText.length);
      if (start == end) continue;

      if (start > cursor) {
        children.add(
          TextSpan(text: plainText.substring(cursor, start), style: style),
        );
      }

      children.add(
        TextSpan(text: plainText.substring(start, end), style: mentionStyle),
      );
      cursor = end;
    }

    if (cursor < plainText.length) {
      children.add(TextSpan(text: plainText.substring(cursor), style: style));
    }

    return TextSpan(style: style, children: children);
  }
}

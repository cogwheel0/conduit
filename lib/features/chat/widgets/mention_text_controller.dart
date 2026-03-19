import 'package:flutter/material.dart';

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

  /// Active mention ranges, sorted by [TextRange.start].
  final List<TextRange> _mentions = <TextRange>[];

  /// The color used for mention text. Updated by the widget that
  /// owns this controller whenever the theme changes.
  Color mentionColor = const Color(0xFF1976D2);

  /// Background highlight for mention tokens.
  Color mentionBackground = const Color(0x1A1976D2);

  /// Registers a new mention spanning [start] to [end] in the
  /// current text.
  void addMention(int start, int end) {
    _mentions
      ..add(TextRange(start: start, end: end))
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Removes all tracked mentions.
  void clearMentions() => _mentions.clear();

  @override
  set value(TextEditingValue newValue) {
    // Adjust mention ranges when text length changes.
    if (_mentions.isNotEmpty) {
      _reconcileMentions(text, newValue.text);
    }
    super.value = newValue;
  }

  /// Walks the diff between [oldText] and [newText] and shifts /
  /// invalidates mention ranges accordingly.
  void _reconcileMentions(String oldText, String newText) {
    if (oldText == newText) return;

    final int delta = newText.length - oldText.length;
    // Find the first character that differs.
    int changeStart = 0;
    final int minLen =
        oldText.length < newText.length ? oldText.length : newText.length;
    while (changeStart < minLen &&
        oldText[changeStart] == newText[changeStart]) {
      changeStart++;
    }

    final List<TextRange> updated = <TextRange>[];
    for (final TextRange m in _mentions) {
      if (changeStart >= m.end) {
        // Change is entirely after this mention — keep as-is.
        updated.add(m);
      } else if (changeStart <= m.start) {
        // Change is entirely before this mention — shift it.
        updated.add(TextRange(
          start: m.start + delta,
          end: m.end + delta,
        ));
      }
      // Otherwise the change overlaps the mention — drop it.
    }
    _mentions
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
    if (plainText.isEmpty || _mentions.isEmpty) {
      return TextSpan(style: style, text: plainText);
    }

    final mentionStyle = style?.copyWith(
      color: mentionColor,
      fontWeight: FontWeight.w600,
      backgroundColor: mentionBackground,
    );

    final List<InlineSpan> children = <InlineSpan>[];
    int cursor = 0;

    for (final TextRange m in _mentions) {
      final int start = m.start.clamp(0, plainText.length);
      final int end = m.end.clamp(start, plainText.length);
      if (start == end) continue;

      // Plain text before this mention.
      if (start > cursor) {
        children.add(
          TextSpan(text: plainText.substring(cursor, start), style: style),
        );
      }

      // The mention itself.
      children.add(
        TextSpan(text: plainText.substring(start, end), style: mentionStyle),
      );
      cursor = end;
    }

    // Trailing plain text.
    if (cursor < plainText.length) {
      children.add(
        TextSpan(text: plainText.substring(cursor), style: style),
      );
    }

    return TextSpan(style: style, children: children);
  }
}

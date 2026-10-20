import 'package:conduit_core/features/chat/composer/composer_mentions.dart';
import 'package:material_ui/material_ui.dart';

export 'package:conduit_core/features/chat/composer/composer_mentions.dart'
    show ComposerMentionKind;

/// A [TextEditingController] that renders tracked `@mention` spans
/// with distinct styling inside the text field.
///
/// Mentions are registered explicitly via [addMention] (typically
/// when the user selects a model from the `@` overlay). The ranges, how they
/// follow edits and the wire format are conduit_core's
/// [ComposerMentionTracker]: a mention whose text is modified is dropped.
class MentionTextEditingController extends TextEditingController {
  MentionTextEditingController({super.text});

  final ComposerMentionTracker _mentions = ComposerMentionTracker();

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
    ComposerMentionKind kind = ComposerMentionKind.entity,
  }) {
    _mentions.add(start, end, idType: idType, id: id, label: label, kind: kind);
  }

  /// Removes all tracked mentions.
  void clearMentions() => _mentions.clear();

  /// Converts display text to the OpenWebUI wire format.
  ///
  /// Replaces each tracked mention span (e.g. `@GPT-4`)
  /// with `<@M:model_id|GPT-4>`.
  String toWireFormat() => _mentions.toWireFormat(text);

  @override
  set value(TextEditingValue newValue) {
    // Adjust mention ranges when text length changes.
    _mentions.reconcile(text, newValue.text);
    super.value = newValue;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final String plainText = text;
    final ranges = _mentions.rangesIn(plainText);
    if (plainText.isEmpty || ranges.isEmpty) {
      return TextSpan(style: style, text: plainText);
    }

    final mentionStyle = style?.copyWith(
      color: mentionColor,
      fontWeight: FontWeight.w600,
      backgroundColor: mentionBackground,
    );

    final List<InlineSpan> children = <InlineSpan>[];
    int cursor = 0;

    for (final range in ranges) {
      if (range.start > cursor) {
        children.add(
          TextSpan(
            text: plainText.substring(cursor, range.start),
            style: style,
          ),
        );
      }

      children.add(
        TextSpan(
          text: plainText.substring(range.start, range.end),
          style: mentionStyle,
        ),
      );
      cursor = range.end;
    }

    if (cursor < plainText.length) {
      children.add(TextSpan(text: plainText.substring(cursor), style: style));
    }

    return TextSpan(style: style, children: children);
  }
}

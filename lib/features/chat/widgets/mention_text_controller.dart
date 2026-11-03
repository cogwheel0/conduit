import 'dart:convert';

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

  /// Saves only visible input and explicitly registered mentions. Literal
  /// wire-looking text must remain literal when the input is restored.
  String snapshotDraft() => text.isEmpty
      ? ''
      : jsonEncode({
          'v': 1,
          'text': text,
          'mentions': [
            for (final mention in _mentions.mentions)
              {
                'start': mention.start,
                'end': mention.end,
                'idType': mention.idType,
                'id': mention.id,
                'label': mention.label,
                'kind': mention.kind.name,
              },
          ],
        });

  bool restoreDraft(String snapshot) {
    if (snapshot.isEmpty) {
      clearMentions();
      clear();
      return true;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(snapshot);
    } on FormatException {
      return false;
    }
    if (decoded is! Map || decoded['v'] != 1 || decoded['text'] is! String) {
      return false;
    }
    final restoredText = decoded['text'] as String;
    clearMentions();
    value = TextEditingValue(
      text: restoredText,
      selection: TextSelection.collapsed(offset: restoredText.length),
    );
    final mentions = decoded['mentions'];
    if (mentions is List) {
      for (final item in mentions) {
        if (item is! Map) continue;
        final start = item['start'];
        final end = item['end'];
        final id = item['id'];
        final label = item['label'];
        final idType = item['idType'];
        final kind = switch (item['kind']) {
          'entity' => ComposerMentionKind.entity,
          'skill' => ComposerMentionKind.skill,
          _ => null,
        };
        if (start is! int ||
            end is! int ||
            start < 0 ||
            end <= start ||
            end > restoredText.length ||
            id is! String ||
            label is! String ||
            idType is! String ||
            kind == null) {
          continue;
        }
        addMention(
          start,
          end,
          id: id,
          label: label,
          idType: idType,
          kind: kind,
        );
      }
    }
    notifyListeners();
    return true;
  }

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

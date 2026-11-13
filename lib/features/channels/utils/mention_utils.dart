import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/channels/utils/channel_mentions.dart';

export 'package:conduit_core/features/channels/utils/channel_mentions.dart';

/// Builds a [TextSpan] tree that renders mention tags
/// with styled highlighting and the rest as plain text.
TextSpan buildMentionSpan({
  required String content,
  required TextStyle baseStyle,
  required Color mentionColor,
}) {
  final matches = mentionRegex.allMatches(content);
  if (matches.isEmpty) {
    return TextSpan(text: content, style: baseStyle);
  }

  final mentionStyle = baseStyle.copyWith(
    color: mentionColor,
    fontWeight: FontWeight.w600,
  );

  final children = <InlineSpan>[];
  var cursor = 0;

  for (final m in matches) {
    if (m.start > cursor) {
      children.add(
        TextSpan(text: content.substring(cursor, m.start), style: baseStyle),
      );
    }
    children.add(TextSpan(text: '@${m.group(2)}', style: mentionStyle));
    cursor = m.end;
  }

  if (cursor < content.length) {
    children.add(TextSpan(text: content.substring(cursor), style: baseStyle));
  }

  return TextSpan(children: children);
}

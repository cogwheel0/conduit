import 'package:flutter/material.dart';

import '../../../core/models/channel_message.dart';

/// Regex matching OpenWebUI mention tags:
/// `<@M:model_id|Label>` or `<@U:user_id|Name>`.
final _mentionRegex =
    RegExp(r'<@[A-Z]:([^|>]+)\|([^>]+)>');

/// Strips OpenWebUI mention markup, keeping only the
/// display label prefixed with @.
String stripMentions(String content) =>
    content.replaceAllMapped(
      _mentionRegex,
      (m) => '@${m.group(2)}',
    );

/// Whether [message] was sent by a model (has model_id
/// in meta).
bool isModelMessage(ChannelMessage message) =>
    message.meta?['model_id'] != null;

/// Display name for the message: model name if it's a
/// model response, otherwise the user name.
String messageDisplayName(ChannelMessage message) {
  if (isModelMessage(message)) {
    return message.meta!['model_name'] as String? ??
        message.meta!['model_id'] as String? ??
        'Model';
  }
  return message.userName;
}

/// Builds a [TextSpan] tree that renders mention tags
/// with styled highlighting and the rest as plain text.
TextSpan buildMentionSpan({
  required String content,
  required TextStyle baseStyle,
  required Color mentionColor,
}) {
  final matches = _mentionRegex.allMatches(content);
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
      children.add(TextSpan(
        text: content.substring(cursor, m.start),
        style: baseStyle,
      ));
    }
    children.add(TextSpan(
      text: '@${m.group(2)}',
      style: mentionStyle,
    ));
    cursor = m.end;
  }

  if (cursor < content.length) {
    children.add(TextSpan(
      text: content.substring(cursor),
      style: baseStyle,
    ));
  }

  return TextSpan(children: children);
}

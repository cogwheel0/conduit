import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../shared/widgets/markdown/markdown_config.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../../../shared/widgets/markdown/renderer/conduit_markdown_widget.dart';

/// Renders channel message text with the same Markdown pipeline used by chat.
class ChannelMessageContent extends StatelessWidget {
  /// Creates a Markdown-rendered channel message body.
  const ChannelMessageContent({
    super.key,
    required this.content,
    this.stateScopeId,
    this.onTapLink,
  });

  /// Raw channel message content from OpenWebUI.
  final String content;

  /// Stable identifier used to preserve Markdown block state for this message.
  final String? stateScopeId;

  /// Optional override used by tests or embedders that want custom link taps.
  final MarkdownLinkTapCallback? onTapLink;

  @override
  Widget build(BuildContext context) {
    final normalized = ConduitMarkdownPreprocessor.normalize(content);
    if (normalized.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return ConduitMarkdownWidget(
      data: normalized,
      stateScopeId: stateScopeId,
      onLinkTap: onTapLink ?? (url, _) => _launchChannelLink(url),
    );
  }
}

Future<void> _launchChannelLink(String url) async {
  if (url.isEmpty) return;
  try {
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  } catch (error, stackTrace) {
    developer.log(
      'Unable to open channel message link',
      name: 'channels.markdown',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

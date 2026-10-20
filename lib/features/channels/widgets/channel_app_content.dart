import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'package:conduit_core/models/channel_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../workspace/widgets/workspace_export_controller.dart';
import '../utils/channel_request_owner.dart';
import 'channel_message_content.dart';

// Cards, buttons and private replies of external apps in channels, as Open
// WebUI 0.12.1 renders them in AppEmbed.svelte, AppChannelReply.svelte and
// Messages.svelte. App content is untrusted: Markdown goes through the same
// pipeline as channel messages, and links through the external link
// allowlist.

const String _logScope = 'channels/apps';

/// The avatar of an app: its profile image, or a grid glyph when it has none.
class ChannelAppAvatar extends StatelessWidget {
  const ChannelAppAvatar({super.key, required this.size, this.imageUrl});

  final double size;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final radius = BorderRadius.circular(size / 4);
    return AvatarImage(
      size: size,
      imageUrl: imageUrl,
      borderRadius: radius,
      fallbackBuilder: (context, size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: theme.surfaceContainer,
          borderRadius: radius,
        ),
        child: Icon(
          Icons.grid_view_rounded,
          size: size * 0.6,
          color: theme.textSecondary,
          semanticLabel: AppLocalizations.of(context)!.channelAppBadge,
        ),
      ),
    );
  }
}

/// The small "App" label next to an app's name.
class ChannelAppBadge extends StatelessWidget {
  const ChannelAppBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      AppLocalizations.of(context)!.channelAppBadge,
      style: AppTypography.labelSmallStyle.copyWith(
        color: context.conduitTheme.textSecondary,
      ),
    );
  }
}

/// The cards and buttons of the app message [message]. Pressing a button
/// asks the app through the interactions endpoint; an answer meant for the
/// asking user alone goes to [onReply].
class ChannelAppMessageCards extends ConsumerStatefulWidget {
  const ChannelAppMessageCards({
    super.key,
    required this.message,
    required this.channelId,
    required this.onReply,
    this.parentId,
  });

  final ChannelMessage message;
  final String channelId;

  /// The thread the message is shown in, or null for the channel itself.
  final String? parentId;
  final ValueChanged<AppChannelReplyEvent> onReply;

  @override
  ConsumerState<ChannelAppMessageCards> createState() =>
      _ChannelAppMessageCardsState();
}

class _ChannelAppMessageCardsState
    extends ConsumerState<ChannelAppMessageCards> {
  bool _busy = false;
  String? _error;

  Future<void> _press(AppAction action) async {
    final message = widget.message;
    final appId = message.appId;
    final actionId = action.actionId;
    if (_busy || appId == null || actionId == null) return;
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    final authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    bool owns() =>
        mounted &&
        isChannelRequestOwnerCurrent(
          ref: ref,
          api: api,
          authSessionEpoch: authSessionEpoch,
        );
    try {
      final json = await api.createAppInteraction(
        appId,
        messageId: message.id,
        actionId: actionId,
      );
      if (!owns()) return;
      // A reply to the channel arrives as a channel message; only an answer
      // for the asking user is shown here.
      final reply = AppChannelReply.fromJson(json);
      if (reply != null && reply.showsToAskerOnly) {
        widget.onReply(
          AppChannelReplyEvent(
            appId: appId,
            appName: message.user?.name,
            channelId: widget.channelId,
            messageId: message.id,
            parentId: widget.parentId,
            reply: reply,
          ),
        );
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'app-interaction-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
      if (!owns()) return;
      setState(() => _error = _errorDetail(error) ?? l10n.errorMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final embeds = message.appEmbeds;
    final actions = message.appActions;
    if (embeds.isEmpty && actions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: ChannelAppReplyBody(
        reply: AppChannelReply(embeds: embeds, actions: actions),
        stateScopeId: 'channel-app:${message.id}',
        busy: _busy,
        error: _error,
        onAction: _press,
      ),
    );
  }
}

/// The detail of an Open WebUI error response, which the web client shows.
String? _errorDetail(Object error) {
  if (error is! DioException) return null;
  final data = error.response?.data;
  final detail = data is Map ? data['detail'] : null;
  return detail is String && detail.trim().isNotEmpty ? detail.trim() : null;
}

/// The body of an app reply: title, text, cards, the fallback text of an
/// error, a download button and the reply's buttons and links.
class ChannelAppReplyBody extends StatelessWidget {
  const ChannelAppReplyBody({
    super.key,
    required this.reply,
    required this.stateScopeId,
    this.busy = false,
    this.error,
    this.onAction,
  });

  final AppChannelReply reply;
  final String stateScopeId;
  final bool busy;

  /// Why the last button press failed.
  final String? error;

  /// Presses a button. Without it buttons are disabled; links still open.
  final ValueChanged<AppAction>? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final children = <Widget>[
      if (reply.title.isNotEmpty)
        Text(
          reply.title,
          style: AppTypography.bodyMediumStyle.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      if (reply.content.isNotEmpty)
        ChannelMessageContent(
          content: reply.content,
          stateScopeId: '$stateScopeId:content',
        ),
      for (final (index, embed) in reply.embeds.indexed)
        AppEmbedCard(embed: embed, stateScopeId: '$stateScopeId:embed:$index'),
      if (reply.isError && reply.content.isEmpty)
        Semantics(
          liveRegion: true,
          child: Text(
            l10n.channelAppErrorFallback,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textPrimary,
            ),
          ),
        ),
      if (error case final error?)
        Semantics(
          liveRegion: true,
          child: Text(
            error,
            style: AppTypography.bodySmallStyle.copyWith(color: theme.error),
          ),
        ),
      if (reply.isDownload) _DownloadButton(reply: reply),
      if (reply.actions.isNotEmpty)
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final (index, action) in reply.actions.indexed)
              _buildAction(action, isFirst: index == 0),
          ],
        ),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) const SizedBox(height: Spacing.sm),
          child,
        ],
      ],
    );
  }

  Widget _buildAction(AppAction action, {required bool isFirst}) {
    final url = action.url;
    if (url != null) {
      return ConduitButton(
        text: action.label,
        isCompact: true,
        isSecondary: true,
        useNative: false,
        onPressed: () => launchExternalLink(url, scope: _logScope),
      );
    }
    final onAction = this.onAction;
    return ConduitButton(
      text: action.label,
      isCompact: true,
      // The first button is the primary one, as on the web.
      isSecondary: !isFirst,
      useNative: false,
      onPressed: busy || onAction == null ? null : () => onAction(action),
    );
  }
}

/// Saves the Markdown file of a download reply through the share sheet.
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.reply});

  final AppChannelReply reply;

  Future<void> _share(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final box = context.findRenderObject();
    final origin = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    try {
      await WorkspaceExportController().shareBytes(
        filename: reply.filename,
        bytes: utf8.encode(reply.content),
        mimeType: 'text/markdown',
        sharePositionOrigin: origin,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'app-download-failed',
        scope: _logScope,
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        AdaptiveSnackBar.show(
          context,
          message: l10n.errorMessage,
          type: AdaptiveSnackBarType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConduitButton(
      text: AppLocalizations.of(context)!.channelAppDownload(reply.filename),
      isCompact: true,
      useNative: false,
      onPressed: () => _share(context),
    );
  }
}

/// One app card: author, linked title, Markdown description, thumbnail,
/// fields and footer, with an accent bar in the card's color.
class AppEmbedCard extends StatelessWidget {
  const AppEmbedCard({
    super.key,
    required this.embed,
    required this.stateScopeId,
  });

  final AppEmbed embed;
  final String stateScopeId;

  static const double _maxWidth = 520;
  static const double _thumbnailSize = 48;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final secondary = AppTypography.bodySmallStyle.copyWith(
      color: theme.textSecondary,
    );
    final color = embed.color;
    final url = embed.url;
    final thumbnail = embed.thumbnailUrl;
    final hasThumbnail =
        thumbnail != null &&
        (thumbnail.startsWith('https://') || thumbnail.startsWith('http://'));

    final heading = <Widget>[
      if (embed.title.isNotEmpty)
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: url == null
              ? null
              : () => launchExternalLink(url, scope: _logScope),
          child: Text(
            embed.title,
            style: AppTypography.bodyMediumStyle.copyWith(
              color: url == null
                  ? theme.textPrimary
                  : Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      if (embed.description.isNotEmpty)
        ChannelMessageContent(
          content: embed.description,
          stateScopeId: '$stateScopeId:description',
        ),
    ];

    final radius = BorderRadius.circular(AppBorderRadius.sm);
    final card = Container(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: theme.surfaceContainer.withValues(alpha: 0.5),
        borderRadius: radius,
        border: Border.all(color: theme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (embed.authorName case final author?)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xs),
              child: Text(author, style: secondary),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (index, child) in heading.indexed) ...[
                      if (index > 0) const SizedBox(height: Spacing.xs),
                      child,
                    ],
                  ],
                ),
              ),
              if (hasThumbnail) ...[
                const SizedBox(width: Spacing.sm),
                AvatarImage(
                  size: _thumbnailSize,
                  imageUrl: thumbnail,
                  borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                  // A thumbnail that fails to load is left out, as on the web.
                  fallbackBuilder: (context, size) => const SizedBox.shrink(),
                ),
              ],
            ],
          ),
          if (embed.fields.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.sm),
              child: _EmbedFields(
                fields: embed.fields,
                stateScopeId: '$stateScopeId:field',
              ),
            ),
          if (embed.footerText case final footer?)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.sm),
              child: Text(footer, style: secondary),
            ),
        ],
      ),
    );
    if (color == null) return card;
    // A rounded border must be one color, so the accent is a bar laid over
    // the card's left edge.
    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        children: [
          card,
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: ColoredBox(color: Color(0xFF000000 | color)),
          ),
        ],
      ),
    );
  }
}

/// The fields of a card: inline fields share rows of three once the card is
/// wide enough, the others take a row each.
class _EmbedFields extends StatelessWidget {
  const _EmbedFields({required this.fields, required this.stateScopeId});

  final List<AppEmbedField> fields;
  final String stateScopeId;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = Spacing.md;
        final width = constraints.maxWidth;
        final inlineWidth = width > 360 ? (width - 2 * gap) / 3 : width;
        return Wrap(
          spacing: gap,
          runSpacing: Spacing.sm,
          children: [
            for (final (index, field) in fields.indexed)
              SizedBox(
                width: field.inline ? inlineWidth : width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      field.name,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    ChannelMessageContent(
                      content: field.value,
                      stateScopeId: '$stateScopeId:$index',
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// An app reply only the signed-in user sees, shown under the message it
/// answers until the user dismisses it or leaves. Mirrors Messages.svelte.
class ChannelPrivateAppReply extends StatelessWidget {
  const ChannelPrivateAppReply({
    super.key,
    required this.event,
    required this.onDismiss,
    this.avatarSize = 28,
  });

  final AppChannelReplyEvent event;
  final VoidCallback onDismiss;
  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final secondary = AppTypography.bodySmallStyle.copyWith(
      color: theme.textSecondary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChannelAppAvatar(size: avatarSize),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        event.appName ?? l10n.channelAppBadge,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.xs),
                    const ChannelAppBadge(),
                  ],
                ),
                const SizedBox(height: Spacing.xxs),
                ChannelAppReplyBody(
                  reply: event.reply,
                  stateScopeId: 'channel-app-reply:${event.key}',
                ),
                const SizedBox(height: Spacing.xs),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: Spacing.xs,
                  children: [
                    Text(l10n.channelAppOnlyVisibleToYou, style: secondary),
                    Text('·', style: secondary),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onDismiss,
                      child: Semantics(
                        button: true,
                        child: Text(
                          l10n.channelAppDismiss,
                          style: secondary.copyWith(
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

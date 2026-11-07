import 'dart:math' as math;

import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'hermes_approval_card.dart';
import 'hermes_room_avatars.dart';
import 'hermes_rooms_section.dart';

const double _kAvatarSize = 28;

/// One timeline row of an open room.
class HermesRoomTimelineRow extends StatelessWidget {
  const HermesRoomTimelineRow({
    super.key,
    required this.item,
    required this.roomId,
    this.previous,
    this.onContinue,
    this.onStop,
    this.busy = false,
  });

  final HermesRoomTimelineItem item;
  final String roomId;

  /// The row before this one, to group a bot's consecutive messages.
  final HermesRoomTimelineItem? previous;

  /// Continues a paused discussion.
  final ValueChanged<String>? onContinue;
  final VoidCallback? onStop;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    return switch (item) {
      HermesRoomMessageItem() => item.own
          ? _OwnMessage(item: item)
          : _AuthorMessage(
              item: item,
              roomId: roomId,
              showAuthor: !_sameAuthor(previous, item),
            ),
      HermesRoomNoticeItem() => _NoticeLine(item: item),
      HermesRoomRouteItem() => _RouteLine(item: item),
      HermesRoomPauseItem() => _PauseRow(
        item: item,
        busy: busy,
        onContinue: onContinue,
        onStop: onStop,
      ),
    };
  }

  static bool _sameAuthor(
    HermesRoomTimelineItem? previous,
    HermesRoomMessageItem item,
  ) =>
      previous is HermesRoomMessageItem &&
      !previous.own &&
      previous.author == item.author &&
      previous.scheduled == item.scheduled;
}

class _OwnMessage extends StatelessWidget {
  const _OwnMessage({required this.item});

  final HermesRoomMessageItem item;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final maxWidth = math.min(MediaQuery.sizeOf(context).width * 0.78, 640.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.xxl,
        Spacing.sm,
        Spacing.md,
        Spacing.xs,
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            key: ValueKey<String>('hermes-room-own-${item.seq}'),
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm + Spacing.xxs,
            ),
            decoration: BoxDecoration(
              color: theme.chatBubbleUser,
              borderRadius: const BorderRadius.all(
                Radius.circular(AppBorderRadius.chatBubble),
              ),
            ),
            child: Text(
              item.text,
              style: AppTypography.chatMessageStyle.copyWith(
                color: theme.chatBubbleUserText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthorMessage extends StatelessWidget {
  const _AuthorMessage({
    required this.item,
    required this.roomId,
    required this.showAuthor,
  });

  final HermesRoomMessageItem item;
  final String roomId;
  final bool showAuthor;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final member = item.member;
    final created = item.event.createdAt;
    Widget avatar;
    if (!showAuthor) {
      avatar = const SizedBox(width: _kAvatarSize);
    } else if (member != null) {
      avatar = HermesRoomMemberAvatar(member: member, size: _kAvatarSize);
    } else {
      avatar = Container(
        width: _kAvatarSize,
        height: _kAvatarSize,
        decoration: BoxDecoration(
          color: theme.surfaceContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          item.scheduled ? Icons.event_repeat_rounded : Icons.person_outline,
          size: IconSize.small,
          color: theme.iconSecondary,
        ),
      );
    }
    final text = ConduitMarkdownPreprocessor.normalize(item.text);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.md,
        showAuthor ? Spacing.sm : 1,
        Spacing.md,
        1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showAuthor)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.xxs),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodySmallStyle.copyWith(
                              color: theme.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (item.scheduled) ...[
                          const SizedBox(width: Spacing.xs),
                          _Badge(text: l10n.hermesRoomScheduled),
                        ],
                        if (created != null) ...[
                          const SizedBox(width: Spacing.sm),
                          Text(
                            hermesRoomActivityLabel(created),
                            style: AppTypography.labelSmallStyle.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (text.trim().isNotEmpty)
                  ConduitMarkdownWidget(
                    data: text,
                    dataIsPrepared: true,
                    stateScopeId: 'hermes-room:$roomId:${item.seq}',
                    onLinkTap: (url, _) =>
                        launchExternalLink(url, scope: 'hermes/rooms'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
      ),
      child: Text(
        text,
        style: AppTypography.labelSmallStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
    );
  }
}

/// A quiet centered line between messages.
class _QuietLine extends StatelessWidget {
  const _QuietLine({required this.child, this.leading});

  final Widget child;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: Spacing.lg,
      vertical: Spacing.xs,
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: Spacing.xs)],
        Flexible(child: child),
      ],
    ),
  );
}

String _noticeLabel(AppLocalizations l10n, HermesRoomNoticeKind kind) =>
    switch (kind) {
      HermesRoomNoticeKind.turnFailed => l10n.hermesRoomTurnFailed,
      HermesRoomNoticeKind.turnCancelled => l10n.hermesRoomTurnCancelled,
      HermesRoomNoticeKind.turnDeferred => l10n.hermesRoomTurnDeferred,
      HermesRoomNoticeKind.memberUnavailable =>
        l10n.hermesRoomMemberUnavailable,
      HermesRoomNoticeKind.stopped => l10n.hermesRoomStopped,
      HermesRoomNoticeKind.disbanded => l10n.hermesRoomDisbanded,
      HermesRoomNoticeKind.authorityLost => l10n.hermesRoomAuthorityLost,
      HermesRoomNoticeKind.workLimit => l10n.hermesRoomWorkLimit,
    };

class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.item});

  final HermesRoomNoticeItem item;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final failed = item.kind == HermesRoomNoticeKind.turnFailed;
    final style = AppTypography.labelSmallStyle.copyWith(
      color: failed ? theme.error : theme.textSecondary,
    );
    final member = item.member;
    final detail = item.detail;
    return _QuietLine(
      leading: member == null
          ? null
          : HermesRoomMemberAvatar(member: member, size: 16),
      child: Text.rich(
        TextSpan(
          children: [
            if (item.memberName case final name?)
              TextSpan(
                text: '$name · ',
                style: style.copyWith(fontWeight: FontWeight.w600),
              ),
            TextSpan(text: _noticeLabel(l10n, item.kind)),
            if (detail != null) TextSpan(text: ': $detail'),
          ],
        ),
        key: ValueKey<String>('hermes-room-notice-${item.seq}'),
        style: style,
        textAlign: TextAlign.center,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _RouteLine extends StatelessWidget {
  const _RouteLine({required this.item});

  final HermesRoomRouteItem item;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final names = item.names.join(', ');
    final lead = item.lead ?? '';
    final text = switch (item.kind) {
      HermesRoomRouteKind.routedTo => l10n.hermesRoomRoutedTo(names),
      HermesRoomRouteKind.routedEveryone => l10n.hermesRoomRoutedEveryone,
      HermesRoomRouteKind.routedFallback => l10n.hermesRoomRoutedFallback,
      HermesRoomRouteKind.assigned => l10n.hermesRoomAssigned(lead, names),
      HermesRoomRouteKind.leadTaking => l10n.hermesRoomLeadTaking(lead),
      HermesRoomRouteKind.continued => l10n.hermesRoomContinued,
      HermesRoomRouteKind.handoff => l10n.hermesRoomHandoff(lead, names),
    };
    return _QuietLine(
      child: Text(
        text,
        key: ValueKey<String>('hermes-room-route-${item.key}'),
        textAlign: TextAlign.center,
        style: AppTypography.labelSmallStyle.copyWith(
          color: theme.textSecondary,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

class _PauseRow extends StatelessWidget {
  const _PauseRow({
    required this.item,
    required this.busy,
    this.onContinue,
    this.onStop,
  });

  final HermesRoomPauseItem item;
  final bool busy;
  final ValueChanged<String>? onContinue;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final label = Text(
      l10n.hermesRoomPaused(item.messageCount),
      textAlign: TextAlign.center,
      style: AppTypography.labelSmallStyle.copyWith(
        color: theme.textSecondary,
        fontWeight: FontWeight.w600,
      ),
    );
    if (!item.actionable) return _QuietLine(child: label);
    return Padding(
      key: ValueKey<String>('hermes-room-pause-${item.seq}'),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      child: Column(
        children: [
          label,
          const SizedBox(height: Spacing.xs),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              ConduitButton(
                key: const ValueKey<String>('hermes-room-continue'),
                text: AppLocalizations.of(context)!.continueAction,
                isCompact: true,
                isLoading: busy,
                onPressed: onContinue == null || busy
                    ? null
                    : () => onContinue!(item.discussionEventId),
              ),
              ConduitButton(
                text: l10n.hermesJobStop,
                isCompact: true,
                isSecondary: true,
                onPressed: onStop,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A decision the room waits on, as a card under the timeline: an
/// approval with the choices Hermes offers, or uncertain work to retry.
class HermesRoomDecisionCard extends StatelessWidget {
  const HermesRoomDecisionCard({
    super.key,
    required this.action,
    required this.room,
    required this.busy,
    required this.onAnswer,
  });

  final HermesRoomPendingAction action;
  final HermesRoom room;
  final bool busy;
  final void Function(HermesRoomPendingAction action, String? choice)
  onAnswer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final member = room.member(action.memberId);
    final name = member?.name ?? action.memberId;
    final padding = const EdgeInsets.symmetric(
      horizontal: Spacing.md,
      vertical: Spacing.sm,
    );
    if (action.isRetry) {
      final theme = context.conduitTheme;
      return Padding(
        padding: padding,
        child: Row(
          children: [
            if (member != null) ...[
              HermesRoomMemberAvatar(member: member, size: 20),
              const SizedBox(width: Spacing.sm),
            ],
            Expanded(
              child: Text(
                l10n.hermesRoomRetryPrompt(name),
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
            ConduitButton(
              text: l10n.retry,
              isCompact: true,
              isLoading: busy,
              onPressed: busy ? null : () => onAnswer(action, null),
            ),
          ],
        ),
      );
    }
    final approval = action.approval;
    final what = action.command ?? approval?.description ?? approval?.command;
    final choices = [
      if (action.canAllowOnce) 'once',
      if (action.canDeny) 'deny',
    ];
    final summary = what == null ? name : '$name: $what';
    if (choices.isEmpty) {
      // Nothing this app may answer: say what waits, without buttons.
      return _QuietLine(
        child: Text(
          '${l10n.hermesRoomNeedsYou} · $summary',
          textAlign: TextAlign.center,
          style: AppTypography.labelSmallStyle.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
      );
    }
    return Padding(
      padding: padding,
      child: HermesApprovalCard(
        key: ValueKey<String>(
          'hermes-room-approval-${action.taskId}-${action.requestId}',
        ),
        state: busy
            ? HermesApprovalState.resolving
            : HermesApprovalState.pending,
        summary: summary,
        choices: choices,
        onChoice: (choice) => onAnswer(action, choice),
        onDecision: (_) {},
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../data/release_links.dart';
import '../models/release_note.dart';

class ReleaseNotesSheet extends StatelessWidget {
  const ReleaseNotesSheet({
    super.key,
    required this.currentVersion,
    required this.previousVersion,
    this.subtitle,
    required this.notes,
    required this.onOpenUrl,
    required this.onOpenSupport,
    required this.supportLabel,
    required this.supportIcon,
    required this.onClose,
  });

  final String currentVersion;
  final String? previousVersion;
  final String? subtitle;
  final List<ReleaseNote> notes;
  final ValueChanged<String> onOpenUrl;
  final VoidCallback onOpenSupport;
  final String supportLabel;
  final IconData supportIcon;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;

    // Stagger index shared across header, notes, and action sections so the
    // sheet content rises as one cascading sequence.
    var revealIndex = 0;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StaggeredReveal(
            index: revealIndex++,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.releaseNotesTitle,
                        style: theme.headingSmall?.copyWith(
                          color: theme.textPrimary,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        subtitle ??
                            l10n.releaseNotesSubtitle(
                              previousVersion ?? currentVersion,
                              currentVersion,
                            ),
                        style: theme.bodySmall?.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                _VersionBadge(version: currentVersion),
              ],
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Flexible(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < notes.length; i++) ...[
                    _StaggeredReveal(
                      index: revealIndex++,
                      child: _ReleaseNoteSection(note: notes[i]),
                    ),
                    if (i != notes.length - 1)
                      const SizedBox(height: Spacing.lg),
                  ],
                  const SizedBox(height: Spacing.xl),
                  _StaggeredReveal(
                    index: revealIndex++,
                    child: _ReleaseActionSection(
                      title: l10n.releaseNotesReviewHeading,
                      message: l10n.releaseNotesReviewMessage,
                      actionLabel: l10n.releaseNotesReviewButton,
                      actionIcon: Icons.rate_review_rounded,
                      onPressed: () => onOpenUrl(reviewUrlForPlatform()),
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  _StaggeredReveal(
                    index: revealIndex++,
                    child: _ReleaseActionSection(
                      title: l10n.releaseNotesSupportHeading,
                      message: l10n.releaseNotesSupportMessage,
                      actionLabel: supportLabel,
                      actionIcon: supportIcon,
                      onPressed: onOpenSupport,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          _StaggeredReveal(
            index: revealIndex++,
            child: ConduitButton(
              text: l10n.releaseNotesDoneButton,
              isFullWidth: true,
              onPressed: onClose,
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades and rises content in a soft cascade when the sheet appears.
///
/// Collapses to a plain passthrough when the platform requests reduced
/// motion, so the sheet stays a static cross-fade for those users.
class _StaggeredReveal extends StatelessWidget {
  const _StaggeredReveal({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 260 + index * 40),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 10),
            child: child,
          ),
        );
      },
    );
  }
}

class _VersionBadge extends StatelessWidget {
  const _VersionBadge({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.buttonPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppBorderRadius.badge),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm + Spacing.xxs,
          vertical: Spacing.xs + Spacing.xxs,
        ),
        child: Text(
          version,
          style: theme.caption?.copyWith(
            color: theme.buttonPrimary,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _ReleaseNoteSection extends StatelessWidget {
  const _ReleaseNoteSection({required this.note});

  final ReleaseNote note;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          note.title,
          style: theme.bodyLarge?.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          note.intro,
          style: theme.bodyMedium?.copyWith(
            color: theme.textSecondary,
            height: 1.45,
          ),
        ),
        const SizedBox(height: Spacing.md),
        for (var i = 0; i < note.bullets.length; i++) ...[
          _ReleaseBullet(text: note.bullets[i], icon: note.iconForBullet(i)),
          if (i != note.bullets.length - 1) const SizedBox(height: Spacing.md),
        ],
      ],
    );
  }
}

class _ReleaseBullet extends StatelessWidget {
  const _ReleaseBullet({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final icon = this.icon;

    final Widget leading = icon != null
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: theme.buttonPrimary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
            ),
            child: SizedBox(
              width: 30,
              height: 30,
              child: Icon(icon, size: IconSize.sm, color: theme.buttonPrimary),
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(top: 8, left: 12, right: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.buttonPrimary,
                shape: BoxShape.circle,
              ),
              child: const SizedBox(width: 6, height: 6),
            ),
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        leading,
        const SizedBox(width: Spacing.sm + Spacing.xs),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: icon != null ? Spacing.xs : 0),
            child: Text(
              text,
              style: theme.bodyMedium?.copyWith(
                color: theme.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReleaseActionSection extends StatelessWidget {
  const _ReleaseActionSection({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.actionIcon,
    required this.onPressed,
  });

  final String title;
  final String message;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaceContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.6),
          width: BorderWidth.thin,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.bodyMedium?.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              message,
              style: theme.bodySmall?.copyWith(
                color: theme.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: Spacing.md),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                ConduitButton(
                  icon: actionIcon,
                  text: actionLabel,
                  isSecondary: true,
                  isCompact: true,
                  onPressed: onPressed,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

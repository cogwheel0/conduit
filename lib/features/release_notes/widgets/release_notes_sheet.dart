import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/chrome_gradient_fade.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../models/release_note.dart';

const double _releaseFooterHeight = Spacing.xl + TouchTarget.comfortable;

/// Editorial release notes built for quick scanning.
///
/// The feature list deliberately stays vertical. Every highlight is visible in
/// the document flow, so people do not need to discover a hidden carousel or
/// remember which page they have already read.
class ReleaseNotesSheet extends StatelessWidget {
  const ReleaseNotesSheet({
    super.key,
    required this.currentVersion,
    required this.notes,
    required this.onReview,
    required this.onOpenSupport,
    required this.supportLabel,
    required this.supportIcon,
    required this.onClose,
  });

  final String currentVersion;
  final List<ReleaseNote> notes;
  final VoidCallback onReview;
  final VoidCallback onOpenSupport;
  final String supportLabel;
  final IconData supportIcon;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final view = View.of(context);
    final composerBottomInset = defaultTargetPlatform == TargetPlatform.iOS
        ? view.viewPadding.bottom / view.devicePixelRatio
        : 0.0;
    final sheetHeight =
        (viewportHeight * 0.84).clamp(0.0, 720.0) + composerBottomInset;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final useCompactSupport = viewportHeight < 600 || textScale > 1.3;
    final highlights = <_ReleaseHighlight>[
      for (final note in notes)
        for (var i = 0; i < note.bullets.length; i++)
          _ReleaseHighlight(
            text: note.bullets[i],
            icon: note.iconForBullet(i),
            iconAsset: note.iconAssetForBullet(i),
          ),
    ];
    final intro = notes.isEmpty ? null : notes.last.intro;
    var revealIndex = 0;
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StaggeredReveal(
          index: revealIndex++,
          child: _ReleaseHeader(
            title: l10n.releaseNotesAnnouncementTitle(
              currentVersion.split('.').take(2).join('.'),
            ),
            version: currentVersion,
            intro: intro,
          ),
        ),
        if (highlights.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          for (var i = 0; i < highlights.length; i++) ...[
            _StaggeredReveal(
              index: revealIndex++,
              child: _ReleaseFeatureRow(
                highlight: highlights[i],
                ordinal: i + 1,
              ),
            ),
            if (i != highlights.length - 1) const SizedBox(height: Spacing.md),
          ],
        ],
      ],
    );

    return ColoredBox(
      color: theme.surfaceBackground,
      child: SizedBox(
        height: sheetHeight,
        child: Stack(
          children: [
            Positioned.fill(
              bottom: _releaseFooterHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const ValueKey('release-notes-summary-scroll'),
                      physics: const BouncingScrollPhysics(),
                      child: summary,
                    ),
                  ),
                  SizedBox(height: useCompactSupport ? Spacing.sm : Spacing.md),
                  _StaggeredReveal(
                    index: revealIndex++,
                    child: _ReleaseSupportSection(
                      heading: l10n.releaseNotesSupportPromptHeading,
                      message: l10n.releaseNotesSupportPromptMessage,
                      reviewLabel: l10n.releaseNotesReviewButton,
                      supportLabel: supportLabel,
                      supportIcon: supportIcon,
                      onReview: onReview,
                      onSupport: onOpenSupport,
                      compact: useCompactSupport,
                    ),
                  ),
                ],
              ),
            ),
            const PositionedDirectional(
              start: 0,
              end: 0,
              bottom: 0,
              child: ConduitChromeGradientFade.bottom(
                contentHeight: TouchTarget.comfortable,
                fadeHeight: Spacing.md,
              ),
            ),
            PositionedDirectional(
              start: 0,
              end: 0,
              bottom: 0,
              child: _StaggeredReveal(
                index: revealIndex,
                child: _ReleaseFooter(
                  doneLabel: l10n.releaseNotesDoneButton,
                  onClose: onClose,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleaseHeader extends StatelessWidget {
  const _ReleaseHeader({
    required this.title,
    required this.version,
    required this.intro,
  });

  final String title;
  final String version;
  final String? intro;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: AppTypography.headlineMediumStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    height: 1.08,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Spacing.md),
            _VersionBadge(version: version),
          ],
        ),
        if (intro != null && intro!.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          Text(
            intro!,
            style: theme.bodyLarge?.copyWith(
              color: theme.textPrimary,
              height: 1.48,
            ),
          ),
        ],
      ],
    );
  }
}

class _ReleaseHighlight {
  const _ReleaseHighlight({required this.text, this.icon, this.iconAsset});

  final String text;
  final IconData? icon;
  final String? iconAsset;

  String get title {
    final separator = text.indexOf(':');
    return separator == -1 ? text : text.substring(0, separator).trim();
  }

  String get body {
    final separator = text.indexOf(':');
    return separator == -1 ? '' : text.substring(separator + 1).trim();
  }
}

class _ReleaseFeatureRow extends StatelessWidget {
  const _ReleaseFeatureRow({required this.highlight, required this.ordinal});

  final _ReleaseHighlight highlight;
  final int ordinal;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Semantics(
      label: '${highlight.title}. ${highlight.body}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReleaseFeatureIcon(
            icon: highlight.icon,
            iconAsset: highlight.iconAsset,
            ordinal: ordinal,
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    highlight.title,
                    style: theme.bodyLarge?.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      height: 1.2,
                    ),
                  ),
                  if (highlight.body.isNotEmpty) ...[
                    const SizedBox(height: Spacing.xs),
                    Text(
                      highlight.body,
                      style: theme.bodyMedium?.copyWith(
                        color: theme.textSecondary,
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReleaseFeatureIcon extends StatelessWidget {
  const _ReleaseFeatureIcon({
    required this.icon,
    required this.iconAsset,
    required this.ordinal,
  });

  final IconData? icon;
  final String? iconAsset;
  final int ordinal;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final foreground = theme.buttonPrimary;
    final graphic = iconAsset != null
        ? ImageIcon(
            AssetImage(iconAsset!),
            size: IconSize.md,
            color: foreground,
          )
        : icon != null
        ? Icon(icon, size: IconSize.md, color: foreground)
        : Text(
            '$ordinal',
            style: theme.caption?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: theme.isDark ? 0.18 : 0.1),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: SizedBox(
        width: TouchTarget.minimum,
        height: TouchTarget.minimum,
        child: Center(child: graphic),
      ),
    );
  }
}

class _ReleaseSupportSection extends StatelessWidget {
  const _ReleaseSupportSection({
    required this.heading,
    required this.message,
    required this.reviewLabel,
    required this.supportLabel,
    required this.supportIcon,
    required this.onReview,
    required this.onSupport,
    required this.compact,
  });

  final String heading;
  final String message;
  final String reviewLabel;
  final String supportLabel;
  final IconData supportIcon;
  final VoidCallback onReview;
  final VoidCallback onSupport;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return DecoratedBox(
      key: const ValueKey<String>('release-notes-support-card'),
      decoration: BoxDecoration(
        color: theme.isDark ? theme.cardBackground : theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        border: theme.isDark
            ? Border.all(color: theme.cardBorder, width: BorderWidth.standard)
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.md,
          Spacing.md,
          Spacing.md,
          Spacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              heading,
              style: theme.bodyLarge?.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (!compact) ...[
              const SizedBox(height: Spacing.xs),
              Text(
                message,
                style: theme.bodyMedium?.copyWith(
                  color: theme.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                Expanded(
                  child: _ReleaseActionRow(
                    label: reviewLabel,
                    icon: Icons.rate_review_rounded,
                    color: theme.buttonPrimary,
                    onPressed: onReview,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: _ReleaseActionRow(
                    label: supportLabel,
                    icon: supportIcon,
                    color: theme.warning,
                    onPressed: onSupport,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleaseActionRow extends StatelessWidget {
  const _ReleaseActionRow({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Semantics(
      label: label,
      button: true,
      child: SizedBox(
        width: double.infinity,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TouchTarget.comfortable),
          child: AdaptiveButton.child(
            onPressed: onPressed,
            color: color,
            style: AdaptiveButtonStyle.plain,
            size: AdaptiveButtonSize.medium,
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            minSize: const Size(0, TouchTarget.comfortable),
            useNative: false,
            child: Row(
              children: [
                Icon(icon, size: IconSize.sm, color: color),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.fade,
                    style: theme.bodyMedium?.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReleaseFooter extends StatelessWidget {
  const _ReleaseFooter({required this.doneLabel, required this.onClose});

  final String doneLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.xl, Spacing.md, 0),
      child: Align(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: ConduitButton(
            text: doneLabel,
            isFullWidth: true,
            useNative: false,
            onPressed: onClose,
          ),
        ),
      ),
    );
  }
}

/// Fades and rises content in a soft cascade when the sheet appears.
///
/// Reduced-motion users get the complete static hierarchy immediately.
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
      duration: Duration(milliseconds: 240 + index * 36),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 8),
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
        color: theme.buttonPrimary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppBorderRadius.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm + Spacing.xs,
          vertical: Spacing.sm,
        ),
        child: Text(
          version,
          style: theme.caption?.copyWith(
            color: theme.buttonPrimary,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

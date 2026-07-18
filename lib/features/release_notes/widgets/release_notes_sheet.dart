import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../models/release_note.dart';

class ReleaseNotesSheet extends StatefulWidget {
  const ReleaseNotesSheet({
    super.key,
    required this.currentVersion,
    required this.previousVersion,
    this.subtitle,
    this.showSubtitle = true,
    required this.notes,
    required this.onReview,
    required this.onOpenSupport,
    required this.supportLabel,
    required this.supportIcon,
    required this.onClose,
  });

  final String currentVersion;
  final String? previousVersion;
  final String? subtitle;
  final bool showSubtitle;
  final List<ReleaseNote> notes;
  final VoidCallback onReview;
  final VoidCallback onOpenSupport;
  final String supportLabel;
  final IconData supportIcon;
  final VoidCallback onClose;

  @override
  State<ReleaseNotesSheet> createState() => _ReleaseNotesSheetState();
}

class _ReleaseNotesSheetState extends State<ReleaseNotesSheet> {
  final _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.84;
    final highlightHeight = (maxHeight * 0.34).clamp(176.0, 240.0);
    final highlights = <_ReleaseHighlight>[
      for (final note in widget.notes)
        for (var i = 0; i < note.bullets.length; i++)
          _ReleaseHighlight(
            text: note.bullets[i],
            icon: note.iconForBullet(i),
            iconAsset: note.iconAssetForBullet(i),
          ),
    ];
    final intro = widget.notes.isEmpty ? null : widget.notes.last.intro;
    var revealIndex = 0;

    void selectPage(int index) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _pageController.jumpToPage(index);
      } else {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
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
                        if (widget.showSubtitle) ...[
                          const SizedBox(height: Spacing.xs),
                          Text(
                            widget.subtitle ??
                                l10n.releaseNotesSubtitle(
                                  widget.previousVersion ??
                                      widget.currentVersion,
                                  widget.currentVersion,
                                ),
                            style: theme.bodySmall?.copyWith(
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  _VersionBadge(version: widget.currentVersion),
                ],
              ),
            ),
            const SizedBox(height: Spacing.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (intro != null) ...[
                  _StaggeredReveal(
                    index: revealIndex++,
                    child: Text(
                      intro,
                      style: theme.bodyMedium?.copyWith(
                        color: theme.textSecondary,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                ],
                if (highlights.isNotEmpty) ...[
                  SizedBox(
                    height: highlightHeight,
                    child: _StaggeredReveal(
                      index: revealIndex++,
                      child: PageView.builder(
                        controller: _pageController,
                        physics: const BouncingScrollPhysics(),
                        allowImplicitScrolling: true,
                        itemCount: highlights.length,
                        itemBuilder: (context, index) {
                          return _ReleaseHighlightCard(
                            highlight: highlights[index],
                            pageIndex: index,
                            pageCount: highlights.length,
                            onPageSelected: selectPage,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: Spacing.md),
            _StaggeredReveal(
              index: revealIndex++,
              child: _ReleaseSupportCard(
                heading: l10n.releaseNotesSupportPromptHeading,
                message: l10n.releaseNotesSupportPromptMessage,
                reviewLabel: l10n.releaseNotesReviewButton,
                supportLabel: widget.supportLabel,
                supportIcon: widget.supportIcon,
                reviewColor: theme.buttonPrimary,
                supportColor: theme.warning,
                onReview: widget.onReview,
                onSupport: widget.onOpenSupport,
              ),
            ),
            const SizedBox(height: Spacing.md),
            _StaggeredReveal(
              index: revealIndex,
              child: ConduitButton(
                text: l10n.releaseNotesDoneButton,
                isFullWidth: true,
                onPressed: widget.onClose,
              ),
            ),
          ],
        ),
      ),
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

class _ReleaseHighlightCard extends StatelessWidget {
  const _ReleaseHighlightCard({
    required this.highlight,
    required this.pageIndex,
    required this.pageCount,
    required this.onPageSelected,
  });

  final _ReleaseHighlight highlight;
  final int pageIndex;
  final int pageCount;
  final ValueChanged<int> onPageSelected;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    final localizations = MaterialLocalizations.of(context);

    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ReleaseHighlightIcon(
                        icon: highlight.icon,
                        iconAsset: highlight.iconAsset,
                      ),
                      const SizedBox(height: Spacing.md),
                      Text(
                        highlight.title,
                        textAlign: TextAlign.center,
                        style: theme.bodyLarge?.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (highlight.body.isNotEmpty) ...[
                        const SizedBox(height: Spacing.sm),
                        Text(
                          highlight.body,
                          textAlign: TextAlign.center,
                          style: theme.bodyMedium?.copyWith(
                            color: theme.textPrimary,
                            height: 1.42,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: TouchTarget.minimum,
          child: Row(
            children: [
              SizedBox(
                width: TouchTarget.minimum,
                child: pageIndex > 0
                    ? _CardChevron(
                        icon: Icons.chevron_left_rounded,
                        tooltip: localizations.previousPageTooltip,
                        onPressed: () => onPageSelected(pageIndex - 1),
                      )
                    : null,
              ),
              Expanded(
                child: _PageIndicator(
                  count: pageCount,
                  selectedIndex: pageIndex,
                  onSelected: onPageSelected,
                ),
              ),
              SizedBox(
                width: TouchTarget.minimum,
                child: pageIndex < pageCount - 1
                    ? _CardChevron(
                        icon: Icons.chevron_right_rounded,
                        tooltip: localizations.nextPageTooltip,
                        onPressed: () => onPageSelected(pageIndex + 1),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReleaseHighlightIcon extends StatelessWidget {
  const _ReleaseHighlightIcon({this.icon, this.iconAsset});

  final IconData? icon;
  final String? iconAsset;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final graphic = iconAsset != null
        ? ImageIcon(
            AssetImage(iconAsset!),
            size: IconSize.xl,
            color: theme.buttonPrimary,
          )
        : Icon(icon, size: IconSize.xl, color: theme.buttonPrimary);

    return SizedBox(width: 48, height: 48, child: Center(child: graphic));
  }
}

class _CardChevron extends StatelessWidget {
  const _CardChevron({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        button: true,
        child: AdaptiveButton.child(
          onPressed: onPressed,
          color: theme.textSecondary.withValues(alpha: 0.68),
          style: AdaptiveButtonStyle.plain,
          size: AdaptiveButtonSize.small,
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(AppBorderRadius.circular),
          minSize: const Size(TouchTarget.minimum, TouchTarget.minimum),
          useSmoothRectangleBorder: false,
          child: Icon(
            icon,
            size: IconSize.lg,
            color: theme.textSecondary.withValues(alpha: 0.68),
          ),
        ),
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  const _PageIndicator({
    required this.count,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int count;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          Semantics(
            label: '${i + 1}/$count',
            selected: i == selectedIndex,
            button: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelected(i),
              child: Padding(
                padding: const EdgeInsets.all(Spacing.xs),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  width: i == selectedIndex ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == selectedIndex
                        ? theme.buttonPrimary
                        : theme.textSecondary.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(AppBorderRadius.pill),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ReleaseSupportCard extends StatelessWidget {
  const _ReleaseSupportCard({
    required this.heading,
    required this.message,
    required this.reviewLabel,
    required this.supportLabel,
    required this.supportIcon,
    required this.reviewColor,
    required this.supportColor,
    required this.onReview,
    required this.onSupport,
  });

  final String heading;
  final String message;
  final String reviewLabel;
  final String supportLabel;
  final IconData supportIcon;
  final Color reviewColor;
  final Color supportColor;
  final VoidCallback onReview;
  final VoidCallback onSupport;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: theme.bodyMedium?.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Spacing.xxs),
          Text(
            message,
            style: theme.bodySmall?.copyWith(
              color: theme.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          _ReleaseActionButton(
            label: reviewLabel,
            icon: Icons.rate_review_rounded,
            accentColor: reviewColor,
            onPressed: onReview,
          ),
          const SizedBox(height: Spacing.xs),
          _ReleaseActionButton(
            label: supportLabel,
            icon: supportIcon,
            accentColor: supportColor,
            onPressed: onSupport,
          ),
        ],
      ),
    );
  }
}

class _ReleaseActionButton extends StatelessWidget {
  const _ReleaseActionButton({
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color accentColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Semantics(
      label: label,
      button: true,
      child: SizedBox(
        width: double.infinity,
        height: TouchTarget.minimum,
        child: AdaptiveButton.child(
          onPressed: onPressed,
          color: accentColor,
          style: AdaptiveButtonStyle.plain,
          size: AdaptiveButtonSize.small,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm + Spacing.xs,
          ),
          borderRadius: BorderRadius.circular(AppBorderRadius.button),
          minSize: const Size(0, TouchTarget.minimum),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: IconSize.sm, color: accentColor),
              const SizedBox(width: Spacing.sm),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.bodySmall?.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
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

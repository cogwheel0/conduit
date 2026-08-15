import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/theme_extensions.dart';

/// Opaque inset-grouped surface with optional section guidance.
class InsetGroupedSection extends StatelessWidget {
  const InsetGroupedSection({
    super.key,
    required this.child,
    this.title,
    this.description,
    this.footer,
    this.padding = const EdgeInsets.all(Spacing.md),
    this.flat = false,
    this.useNativeSurface = false,
  });

  final String? title;
  final String? description;
  final String? footer;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool flat;
  final bool useNativeSurface;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final hasTitle = title != null && title!.isNotEmpty;
    final hasDescription = description != null && description!.isNotEmpty;
    final hasFooter = footer != null && footer!.isNotEmpty;
    final nativeSurface =
        context.usesCupertinoChrome && (useNativeSurface || !flat);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasTitle)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Text(
              title!,
              style:
                  (nativeSurface
                          ? AppTypography.bodySmallStyle
                          : AppTypography.labelMediumStyle)
                      .copyWith(
                        color: theme.textSecondary,
                        fontWeight: nativeSurface
                            ? FontWeight.w400
                            : FontWeight.w600,
                      ),
            ),
          ),
        if (hasDescription) ...[
          const SizedBox(height: Spacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Text(
              description!,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textTertiary,
              ),
            ),
          ),
        ],
        if (hasTitle || hasDescription) const SizedBox(height: Spacing.sm),
        if (flat)
          Padding(
            padding: padding,
            child: Material(type: MaterialType.transparency, child: child),
          )
        else
          Container(
            clipBehavior: Clip.antiAlias,
            padding: padding,
            decoration: BoxDecoration(
              color: nativeSurface
                  ? CupertinoColors.secondarySystemGroupedBackground
                        .resolveFrom(context)
                  : theme.surfaceContainer.withValues(alpha: 0.68),
              borderRadius: BorderRadius.circular(
                nativeSurface ? AppBorderRadius.md : AppBorderRadius.card,
              ),
              border: nativeSurface
                  ? null
                  : Border.all(
                      color: theme.cardBorder,
                      width: BorderWidth.thin,
                    ),
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        if (hasFooter) ...[
          const SizedBox(height: Spacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Text(
              footer!,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textTertiary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A single grouped surface with quiet dividers between rows.
class InsetGroupedList extends StatelessWidget {
  const InsetGroupedList({
    super.key,
    required this.children,
    this.title,
    this.description,
    this.footer,
    this.dividerIndent = Spacing.md,
    this.useNativeSurface = false,
  });

  final List<Widget> children;
  final String? title;
  final String? description;
  final String? footer;
  final double dividerIndent;
  final bool useNativeSurface;

  @override
  Widget build(BuildContext context) {
    return InsetGroupedSection(
      title: title,
      description: description,
      footer: footer,
      useNativeSurface: useNativeSurface,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            children[index],
            if (index != children.length - 1)
              Divider(
                height: BorderWidth.thin,
                thickness: BorderWidth.thin,
                indent: dividerIndent,
                endIndent: dividerIndent,
                color: context.conduitTheme.dividerColor,
              ),
          ],
        ],
      ),
    );
  }
}

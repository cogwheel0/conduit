import 'package:material_ui/material_ui.dart';

import '../../theme/theme_extensions.dart';
import '../platform_ui/platform_ui.dart';

/// Corner radius of an iOS 26 inset-grouped list section, as UIKit draws
/// `UITableView.Style.insetGrouped` (measured on iOS 26: 26 pt, continuous
/// corners). Flutter grouped cards use it so they match the native settings
/// and picker sheets beside them.
const double kIOS26InsetGroupedRadius = 26;

/// Corner radius of inset-grouped sections before iOS 26, and of Flutter's
/// own grouped cards there.
const double kLegacyInsetGroupedRadius = AppBorderRadius.md;

/// The corner radius iOS uses for inset-grouped sections on this system.
double insetGroupedCornerRadius() => PlatformUiCapabilities.usesNativeIOS26
    ? kIOS26InsetGroupedRadius
    : kLegacyInsetGroupedRadius;

/// The side margins UIKit gives an inset-grouped list on an iPhone of
/// [screenWidth] points: 16 on regular phones, 20 from the 414 pt wide
/// (Plus and Max) phones up.
double iosInsetGroupedMargin(double screenWidth) =>
    screenWidth >= 414 ? Spacing.pagePadding : Spacing.screenPadding;

/// The shape of an iOS inset-grouped section: continuous (superellipse)
/// corners at [insetGroupedCornerRadius], as UIKit draws them.
RoundedSuperellipseBorder insetGroupedShape() => RoundedSuperellipseBorder(
  borderRadius: BorderRadius.circular(insetGroupedCornerRadius()),
);

/// iOS's list separator colour (`UIColor.separator`) on this system, as
/// UIKit draws it between inset-grouped rows. iOS 26 draws a softer line one
/// point thick (measured on iOS 26: light rgba(60, 60, 67, 0.12), dark
/// rgba(84, 84, 88, 0.5)); earlier systems a stronger one-pixel hairline.
Color iosSeparatorColor({required bool isDark}) =>
    PlatformUiCapabilities.usesNativeIOS26
    ? (isDark ? const Color(0x80545458) : const Color(0x1F3C3C43))
    : (isDark ? const Color(0x99545458) : const Color(0x4A3C3C43));

/// An iOS list separator between grouped rows: from [indent] (where the row
/// text starts) to the row's trailing margin on iOS 26, as UIKit insets it
/// there, or to the section's trailing edge before iOS 26. [endIndent]
/// overrides the trailing inset.
class InsetGroupedSeparator extends StatelessWidget {
  const InsetGroupedSeparator({
    super.key,
    this.indent = Spacing.md,
    this.endIndent,
  });

  final double indent;
  final double? endIndent;

  @override
  Widget build(BuildContext context) {
    final modern = PlatformUiCapabilities.usesNativeIOS26;
    final thickness = modern ? 1.0 : 1 / MediaQuery.devicePixelRatioOf(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: indent,
        end: endIndent ?? (modern ? Spacing.md : 0),
      ),
      child: SizedBox(
        height: thickness,
        width: double.infinity,
        child: ColoredBox(
          color: iosSeparatorColor(isDark: context.conduitTheme.isDark),
        ),
      ),
    );
  }
}

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
    this.color,
  });

  final String? title;
  final String? description;
  final String? footer;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool flat;
  final bool useNativeSurface;

  /// Card fill. Defaults to [ConduitThemeExtension.groupedSurface], which
  /// assumes the grouped page behind it; sections on the plain page pass
  /// [ConduitThemeExtension.groupedSurfaceOnPage].
  final Color? color;

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
            child: Semantics(
              header: true,
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
            // Palette-derived grouped card on both platforms: the lighter
            // palette surface on the darker grouped page, so sections lift
            // without borders (iOS inset-grouped, Material 3 filled cards).
            // On iOS the card takes the inset-grouped list's own corners, so
            // it matches the native sheets.
            decoration: nativeSurface
                ? ShapeDecoration(
                    color: color ?? theme.groupedSurface,
                    shape: insetGroupedShape(),
                  )
                : BoxDecoration(
                    color: color ?? theme.groupedSurface,
                    borderRadius: BorderRadius.circular(AppBorderRadius.card),
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
///
/// On iOS the dividers are the system's hairline separators: they start at
/// [dividerIndent] (where the row text starts) and run to the section's
/// trailing edge. Material keeps its inset dividers.
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
    final cupertino = context.usesCupertinoChrome;
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
              if (cupertino)
                InsetGroupedSeparator(indent: dividerIndent)
              else
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

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';

/// Inset-grouped form pieces for the iOS sign-in flow: the server address and
/// sign-in steps read like setting up an account in a first-party app.
///
/// Rows, headers and footers share one leading inset so their text lines up,
/// separators are hairlines that run to the card's trailing edge, and errors
/// take the footer's place under the group they belong to. Android keeps its
/// Material forms; these are built only where `usesCupertinoChrome` is true.

/// Leading inset of row text inside a grouped card. Headers and footers use
/// it too, so they line up with the rows.
const double authGroupedInset = Spacing.md;

/// Minimum height of one grouped row.
const double authGroupedRowHeight = 52;

/// Corner radius of a grouped card; the one the app's settings lists use.
const double authGroupedRadius = AppBorderRadius.md;

/// Section header style: footnote, secondary.
TextStyle authGroupedHeaderStyle(BuildContext context) =>
    AppTypography.bodySmallStyle.copyWith(
      color: context.conduitTheme.textSecondary,
    );

/// Section footer style: footnote, secondary.
TextStyle authGroupedFooterStyle(BuildContext context) =>
    AppTypography.bodySmallStyle.copyWith(
      color: context.conduitTheme.textSecondary,
    );

/// Row title style: body, primary.
TextStyle authGroupedRowStyle(BuildContext context) =>
    AppTypography.bodyLargeStyle.copyWith(
      color: context.conduitTheme.textPrimary,
    );

/// One inset-grouped section: an optional header, a card of rows with
/// hairline separators, and a footer, which [error] replaces while set.
class AuthGroupedSection extends StatelessWidget {
  const AuthGroupedSection({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.error,
    this.separatorInset = authGroupedInset,
  });

  final List<Widget> children;
  final String? header;
  final String? footer;

  /// Shown in the footer's place, in the error colour, and announced.
  final String? error;

  /// Where separators start, from the card's leading edge. Rows with a
  /// leading tile start them after it, as iOS lists do.
  final double separatorInset;

  @override
  Widget build(BuildContext context) {
    final header = this.header;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null && header.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              authGroupedInset,
              0,
              authGroupedInset,
              Spacing.sm - Spacing.xxs,
            ),
            child: Semantics(
              header: true,
              child: Text(header, style: authGroupedHeaderStyle(context)),
            ),
          ),
        if (children.isNotEmpty)
          AuthGroupedCard(
            separatorInset: separatorInset,
            children: children,
          ),
        AuthGroupedFooter(footer: footer, error: error),
      ],
    );
  }
}

/// The card of an [AuthGroupedSection], for callers that place their own
/// header or footer.
class AuthGroupedCard extends StatelessWidget {
  const AuthGroupedCard({
    super.key,
    required this.children,
    this.separatorInset = authGroupedInset,
  });

  final List<Widget> children;
  final double separatorInset;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.groupedSurface,
        borderRadius: BorderRadius.circular(authGroupedRadius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(authGroupedRadius),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                children[index],
                if (index != children.length - 1)
                  AuthGroupedSeparator(inset: separatorInset),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A one-pixel separator that starts at [inset] and runs to the trailing
/// edge.
class AuthGroupedSeparator extends StatelessWidget {
  const AuthGroupedSeparator({super.key, this.inset = authGroupedInset});

  final double inset;

  @override
  Widget build(BuildContext context) {
    final pixel = 1 / MediaQuery.devicePixelRatioOf(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: inset),
      child: SizedBox(
        height: pixel,
        child: ColoredBox(color: context.conduitTheme.dividerColor),
      ),
    );
  }
}

/// The footer under a grouped card: guidance, or an error in its place.
class AuthGroupedFooter extends StatelessWidget {
  const AuthGroupedFooter({super.key, this.footer, this.error});

  final String? footer;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final error = this.error;
    final footer = this.footer;
    final Widget content;
    if (error != null && error.isNotEmpty) {
      final style = authGroupedFooterStyle(context).copyWith(
        color: theme.error,
      );
      content = Semantics(
        key: const ValueKey<String>('auth-footer-error'),
        liveRegion: true,
        label: error,
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              authGroupedInset,
              Spacing.sm - Spacing.xxs,
              authGroupedInset,
              0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  // Centres the glyph on the first line of footnote text.
                  padding: const EdgeInsets.only(top: 1.5),
                  child: Icon(
                    CupertinoIcons.exclamationmark_circle_fill,
                    size: 15,
                    color: theme.error,
                  ),
                ),
                const SizedBox(width: Spacing.xs + Spacing.xxs),
                Expanded(child: Text(error, style: style)),
              ],
            ),
          ),
        ),
      );
    } else if (footer != null && footer.isNotEmpty) {
      content = Padding(
        key: ValueKey<String>('auth-footer:$footer'),
        padding: const EdgeInsetsDirectional.fromSTEB(
          authGroupedInset,
          Spacing.sm - Spacing.xxs,
          authGroupedInset,
          0,
        ),
        child: Text(footer, style: authGroupedFooterStyle(context)),
      );
    } else {
      content = const SizedBox.shrink(key: ValueKey<String>('auth-footer'));
    }
    return AnimatedSwitcher(
      duration: context.motionDuration(AnimationDuration.fast),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.topStart,
        children: [...previous, ?current],
      ),
      child: content,
    );
  }
}

/// A borderless text field filling one grouped row. The placeholder names
/// the field; there is no label above it.
class AuthGroupedTextField extends StatelessWidget {
  const AuthGroupedTextField({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.semanticLabel,
    this.focusNode,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.validator,
    this.obscureText = false,
    this.autocorrect = false,
    this.autofocus = false,
    this.readOnly = false,
    this.enabled = true,
    this.autofillHints,
    this.trailing,
  });

  final TextEditingController controller;
  final String placeholder;
  final String semanticLabel;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;
  final bool obscureText;
  final bool autocorrect;
  final bool autofocus;
  final bool readOnly;
  final bool enabled;
  final Iterable<String>? autofillHints;

  /// A control at the row's end, such as Show Password.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final trailing = this.trailing;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: authGroupedRowHeight),
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: authGroupedInset,
          end: trailing == null ? authGroupedInset : Spacing.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                label: semanticLabel,
                textField: true,
                child: AdaptiveTextFormField(
                  controller: controller,
                  focusNode: focusNode,
                  placeholder: placeholder,
                  keyboardType: keyboardType,
                  textInputAction: textInputAction,
                  onSubmitted: onSubmitted,
                  onChanged: onChanged,
                  validator: validator == null
                      ? null
                      : (value) => validator!(value ?? controller.text),
                  obscureText: obscureText,
                  autocorrect: autocorrect,
                  autofocus: autofocus,
                  readOnly: readOnly,
                  enabled: enabled,
                  autofillHints: autofillHints,
                  style: authGroupedRowStyle(context),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  cupertinoDecoration: const BoxDecoration(
                    color: Colors.transparent,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// A tappable grouped row with press highlight: navigation, disclosure, or
/// an action.
class AuthGroupedRow extends StatefulWidget {
  const AuthGroupedRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.leading,
    this.trailing,
    this.onTap,
    this.showChevron = false,
    this.expanded,
    this.titleColor,
    this.semanticLabel,
    this.subtitleMaxLines = 3,
    this.verticalPadding = 11,
  });

  final String title;
  final String? subtitle;

  /// Secondary text at the trailing edge, as in iOS Settings.
  final String? value;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Shows a forward chevron (navigation).
  final bool showChevron;

  /// Shows a disclosure chevron that turns down while expanded.
  final bool? expanded;
  final Color? titleColor;
  final String? semanticLabel;
  final int subtitleMaxLines;
  final double verticalPadding;

  @override
  State<AuthGroupedRow> createState() => _AuthGroupedRowState();
}

class _AuthGroupedRowState extends State<AuthGroupedRow> {
  bool _pressed = false;

  bool get _interactive => widget.onTap != null;

  void _setPressed(bool value) {
    if (!_interactive || _pressed == value) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    if (!_interactive) return;
    ConduitHaptics.selectionClick();
    widget.onTap!();
  }

  /// One line on regular text sizes. At accessibility sizes the value and
  /// trailing control move under the text, as iOS reflows its rows, so a
  /// long label never pushes them off the row.
  Widget _layout(
    BuildContext context, {
    required Widget? leading,
    required Widget texts,
    required Widget? value,
    required Widget? trailing,
    required Widget? chevron,
    required bool stacked,
  }) {
    final lead = <Widget>[
      ?leading,
      if (leading != null) const SizedBox(width: Spacing.sm + Spacing.xs),
    ];
    final end = <Widget>[
      if (chevron != null) ...[
        const SizedBox(width: Spacing.sm + Spacing.xxs),
        chevron,
      ],
    ];
    if (stacked && (value != null || trailing != null)) {
      return Row(
        children: [
          ...lead,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                texts,
                if (value != null) ...[
                  const SizedBox(height: Spacing.xxs),
                  value,
                ],
                ?trailing,
              ],
            ),
          ),
          ...end,
        ],
      );
    }
    return Row(
      children: [
        ...lead,
        Expanded(child: texts),
        if (value != null) ...[
          const SizedBox(width: Spacing.sm),
          Flexible(child: value),
        ],
        if (trailing != null) ...[
          const SizedBox(width: Spacing.sm),
          trailing,
        ],
        ...end,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final usesLargeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final subtitle = widget.subtitle;
    final value = widget.value;
    final leading = widget.leading;
    final trailing = widget.trailing;
    final expanded = widget.expanded;
    final label =
        widget.semanticLabel ??
        [
          widget.title,
          if (subtitle != null && subtitle.isNotEmpty) subtitle,
          if (value != null && value.isNotEmpty) value,
        ].join('. ');

    return Semantics(
      button: _interactive,
      expanded: expanded,
      label: label,
      onTap: _interactive ? _handleTap : null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _interactive ? (_) => _setPressed(true) : null,
        onTapUp: _interactive ? (_) => _setPressed(false) : null,
        onTapCancel: _interactive ? () => _setPressed(false) : null,
        onTap: _interactive ? _handleTap : null,
        child: AnimatedContainer(
          duration: _pressed
              ? Duration.zero
              : context.motionDuration(AnimationDuration.fast),
          curve: Curves.easeOut,
          color: _pressed
              ? theme.textPrimary.withValues(alpha: theme.isDark ? 0.12 : 0.08)
              : theme.textPrimary.withValues(alpha: 0),
          constraints: const BoxConstraints(minHeight: authGroupedRowHeight),
          padding: EdgeInsetsDirectional.fromSTEB(
            authGroupedInset,
            widget.verticalPadding,
            authGroupedInset,
            widget.verticalPadding,
          ),
          child: _layout(
            context,
            leading: leading,
            texts: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: usesLargeText ? null : 2,
                  overflow: usesLargeText
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                  style: authGroupedRowStyle(context).copyWith(
                    color: widget.titleColor,
                  ),
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    subtitle,
                    maxLines: usesLargeText ? null : widget.subtitleMaxLines,
                    overflow: usesLargeText
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: AppTypography.titleMediumStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
            value: value == null || value.isEmpty
                ? null
                : Text(
                    value,
                    maxLines: usesLargeText ? null : 1,
                    overflow: usesLargeText
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    textAlign: usesLargeText
                        ? TextAlign.start
                        : TextAlign.end,
                    style: authGroupedRowStyle(context).copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
            trailing: trailing,
            chevron: widget.showChevron || expanded != null
                ? AuthChevron(turnedDown: expanded ?? false)
                : null,
            stacked: usesLargeText,
          ),
        ),
      ),
    );
  }
}

/// A grouped row with a switch, announced as one toggle.
class AuthGroupedSwitchRow extends StatelessWidget {
  const AuthGroupedSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return MergeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: authGroupedRowHeight),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            authGroupedInset,
            Spacing.sm,
            authGroupedInset - Spacing.xxs,
            Spacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(title, style: authGroupedRowStyle(context)),
              ),
              const SizedBox(width: Spacing.sm),
              AdaptiveSwitch(
                value: value,
                semanticLabel: title,
                onChanged: onChanged,
                activeColor: theme.buttonPrimary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The list chevron: tertiary, semibold, 13pt tall. [turnedDown] points it
/// down for an expanded disclosure row.
class AuthChevron extends StatelessWidget {
  const AuthChevron({super.key, this.turnedDown = false});

  final bool turnedDown;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return ExcludeSemantics(
      child: AnimatedRotation(
        turns: turnedDown ? (rtl ? -0.25 : 0.25) : 0,
        duration: context.motionDuration(AnimationDuration.fast),
        curve: Curves.easeOutCubic,
        child: CustomPaint(
          size: const Size(8, 14),
          painter: _ChevronPainter(
            color: context.conduitTheme.textTertiary,
            pointsLeft: rtl,
          ),
        ),
      ),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter({required this.color, required this.pointsLeft});

  final Color color;
  final bool pointsLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    const inset = 1.5;
    final tipX = pointsLeft ? inset : size.width - inset;
    final tailX = pointsLeft ? size.width - inset : inset;
    final path = Path()
      ..moveTo(tailX, inset)
      ..lineTo(tipX, size.height / 2)
      ..lineTo(tailX, size.height - inset);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.pointsLeft != pointsLeft;
}

/// A rounded-square tile behind a row's glyph or brand mark. Every tile in a
/// list shares its size, fill and glyph colour.
class AuthIconTile extends StatelessWidget {
  const AuthIconTile({
    super.key,
    this.icon,
    this.assetName,
    this.assetSize,
    this.size = 40,
  }) : assert((icon == null) != (assetName == null));

  final IconData? icon;

  /// A one-colour mark whose alpha is the shape; drawn in the glyph colour.
  final String? assetName;
  final double? assetSize;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final glyphColor = theme.textPrimary;
    final glyphSize = size * 0.55;
    final Widget glyph;
    if (icon case final icon?) {
      // A hairline outline of the glyph in its own colour gives the thin
      // Cupertino outlines the medium weight of the brand marks beside them.
      const offset = 0.35;
      glyph = Icon(
        icon,
        size: glyphSize,
        color: glyphColor,
        shadows: [
          Shadow(color: glyphColor, offset: const Offset(-offset, 0)),
          Shadow(color: glyphColor, offset: const Offset(offset, 0)),
          Shadow(color: glyphColor, offset: const Offset(0, -offset)),
          Shadow(color: glyphColor, offset: const Offset(0, offset)),
        ],
      );
    } else {
      glyph = Image.asset(
        assetName!,
        width: assetSize ?? glyphSize,
        height: assetSize ?? glyphSize,
        fit: BoxFit.contain,
        color: glyphColor,
        colorBlendMode: BlendMode.srcIn,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      );
    }
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: theme.textPrimary.withValues(alpha: theme.isDark ? 0.12 : 0.06),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(size * 0.24),
          ),
        ),
        child: glyph,
      ),
    );
  }
}

/// The step's primary action, pinned under the form.
///
/// Disabled, it is a quiet neutral fill with a dimmed label, not a tinted
/// one; busy, it keeps its width and reads "[busyLabel]…".
class AuthPrimaryButton extends StatelessWidget {
  const AuthPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.busyLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final String? busyLabel;

  /// [text] ending in one ellipsis character, whatever the locale's string
  /// ended with.
  static String withEllipsis(String text) =>
      '${text.trim().replaceFirst(RegExp(r'(\.\.\.|…)$'), '')}…';

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final enabled = onPressed != null && !busy;
    // Busy keeps the filled look -- the action is under way, not
    // unavailable -- and only stops further taps.
    final filled = enabled || busy;
    final text = busy ? withEllipsis(busyLabel ?? label) : label;
    final foreground = filled
        ? theme.buttonPrimaryText
        : theme.textPrimary.withValues(alpha: theme.isDark ? 0.4 : 0.32);
    final background = filled
        ? theme.buttonPrimary
        : theme.textPrimary.withValues(alpha: theme.isDark ? 0.14 : 0.08);
    const height = 50.0;
    final labelStyle = AppTypography.bodyLargeStyle.copyWith(
      fontWeight: FontWeight.w600,
      color: foreground,
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: text,
      onTap: enabled ? onPressed : null,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) => SizedBox(
          width: double.infinity,
          height: height,
          child: AdaptiveButton(
            onPressed: enabled ? onPressed : (busy ? () {} : null),
            enabled: filled,
            label: text,
            color: background,
            textColor: foreground,
            labelStyle: labelStyle,
            style: PlatformUiCapabilities.usesNativeIOS26
                ? (filled
                      ? AdaptiveButtonStyle.prominentGlass
                      : AdaptiveButtonStyle.glass)
                : AdaptiveButtonStyle.filled,
            size: AdaptiveButtonSize.large,
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            borderRadius: BorderRadius.circular(height / 2),
            minSize: Size(
              constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
              height,
            ),
          ),
        ),
      ),
    );
  }
}

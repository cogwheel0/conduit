import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/chat_action_button.dart' show NativeSymbolGlyph;
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/utility_components.dart';

/// Inset-grouped form pieces for the iOS sign-in flow: the server address and
/// sign-in steps read like setting up an account in a first-party app.
///
/// Cards take the corners of UIKit's inset-grouped lists, so these forms match
/// the native settings sheets. Rows, headers and footers share one leading
/// inset so their text lines up, separators are the system hairline from the
/// row text to the card's trailing edge, and errors take the footer's place
/// under the group they belong to. A text field names itself with a leading
/// label in its row, as iOS account forms do, so its name stays in view once
/// it is filled. Android keeps its Material forms; these are built only where
/// `usesCupertinoChrome` is true.

/// Leading inset of row text inside a grouped card. Headers and footers use
/// it too, so they line up with the rows.
const double authGroupedInset = Spacing.md;

/// Minimum height of one grouped row.
const double authGroupedRowHeight = 52;

/// Space between a field's leading label and its text.
const double authGroupedLabelGap = Spacing.md;

/// The widest share of a row a leading label may take; a longer label wraps.
const double authGroupedLabelMaxShare = 0.42;

/// Section header style: footnote, secondary.
TextStyle authGroupedHeaderStyle(BuildContext context) => AppTypography
    .bodySmallStyle
    .copyWith(color: context.conduitTheme.textSecondary);

/// Section footer style: footnote, secondary.
TextStyle authGroupedFooterStyle(BuildContext context) => AppTypography
    .bodySmallStyle
    .copyWith(color: context.conduitTheme.textSecondary);

/// Row title style: body, primary.
TextStyle authGroupedRowStyle(BuildContext context) => AppTypography
    .bodyLargeStyle
    .copyWith(color: context.conduitTheme.textPrimary);

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
          AuthGroupedCard(separatorInset: separatorInset, children: children),
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
    final shape = insetGroupedShape();
    final labels = [
      for (final child in children)
        if (child is AuthGroupedTextField && child.label != null) child.label!,
    ];
    Widget rows = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < children.length; index++) ...[
          children[index],
          if (index != children.length - 1)
            AuthGroupedSeparator(inset: separatorInset),
        ],
      ],
    );
    if (labels.isNotEmpty) {
      // Every labelled field in the card starts its text on one line: the
      // widest label's, up to a share of the card, past which labels wrap.
      final measured = measureAuthGroupedLabels(context, labels);
      final column = rows;
      rows = LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth - authGroupedInset * 2;
          final cap = available.isFinite
              ? available * authGroupedLabelMaxShare
              : measured;
          return AuthGroupedLabelColumn(
            width: measured < cap ? measured : cap,
            child: column,
          );
        },
      );
    }
    return DecoratedBox(
      decoration: ShapeDecoration(color: theme.groupedSurface, shape: shape),
      child: ClipRSuperellipse(
        borderRadius: shape.borderRadius.resolve(Directionality.of(context)),
        child: AdaptiveTransparentLayer(child: rows),
      ),
    );
  }
}

/// The width of the widest of [labels] in the row title style, at the
/// current text size.
double measureAuthGroupedLabels(BuildContext context, List<String> labels) {
  final style = authGroupedRowStyle(context);
  final scaler = MediaQuery.textScalerOf(context);
  var widest = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
  }
  return widest.ceilToDouble();
}

/// The shared width of the leading labels in one grouped card, so the
/// fields' text lines up under one another, as in an iOS account form.
class AuthGroupedLabelColumn extends InheritedWidget {
  const AuthGroupedLabelColumn({
    super.key,
    required this.width,
    required super.child,
  });

  final double width;

  static double? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AuthGroupedLabelColumn>()
      ?.width;

  @override
  bool updateShouldNotify(AuthGroupedLabelColumn oldWidget) =>
      oldWidget.width != width;
}

/// The system list separator between grouped rows, starting at [inset],
/// as [InsetGroupedSeparator] draws it.
class AuthGroupedSeparator extends StatelessWidget {
  const AuthGroupedSeparator({super.key, this.inset = authGroupedInset});

  final double inset;

  @override
  Widget build(BuildContext context) => InsetGroupedSeparator(indent: inset);
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
      final style = authGroupedFooterStyle(context)
          .copyWith(color: theme.error);
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

/// A borderless text field filling one grouped row.
///
/// With a [label], the row reads as an iOS account form's does: the field's
/// name at the leading edge, in the row title style, and the field after it,
/// so the name stays in view once the field is filled. Labels in one card
/// share a column. At accessibility text sizes the label moves above the
/// field. Without a label the placeholder names the field.
class AuthGroupedTextField extends StatefulWidget {
  const AuthGroupedTextField({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.semanticLabel,
    this.label,
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

  /// The field's visible name at the row's leading edge.
  final String? label;
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
  State<AuthGroupedTextField> createState() => _AuthGroupedTextFieldState();
}

class _AuthGroupedTextFieldState extends State<AuthGroupedTextField> {
  FocusNode? _ownFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode());

  @override
  void dispose() {
    _ownFocusNode?.dispose();
    super.dispose();
  }

  Widget _buildField(BuildContext context) {
    final validator = widget.validator;
    return Semantics(
      label: widget.semanticLabel,
      textField: true,
      child: AdaptiveTextFormField(
        controller: widget.controller,
        focusNode: _focusNode,
        placeholder: widget.placeholder,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        onSubmitted: widget.onSubmitted,
        onChanged: widget.onChanged,
        validator: validator == null
            ? null
            : (value) => validator(value ?? widget.controller.text),
        obscureText: widget.obscureText,
        autocorrect: widget.autocorrect,
        autofocus: widget.autofocus,
        readOnly: widget.readOnly,
        enabled: widget.enabled,
        autofillHints: widget.autofillHints,
        style: authGroupedRowStyle(context),
        padding: const EdgeInsets.symmetric(vertical: 15),
        cupertinoDecoration: const BoxDecoration(color: Color(0x00000000)),
        decoration: const InputDecoration(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  /// The label, which focuses its field when tapped, as tapping anywhere in
  /// an iOS form row does. Assistive tech hears the field's own label.
  Widget _buildLabel(BuildContext context, String label) {
    return ExcludeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? _focusNode.requestFocus : null,
        child: Text(
          label,
          key: ValueKey<String>('auth-field-label:$label'),
          maxLines: 2,
          style: authGroupedRowStyle(context),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trailing = widget.trailing;
    final label = widget.label;
    final field = _buildField(context);
    final Widget content;
    if (label == null || label.isEmpty) {
      content = field;
    } else if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Spacing.sm),
            child: _buildLabel(context, label),
          ),
          field,
        ],
      );
    } else {
      final shared = AuthGroupedLabelColumn.maybeOf(context);
      final labelWidth = shared ?? measureAuthGroupedLabels(context, [label]);
      final row = Row(
        children: [
          SizedBox(width: labelWidth, child: _buildLabel(context, label)),
          const SizedBox(width: authGroupedLabelGap),
          Expanded(child: field),
        ],
      );
      // Inside a card the column is already capped; a lone field caps its
      // own label so a long one wraps rather than squeezing the field.
      content = shared != null
          ? row
          : LayoutBuilder(
              builder: (context, constraints) {
                final cap = constraints.maxWidth * authGroupedLabelMaxShare;
                if (!constraints.maxWidth.isFinite || labelWidth <= cap) {
                  return row;
                }
                return Row(
                  children: [
                    SizedBox(width: cap, child: _buildLabel(context, label)),
                    const SizedBox(width: authGroupedLabelGap),
                    Expanded(child: field),
                  ],
                );
              },
            );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: authGroupedRowHeight),
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: authGroupedInset,
          end: trailing == null ? authGroupedInset : Spacing.xs,
        ),
        child: Row(
          children: [
            Expanded(child: content),
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
      if (leading != null) ExcludeSemantics(child: leading),
      if (leading != null) const SizedBox(width: Spacing.sm + Spacing.xs),
    ];
    texts = ExcludeSemantics(child: texts);
    if (value != null) value = ExcludeSemantics(child: value);
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
    if (value != null) {
      // The title keeps its natural width, up to a little over half the
      // row, and the value takes the rest at the trailing edge, as in iOS
      // Settings.
      final valueText = value;
      return LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            ...lead,
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.55,
              ),
              child: texts,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: valueText,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Spacing.sm),
              trailing,
            ],
            ...end,
          ],
        ),
      );
    }
    return Row(
      children: [
        ...lead,
        Expanded(child: texts),
        if (trailing != null) ...[const SizedBox(width: Spacing.sm), trailing],
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

    // The row reads as one element; an interactive trailing control, such
    // as Change or Remove, stays reachable as its own.
    return Semantics(
      container: true,
      button: _interactive,
      expanded: expanded,
      label: label,
      onTap: _interactive ? _handleTap : null,
      excludeSemantics: trailing == null,
      explicitChildNodes: trailing != null,
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
                  style: authGroupedRowStyle(context)
                      .copyWith(color: widget.titleColor),
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
                    textAlign: usesLargeText ? TextAlign.start : TextAlign.end,
                    style: authGroupedRowStyle(context)
                        .copyWith(color: theme.textSecondary),
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
              Expanded(child: Text(title, style: authGroupedRowStyle(context))),
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
          color: theme.textPrimary.withValues(
            alpha: theme.isDark ? 0.12 : 0.06,
          ),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(size * 0.24),
          ),
        ),
        child: glyph,
      ),
    );
  }
}

/// A plain button at the end of a grouped row, such as Change on the
/// server row, in the manner of a bar button: the label alone, semibold in
/// the button colour, dimmed while pressed. The weight says it acts; without
/// a fill or capsule it stays quieter than the step's primary action.
class AuthRowTextButton extends StatelessWidget {
  const AuthRowTextButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return AuthPlainRowButton(
      semanticLabel: label,
      onPressed: onPressed,
      // The target reaches past the label towards the row's text, so a tap
      // just short of the word still lands; the label itself ends on the
      // row's margin.
      padding: const EdgeInsetsDirectional.only(start: Spacing.sm),
      child: Text(
        label,
        style: authGroupedRowStyle(context).copyWith(
          color: context.conduitTheme.buttonPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The show/hide control at the end of a password field: the SF Symbol eye
/// at body size in the secondary tone, as iOS draws an accessory in a text
/// field, slashed while the text is hidden. Where symbols cannot be drawn
/// the Cupertino eye stands in.
class AuthPasswordVisibilityButton extends StatelessWidget {
  const AuthPasswordVisibilityButton({
    super.key,
    required this.obscured,
    required this.label,
    required this.onPressed,
  });

  /// Whether the field hides its text, so the control offers to show it.
  final bool obscured;
  final String label;
  final VoidCallback onPressed;

  /// Body size, the size of the field's text.
  static const double _symbolSize = 17;

  @override
  Widget build(BuildContext context) {
    final color = context.conduitTheme.textSecondary;
    final fallback = obscured ? CupertinoIcons.eye_slash : CupertinoIcons.eye;
    final glyph = NativeSymbolGlyph.isAvailable
        ? NativeSymbolGlyph(
            symbol: obscured ? 'eye.slash' : 'eye',
            fallbackIcon: fallback,
            pointSize: _symbolSize,
            color: color,
          )
        : Icon(fallback, size: IconSize.md, color: color);
    return AuthPlainRowButton(
      semanticLabel: label,
      onPressed: onPressed,
      child: SizedBox.square(
        dimension: TouchTarget.minimum,
        child: Center(child: glyph),
      ),
    );
  }
}

/// A row accessory that acts on a tap: no fill, at least a touch target
/// tall, dimmed at once under the finger and eased back on release.
class AuthPlainRowButton extends StatefulWidget {
  const AuthPlainRowButton({
    super.key,
    required this.semanticLabel,
    required this.onPressed,
    required this.child,
    this.padding = EdgeInsetsDirectional.zero,
  });

  final String semanticLabel;
  final VoidCallback? onPressed;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  State<AuthPlainRowButton> createState() => _AuthPlainRowButtonState();
}

class _AuthPlainRowButtonState extends State<AuthPlainRowButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.onPressed;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: onPressed == null
            ? null
            : () {
                ConduitHaptics.selectionClick();
                onPressed();
              },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TouchTarget.minimum),
          child: Padding(
            padding: widget.padding,
            child: Center(
              widthFactor: 1,
              child: AnimatedOpacity(
                opacity: !enabled || _pressed ? 0.35 : 1,
                duration: _pressed
                    ? Duration.zero
                    : context.motionDuration(AnimationDuration.fast),
                curve: Curves.easeOut,
                child: widget.child,
              ),
            ),
          ),
        ),
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
    // Unavailable, the label drops to the secondary tone rather than fading
    // out: the control still reads as the step's button, only not yet ready.
    final foreground = filled ? theme.buttonPrimaryText : theme.textSecondary;
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

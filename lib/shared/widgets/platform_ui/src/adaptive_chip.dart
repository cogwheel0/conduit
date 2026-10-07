import 'package:material_ui/material_ui.dart';

enum AdaptiveChipStyle { action, choice, filter, input }

/// Selection belongs to the caller; deletion is a separate action.
class AdaptiveChip extends StatelessWidget {
  const AdaptiveChip.action({
    super.key,
    required this.label,
    required this.onPressed,
    this.enabled = true,
    this.semanticLabel,
    this.avatar,
    this.backgroundColor,
    this.labelStyle,
    this.padding,
    this.side,
    this.shape,
    this.visualDensity,
    this.materialTapTargetSize,
  }) : style = AdaptiveChipStyle.action,
       selected = false,
       onSelected = null,
       onDeleted = null,
       selectedColor = null,
       showCheckmark = false,
       deleteButtonTooltipMessage = null;

  const AdaptiveChip.choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    this.semanticLabel,
    this.avatar,
    this.selectedColor,
    this.backgroundColor,
    this.labelStyle,
    this.padding,
    this.showCheckmark,
    this.side,
    this.shape,
    this.visualDensity,
    this.materialTapTargetSize,
  }) : onPressed = null,
       style = AdaptiveChipStyle.choice,
       onDeleted = null,
       deleteButtonTooltipMessage = null;
  const AdaptiveChip.filter({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    this.semanticLabel,
    this.avatar,
    this.selectedColor,
    this.backgroundColor,
    this.labelStyle,
    this.padding,
    this.showCheckmark,
    this.side,
    this.shape,
    this.visualDensity,
    this.materialTapTargetSize,
  }) : onPressed = null,
       style = AdaptiveChipStyle.filter,
       onDeleted = null,
       deleteButtonTooltipMessage = null;
  const AdaptiveChip.input({
    super.key,
    required this.label,
    this.selected = false,
    this.onSelected,
    this.onDeleted,
    this.enabled = true,
    this.semanticLabel,
    this.avatar,
    this.selectedColor,
    this.backgroundColor,
    this.labelStyle,
    this.padding,
    this.showCheckmark,
    this.side,
    this.shape,
    this.visualDensity,
    this.materialTapTargetSize,
    this.deleteButtonTooltipMessage,
  }) : onPressed = null,
       style = AdaptiveChipStyle.input;

  final AdaptiveChipStyle style;
  final Widget label;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool>? onSelected;
  final VoidCallback? onDeleted;
  final String? semanticLabel;
  final String? deleteButtonTooltipMessage;
  final Widget? avatar;
  final Color? selectedColor;
  final Color? backgroundColor;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? padding;
  final bool? showCheckmark;
  final VoidCallback? onPressed;
  final BorderSide? side;
  final OutlinedBorder? shape;
  final VisualDensity? visualDensity;
  final MaterialTapTargetSize? materialTapTargetSize;

  @override
  Widget build(BuildContext context) {
    final callback = enabled ? onSelected : null;
    final chipLabel = semanticLabel == null
        ? label
        : Semantics(label: semanticLabel, excludeSemantics: true, child: label);
    final chip = switch (style) {
      AdaptiveChipStyle.action => ActionChip(
        label: chipLabel,
        avatar: avatar,
        onPressed: enabled ? onPressed : null,
        backgroundColor: backgroundColor,
        labelStyle: labelStyle,
        padding: padding,
        side: side,
        shape: shape,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
      ),
      AdaptiveChipStyle.choice => ChoiceChip(
        label: chipLabel,
        selected: selected,
        onSelected: callback,
        avatar: avatar,
        selectedColor: selectedColor,
        backgroundColor: backgroundColor,
        labelStyle: labelStyle,
        padding: padding,
        showCheckmark: showCheckmark,
        side: side,
        shape: shape,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
      ),
      AdaptiveChipStyle.filter => FilterChip(
        label: chipLabel,
        selected: selected,
        onSelected: callback,
        avatar: avatar,
        selectedColor: selectedColor,
        backgroundColor: backgroundColor,
        labelStyle: labelStyle,
        padding: padding,
        showCheckmark: showCheckmark,
        side: side,
        shape: shape,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
      ),
      AdaptiveChipStyle.input => InputChip(
        label: chipLabel,
        selected: selected,
        onSelected: callback,
        avatar: avatar,
        isEnabled: enabled,
        onDeleted: enabled ? onDeleted : null,
        deleteButtonTooltipMessage: deleteButtonTooltipMessage,
        selectedColor: selectedColor,
        backgroundColor: backgroundColor,
        labelStyle: labelStyle,
        padding: padding,
        showCheckmark: showCheckmark,
        side: side,
        shape: shape,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
      ),
    };
    return chip;
  }
}

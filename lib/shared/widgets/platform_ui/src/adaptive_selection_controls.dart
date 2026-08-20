import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/services/haptic_service.dart';
import 'adaptive_controls.dart';
import 'platform_ui_capabilities.dart';

class AdaptiveSwitch extends StatelessWidget {
  const AdaptiveSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.thumbColor,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final Color? thumbColor;

  @override
  Widget build(BuildContext context) {
    final effectiveOnChanged = onChanged == null
        ? null
        : PlatformUiCapabilities.isIOS
        ? onChanged
        : (bool next) {
            ConduitHaptics.selectionClick();
            onChanged!(next);
          };
    if (PlatformUiCapabilities.isIOS) {
      final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
      return SizedBox(
        key: const ValueKey<String>('adaptive-switch-frame'),
        width: 51,
        height: 31,
        child: FittedBox(
          fit: BoxFit.fill,
          child: CupertinoSwitch(
            value: value,
            onChanged: effectiveOnChanged,
            activeTrackColor: activeColor ?? CupertinoColors.activeGreen,
            inactiveTrackColor: isDark
                ? const Color(0xFF39393D)
                : const Color(0xFFE5E5EA),
            thumbColor: thumbColor ?? CupertinoColors.white,
          ),
        ),
      );
    }
    return Switch(
      value: value,
      onChanged: effectiveOnChanged,
      thumbColor: thumbColor == null
          ? null
          : WidgetStatePropertyAll<Color?>(thumbColor),
      trackColor: activeColor == null
          ? null
          : WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.selected) ? activeColor : null;
            }),
    );
  }
}

class AdaptiveSlider extends StatefulWidget {
  const AdaptiveSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.activeColor,
    this.thumbColor,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final Color? activeColor;
  final Color? thumbColor;

  @override
  State<AdaptiveSlider> createState() => _AdaptiveSliderState();
}

class _AdaptiveSliderState extends State<AdaptiveSlider> {
  int? _lastHapticStep;

  @override
  void initState() {
    super.initState();
    _lastHapticStep = _stepFor(widget.value);
  }

  @override
  void didUpdateWidget(covariant AdaptiveSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    _lastHapticStep = _stepFor(widget.value);
  }

  int? _stepFor(double value) {
    final divisions = widget.divisions;
    if (divisions == null || divisions <= 0 || widget.max <= widget.min) {
      return null;
    }
    return (((value - widget.min) / (widget.max - widget.min)) * divisions)
        .round()
        .clamp(0, divisions);
  }

  void _handleChanged(double value) {
    final step = _stepFor(value);
    final systemProvidesEdgeHaptic =
        PlatformUiCapabilities.isIOS && (step == 0 || step == widget.divisions);
    if (step != null && step != _lastHapticStep && !systemProvidesEdgeHaptic) {
      _lastHapticStep = step;
      ConduitHaptics.selectionClick();
    } else if (step != null) {
      _lastHapticStep = step;
    }
    widget.onChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    if (PlatformUiCapabilities.usesNativeIOS26 &&
        widget.onChangeStart == null &&
        widget.onChangeEnd == null) {
      return CNSlider(
        value: widget.value.clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        enabled: widget.onChanged != null,
        onChanged: widget.onChanged == null ? (_) {} : _handleChanged,
        trackColor: widget.activeColor,
        thumbColor: widget.thumbColor,
        step: widget.divisions == null || widget.divisions == 0
            ? null
            : (widget.max - widget.min) / widget.divisions!,
      );
    }
    if (PlatformUiCapabilities.isIOS) {
      return CupertinoSlider(
        value: widget.value.clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        onChanged: widget.onChanged == null ? null : _handleChanged,
        onChangeStart: widget.onChangeStart,
        onChangeEnd: widget.onChangeEnd,
        activeColor: widget.activeColor,
        thumbColor: widget.thumbColor ?? CupertinoColors.white,
        divisions: widget.divisions,
      );
    }
    return Slider(
      value: widget.value.clamp(widget.min, widget.max),
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      label: widget.label,
      onChanged: widget.onChanged == null ? null : _handleChanged,
      onChangeStart: widget.onChangeStart,
      onChangeEnd: widget.onChangeEnd,
      activeColor: widget.activeColor,
      thumbColor: widget.thumbColor,
    );
  }
}

class AdaptiveSegmentedControl extends StatelessWidget {
  const AdaptiveSegmentedControl({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onValueChanged,
    this.enabled = true,
    this.color,
    this.height = 36,
    this.shrinkWrap = false,
    this.sfSymbols,
    this.iconSize,
    this.iconColor,
    this.textColor,
    this.selectedTextColor,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onValueChanged;
  final bool enabled;
  final Color? color;
  final double height;
  final bool shrinkWrap;
  final List<dynamic>? sfSymbols;
  final double? iconSize;
  final Color? iconColor;
  final Color? textColor;
  final Color? selectedTextColor;

  @override
  Widget build(BuildContext context) {
    void handleSelection(int index, {bool systemProvidesHaptic = false}) {
      if (!enabled || index == selectedIndex) return;
      if (!systemProvidesHaptic) ConduitHaptics.selectionClick();
      onValueChanged(index);
    }

    IconData? fallbackIcon(dynamic icon) => switch (icon) {
      final IconData value => value,
      final String symbol => cupertinoIconForSFSymbol(symbol),
      _ => null,
    };

    final nativeSymbols = sfSymbols?.map<CNSymbol?>((symbol) {
      if (symbol is String) {
        return CNSymbol(symbol, size: iconSize ?? 20, color: iconColor);
      }
      return null;
    }).toList();
    final nativeCompatible =
        textColor == null &&
        selectedTextColor == null &&
        (nativeSymbols == null ||
            (nativeSymbols.length == labels.length &&
                nativeSymbols.every((symbol) => symbol != null)));
    if (PlatformUiCapabilities.usesNativeIOS26 && nativeCompatible) {
      return CNSegmentedControl(
        labels: labels,
        selectedIndex: selectedIndex,
        onValueChanged: (index) =>
            handleSelection(index, systemProvidesHaptic: true),
        enabled: enabled,
        color: color,
        height: height,
        shrinkWrap: shrinkWrap,
        sfSymbols: nativeSymbols?.cast<CNSymbol>(),
        iconSize: iconSize,
        iconColor: iconColor,
      );
    }

    final children = <int, Widget>{};
    final icons = sfSymbols;
    dynamic iconAt(int index) =>
        icons != null && index < icons.length ? icons[index] : null;
    final count = labels.length;
    for (var index = 0; index < count; index++) {
      final icon = iconAt(index);
      final mappedIcon = fallbackIcon(icon);
      children[index] = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: mappedIcon != null
            ? Icon(mappedIcon, size: iconSize ?? 20, color: iconColor)
            : Text(
                labels[index],
                style: TextStyle(
                  color: index == selectedIndex ? selectedTextColor : textColor,
                ),
              ),
      );
    }

    if (PlatformUiCapabilities.isIOS) {
      Widget control = ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: CupertinoSlidingSegmentedControl<int>(
          groupValue: selectedIndex,
          thumbColor: color ?? CupertinoColors.systemGrey5,
          onValueChanged: (value) {
            if (value != null) handleSelection(value);
          },
          children: children,
        ),
      );
      if (shrinkWrap) {
        control = Center(child: IntrinsicWidth(child: control));
      }
      return control;
    }

    Widget control = ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: SegmentedButton<int>(
        style: SegmentedButton.styleFrom(
          textStyle: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontSize: 14),
        ),
        segments: [
          for (var index = 0; index < count; index++)
            ButtonSegment<int>(
              value: index,
              label: fallbackIcon(iconAt(index)) == null
                  ? Text(labels[index])
                  : null,
              icon: fallbackIcon(iconAt(index)) == null
                  ? null
                  : Icon(fallbackIcon(iconAt(index))!),
            ),
        ],
        selected: {selectedIndex},
        showSelectedIcon: false,
        onSelectionChanged: enabled
            ? (selection) => handleSelection(selection.first)
            : null,
      ),
    );
    if (shrinkWrap) {
      control = Center(child: IntrinsicWidth(child: control));
    }
    return control;
  }
}

class AdaptiveCheckbox extends StatelessWidget {
  const AdaptiveCheckbox({
    super.key,
    required this.value,
    this.tristate = false,
    required this.onChanged,
    this.activeColor,
    this.checkColor,
    this.focusColor,
    this.hoverColor,
  });

  final bool? value;
  final bool tristate;
  final ValueChanged<bool?>? onChanged;
  final Color? activeColor;
  final Color? checkColor;
  final Color? focusColor;
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) {
    void handleChanged(bool? next) {
      ConduitHaptics.selectionClick();
      onChanged?.call(next);
    }

    if (!PlatformUiCapabilities.isIOS) {
      return Checkbox(
        value: value,
        tristate: tristate,
        onChanged: onChanged == null ? null : handleChanged,
        activeColor: activeColor,
        checkColor: checkColor,
        focusColor: focusColor,
        hoverColor: hoverColor,
      );
    }
    final selected = value != false;
    return Semantics(
      checked: value,
      enabled: onChanged != null,
      button: true,
      child: GestureDetector(
        onTap: onChanged == null
            ? null
            : () {
                if (!tristate) return handleChanged(!(value ?? false));
                handleChanged(
                  value == false ? true : (value == true ? null : false),
                );
              },
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: selected
                    ? activeColor ?? CupertinoTheme.of(context).primaryColor
                    : CupertinoColors.systemBackground.resolveFrom(context),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : CupertinoColors.systemGrey3.resolveFrom(context),
                ),
              ),
              child: selected
                  ? Icon(
                      value == null
                          ? CupertinoIcons.minus
                          : CupertinoIcons.check_mark,
                      size: 16,
                      color: checkColor ?? CupertinoColors.white,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

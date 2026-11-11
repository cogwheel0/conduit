import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
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
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final Color? thumbColor;

  /// Accessibility label. Without it, VoiceOver announces only the value.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final label = semanticLabel;
    if (PlatformUiCapabilities.usesNativeIOS26 && thumbColor == null) {
      var nativeValue = value;
      void change(bool next) {
        // SwiftUI also reports programmatic updates through onChange.
        if (next == nativeValue) return;
        nativeValue = next;
        onChanged?.call(next);
      }

      return CNSwitch(
        value: value,
        enabled: onChanged != null,
        onChanged: change,
        semanticLabel: label,
        color: activeColor ?? CupertinoColors.activeGreen,
      );
    }
    final control = _buildControl(context);
    if (label == null) return control;
    return Semantics(label: label, child: control);
  }

  Widget _buildControl(BuildContext context) {
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

/// The most [AdaptiveSlider.divisions] for which the native iOS 26 slider
/// draws a tick mark at each step. Sliders with more steps still snap to them.
const int kAdaptiveSliderMaxTickedDivisions = 12;

/// How far the Cupertino slider's thumb centre stays from either end of the
/// slider: its padding (cupertino_ui's `_kPadding`) and the thumb's radius.
const double _kCupertinoThumbTravelInset = 8 + CupertinoThumbPainter.radius;

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
    this.semanticLabel,
    this.semanticValue,
    this.thumbless = false,
    this.seekOnTap = false,
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
  final String? semanticLabel;
  final String? semanticValue;

  /// A media scrubber: on iOS 26 the system draws it without a thumb, as in
  /// Music. Other platforms keep their slider.
  final bool thumbless;

  /// Whether a tap on the track moves the value to the tapped point, as a
  /// media scrubber does, reported as a change from start to end. The iOS
  /// sliders otherwise only follow a drag (and the Cupertino one only from
  /// near its thumb); the Material slider always does this.
  final bool seekOnTap;

  @override
  State<AdaptiveSlider> createState() => _AdaptiveSliderState();
}

class _AdaptiveSliderState extends State<AdaptiveSlider> {
  int? _lastHapticStep;

  /// Where a press on the Cupertino slider began, until it moves far enough
  /// to be a drag.
  Offset? _pressedAt;

  /// The value a touch on an iOS slider started from, until the touch
  /// changes it. Both report the start and the end of a touch that moves
  /// nothing: UIKit's slider for every touch, such as a tap, and the
  /// Cupertino one for a press on its thumb. Only a touch that changes the
  /// value is reported, as the Material slider does.
  double? _touchStartValue;
  bool _touchChanged = false;

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
    final slider = _buildSlider(context);
    return widget.semanticLabel == null && widget.semanticValue == null
        ? slider
        : Semantics(
            label: widget.semanticLabel,
            value: widget.semanticValue,
            child: slider,
          );
  }

  void _onTouchStart(double value) {
    _touchStartValue = value;
    _touchChanged = false;
  }

  void _onTouchChanged(double value) {
    final start = _touchStartValue;
    if (start != null && !_touchChanged) {
      // The Cupertino slider reports the value it starts from.
      if (value == start) return;
      _touchChanged = true;
      widget.onChangeStart?.call(start);
    }
    // A press the slider moves the value for is its drag, never a tap.
    _pressedAt = null;
    _handleChanged(value);
  }

  void _onTouchEnd(double value) {
    final changed = _touchChanged;
    _touchStartValue = null;
    _touchChanged = false;
    if (changed) widget.onChangeEnd?.call(value);
  }

  /// A tap on the Cupertino slider moves the value to the tapped point,
  /// along the travel of the thumb's centre. On its own it follows only a
  /// drag that starts near its thumb. The iOS 26 slider seeks on a tap
  /// itself.
  Widget _seekingOnTap(Widget slider) {
    const inset = _kCupertinoThumbTravelInset;
    return Listener(
      // Raw pointer events reach this listener whether or not the slider
      // takes the gesture, across the whole track.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => _pressedAt = event.localPosition,
      onPointerMove: (event) {
        final pressedAt = _pressedAt;
        if (pressedAt != null &&
            (event.localPosition - pressedAt).distance > kTouchSlop) {
          // A drag, even one that comes back, is the slider's own.
          _pressedAt = null;
        }
      },
      onPointerCancel: (_) => _pressedAt = null,
      onPointerUp: (event) {
        final pressedAt = _pressedAt;
        _pressedAt = null;
        // The slider's own width, which can be less than the room it is
        // offered.
        final travel = (context.size?.width ?? 0) - 2 * inset;
        if (widget.onChanged == null ||
            pressedAt == null ||
            travel <= 0 ||
            widget.max <= widget.min) {
          return;
        }
        var along = ((event.localPosition.dx - inset) / travel).clamp(
          0.0,
          1.0,
        );
        if (Directionality.of(context) == TextDirection.rtl) along = 1 - along;
        final divisions = widget.divisions;
        if (divisions != null && divisions > 0) {
          along = (along * divisions).round() / divisions;
        }
        final value = widget.min + along * (widget.max - widget.min);
        widget.onChangeStart?.call(widget.value);
        _handleChanged(value);
        widget.onChangeEnd?.call(value);
      },
      child: slider,
    );
  }

  Widget _buildSlider(BuildContext context) {
    if (PlatformUiCapabilities.usesNativeIOS26) {
      final divisions = widget.divisions;
      return CNSlider(
        value: widget.value.clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        enabled: widget.onChanged != null,
        onChanged: widget.onChanged == null ? (_) {} : _onTouchChanged,
        onChangeStart: _onTouchStart,
        onChangeEnd: _onTouchEnd,
        seekOnTap: widget.seekOnTap,
        trackColor: widget.activeColor,
        thumbColor: widget.thumbColor,
        style: widget.thumbless
            ? CNSliderStyle.thumbless
            : CNSliderStyle.standard,
        step: divisions == null || divisions == 0
            ? null
            : (widget.max - widget.min) / divisions,
        // A mark per step reads as a scale only when the steps are few.
        numberOfTicks:
            divisions != null &&
                divisions > 0 &&
                divisions <= kAdaptiveSliderMaxTickedDivisions
            ? divisions + 1
            : null,
      );
    }
    if (PlatformUiCapabilities.isIOS) {
      final slider = CupertinoSlider(
        value: widget.value.clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        onChanged: widget.onChanged == null ? null : _onTouchChanged,
        onChangeStart: _onTouchStart,
        onChangeEnd: _onTouchEnd,
        activeColor: widget.activeColor,
        thumbColor: widget.thumbColor ?? CupertinoColors.white,
        divisions: widget.divisions,
      );
      return widget.seekOnTap ? _seekingOnTap(slider) : slider;
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
    this.semanticLabel,
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

  /// What the control chooses, read by VoiceOver and TalkBack before the
  /// selected segment, e.g. the field label shown above it.
  final String? semanticLabel;

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
        semanticLabel: semanticLabel,
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
      return _labelled(control);
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
    return _labelled(control);
  }

  Widget _labelled(Widget control) {
    final label = semanticLabel;
    if (label == null || label.isEmpty) return control;
    return Semantics(container: true, label: label, child: control);
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
    this.visualDensity,
    this.materialTapTargetSize,
  });

  final bool? value;
  final bool tristate;
  final ValueChanged<bool?>? onChanged;
  final Color? activeColor;
  final Color? checkColor;
  final Color? focusColor;
  final Color? hoverColor;
  final VisualDensity? visualDensity;
  final MaterialTapTargetSize? materialTapTargetSize;

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
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
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

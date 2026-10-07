import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/services/haptic_service.dart';

class AdaptiveSegment<T extends Object> {
  const AdaptiveSegment({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
    this.semanticLabel,
  });
  final T value;
  final Widget label;
  final Widget? icon;
  final String? semanticLabel;
  final bool enabled;
}

/// Requires at least two segments with distinct values on every platform.
class AdaptiveValueSegmentedControl<T extends Object> extends StatelessWidget {
  const AdaptiveValueSegmentedControl({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });
  final List<AdaptiveSegment<T>> segments;
  final T? value;
  final ValueChanged<T>? onChanged;

  T? get _selection =>
      segments.any((s) => s.enabled && s.value == value) ? value : null;
  void _select(T next) {
    if (onChanged == null ||
        next == value ||
        !segments.any((s) => s.value == next && s.enabled)) {
      return;
    }
    ConduitHaptics.selectionClick();
    onChanged!(next);
  }

  Widget _label(AdaptiveSegment<T> segment) => Semantics(
    label: segment.semanticLabel,
    enabled: segment.enabled && onChanged != null,
    excludeSemantics: segment.semanticLabel != null,
    child: segment.label,
  );

  Widget _cupertinoLabel(AdaptiveSegment<T> segment) {
    final icon = segment.icon;
    final label = _label(segment);
    return icon == null
        ? label
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [icon, const SizedBox(width: 6), label],
          );
  }

  @override
  Widget build(BuildContext context) {
    if (segments.length < 2 ||
        segments.map((segment) => segment.value).toSet().length !=
            segments.length) {
      throw ArgumentError('Segments require at least two distinct values.');
    }
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      return CupertinoSlidingSegmentedControl<T>(
        groupValue: _selection,
        disabledChildren: {
          for (final segment in segments)
            if (!segment.enabled || onChanged == null) segment.value,
        },
        onValueChanged: (next) {
          if (next != null) _select(next);
        },
        children: {
          for (final segment in segments)
            segment.value: _cupertinoLabel(segment),
        },
      );
    }
    return SegmentedButton<T>(
      selected: _selection == null ? <T>{} : <T>{_selection!},
      emptySelectionAllowed: _selection == null,
      showSelectedIcon: false,
      segments: [
        for (final segment in segments)
          ButtonSegment<T>(
            value: segment.value,
            label: _label(segment),
            icon: segment.icon,
            enabled: segment.enabled,
          ),
      ],
      onSelectionChanged: onChanged == null
          ? null
          : (next) {
              if (next.isNotEmpty) _select(next.first);
            },
    );
  }
}

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/services/haptic_service.dart';

class AdaptiveSegment<T extends Object> {
  const AdaptiveSegment({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
    this.sfSymbol,
    this.semanticLabel,
  });
  final T value;
  final Widget label;
  final Widget? icon;
  final String? sfSymbol;
  final String? semanticLabel;
  final bool enabled;
}

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

  @override
  Widget build(BuildContext context) {
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
          for (final segment in segments) segment.value: segment.label,
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
            label: segment.label,
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

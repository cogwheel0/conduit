import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:cupertino_ui/cupertino_ui.dart';

import 'platform_ui_capabilities.dart';

/// What an [AdaptiveCompactDatePicker] edits.
enum AdaptiveCompactDatePickerMode { date, time }

/// The native compact date or time pill of iOS 26 and later, edited in place
/// as in Calendar and Reminders: tapping it opens the system picker in a
/// popover.
///
/// Only iOS 26 and later have it. Check [isSupported] first, and elsewhere
/// show a row that opens `showAdaptiveDatePicker` or `showAdaptiveTimePicker`.
///
/// The pill edits wall-clock fields: the year, month, day, hour and minute of
/// [value], [minimumDate] and [maximumDate] are read whatever their zone, and
/// [onChanged] receives a UTC [DateTime] whose fields are the picked wall
/// clock. Working in UTC keeps a time that a daylight-saving change skips in
/// the device's zone pickable.
class AdaptiveCompactDatePicker extends StatelessWidget {
  const AdaptiveCompactDatePicker({
    super.key,
    required this.value,
    required this.mode,
    required this.onChanged,
    this.minimumDate,
    this.maximumDate,
    this.semanticLabel,
  });

  /// Whether the native pill can be shown here.
  static bool get isSupported => PlatformUiCapabilities.usesNativeIOS26;

  final DateTime value;
  final AdaptiveCompactDatePickerMode mode;

  /// Called with the picked wall clock (see the class documentation). Null
  /// disables the pill.
  final ValueChanged<DateTime>? onChanged;

  final DateTime? minimumDate;
  final DateTime? maximumDate;

  /// What VoiceOver reads before the value, such as the row's title.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final minimum = minimumDate;
    final maximum = maximumDate;
    final onChanged = this.onChanged;
    return CNDatePicker(
      value: _wallClock(value),
      mode: switch (mode) {
        AdaptiveCompactDatePickerMode.date => CNDatePickerMode.date,
        AdaptiveCompactDatePickerMode.time => CNDatePickerMode.time,
      },
      style: CNDatePickerStyle.compact,
      minimumDate: minimum == null ? null : _wallClock(minimum),
      maximumDate: maximum == null ? null : _wallClock(maximum),
      enabled: onChanged != null,
      onChanged: (picked) => onChanged?.call(picked),
      semanticLabel: semanticLabel,
    );
  }

  static DateTime _wallClock(DateTime value) => DateTime.utc(
    value.year,
    value.month,
    value.day,
    value.hour,
    value.minute,
  );
}

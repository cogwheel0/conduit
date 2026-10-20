import 'dart:io' show Platform;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/services/native_sheet_bridge.dart';
import '../theme/theme_extensions.dart';
import 'adaptive_selection_sheet.dart';
import 'conduit_components.dart';

/// Asks for a calendar day, in the picker the platform expects: the native
/// sheet on iOS (a Cupertino wheel when it cannot be shown), and the Material
/// calendar dialog elsewhere.
///
/// Only the year, month and day of [initial], [first] and [last] are read, and
/// [initial] is kept between the other two. Returns the chosen day as a local
/// date at midnight, or null when the picker was dismissed. [title] names what
/// is being picked on the iOS sheets.
Future<DateTime?> showAdaptiveDatePicker(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
  String? title,
}) async {
  final firstDay = _dateOnly(first);
  final lastDay = _dateOnly(last);
  assert(!lastDay.isBefore(firstDay), 'last must not be before first');
  final initialDay = _clampDay(_dateOnly(initial), firstDay, lastDay);
  final materialL10n = MaterialLocalizations.of(context);

  if (!context.usesCupertinoChrome) {
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDay,
      firstDate: firstDay,
      lastDate: lastDay,
      helpText: title,
    );
    return picked == null ? null : _dateOnly(picked);
  }

  if (Platform.isIOS) {
    try {
      // Noon keeps the day the same whichever zone the native side reads the
      // instant in.
      final picked = await NativeSheetBridge.instance.presentDatePicker(
        title: title ?? '',
        initialDate: initialDay.add(const Duration(hours: 12)),
        firstDate: firstDay,
        lastDate: lastDay.add(const Duration(hours: 23, minutes: 59)),
        doneLabel: materialL10n.okButtonLabel,
        cancelLabel: materialL10n.cancelButtonLabel,
        rethrowErrors: true,
      );
      return picked == null ? null : _dateOnly(picked.toLocal());
    } catch (_) {
      // The native sheet could not be shown; the Cupertino one stands in.
    }
    if (!context.mounted) return null;
  }

  var selected = initialDay;
  final picked = await _showCupertinoPickerSheet<DateTime>(
    context,
    title: title,
    onDone: () => selected,
    picker: CupertinoDatePicker(
      mode: CupertinoDatePickerMode.date,
      initialDateTime: initialDay,
      minimumDate: firstDay,
      maximumDate: lastDay,
      onDateTimeChanged: (value) => selected = _dateOnly(value),
    ),
  );
  return picked;
}

/// Asks for a wall clock time, in the picker the platform expects: a Cupertino
/// wheel on iOS and the Material clock dialog elsewhere. Both follow the
/// device's 24-hour setting ([MediaQuery.alwaysUse24HourFormatOf]).
///
/// Returns null when the picker was dismissed. [title] names what is being
/// picked.
Future<TimeOfDay?> showAdaptiveTimePicker(
  BuildContext context, {
  required TimeOfDay initial,
  String? title,
}) async {
  if (!context.usesCupertinoChrome) {
    return showTimePicker(
      context: context,
      initialTime: initial,
      helpText: title,
    );
  }

  final use24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
  final now = DateTime.now();
  var selected = initial;
  return _showCupertinoPickerSheet<TimeOfDay>(
    context,
    title: title,
    onDone: () => selected,
    picker: CupertinoDatePicker(
      mode: CupertinoDatePickerMode.time,
      use24hFormat: use24Hour,
      initialDateTime: DateTime(
        now.year,
        now.month,
        now.day,
        initial.hour,
        initial.minute,
      ),
      onDateTimeChanged: (value) =>
          selected = TimeOfDay(hour: value.hour, minute: value.minute),
    ),
  );
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _clampDay(DateTime day, DateTime first, DateTime last) {
  if (day.isBefore(first)) return first;
  if (day.isAfter(last)) return last;
  return day;
}

/// The wheel picker sheet: Cancel and OK either side of the title, the wheel
/// below. OK returns what [onDone] reads at that moment.
Future<T?> _showCupertinoPickerSheet<T>(
  BuildContext context, {
  required String? title,
  required T Function() onDone,
  required Widget picker,
}) {
  return showAdaptiveSelectionSheet<T>(
    context: context,
    builder: (sheetContext) {
      final theme = sheetContext.conduitTheme;
      final materialL10n = MaterialLocalizations.of(sheetContext);
      return SafeArea(
        top: false,
        child: Container(
          key: const Key('adaptive-picker-sheet'),
          decoration: BoxDecoration(
            color: theme.surfaceContainer,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppBorderRadius.bottomSheet),
            ),
          ),
          padding: const EdgeInsets.only(bottom: Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.sm,
                  Spacing.sm,
                  Spacing.sm,
                  Spacing.xs,
                ),
                child: Row(
                  children: [
                    ConduitTextButton(
                      text: materialL10n.cancelButtonLabel,
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title ?? '',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.bodyMedium?.copyWith(
                            color: theme.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    ConduitTextButton(
                      key: const Key('adaptive-picker-done'),
                      text: materialL10n.okButtonLabel,
                      isPrimary: true,
                      onPressed: () => Navigator.of(sheetContext).pop(onDone()),
                    ),
                  ],
                ),
              ),
              // The wheel's standard height on iOS.
              SizedBox(height: 216, child: picker),
            ],
          ),
        ),
      );
    },
  );
}

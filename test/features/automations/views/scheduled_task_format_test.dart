import 'package:conduit/features/automations/views/scheduled_task_format.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Runs [read] in a context that does or does not use 24-hour time.
Future<T> readWith<T>(
  WidgetTester tester, {
  required bool alwaysUse24HourFormat,
  required T Function(BuildContext context, AppLocalizations l10n) read,
}) async {
  late T value;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(alwaysUse24HourFormat: alwaysUse24HourFormat),
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          value = read(context, AppLocalizations.of(context)!);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return value;
}

void main() {
  // 17:05 local time on 6 October 2026.
  final instantNs = DateTime(2026, 10, 6, 17, 5).microsecondsSinceEpoch * 1000;

  testWidgets('times use the 12-hour clock where the device does', (
    tester,
  ) async {
    final values = await readWith(
      tester,
      alwaysUse24HourFormat: false,
      read: (context, l10n) => [
        formatWallClockTime(context, 17, 5),
        formatServerTime(context, instantNs),
        scheduleSummary(
          context,
          l10n,
          const DailyAutomationSchedule(hour: 17, minute: 5),
        ),
      ],
    );

    expect(values[0], '5:05 PM');
    expect(values[1], contains('5:05'));
    expect(values[1], contains('PM'));
    expect(values[2], contains('5:05 PM'));
  });

  testWidgets('times use the 24-hour clock when the device asks for it', (
    tester,
  ) async {
    final values = await readWith(
      tester,
      alwaysUse24HourFormat: true,
      read: (context, l10n) => [
        formatWallClockTime(context, 17, 5),
        formatServerTime(context, instantNs),
        scheduleSummary(
          context,
          l10n,
          const OnceAutomationSchedule(
            year: 2026,
            month: 10,
            day: 6,
            hour: 17,
            minute: 5,
          ),
        ),
      ],
    );

    expect(values[0], '17:05');
    expect(values[1], contains('17:05'));
    expect(values[1], isNot(contains('PM')));
    expect(values[2], contains('17:05'));
    expect(values[2], isNot(contains('PM')));
  });
}

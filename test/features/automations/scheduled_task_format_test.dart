import 'package:conduit/features/automations/scheduled_task_format.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('de');
  });

  // 17:05 local time on 6 October 2026.
  final instantNs = DateTime(2026, 10, 6, 17, 5).microsecondsSinceEpoch * 1000;

  test('times use the 12-hour clock where the device does', () {
    const clock = (locale: 'en', use24Hour: false);

    expect(formatWallClockTime(clock, 17, 5), '5:05 PM');
    final server = formatServerTime(clock, instantNs);
    expect(server, contains('5:05'));
    expect(server, contains('PM'));
    expect(
      scheduleSummary(
        clock,
        _l10n,
        const DailyAutomationSchedule(hour: 17, minute: 5),
      ),
      contains('5:05 PM'),
    );
  });

  test('times use the 24-hour clock when the device asks for it', () {
    const clock = (locale: 'en', use24Hour: true);

    expect(formatWallClockTime(clock, 17, 5), '17:05');
    final server = formatServerTime(clock, instantNs);
    expect(server, contains('17:05'));
    expect(server, isNot(contains('PM')));
    final summary = scheduleSummary(
      clock,
      _l10n,
      const OnceAutomationSchedule(
        year: 2026,
        month: 10,
        day: 6,
        hour: 17,
        minute: 5,
      ),
    );
    expect(summary, contains('17:05'));
    expect(summary, isNot(contains('PM')));
  });

  test("a device on the 12-hour clock gets it whatever the language's own "
      'habit', () {
    const german = (locale: 'de', use24Hour: false);

    expect(formatWallClockTime(german, 17, 5), '5:05 PM');
    expect(formatServerTime(german, instantNs), contains('5:05 PM'));
    const german24 = (locale: 'de', use24Hour: true);
    expect(formatWallClockTime(german24, 17, 5), '17:05');
  });

  test('weekdays are named in the app language', () {
    const clock = (locale: 'en', use24Hour: false);

    expect(weekdayLabel(clock, 'MO'), 'Mon');
    expect(weekdayName(clock, 'SU'), 'Sunday');
    // Another app language names them its own way.
    const german = (locale: 'de', use24Hour: true);
    expect(weekdayLabel(german, 'MO'), 'Mo');
    expect(weekdayName(german, 'SU'), 'Sonntag');
  });
}

import 'package:conduit/features/calendar/calendar_text.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('de');
  });

  const evening = CalendarWallTime(2026, 10, 6, 17);

  test("a device on the 12-hour clock gets it whatever the language's own "
      'habit', () {
    expect(
      calendarClockText((locale: 'de', use24Hour: false), evening),
      '5:00 PM',
    );
    expect(
      calendarClockText((locale: 'en', use24Hour: false), evening),
      '5:00 PM',
    );
  });

  test('a device on the 24-hour clock gets it in any language', () {
    expect(
      calendarClockText((locale: 'de', use24Hour: true), evening),
      '17:00',
    );
    expect(
      calendarClockText((locale: 'en', use24Hour: true), evening),
      '17:00',
    );
  });
}

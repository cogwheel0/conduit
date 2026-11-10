import 'package:conduit/features/navigation/utils/recency_stamp_label.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_de.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/app_localizations_fr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting());

  // Wednesday 11 November 2026, late afternoon.
  final now = DateTime(2026, 11, 11, 17, 30);

  RecencyStamp stamp(
    DateTime timestamp, {
    AppLocalizations? l10n,
    String locale = 'en',
    bool use24HourTime = false,
  }) => recencyStampLabel(
    timestamp,
    l10n ?? AppLocalizationsEn(),
    locale: locale,
    now: now,
    use24HourTime: use24HourTime,
  );

  test('today shows the time in the 12 or 24 hour style asked for', () {
    final morning = DateTime(2026, 11, 11, 9, 41);
    expect(stamp(morning).text, matches(RegExp(r'^9:41\sAM$')));
    expect(stamp(morning).spoken, stamp(morning).text);
    expect(stamp(morning, use24HourTime: true).text, '09:41');
    final evening = DateTime(2026, 11, 11, 21, 5);
    expect(stamp(evening, use24HourTime: true).text, '21:05');
  });

  test('yesterday says so, in the app language', () {
    final lastNight = DateTime(2026, 11, 10, 23, 59);
    expect(stamp(lastNight).text, 'Yesterday');
    expect(
      stamp(lastNight, l10n: AppLocalizationsDe(), locale: 'de').text,
      AppLocalizationsDe().yesterday,
    );
  });

  test('the rest of the week shows the weekday, capitalised', () {
    expect(stamp(DateTime(2026, 11, 9, 8)).text, 'Monday');
    expect(stamp(DateTime(2026, 11, 5, 8)).text, 'Thursday');
    expect(
      stamp(
        DateTime(2026, 11, 9, 8),
        l10n: AppLocalizationsFr(),
        locale: 'fr',
      ).text,
      'Lundi',
    );
  });

  test('older items show the short date, spelled out for VoiceOver', () {
    final older = DateTime(2026, 11, 2, 8);
    expect(stamp(older).text, '11/2/26');
    expect(stamp(older).spoken, 'November 2, 2026');
    final german = stamp(older, l10n: AppLocalizationsDe(), locale: 'de');
    expect(german.text, '02.11.26');
    expect(german.spoken, '2. November 2026');
  });

  test('an unknown locale falls back to English forms', () {
    expect(stamp(DateTime(2026, 11, 2, 8), locale: 'xx').text, '11/2/26');
  });
}

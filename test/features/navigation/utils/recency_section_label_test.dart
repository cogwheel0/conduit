import 'dart:ui' show Locale;

import 'package:conduit/features/navigation/utils/recency_section_label.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_de.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/app_localizations_es.dart';
import 'package:conduit/l10n/app_localizations_ru.dart';
import 'package:conduit/l10n/app_localizations_zh.dart';
import 'package:conduit_core/utils/recency_sections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting());

  final now = DateTime(2026, 11, 8, 17);

  String label(RecencySection section, AppLocalizations l10n, String locale) =>
      recencySectionLabel(section, l10n, locale: locale, now: now);

  test('relative sections use the localized strings', () {
    final en = AppLocalizationsEn();
    expect(label(RecencySection.today, en, 'en'), en.today);
    expect(label(RecencySection.yesterday, en, 'en'), en.yesterday);
    expect(label(RecencySection.previous7Days, en, 'en'), 'Previous 7 Days');
    expect(label(RecencySection.previous30Days, en, 'en'), 'Previous 30 Days');
  });

  test('a month of this year is named alone, an older one with its year', () {
    final en = AppLocalizationsEn();
    expect(label(RecencySection.month(2026, 9), en, 'en'), 'September');
    expect(label(RecencySection.month(2025, 12), en, 'en'), 'December 2025');
  });

  test('month headers take the locale\'s form and start with a capital', () {
    expect(
      label(RecencySection.month(2026, 9), AppLocalizationsDe(), 'de'),
      'September',
    );
    // Spanish and Russian write month names in lowercase.
    expect(
      label(RecencySection.month(2026, 9), AppLocalizationsEs(), 'es'),
      'Septiembre',
    );
    // Stand-alone nominative, not the genitive "сентября".
    expect(
      label(RecencySection.month(2026, 9), AppLocalizationsRu(), 'ru'),
      'Сентябрь',
    );
    expect(
      label(RecencySection.month(2025, 9), AppLocalizationsZh(), 'zh'),
      '2025年9月',
    );
  });

  test('a script-tagged locale falls back to its language', () {
    final zhHant = lookupAppLocalizations(
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    );
    expect(label(RecencySection.month(2026, 9), zhHant, 'zh_Hant'), isNotEmpty);
  });
}

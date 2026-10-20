import 'package:conduit_core/features/web_search/models/web_search_preferences.dart';
import 'package:test/test.dart';

void main() {
  test('region follows the stored choice, then the device locale', () {
    final cases = <(String?, String, String)>[
      // Auto: device locale → the matching DuckDuckGo region.
      (null, 'en_GB', 'uk-en'),
      (null, 'fr_CA', 'ca-fr'),
      (null, 'en_CA.UTF-8', 'ca-en'),
      (null, 'ja-JP', 'jp-jp'),
      (kWebSearchRegionAuto, 'de_AT', 'at-de'),
      // A country without the locale's language still gets its region.
      (null, 'it_CH', 'ch-de'),
      // No country, or no region for it: worldwide.
      (null, 'en', 'wt-wt'),
      (null, 'xx_ZZ', 'wt-wt'),
      // An explicit choice wins over the device.
      ('wt-wt', 'en_GB', 'wt-wt'),
      ('de-de', 'en_GB', 'de-de'),
      // A stored code that is no longer offered falls back safely.
      ('zz-zz', 'en_GB', 'wt-wt'),
    ];
    for (final (stored, locale, expected) in cases) {
      expect(
        resolveWebSearchRegion(stored, locale).code,
        expected,
        reason: 'stored=$stored locale=$locale',
      );
    }
  });
}

import 'package:conduit_core/utils/openwebui_request_variables.dart';
import 'package:test/test.dart';

void main() {
  test('fills every variable, with Open WebUI fallbacks', () {
    final variables = buildOpenWebUiPromptVariables(
      now: DateTime(2026, 9, 23, 7, 5, 9),
      userName: ' ',
      userEmail: 'ada@example.com',
      userLanguage: 'fr-FR',
    );
    expect(variables['{{USER_NAME}}'], 'User');
    expect(variables['{{USER_EMAIL}}'], 'ada@example.com');
    expect(variables['{{USER_LOCATION}}'], 'Unknown');
    expect(variables['{{CURRENT_DATE}}'], '2026-09-23');
    expect(variables['{{CURRENT_TIME}}'], '07:05:09');
    expect(variables['{{CURRENT_DATETIME}}'], '2026-09-23 07:05:09');
    expect(variables['{{CURRENT_WEEKDAY}}'], 'Wednesday');
    expect(variables['{{USER_LANGUAGE}}'], 'fr-FR');
    expect(variables, contains('{{CURRENT_TIMEZONE}}'));
  });

  group('extractUserLocationSetting', () {
    test('a flag, the words for on and off, or a place', () {
      expect(
        extractUserLocationSetting({'userLocation': true}).autoRefreshEnabled,
        isTrue,
      );
      expect(
        extractUserLocationSetting({
          'ui': {'userLocation': 'always'},
        }).autoRefreshEnabled,
        isTrue,
      );
      expect(
        extractUserLocationSetting({'userLocation': 'off'}).autoRefreshEnabled,
        isFalse,
      );
      expect(
        extractUserLocationSetting({
          'ui': {'userLocation': ' Lisbon '},
        }).legacyLocation,
        'Lisbon',
      );
      expect(extractUserLocationSetting(null).legacyLocation, isNull);
      expect(
        extractUserLocationSetting({
          'userLocation': {'nested': true},
        }).autoRefreshEnabled,
        isFalse,
      );
    });
  });

  test('coordinates as Open WebUI writes them', () {
    expect(
      formatUserLocationCoordinates(latitude: 52.52, longitude: 13.4049),
      '52.520, 13.405 (lat, long)',
    );
  });
}

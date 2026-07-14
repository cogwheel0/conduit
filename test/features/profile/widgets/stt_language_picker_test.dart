import 'package:checks/checks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:conduit/features/profile/views/audio_settings_page.dart';
import 'package:conduit/features/profile/widgets/settings_page_scaffold.dart';
import 'package:conduit/features/profile/widgets/stt_language_picker.dart';
import 'package:conduit/l10n/app_localizations.dart';

void main() {
  test('device recognition language tile is Android and device-STT only', () {
    check(
      shouldShowDeviceSttLanguageSetting(
        TargetPlatform.android,
        SttPreference.deviceOnly,
      ),
    ).isTrue();
    check(
      shouldShowDeviceSttLanguageSetting(
        TargetPlatform.android,
        SttPreference.serverOnly,
      ),
    ).isFalse();
    check(
      shouldShowDeviceSttLanguageSetting(
        TargetPlatform.iOS,
        SttPreference.deviceOnly,
      ),
    ).isFalse();
  });

  testWidgets('picker marks auto, system, installed, and custom selections', (
    tester,
  ) async {
    await _pumpPicker(tester, const AppSettings());
    _expectSelected(tester, 'device-stt-auto-option');

    await _pumpPicker(
      tester,
      const AppSettings(
        voiceLocaleId: SettingsService.voiceLocaleSystemDefault,
      ),
    );
    _expectSelected(tester, 'device-stt-system-option');

    await _pumpPicker(tester, const AppSettings(voiceLocaleId: 'pl-PL'));
    _expectSelected(tester, 'device-stt-locale-pl-PL');

    await _pumpPicker(tester, const AppSettings(voiceLocaleId: 'cy-GB'));
    _expectSelected(tester, 'device-stt-custom-option');
  });
}

Future<void> _pumpPicker(WidgetTester tester, AppSettings settings) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: DeviceSttLanguagePicker(
          settings: settings,
          locales: const <LocaleName>[
            LocaleName('en-US', 'English'),
            LocaleName('pl-PL', 'Polski'),
          ],
          onSelected: (_) async {},
          onCustom: () async {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectSelected(WidgetTester tester, String selectedKey) {
  final optionKeys = <String>[
    'device-stt-auto-option',
    'device-stt-system-option',
    'device-stt-locale-en-US',
    'device-stt-locale-pl-PL',
    'device-stt-custom-option',
  ];
  for (final key in optionKeys) {
    final tile = tester.widget<SettingsSelectorTile>(find.byKey(Key(key)));
    check(tile.selected, because: key).equals(key == selectedKey);
  }
}

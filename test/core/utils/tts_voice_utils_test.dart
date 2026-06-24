import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/utils/tts_voice_utils.dart';
import 'package:conduit/l10n/app_localizations_en.dart';

void main() {
  final l10n = AppLocalizationsEn();

  group('TTS voice utils', () {
    test('device voice ids prefer native identifiers', () {
      final voice = {
        'id': 'com.apple.voice.compact.en-US.Samantha',
        'identifier': 'com.apple.voice.enhanced.en-US.Samantha',
        'name': 'Samantha',
      };

      check(
        ttsVoiceIdFor(TtsEngine.device, voice),
      ).equals('com.apple.voice.enhanced.en-US.Samantha');
    });

    test('selected option resolves legacy saved names to native ids', () {
      final voices = [
        {
          'id': 'com.apple.voice.compact.en-US.Samantha',
          'identifier': 'com.apple.voice.enhanced.en-US.Samantha',
          'name': 'Samantha',
          'locale': 'en-US',
        },
      ];
      final settings = const AppSettings().copyWith(ttsVoice: 'Samantha');

      check(
        selectedTtsVoiceOptionId(settings, voices),
      ).equals('com.apple.voice.enhanced.en-US.Samantha');
      check(ttsVoiceMatchesSettings(settings, voices.single)).isTrue();
    });

    test('builds display labels and subtitles consistently', () {
      final options = buildTtsVoiceOptions(l10n, TtsEngine.device, [
        {
          'identifier': 'com.apple.voice.enhanced.en-US.Samantha',
          'name': 'Samantha',
          'displayName': 'Samantha',
          'locale': 'en-US',
          'qualityName': 'Enhanced',
        },
      ]);

      check(options).length.equals(1);
      check(options.single.label).equals('Samantha');
      check(options.single.subtitle).equals('en-US · Enhanced');
    });

    test('includes native iOS voice metadata in subtitles', () {
      final options = buildTtsVoiceOptions(l10n, TtsEngine.device, [
        {
          'identifier': 'com.apple.voice.personal.en-US.Example',
          'name': 'Example',
          'displayName': 'Example (Personal Voice)',
          'locale': 'en-US',
          'languageName': 'English (United States)',
          'qualityName': 'Premium',
          'isPersonalVoice': true,
        },
      ]);

      check(options).length.equals(1);
      check(options.single.label).equals('Example (Personal Voice)');
      check(
        options.single.subtitle,
      ).equals('English (United States) · Premium · Personal Voice');
    });
  });
}

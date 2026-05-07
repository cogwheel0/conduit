import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/models/account_metadata.dart';
import 'package:conduit/core/models/server_about_info.dart';
import 'package:conduit/core/models/server_user_settings.dart';

void main() {
  group('ServerUserSettings.fromJson', () {
    test('prefers ui.system and parses memory plus model IDs', () {
      final settings = ServerUserSettings.fromJson({
        'system': 'legacy prompt',
        'ui': {
          'system': 'preferred prompt',
          'memory': true,
          'models': ['gpt-4.1', 'fallback-model'],
        },
      });

      check(settings.systemPrompt).equals('preferred prompt');
      check(settings.memoryEnabled).isTrue();
      check(settings.defaultModelIds).deepEquals(['gpt-4.1', 'fallback-model']);
      check(settings.defaultModelId).equals('gpt-4.1');
    });

    test('falls back to root system when nested prompt is absent', () {
      final settings = ServerUserSettings.fromJson({
        'system': 'root prompt',
        'ui': {'memory': 'false'},
      });

      check(settings.systemPrompt).equals('root prompt');
      check(settings.memoryEnabled).isFalse();
      check(settings.defaultModelIds).isEmpty();
    });
  });

  group('AccountMetadata.fromJson', () {
    test('normalizes optional profile fields and timezone', () {
      final profile = AccountMetadata.fromJson(
        {
          'id': 'user-1',
          'email': 'dev@example.com',
          'name': 'Dev User',
          'role': 'admin',
          'is_active': true,
          'profile_image_url': 'https://example.com/avatar.png',
          'bio': 'Writes tests',
          'gender': 'non-binary',
          'date_of_birth': '1990-01-02T00:00:00',
          'status_emoji': '🟢',
          'status_message': 'Online',
        },
        info: {'timezone': 'Asia/Kolkata'},
      );

      check(profile.displayName).equals('Dev User');
      check(profile.profileImageUrl).equals('https://example.com/avatar.png');
      check(profile.dateOfBirth).equals('1990-01-02');
      check(profile.timezone).equals('Asia/Kolkata');
      check(profile.hasStatus).isTrue();
    });
  });

  group('ServerAboutInfo.fromJson', () {
    test('combines config, version, and update payloads', () {
      final about = ServerAboutInfo.fromJson(
        {
          'name': 'Open WebUI',
          'version': '0.6.0',
          'default_locale': 'en',
          'user_count': 12,
          'default_models': ['gpt-4.1'],
          'license_metadata': {'plan': 'pro'},
          'features': {
            'enable_login_form': true,
            'enable_password_change_form': false,
            'enable_api_keys': true,
            'enable_audio_input': true,
            'enable_audio_output': false,
          },
          'audio': {
            'stt': {'engine': 'faster-whisper'},
            'tts': {'engine': 'kokoro'},
          },
        },
        versionData: {'version': '0.6.1', 'deployment_id': 'deploy-123'},
        updateData: {'latest': '0.6.2'},
        changelog: {
          '0.6.2': ['Improvement'],
        },
      );

      check(about.name).equals('Open WebUI');
      check(about.version).equals('0.6.1');
      check(about.latestVersion).equals('0.6.2');
      check(about.deploymentId).equals('deploy-123');
      check(about.defaultModels).deepEquals(['gpt-4.1']);
      check(about.enablePasswordChangeForm).equals(false);
      check(about.sttEngine).equals('faster-whisper');
      check(about.ttsEngine).equals('kokoro');
      check(about.hasAvailableUpdate).isTrue();
      check(about.hasLicenseMetadata).isTrue();
    });
  });
}

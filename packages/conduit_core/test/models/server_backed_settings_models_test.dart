import 'package:checks/checks.dart';
import 'package:test/test.dart';

import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_about_info.dart';
import 'package:conduit_core/models/server_user_settings.dart';

void main() {
  group('ServerUserSettings.fromJson', () {
    test('prefers ui.system and parses memory plus model IDs', () {
      final settings = ServerUserSettings.fromJson({
        'system': 'legacy prompt',
        'ui': {
          'system': 'preferred prompt',
          'memory': true,
          'models': ['gpt-4.1', 'fallback-model'],
          'pinnedModels': ['gpt-4.1', 'gpt-4.1', 'claude-sonnet'],
        },
      });

      check(settings.systemPrompt).equals('preferred prompt');
      check(settings.memoryEnabled).isTrue();
      check(settings.defaultModelIds).deepEquals(['gpt-4.1', 'fallback-model']);
      check(settings.defaultModelId).equals('gpt-4.1');
      check(settings.pinnedModelIds).deepEquals(['gpt-4.1', 'claude-sonnet']);
    });

    test('falls back to root system when nested prompt is absent', () {
      final settings = ServerUserSettings.fromJson({
        'system': 'root prompt',
        'ui': {'memory': 'false'},
      });

      check(settings.systemPrompt).equals('root prompt');
      check(settings.memoryEnabled).isFalse();
      check(settings.defaultModelIds).isEmpty();
      check(settings.pinnedModelIds).isEmpty();
    });

    test('copyWith preserves fields and can replace pinned models', () {
      const original = ServerUserSettings(
        systemPrompt: 'prompt',
        memoryEnabled: true,
        defaultModelIds: ['gpt-4.1'],
        pinnedModelIds: ['old-model'],
      );

      final updated = original.copyWith(pinnedModelIds: ['new-model']);

      check(updated.systemPrompt).equals('prompt');
      check(updated.memoryEnabled).isTrue();
      check(updated.defaultModelIds).deepEquals(['gpt-4.1']);
      check(updated.pinnedModelIds).deepEquals(['new-model']);
    });

    test('parses top-level notification preferences', () {
      final settings = ServerUserSettings.fromJson({
        'notificationEnabled': true,
        'notificationSound': false,
        'notificationSoundAlways': true,
      });

      check(settings.notificationEnabled).equals(true);
      check(settings.notificationSound).equals(false);
      check(settings.notificationSoundAlways).equals(true);
    });

    test('leaves notification preferences null when the server omits them', () {
      final settings = ServerUserSettings.fromJson({'ui': {}});

      check(settings.notificationEnabled).isNull();
      check(settings.notificationSound).isNull();
      check(settings.notificationSoundAlways).isNull();
    });

    test('reads reasoning effort from OpenWebUI params', () {
      final settings = ServerUserSettings.fromJson({
        'params': {'reasoning_effort': ' high '},
      });

      check(settings.reasoningEffort).equals('high');
      check(settings.copyWith(reasoningEffort: null).reasoningEffort).isNull();
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

    test('parses Open WebUI 0.10 string defaults and nested audio flags', () {
      final about = ServerAboutInfo.fromJson({
        'name': 'Open WebUI',
        'version': '0.10.1',
        'default_models': 'gpt-4.1, claude-sonnet',
        'features': {'enable_login_form': true},
        'audio': {
          'stt': {'engine': 'openai'},
          'tts': {'engine': 'openai'},
        },
      });

      check(about.defaultModels).deepEquals(['gpt-4.1', 'claude-sonnet']);
      check(about.enableAudioInput).equals(true);
      check(about.enableAudioOutput).equals(true);
      check(about.sttEngine).equals('openai');
      check(about.ttsEngine).equals('openai');
    });
  });

  group('BackendConfig.fromJson', () {
    test('parses Open WebUI 0.10 nested audio config', () {
      final config = BackendConfig.fromJson({
        'features': {
          'enable_websocket': true,
          'enable_ldap': true,
          'enable_login_form': false,
        },
        'audio': {
          'stt': {'engine': 'openai'},
          'tts': {
            'engine': 'openai',
            'voice': 'alloy',
            'split_on': 'punctuation',
          },
        },
        'oauth': {
          'providers': {'github': 'GitHub'},
        },
      });

      check(config.enableWebsocket).equals(true);
      check(config.enableLdap).isTrue();
      check(config.enableLoginForm).isFalse();
      check(config.enableAudioInput).equals(true);
      check(config.enableAudioOutput).equals(true);
      check(config.sttProvider).equals('openai');
      check(config.ttsProvider).equals('openai');
      check(config.ttsVoice).equals('alloy');
      check(config.ttsSplitOn).equals('punctuation');
      check(config.oauthProviders.github).equals('GitHub');
    });

    test('reads realtime calls from Open WebUI 0.12 and keeps them cached', () {
      final config = BackendConfig.fromJson({
        'audio': {
          'stt': {'engine': 'openai'},
          'realtime': {
            'enabled': true,
            'model': 'gpt-realtime-2.1-mini',
            'voice': 'marin',
          },
        },
      });

      check(config.enableRealtimeCall).equals(true);
      check(config.realtimeCallModel).equals('gpt-realtime-2.1-mini');
      check(config.realtimeCallVoice).equals('marin');

      // The app caches the flat form and reads it back on the next launch.
      final cached = BackendConfig.fromJson(config.toJson());
      check(cached.enableRealtimeCall).equals(true);
      check(cached.realtimeCallModel).equals('gpt-realtime-2.1-mini');
      check(cached.realtimeCallVoice).equals('marin');
    });

    test('a server without realtime calls leaves them unknown', () {
      // Open WebUI 0.11 and signed-out configs send no `audio.realtime`.
      final config = BackendConfig.fromJson({
        'audio': {
          'stt': {'engine': 'openai'},
          'tts': {'engine': 'openai'},
        },
      });

      check(config.enableRealtimeCall).isNull();
      check(config.realtimeCallModel).isNull();
      check(BackendConfig.fromJson(config.toJson()).enableRealtimeCall)
          .isNull();
    });

    test('explicit nested audio feature flags override engine inference', () {
      final config = BackendConfig.fromJson({
        'features': {'enable_audio_input': false, 'enable_audio_output': false},
        'audio': {
          'stt': {'engine': 'openai'},
          'tts': {'engine': 'openai'},
        },
      });

      check(config.enableAudioInput).equals(false);
      check(config.enableAudioOutput).equals(false);
      check(config.sttProvider).equals('openai');
      check(config.ttsProvider).equals('openai');
    });

    test('reads the user webhooks flag the server reports to a signed-in '
        'account and keeps absence unknown', () {
      final enabled = BackendConfig.fromJson({
        'features': {'enable_user_webhooks': true},
      });
      final disabled = BackendConfig.fromJson({
        'features': {'enable_user_webhooks': false},
      });
      // The signed-out config omits the flag, which is not the same as off.
      final signedOut = BackendConfig.fromJson({
        'features': {'enable_websocket': true},
      });

      check(enabled.enableUserWebhooks).equals(true);
      check(disabled.enableUserWebhooks).equals(false);
      check(signedOut.enableUserWebhooks).isNull();
    });

    test('keeps the user webhooks flag through the stored copy', () {
      final stored = BackendConfig.fromJson(
        BackendConfig.fromJson({
          'features': {'enable_user_webhooks': true},
        }).toJson(),
      );

      check(stored.enableUserWebhooks).equals(true);
      check(stored.copyWith(serverId: 'server').enableUserWebhooks)
          .equals(true);
    });

    test('reads the automations flag the server reports to a signed-in '
        'account and keeps absence unknown', () {
      final enabled = BackendConfig.fromJson({
        'features': {'enable_automations': true},
      });
      final disabled = BackendConfig.fromJson({
        'features': {'enable_automations': false},
      });
      final signedOut = BackendConfig.fromJson({
        'features': {'enable_websocket': true},
      });

      check(enabled.enableAutomations).equals(true);
      check(disabled.enableAutomations).equals(false);
      check(signedOut.enableAutomations).isNull();
    });

    test('keeps the automations flag through the stored copy', () {
      final stored = BackendConfig.fromJson(
        BackendConfig.fromJson({
          'features': {'enable_automations': true},
        }).toJson(),
      );

      check(stored.enableAutomations).equals(true);
      check(stored.copyWith(serverId: 'server').enableAutomations).equals(true);
    });

    test('reads the calendar flag the server reports to a signed-in account '
        'and keeps absence unknown', () {
      final enabled = BackendConfig.fromJson({
        'features': {'enable_calendar': true},
      });
      final disabled = BackendConfig.fromJson({
        'features': {'enable_calendar': false},
      });
      final signedOut = BackendConfig.fromJson({
        'features': {'enable_websocket': true},
      });

      check(enabled.enableCalendar).equals(true);
      check(disabled.enableCalendar).equals(false);
      check(signedOut.enableCalendar).isNull();
    });

    test('keeps the calendar flag through the stored copy', () {
      final stored = BackendConfig.fromJson(
        BackendConfig.fromJson({
          'features': {'enable_calendar': true},
        }).toJson(),
      );

      check(stored.enableCalendar).equals(true);
      check(stored.copyWith(serverId: 'server').enableCalendar).equals(true);
    });
  });
}

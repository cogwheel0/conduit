import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/settings_service.dart';

void main() {
  group('AppSettings', () {
    group('default constructor values', () {
      const settings = AppSettings();

      test('reduceMotion defaults to false', () {
        check(settings.reduceMotion).equals(false);
      });

      test('animationSpeed defaults to 1.0', () {
        check(settings.animationSpeed).equals(1.0);
      });

      test('hapticFeedback defaults to true', () {
        check(settings.hapticFeedback).equals(true);
      });

      test('highContrast defaults to false', () {
        check(settings.highContrast).equals(false);
      });

      test('largeText defaults to false', () {
        check(settings.largeText).equals(false);
      });

      test('darkMode defaults to true', () {
        check(settings.darkMode).equals(true);
      });

      test('defaultModel defaults to null', () {
        check(settings.defaultModel).isNull();
      });

      test('voiceLocaleId defaults to null', () {
        check(settings.voiceLocaleId).isNull();
      });

      test('voiceHoldToTalk defaults to false', () {
        check(settings.voiceHoldToTalk).equals(false);
      });

      test('voiceAutoSendFinal defaults to false', () {
        check(settings.voiceAutoSendFinal).equals(false);
      });

      test('socketTransportMode defaults to ws', () {
        check(settings.socketTransportMode).equals('ws');
      });

      test('quickPills defaults to empty list', () {
        check(settings.quickPills).isEmpty();
      });

      test('sendOnEnter defaults to false', () {
        check(settings.sendOnEnter).equals(false);
      });

      test('sttPreference defaults to deviceOnly', () {
        check(settings.sttPreference).equals(SttPreference.deviceOnly);
      });

      test('ttsVoice defaults to null', () {
        check(settings.ttsVoice).isNull();
      });

      test('ttsSpeechRate defaults to 0.5', () {
        check(settings.ttsSpeechRate).equals(0.5);
      });

      test('ttsPitch defaults to 1.0', () {
        check(settings.ttsPitch).equals(1.0);
      });

      test('ttsVolume defaults to 1.0', () {
        check(settings.ttsVolume).equals(1.0);
      });

      test('ttsEngine defaults to device', () {
        check(settings.ttsEngine).equals(TtsEngine.device);
      });

      test('ttsServerVoiceId defaults to null', () {
        check(settings.ttsServerVoiceId).isNull();
      });

      test('ttsServerVoiceName defaults to null', () {
        check(settings.ttsServerVoiceName).isNull();
      });

      test('androidAssistantTrigger defaults to overlay', () {
        check(settings.androidAssistantTrigger)
            .equals(AndroidAssistantTrigger.overlay);
      });

      test('voiceSilenceDuration defaults to 2000', () {
        check(settings.voiceSilenceDuration).equals(2000);
      });

      test('temporaryChatByDefault defaults to false', () {
        check(settings.temporaryChatByDefault).equals(false);
      });
    });

    group('copyWith', () {
      test('returns identical settings when no arguments given', () {
        const original = AppSettings();
        final copy = original.copyWith();
        check(copy).equals(original);
      });

      test('copies non-nullable fields correctly', () {
        const original = AppSettings();
        final modified = original.copyWith(
          reduceMotion: true,
          animationSpeed: 1.5,
          hapticFeedback: false,
          highContrast: true,
          largeText: true,
          darkMode: false,
          voiceHoldToTalk: true,
          voiceAutoSendFinal: true,
          socketTransportMode: 'polling',
          quickPills: ['web', 'image'],
          sendOnEnter: true,
          sttPreference: SttPreference.serverOnly,
          ttsSpeechRate: 0.8,
          ttsPitch: 1.2,
          ttsVolume: 0.9,
          ttsEngine: TtsEngine.server,
          androidAssistantTrigger: AndroidAssistantTrigger.newChat,
          voiceSilenceDuration: 1500,
          temporaryChatByDefault: true,
        );

        check(modified.reduceMotion).equals(true);
        check(modified.animationSpeed).equals(1.5);
        check(modified.hapticFeedback).equals(false);
        check(modified.highContrast).equals(true);
        check(modified.largeText).equals(true);
        check(modified.darkMode).equals(false);
        check(modified.voiceHoldToTalk).equals(true);
        check(modified.voiceAutoSendFinal).equals(true);
        check(modified.socketTransportMode).equals('polling');
        check(modified.quickPills).deepEquals(['web', 'image']);
        check(modified.sendOnEnter).equals(true);
        check(modified.sttPreference)
            .equals(SttPreference.serverOnly);
        check(modified.ttsSpeechRate).equals(0.8);
        check(modified.ttsPitch).equals(1.2);
        check(modified.ttsVolume).equals(0.9);
        check(modified.ttsEngine).equals(TtsEngine.server);
        check(modified.androidAssistantTrigger)
            .equals(AndroidAssistantTrigger.newChat);
        check(modified.voiceSilenceDuration).equals(1500);
        check(modified.temporaryChatByDefault).equals(true);
      });

      test('can set nullable fields to a value', () {
        const original = AppSettings();
        final modified = original.copyWith(
          defaultModel: 'gpt-4',
          voiceLocaleId: 'en_US',
          ttsVoice: 'voice1',
          ttsServerVoiceId: 'server-voice-1',
          ttsServerVoiceName: 'Server Voice',
        );

        check(modified.defaultModel).equals('gpt-4');
        check(modified.voiceLocaleId).equals('en_US');
        check(modified.ttsVoice).equals('voice1');
        check(modified.ttsServerVoiceId).equals('server-voice-1');
        check(modified.ttsServerVoiceName)
            .equals('Server Voice');
      });

      test('can set nullable fields back to null', () {
        final original = const AppSettings().copyWith(
          defaultModel: 'gpt-4',
          voiceLocaleId: 'en_US',
          ttsVoice: 'voice1',
          ttsServerVoiceId: 'server-voice-1',
          ttsServerVoiceName: 'Server Voice',
        );

        final cleared = original.copyWith(
          defaultModel: null,
          voiceLocaleId: null,
          ttsVoice: null,
          ttsServerVoiceId: null,
          ttsServerVoiceName: null,
        );

        check(cleared.defaultModel).isNull();
        check(cleared.voiceLocaleId).isNull();
        check(cleared.ttsVoice).isNull();
        check(cleared.ttsServerVoiceId).isNull();
        check(cleared.ttsServerVoiceName).isNull();
      });

      test('preserves nullable values when not specified', () {
        final original = const AppSettings().copyWith(
          defaultModel: 'gpt-4',
          voiceLocaleId: 'en_US',
        );

        final copy = original.copyWith(darkMode: false);

        check(copy.defaultModel).equals('gpt-4');
        check(copy.voiceLocaleId).equals('en_US');
        check(copy.darkMode).equals(false);
      });

      test('does not mutate the original', () {
        const original = AppSettings();
        original.copyWith(reduceMotion: true, animationSpeed: 2.0);

        check(original.reduceMotion).equals(false);
        check(original.animationSpeed).equals(1.0);
      });
    });

    group('equality', () {
      test('two default instances are equal', () {
        const a = AppSettings();
        const b = AppSettings();
        check(a).equals(b);
      });

      test('identical instance is equal', () {
        const a = AppSettings();
        check(a == a).equals(true);
      });

      test('instances with same non-default values are equal', () {
        final a = const AppSettings().copyWith(
          darkMode: false,
          defaultModel: 'model-1',
          quickPills: ['web'],
        );
        final b = const AppSettings().copyWith(
          darkMode: false,
          defaultModel: 'model-1',
          quickPills: ['web'],
        );
        check(a).equals(b);
      });

      test('different reduceMotion yields inequality', () {
        const a = AppSettings();
        final b = a.copyWith(reduceMotion: true);
        check(a).not((it) => it.equals(b));
      });

      test('different quickPills yields inequality', () {
        final a = const AppSettings().copyWith(
          quickPills: ['web'],
        );
        final b = const AppSettings().copyWith(
          quickPills: ['image'],
        );
        check(a).not((it) => it.equals(b));
      });

      test('quickPills order matters', () {
        final a = const AppSettings().copyWith(
          quickPills: ['web', 'image'],
        );
        final b = const AppSettings().copyWith(
          quickPills: ['image', 'web'],
        );
        check(a).not((it) => it.equals(b));
      });

      test(
        'socketTransportMode is excluded from equality',
        () {
          final a = const AppSettings().copyWith(
            socketTransportMode: 'ws',
          );
          final b = const AppSettings().copyWith(
            socketTransportMode: 'polling',
          );
          // socketTransportMode is intentionally not in ==
          check(a).equals(b);
        },
      );

      test('not equal to a non-AppSettings object', () {
        const a = AppSettings();
        // ignore: unrelated_type_equality_checks
        check(a == 'not an AppSettings').equals(false);
      });
    });

    group('hashCode', () {
      test('equal objects have the same hashCode', () {
        const a = AppSettings();
        const b = AppSettings();
        check(a.hashCode).equals(b.hashCode);
      });

      test('copies with same values have same hashCode', () {
        final a = const AppSettings().copyWith(
          darkMode: false,
          defaultModel: 'model-1',
        );
        final b = const AppSettings().copyWith(
          darkMode: false,
          defaultModel: 'model-1',
        );
        check(a.hashCode).equals(b.hashCode);
      });
    });
  });

  group('Enum values', () {
    test('SttPreference has expected values', () {
      check(SttPreference.values).length.equals(2);
      check(SttPreference.values)
          .contains(SttPreference.deviceOnly);
      check(SttPreference.values)
          .contains(SttPreference.serverOnly);
    });

    test('TtsEngine has expected values', () {
      check(TtsEngine.values).length.equals(2);
      check(TtsEngine.values).contains(TtsEngine.device);
      check(TtsEngine.values).contains(TtsEngine.server);
    });

    test('AndroidAssistantTrigger has expected values', () {
      check(AndroidAssistantTrigger.values).length.equals(3);
      check(AndroidAssistantTrigger.values)
          .contains(AndroidAssistantTrigger.overlay);
      check(AndroidAssistantTrigger.values)
          .contains(AndroidAssistantTrigger.newChat);
      check(AndroidAssistantTrigger.values)
          .contains(AndroidAssistantTrigger.voiceCall);
    });
  });

  group('AndroidAssistantTriggerStorage', () {
    test('overlay storageValue is "overlay"', () {
      check(AndroidAssistantTrigger.overlay.storageValue)
          .equals('overlay');
    });

    test('newChat storageValue is "new_chat"', () {
      check(AndroidAssistantTrigger.newChat.storageValue)
          .equals('new_chat');
    });

    test('voiceCall storageValue is "voice_call"', () {
      check(AndroidAssistantTrigger.voiceCall.storageValue)
          .equals('voice_call');
    });
  });
}

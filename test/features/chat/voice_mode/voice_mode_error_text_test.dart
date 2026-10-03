import 'package:checks/checks.dart';
import 'package:conduit/features/chat/voice_mode/voice_mode_error_text.dart';
import 'package:conduit/l10n/app_localizations_de.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit_core/voice/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final en = AppLocalizationsEn();
  final de = AppLocalizationsDe();

  String? text(
    ChatVoiceModeError? kind,
    String? message, {
    bool german = false,
  }) => voiceModeErrorText(german ? de : en, kind: kind, message: message);

  group('voiceModeErrorText', () {
    test('says each known failure in the language of the app', () {
      check(text(ChatVoiceModeError.microphoneDenied, 'raw'))
          .equals(en.microphonePermissionDenied);
      check(text(ChatVoiceModeError.inputUnavailable, 'raw'))
          .equals(en.voiceInputUnavailable);
      check(text(ChatVoiceModeError.timeout, 'raw'))
          .equals(en.voiceCallStartTimeout);
      check(text(ChatVoiceModeError.noSpeech, 'raw'))
          .equals(en.voiceCallNoSpeech);

      check(text(ChatVoiceModeError.microphoneDenied, 'raw', german: true))
          .equals(de.microphonePermissionDenied);
      check(text(ChatVoiceModeError.timeout, 'raw', german: true))
          .equals(de.voiceCallStartTimeout);
      check(de.voiceCallStartTimeout)
          .not((it) => it.equals(en.voiceCallStartTimeout));
    });

    test('shows text meant for the user as it is', () {
      check(text(ChatVoiceModeError.message, 'The server said no.'))
          .equals('The server said no.');
    });

    test('never prints an exception text', () {
      check(text(ChatVoiceModeError.other, 'SocketException: boom'))
          .equals(en.voiceCallFailed);
      check(text(null, 'SocketException: boom')).equals(en.voiceCallFailed);
      check(text(ChatVoiceModeError.message, '')).equals(en.voiceCallFailed);
    });

    test('is null when there is no error', () {
      check(text(null, null)).isNull();
    });
  });
}

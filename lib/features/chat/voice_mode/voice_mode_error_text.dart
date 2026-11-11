import 'package:conduit_core/voice/voice_session.dart';

import '../../../l10n/app_localizations.dart';

/// The text a voice call error shows, in the user's language.
///
/// [kind] says why the call failed; [message] is only shown as it is for
/// [ChatVoiceModeError.message], which carries text meant for the user.
/// Anything else (including an error with no kind) never prints [message],
/// which for those is an exception's text kept for logs.
///
/// Null when there is no error to show ([message] null and no [kind]).
String? voiceModeErrorText(
  AppLocalizations l10n, {
  required ChatVoiceModeError? kind,
  required String? message,
}) {
  if (kind == null && message == null) return null;
  return switch (kind) {
    ChatVoiceModeError.microphoneDenied => l10n.microphonePermissionDenied,
    ChatVoiceModeError.inputUnavailable => l10n.voiceInputUnavailable,
    ChatVoiceModeError.timeout => l10n.voiceCallStartTimeout,
    ChatVoiceModeError.noSpeech => l10n.voiceCallNoSpeech,
    ChatVoiceModeError.message when message != null && message.isNotEmpty =>
      message,
    ChatVoiceModeError.message ||
    ChatVoiceModeError.other ||
    null => l10n.voiceCallFailed,
  };
}

/// The text a call notice shows, in the user's language.
String voiceModeNoticeText(AppLocalizations l10n, ChatVoiceModeNotice notice) =>
    switch (notice) {
      ChatVoiceModeNotice.transcriptionFailed =>
        l10n.voiceCallNoticeTranscriptionFailed,
      ChatVoiceModeNotice.replyIncomplete => l10n.voiceCallNoticeReplyIncomplete,
      ChatVoiceModeNotice.transcriptNotSaved =>
        l10n.voiceCallNoticeTranscriptNotSaved,
    };

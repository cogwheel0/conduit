import 'chat_message.dart';

/// Where a message's voice record lives in its metadata: Open WebUI's
/// `meta.voice` object, which holds what a realtime call spoke for the
/// message, or absent.
const String kMessageVoiceMetadataKey = 'voice';

/// The label Open WebUI puts on a spoken transcript when it replays one to the
/// chat model. It keeps what the voice said as history, never as the current
/// state of a task the chat model is working on.
const String kHistoricalVoiceTranscriptPrefix =
    '[Historical voice assistant transcript; not current task status]\n';

/// How a message's spoken transcripts reach a chat model.
///
/// [spokenOnly] means the message is a reply the voice gave by itself and is
/// replaced by [speech]; otherwise [speech] follows the message. Each entry
/// already carries [kHistoricalVoiceTranscriptPrefix].
typedef VoiceReplay = ({bool spokenOnly, List<String> speech});

/// The voice record stored on [message], or null.
Map<String, dynamic>? messageVoiceRecord(ChatMessage message) {
  final voice = message.metadata?[kMessageVoiceMetadataKey];
  if (voice is Map<String, dynamic>) return voice;
  if (voice is Map) {
    return voice.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

/// How [message]'s spoken transcripts are replayed to a chat model.
///
/// Mirrors Open WebUI's `process_messages_with_output`: an assistant message
/// stored under the voice model with no output is the voice's own reply and
/// is replayed only as its transcript; any other assistant message keeps its
/// place and is followed by the transcripts in `speech`.
VoiceReplay voiceReplayFor(ChatMessage message) {
  final voice = messageVoiceRecord(message) ?? const <String, dynamic>{};
  final isAssistant = message.role == 'assistant';
  final spokenOnly =
      isAssistant &&
      voice.isNotEmpty &&
      message.model == voice['model'] &&
      (message.output == null || message.output!.isEmpty);

  final Iterable<Object?> transcripts;
  if (spokenOnly) {
    transcripts = [message.content];
  } else if (isAssistant && voice['speech'] is List) {
    transcripts = [
      for (final item in voice['speech'] as List)
        if (item is Map) item['transcript'],
    ];
  } else {
    transcripts = const [];
  }

  return (
    spokenOnly: spokenOnly,
    speech: [
      for (final transcript in transcripts)
        if (transcript is String && transcript.isNotEmpty)
          '$kHistoricalVoiceTranscriptPrefix$transcript',
    ],
  );
}

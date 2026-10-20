import 'package:checks/checks.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/message_voice.dart';
import 'package:test/test.dart';

/// Cases mirror Open WebUI's `process_messages_with_output`, which decides how
/// a realtime call's transcripts reach the chat model.
void main() {
  ChatMessage message({
    String role = 'assistant',
    String content = 'Answer',
    String? model = 'chat-model',
    Map<String, dynamic>? voice,
    List<Map<String, dynamic>>? output,
  }) => ChatMessage(
    id: 'm-1',
    role: role,
    content: content,
    timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    model: model,
    metadata: voice == null
        ? null
        : <String, dynamic>{kMessageVoiceMetadataKey: voice},
    output: output,
  );

  test('a voice reply is replayed only as its labeled transcript', () {
    final replay = voiceReplayFor(
      message(
        content: 'Hi there!',
        model: 'gpt-realtime',
        voice: {'model': 'gpt-realtime', 'call_id': 'call-1'},
      ),
    );

    check(replay.spokenOnly).isTrue();
    check(replay.speech)
        .deepEquals(['${kHistoricalVoiceTranscriptPrefix}Hi there!']);
  });

  test('an empty voice reply is dropped', () {
    final replay = voiceReplayFor(
      message(
        content: '',
        model: 'gpt-realtime',
        voice: {'model': 'gpt-realtime'},
      ),
    );

    check(replay.spokenOnly).isTrue();
    check(replay.speech).isEmpty();
  });

  test('a chat answer keeps its place, followed by what was spoken', () {
    final replay = voiceReplayFor(
      message(
        voice: {
          'model': 'gpt-realtime',
          'speech': [
            {'item_id': 'i-1', 'transcript': "I'll check."},
            {'item_id': 'i-2', 'transcript': ''},
            {'item_id': 'i-3', 'transcript': 7},
            'not a map',
            {'item_id': 'i-4', 'transcript': 'It is sunny.'},
          ],
        },
      ),
    );

    check(replay.spokenOnly).isFalse();
    check(replay.speech).deepEquals([
      "$kHistoricalVoiceTranscriptPrefix${"I'll check."}",
      '${kHistoricalVoiceTranscriptPrefix}It is sunny.',
    ]);
  });

  test('a voice-model message with output is a chat answer', () {
    final replay = voiceReplayFor(
      message(
        model: 'gpt-realtime',
        voice: {'model': 'gpt-realtime'},
        output: const [
          {'type': 'message', 'content': <Object>[]},
        ],
      ),
    );

    check(replay.spokenOnly).isFalse();
    check(replay.speech).isEmpty();
  });

  test('a user transcript is replayed as itself', () {
    final replay = voiceReplayFor(
      message(
        role: 'user',
        model: null,
        voice: {
          'call_id': 'call-1',
          'speech': [
            {'transcript': 'ignored'},
          ],
        },
      ),
    );

    check(replay.spokenOnly).isFalse();
    check(replay.speech).isEmpty();
  });

  test('a message without a voice record replays nothing extra', () {
    final replay = voiceReplayFor(message());

    check(replay.spokenOnly).isFalse();
    check(replay.speech).isEmpty();
  });
}

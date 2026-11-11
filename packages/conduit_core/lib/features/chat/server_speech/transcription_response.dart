/// The transcript in a speech-to-text response, or null when it holds none.
///
/// Reads the shapes Open WebUI passes through from its engines: OpenAI-style
/// `text`, Azure `DisplayText` and `combinedRecognizedPhrases`, Deepgram
/// `results.channels`, and Whisper-style `segments`.
String? transcriptionResponseText(Map<String, dynamic> data) {
  final direct = data['text'];
  if (direct is String && direct.trim().isNotEmpty) {
    return direct;
  }

  final display = data['display_text'] ?? data['DisplayText'];
  if (display is String && display.trim().isNotEmpty) {
    return display;
  }

  final result = data['result'];
  if (result is Map<String, dynamic>) {
    final resultText = result['text'];
    if (resultText is String && resultText.trim().isNotEmpty) {
      return resultText;
    }
  }

  final combined = data['combinedRecognizedPhrases'];
  if (combined is List && combined.isNotEmpty) {
    final first = combined.first;
    if (first is Map<String, dynamic>) {
      final candidate =
          first['display'] ??
          first['Display'] ??
          first['transcript'] ??
          first['text'];
      if (candidate is String && candidate.trim().isNotEmpty) {
        return candidate;
      }
    } else if (first is String && first.trim().isNotEmpty) {
      return first;
    }
  }

  final results = data['results'];
  if (results is Map<String, dynamic>) {
    final channels = results['channels'];
    if (channels is List && channels.isNotEmpty) {
      final channel = channels.first;
      if (channel is Map<String, dynamic>) {
        final alternatives = channel['alternatives'];
        if (alternatives is List && alternatives.isNotEmpty) {
          final alternative = alternatives.first;
          if (alternative is Map<String, dynamic>) {
            final transcript = alternative['transcript'] ?? alternative['text'];
            if (transcript is String && transcript.trim().isNotEmpty) {
              return transcript;
            }
          }
        }
      }
    }
  }

  final segments = data['segments'];
  if (segments is List && segments.isNotEmpty) {
    final buffer = StringBuffer();
    for (final segment in segments) {
      if (segment is Map<String, dynamic>) {
        final text = segment['text'];
        if (text is String && text.trim().isNotEmpty) {
          buffer.write(text.trim());
          buffer.write(' ');
        }
      } else if (segment is String && segment.trim().isNotEmpty) {
        buffer.write(segment.trim());
        buffer.write(' ');
      }
    }
    final combinedText = buffer.toString().trim();
    if (combinedText.isNotEmpty) {
      return combinedText;
    }
  }

  return null;
}

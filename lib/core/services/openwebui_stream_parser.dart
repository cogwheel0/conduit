import 'dart:async';
import 'dart:convert';

/// Base class for all stream update types emitted by the OpenWebUI SSE parser.
sealed class OpenWebUIStreamUpdate {
  const OpenWebUIStreamUpdate();
}

/// A content delta from a streamed completion chunk.
final class OpenWebUIContentDelta extends OpenWebUIStreamUpdate {
  const OpenWebUIContentDelta(this.content);

  /// The incremental text content from this chunk.
  final String content;
}

/// Token usage statistics from a completion chunk.
final class OpenWebUIUsageUpdate extends OpenWebUIStreamUpdate {
  const OpenWebUIUsageUpdate(this.usage);

  /// Raw usage map (e.g. `{"total_tokens": 3}`).
  final Map<String, dynamic> usage;
}

/// Source/citation references from a completion chunk.
final class OpenWebUISourcesUpdate extends OpenWebUIStreamUpdate {
  const OpenWebUISourcesUpdate(this.sources);

  /// List of source objects attached to the response.
  final List<dynamic> sources;
}

/// The selected model ID for arena/routing flows.
final class OpenWebUISelectedModelUpdate extends OpenWebUIStreamUpdate {
  const OpenWebUISelectedModelUpdate(this.selectedModelId);

  /// The model ID that was selected for this completion.
  final String selectedModelId;
}

/// A structured error from a completion chunk.
final class OpenWebUIErrorUpdate extends OpenWebUIStreamUpdate {
  const OpenWebUIErrorUpdate(this.error);

  /// Raw error map (e.g. `{"message": "boom"}`).
  final Map<String, dynamic> error;
}

/// The stream has completed ([DONE] received or stream ended).
final class OpenWebUIStreamDone extends OpenWebUIStreamUpdate {
  const OpenWebUIStreamDone();
}

/// Parses an OpenWebUI/OpenAI-compatible SSE byte stream into typed updates.
///
/// Handles:
/// - Split SSE frames across byte chunks
/// - Multi-byte UTF-8 characters split across chunks (via [utf8.decoder])
/// - CRLF normalization
/// - Comment/event-only frames (skipped)
/// - Trailing frames without final `\n\n` boundary
Stream<OpenWebUIStreamUpdate> parseOpenWebUIStream(
  Stream<List<int>> chunks,
) async* {
  final buffer = StringBuffer();
  final textChunks = chunks.transform(utf8.decoder);

  await for (final chunk in textChunks) {
    buffer.write(chunk.replaceAll('\r\n', '\n'));
    final frames = _takeCompleteFrames(buffer);

    for (final frame in frames) {
      final data = _extractData(frame);
      if (data.isEmpty) continue;
      if (data == '[DONE]') {
        yield const OpenWebUIStreamDone();
        return;
      }
      yield* _parseFrameData(data);
    }
  }

  // Handle trailing data that wasn't terminated by \n\n.
  final trailing = buffer.toString().trim();
  if (trailing.isNotEmpty) {
    final data = _extractData(trailing);
    if (data.isEmpty) return;
    if (data == '[DONE]') {
      yield const OpenWebUIStreamDone();
    } else {
      yield* _parseFrameData(data);
    }
  }
}

/// Splits completed SSE frames (delimited by `\n\n`) out of [buffer],
/// leaving any incomplete trailing text in the buffer.
List<String> _takeCompleteFrames(StringBuffer buffer) {
  final text = buffer.toString();
  final frames = text.split('\n\n');

  // The last element is either empty (if text ended with \n\n) or an
  // incomplete frame -- either way it stays in the buffer.
  buffer
    ..clear()
    ..write(frames.removeLast());

  return frames
      .where((frame) => frame.trim().isNotEmpty)
      .toList(growable: false);
}

/// Extracts the concatenated `data:` field values from an SSE frame,
/// ignoring comment lines (`:`) and event/id lines.
String _extractData(String frame) {
  return frame
      .split('\n')
      .where((line) => line.startsWith('data:'))
      .map((line) => line.substring(5).trimLeft())
      .join('\n');
}

/// Decodes a JSON data payload and yields the appropriate typed update.
Stream<OpenWebUIStreamUpdate> _parseFrameData(String data) async* {
  final parsed = jsonDecode(data) as Map<String, dynamic>;

  if (parsed['error'] != null) {
    yield OpenWebUIErrorUpdate(parsed['error'] as Map<String, dynamic>);
    return;
  }
  if (parsed['sources'] != null) {
    yield OpenWebUISourcesUpdate(parsed['sources'] as List<dynamic>);
    return;
  }
  if (parsed['selected_model_id'] != null) {
    yield OpenWebUISelectedModelUpdate(parsed['selected_model_id'].toString());
    return;
  }
  if (parsed['usage'] is Map<String, dynamic>) {
    yield OpenWebUIUsageUpdate(parsed['usage'] as Map<String, dynamic>);
    return;
  }

  final choices = parsed['choices'];
  if (choices is! List || choices.isEmpty) return;

  final firstChoice = choices.first;
  if (firstChoice is! Map<String, dynamic>) return;

  final delta = firstChoice['delta'];
  if (delta is! Map<String, dynamic>) return;

  final content = delta['content']?.toString() ?? '';
  if (content.isNotEmpty) {
    yield OpenWebUIContentDelta(content);
  }
}

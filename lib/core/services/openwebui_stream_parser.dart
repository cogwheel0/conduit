import 'dart:async';
import 'dart:convert';

import 'structured_output.dart';

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

/// A reasoning/thinking content delta from a streamed completion chunk.
///
/// This corresponds to `delta.reasoning_content` in the OpenAI-compatible
/// format, used by models that expose chain-of-thought reasoning tokens.
final class OpenWebUIReasoningDelta extends OpenWebUIStreamUpdate {
  const OpenWebUIReasoningDelta(this.content);

  /// The incremental reasoning text from this chunk.
  final String content;
}

/// Structured output items from the backend middleware.
///
/// The `output` array contains OR-aligned items such as message, reasoning,
/// code_interpreter, function_call, and function_call_output.
final class OpenWebUIOutputUpdate extends OpenWebUIStreamUpdate {
  OpenWebUIOutputUpdate(this.output)
    : blocks = parseOpenWebUIStructuredOutput(output);

  /// Raw output item maps from the server, preserved for message storage.
  final List<dynamic> output;

  /// Typed blocks parsed from [output].
  final List<StructuredOutputBlock> blocks;
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

/// A custom OpenWebUI event-emitter payload.
///
/// Tools and filters can send payloads such as
/// `{"type":"citation","data":{...}}` through `__event_emitter__`. Some
/// streaming middleware forwards these under an `event` envelope.
final class OpenWebUIEventUpdate extends OpenWebUIStreamUpdate {
  const OpenWebUIEventUpdate({required this.type, this.data});

  /// Event type, for example `status`, `citation`, or `source`.
  final String type;

  /// Raw event data payload.
  final Object? data;
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
/// - CRLF normalization, including split CRLF boundaries across chunks
/// - Comment/event-only frames (skipped)
/// - Trailing frames without final `\n\n` boundary
Stream<OpenWebUIStreamUpdate> parseOpenWebUIStream(
  Stream<List<int>> chunks,
) async* {
  final scanner = _OpenWebUISseScanner();
  final textChunks = chunks.transform(utf8.decoder);

  await for (final chunk in textChunks) {
    for (final data in scanner.addChunk(chunk)) {
      if (data == '[DONE]') {
        yield const OpenWebUIStreamDone();
        return;
      }
      for (final update in parseOpenWebUIDataPayload(data)) {
        yield update;
      }
    }
  }

  for (final data in scanner.close()) {
    if (data == '[DONE]') {
      yield const OpenWebUIStreamDone();
      return;
    }
    for (final update in parseOpenWebUIDataPayload(data)) {
      yield update;
    }
  }
}

/// Decodes a JSON data payload and yields the appropriate typed updates.
Iterable<OpenWebUIStreamUpdate> parseOpenWebUIDataPayload(String data) sync* {
  yield* parseOpenWebUIParsedPayload(decodeOpenWebUIDataPayload(data));
}

/// Decodes a raw OpenWebUI/OpenAI-compatible SSE `data:` payload.
Map<String, dynamic> decodeOpenWebUIDataPayload(String data) {
  final decoded = jsonDecode(data);
  if (decoded is! Map) {
    throw const FormatException(
      'OpenWebUI SSE payload must decode to a JSON object.',
    );
  }
  return decoded.cast<String, dynamic>();
}

/// Converts a decoded payload map into typed stream updates.
Iterable<OpenWebUIStreamUpdate> parseOpenWebUIParsedPayload(
  Map<String, dynamic> parsed,
) sync* {
  final envelopedEvent = parsed['event'];
  if (envelopedEvent is Map) {
    final event = _eventUpdateFromMap(envelopedEvent);
    if (event != null) {
      yield event;
      return;
    }
  }

  if (parsed['error'] != null) {
    yield OpenWebUIErrorUpdate(parsed['error'] as Map<String, dynamic>);
    return;
  }

  final directEvent = _eventUpdateFromMap(parsed);
  if (directEvent != null) {
    yield directEvent;
    return;
  }
  if (parsed['sources'] != null) {
    yield OpenWebUISourcesUpdate(parsed['sources'] as List<dynamic>);
  }
  if (parsed['selected_model_id'] != null) {
    yield OpenWebUISelectedModelUpdate(parsed['selected_model_id'].toString());
  }
  if (parsed['usage'] is Map<String, dynamic>) {
    yield OpenWebUIUsageUpdate(parsed['usage'] as Map<String, dynamic>);
  }

  final choices = parsed['choices'];
  if (choices is List && choices.isNotEmpty) {
    final firstChoice = choices.first;
    if (firstChoice is Map<String, dynamic>) {
      final delta = firstChoice['delta'];
      if (delta is Map<String, dynamic>) {
        // Reasoning/thinking content (chain-of-thought tokens).
        final reasoning = delta['reasoning_content']?.toString() ?? '';
        if (reasoning.isNotEmpty) {
          yield OpenWebUIReasoningDelta(reasoning);
        }

        final content = delta['content']?.toString() ?? '';
        if (content.isNotEmpty) {
          yield OpenWebUIContentDelta(content);
        }
      }
    }
  }

  // Structured output snapshots are applied after deltas from the same frame so
  // the renderer can merge details with the plain text instead of duplicating it.
  final output = parsed['output'];
  if (output is List && output.isNotEmpty) {
    yield OpenWebUIOutputUpdate(output);
  }
}

/// Incrementally scans decoded SSE text and emits complete `data:` payloads.
final class _OpenWebUISseScanner {
  final StringBuffer _lineBuffer = StringBuffer();
  final StringBuffer _dataBuffer = StringBuffer();
  bool _frameHasDataLine = false;
  bool _skipLeadingLineFeed = false;

  Iterable<String> addChunk(String chunk) sync* {
    for (var index = 0; index < chunk.length; index++) {
      final codeUnit = chunk.codeUnitAt(index);
      if (_skipLeadingLineFeed) {
        _skipLeadingLineFeed = false;
        if (codeUnit == _lineFeed) {
          continue;
        }
      }

      if (codeUnit == _lineFeed) {
        final payload = _finishLine();
        if (payload != null) {
          yield payload;
        }
        continue;
      }

      if (codeUnit == _carriageReturn) {
        final payload = _finishLine();
        _skipLeadingLineFeed = true;
        if (payload != null) {
          yield payload;
        }
        continue;
      }

      _lineBuffer.writeCharCode(codeUnit);
    }
  }

  Iterable<String> close() sync* {
    _skipLeadingLineFeed = false;
    if (_lineBuffer.length > 0) {
      _consumeLine(_lineBuffer.toString());
      _lineBuffer.clear();
    }

    final payload = _finishFrame();
    if (payload != null) {
      yield payload;
    }
  }

  String? _finishLine() {
    if (_lineBuffer.length == 0) {
      return _finishFrame();
    }

    _consumeLine(_lineBuffer.toString());
    _lineBuffer.clear();
    return null;
  }

  void _consumeLine(String line) {
    if (!line.startsWith('data:')) {
      return;
    }

    if (_frameHasDataLine) {
      _dataBuffer.write('\n');
    }
    _dataBuffer.write(line.substring(5).trimLeft());
    _frameHasDataLine = true;
  }

  String? _finishFrame() {
    if (!_frameHasDataLine) {
      return null;
    }

    final payload = _dataBuffer.toString();
    _dataBuffer.clear();
    _frameHasDataLine = false;
    if (payload.isEmpty) {
      return null;
    }
    return payload;
  }
}

const int _lineFeed = 0x0A;
const int _carriageReturn = 0x0D;

OpenWebUIEventUpdate? _eventUpdateFromMap(Map<dynamic, dynamic> raw) {
  final type = raw['type']?.toString();
  if (type == null || type.isEmpty || type.startsWith('response.')) {
    return null;
  }

  final data = raw.containsKey('data')
      ? raw['data']
      : raw.entries
            .where((entry) => entry.key?.toString() != 'type')
            .fold<Map<String, dynamic>>(<String, dynamic>{}, (map, entry) {
              map[entry.key.toString()] = entry.value;
              return map;
            });
  return OpenWebUIEventUpdate(type: type, data: data);
}

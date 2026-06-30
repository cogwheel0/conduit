import 'dart:async';
import 'dart:convert';

/// Reusable HTML escaper for attribute and body text in serialized output.
const HtmlEscape _outputHtmlEscape = HtmlEscape();

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
  const OpenWebUIOutputUpdate(this.output);

  /// List of output item maps.
  final List<dynamic> output;
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

  // Structured output items from the backend middleware.
  final output = parsed['output'];
  if (output is List && output.isNotEmpty) {
    yield OpenWebUIOutputUpdate(output);
  }

  final choices = parsed['choices'];
  if (choices is! List || choices.isEmpty) return;

  final firstChoice = choices.first;
  if (firstChoice is! Map<String, dynamic>) return;

  final delta = firstChoice['delta'];
  if (delta is! Map<String, dynamic>) return;

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

/// Serializes OpenWebUI OR-aligned output items into a visible HTML string.
///
/// Mirrors the upstream `serialize_output` contract that Open WebUI used to
/// emit as the `content` field on `chat:completion` socket deltas. Newer
/// servers emit only the structured `output` list (no `content` string), so
/// callers must serialize it client-side to render assistant text, reasoning,
/// and tool-call blocks.
///
/// Supported item types:
/// - `message`: concatenates `content[].text` for `text`/`output_text` parts.
/// - `reasoning`: renders a `<details type="reasoning">` block matching the
///   shape produced by `streaming_helper._buildStreamingReasoningDetails` so
///   existing reasoning parsers keep working.
/// - `function_call`: renders a `<details type="tool_calls">` block, paired
///   with any matching `function_call_output` by `call_id`.
/// - `function_call_output`: skipped (consumed inline with its call).
/// - `code_interpreter`: renders a `<details type="code_interpreter">` block.
String serializeOpenWebUIOutput(List<Map<String, dynamic>> output) {
  if (output.isEmpty) return '';

  // First pass: index function_call_output items by call_id for pairing.
  final toolOutputs = <String, Map<String, dynamic>>{};
  for (final item in output) {
    if (item['type']?.toString() == 'function_call_output') {
      final callId = item['call_id']?.toString();
      if (callId != null && callId.isNotEmpty) {
        toolOutputs[callId] = item;
      }
    }
  }

  final parts = <String>[];
  for (var index = 0; index < output.length; index++) {
    final item = output[index];
    final itemType = item['type']?.toString() ?? '';

    if (itemType == 'message') {
      final content = item['content'];
      if (content is List) {
        for (final part in content) {
          if (part is Map) {
            final partType = part['type']?.toString();
            if (partType == 'text' || partType == 'output_text') {
              final text = part['text']?.toString().trim() ?? '';
              if (text.isNotEmpty) {
                parts.add(text);
              }
            }
          }
        }
      }
    } else if (itemType == 'reasoning') {
      final sourceList = item['summary'] is List
          ? item['summary'] as List
          : (item['content'] is List ? item['content'] as List : const []);
      final reasoningParts = <String>[];
      for (final part in sourceList) {
        if (part is Map) {
          final text = part['text']?.toString();
          if (text != null && text.isNotEmpty) {
            reasoningParts.add(text);
          }
        }
      }
      final reasoningContent = reasoningParts.join().trim();
      if (reasoningContent.isNotEmpty) {
        final duration = item['duration']?.toString();
        final status = item['status']?.toString();
        final isLastItem = index == output.length - 1;
        final done = status == 'completed' || duration != null || !isLastItem;
        final escapedDisplay = _outputHtmlEscape.convert(
          LineSplitter.split(reasoningContent)
              .map((line) => line.startsWith('>') ? line : '> $line')
              .join('\n'),
        );
        if (done) {
          final dur = duration ?? '0';
          parts.add(
            '<details type="reasoning" done="true" duration="$dur">\n'
            '<summary>Thought for $dur seconds</summary>\n'
            '$escapedDisplay\n'
            '</details>',
          );
        } else {
          parts.add(
            '<details type="reasoning" done="false">\n'
            '<summary>Thinking…</summary>\n'
            '$escapedDisplay\n'
            '</details>',
          );
        }
      }
    } else if (itemType == 'function_call') {
      final callId = item['call_id']?.toString() ?? '';
      final name = item['name']?.toString() ?? '';
      final arguments = item['arguments'] ?? '';
      final escapedArgs = _outputHtmlEscape.convert(jsonEncode(arguments));
      final resultItem = toolOutputs[callId];
      if (resultItem != null) {
        final resultParts = <String>[];
        final resultOutput = resultItem['output'];
        if (resultOutput is List) {
          for (final out in resultOutput) {
            if (out is Map) {
              final text = out['text'];
              if (text != null) {
                resultParts.add(
                  text is String ? text : text.toString(),
                );
              }
            }
          }
        } else if (resultOutput is String) {
          resultParts.add(resultOutput);
        }
        final resultText = resultParts.join();
        final escapedResult = _outputHtmlEscape.convert(
          jsonEncode(resultText),
        );
        final files = resultItem['files'];
        final escapedFiles =
            files == null ? '' : _outputHtmlEscape.convert(jsonEncode(files));
        final embeds = resultItem['embeds'];
        final escapedEmbeds =
            embeds == null ? '' : _outputHtmlEscape.convert(jsonEncode(embeds));
        parts.add(
          '<details type="tool_calls" done="true" id="$callId" name="$name" arguments="$escapedArgs" files="$escapedFiles" embeds="$escapedEmbeds">\n'
          '<summary>Tool Executed</summary>\n'
          '$escapedResult\n'
          '</details>',
        );
      } else {
        parts.add(
          '<details type="tool_calls" done="false" id="$callId" name="$name" arguments="$escapedArgs">\n'
          '<summary>Executing...</summary>\n'
          '</details>',
        );
      }
    } else if (itemType == 'function_call_output') {
      // Consumed inline with its function_call above.
      continue;
    } else if (itemType == 'code_interpreter') {
      final status = item['status']?.toString() ?? 'in_progress';
      final duration = item['duration']?.toString();
      final isLastItem = index == output.length - 1;
      final done = status == 'completed' ||
          status == 'failed' ||
          status == 'incomplete' ||
          duration != null ||
          !isLastItem;
      final code = item['code']?.toString() ?? '';
      final lang = item['language']?.toString() ?? '';
      final display = code.isEmpty ? '' : '```$lang\n$code\n```';
      final ciOutput = item['output'];
      String outputAttr = '';
      if (ciOutput != null) {
        final outputJson = ciOutput is Map
            ? jsonEncode(ciOutput)
            : jsonEncode({'result': ciOutput.toString()});
        outputAttr = ' output="${_outputHtmlEscape.convert(outputJson)}"';
      }
      if (done) {
        final dur = duration ?? '0';
        parts.add(
          '<details type="code_interpreter" done="true" duration="$dur"$outputAttr>\n'
          '<summary>Analyzed</summary>\n'
          '$display\n'
          '</details>',
        );
      } else {
        parts.add(
          '<details type="code_interpreter" done="false"$outputAttr>\n'
          '<summary>Analyzing…</summary>\n'
          '$display\n'
          '</details>',
        );
      }
    }
  }

  return parts.join('\n').trim();
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

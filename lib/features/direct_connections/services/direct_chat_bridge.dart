import '../../../core/models/chat_message.dart';
import '../../../core/services/direct_replay_output.dart';
import '../../../core/services/semantic_message_builder.dart';
import '../../../core/utils/tool_calls_parser.dart';
import '../models/direct_completion.dart';
import 'direct_local_document_service.dart';
import 'ollama_cloud_tools.dart';

const String kDirectTransport = kConduitDirectTransport;
const String kDirectRawAssistantContentMetadataKey =
    kConduitDirectRawAssistantContentMetadataKey;
const int kDirectMaxImages = 4;
const int kDirectMaxDecodedImageBytes = 20 * 1024 * 1024;
const int _kDirectMaxWebSources = kOllamaCloudMaxSearchResults;
const int _kDirectMaxWebSourceTitleCharacters = 2048;
const int _kDirectMaxWebSourceSnippetCharacters = 2048;

final RegExp _directOpenWebUiFileReferencePattern = RegExp(
  r'/api/v1/files/([^/]+)(?:/content)?/?$',
);

typedef DirectImageResolver =
    Future<String?> Function(String fileId, int maxDecodedBytes);

final class DirectChatInputException implements Exception {
  const DirectChatInputException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Prepends the conversation-level system prompt exactly once for direct
/// sends and regenerations. The synthetic message exists only in the provider
/// request and is never persisted into chat history.
List<ChatMessage> withDirectConversationSystemPrompt({
  required Iterable<ChatMessage> messages,
  required String? systemPrompt,
}) {
  final result = List<ChatMessage>.from(messages, growable: true);
  final prompt = systemPrompt?.trim() ?? '';
  if (prompt.isEmpty || result.any((message) => message.role == 'system')) {
    return List.unmodifiable(result);
  }
  result.insert(
    0,
    ChatMessage(
      id: 'direct-conversation-system-prompt',
      role: 'system',
      content: prompt,
      timestamp: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    ),
  );
  return List.unmodifiable(result);
}

/// Returns one persisted message's text for an outbound provider request.
///
/// Completed direct assistants can have an app-owned output mirror (or legacy
/// raw metadata fallback) because visible [ChatMessage.content] is escaped for
/// presentation. Every other message retains the established sanitization
/// path.
String outboundProviderReplayText(ChatMessage message) {
  final hasTerminalDirectProvenance =
      message.role.trim().toLowerCase() == 'assistant' &&
      !message.isStreaming &&
      message.metadata?['transport'] == kDirectTransport;
  if (hasTerminalDirectProvenance) {
    final output = message.output;
    if (output != null && output.isNotEmpty) {
      final mirror = parseConduitDirectReplayOutput(output);
      if (mirror != null) {
        return mirror.text;
      }

      // Open WebUI's Continue Response flow replaces the existing assistant's
      // output in place. A non-empty replacement that is no longer our exact
      // mirror invalidates the previously persisted raw replay metadata.
      return ToolCallsParser.sanitizeForApi(message.content);
    }

    final trustedRawAssistantContent =
        message.metadata?[kDirectRawAssistantContentMetadataKey];
    if (trustedRawAssistantContent is String) {
      // Direct assistant text is presentation-escaped before it reaches the
      // Markdown renderer. Replay the provider-owned source captured at that
      // boundary instead of decoding arbitrary persisted HTML entities. The
      // role, transport, and terminal-state checks keep this narrow channel
      // from changing legacy/OpenWebUI/user content semantics.
      return trustedRawAssistantContent;
    }
  }
  return ToolCallsParser.sanitizeForApi(message.content);
}

/// Creates the persisted Responses output mirror consumed by Open WebUI when
/// it reconstructs provider history from its own database.
List<Map<String, dynamic>>? directProviderReplayOutput({
  required String assistantMessageId,
  required String rawContent,
  bool useIncompleteAnswerSentinel = false,
}) => buildConduitDirectReplayOutput(
  assistantMessageId: assistantMessageId,
  rawContent: rawContent,
  useIncompleteAnswerSentinel: useIncompleteAnswerSentinel,
);

/// Converts Conduit's persisted message shape into the small protocol-neutral
/// request understood by direct provider adapters.
///
/// Open WebUI file ids are resolved by the caller through an authenticated API
/// client and returned as data URLs. Direct adapters never receive Open WebUI
/// credentials and never fetch those protected URLs themselves.
Future<List<DirectChatMessage>> buildDirectChatMessages({
  required Iterable<ChatMessage> messages,
  DirectImageResolver? resolveImage,
  List<int>? directDocumentVerificationKey,
  int maxImages = kDirectMaxImages,
  int maxDecodedImageBytes = kDirectMaxDecodedImageBytes,
}) async {
  final result = <DirectChatMessage>[];
  var imageCount = 0;
  var decodedImageBytes = 0;

  Future<void> addImage(
    List<DirectContentPart> parts,
    String candidate, {
    required Set<String> seenImages,
    required Set<String> seenImageReferences,
  }) async {
    var value = _normalizeDirectFileReference(candidate);
    // Every caller has already classified this value as an image. Missing or
    // inaccessible image data must fail closed instead of changing the prompt.
    if (value.isEmpty) {
      throw const DirectChatInputException(
        'This direct model does not support this attachment.',
      );
    }
    if (!seenImageReferences.add(value)) return;
    if (!value.startsWith('data:image/')) {
      final resolver = resolveImage;
      if (resolver == null) {
        throw const DirectChatInputException(
          'This direct model does not support this attachment.',
        );
      }
      final remainingBytes = maxDecodedImageBytes - decodedImageBytes;
      if (remainingBytes <= 0) {
        throw DirectChatInputException(
          'Direct chat images must be '
          '${_formatDirectByteLimit(maxDecodedImageBytes)} or less in total.',
        );
      }
      value = (await resolver(value, remainingBytes))?.trim() ?? '';
      if (value.isEmpty || !value.startsWith('data:image/')) {
        throw const DirectChatInputException(
          'This direct model does not support this attachment.',
        );
      }
    }
    if (!seenImages.add(value)) return;

    final bytes = decodedImageByteLength(
      value,
      maxDecodedBytes: maxDecodedImageBytes - decodedImageBytes,
      tooLargeMessage:
          'Direct chat images must be '
          '${_formatDirectByteLimit(maxDecodedImageBytes)} or less in total.',
    );
    imageCount++;
    decodedImageBytes += bytes;
    if (imageCount > maxImages) {
      throw DirectChatInputException(
        'Direct chats support up to $maxImages '
        '${maxImages == 1 ? 'image' : 'images'} per request.',
      );
    }
    if (decodedImageBytes > maxDecodedImageBytes) {
      throw DirectChatInputException(
        'Direct chat images must be '
        '${_formatDirectByteLimit(maxDecodedImageBytes)} or less in total.',
      );
    }
    parts.add(DirectImagePart(value));
  }

  for (final message in messages) {
    if (message.metadata?['archivedVariant'] == true) continue;
    final role = message.role.trim().toLowerCase();
    if (role != 'system' && role != 'user' && role != 'assistant') continue;

    final parts = <DirectContentPart>[];
    final seenImages = <String>{};
    final seenImageReferences = <String>{};
    var text = outboundProviderReplayText(message);
    if (role == 'user' && directDocumentVerificationKey != null) {
      final documents = <DirectPreparedDocument>[];
      for (final file in message.files ?? const <Map<String, dynamic>>[]) {
        final document = trustedDirectDocumentFromDescriptor(
          file,
          verificationKey: directDocumentVerificationKey,
        );
        if (document != null) documents.add(document);
      }
      if (documents.length > kDirectMaxLocalDocuments) {
        throw const DirectChatInputException(
          'Direct chats support up to 4 local documents per message.',
        );
      }
      final documentCharacters = documents.fold<int>(
        0,
        (total, document) => total + document.extractedText.runes.length,
      );
      if (documentCharacters > kDirectMaxLocalDocumentCharacters) {
        throw const DirectChatInputException(
          'The local document text exceeds the Direct prompt limit.',
        );
      }
      if (documents.isNotEmpty) {
        final references = documents
            .map((document) => document.renderForPrompt())
            .join('\n\n');
        text = text.trim().isEmpty ? references : '$text\n\n$references';
      }
    }
    if (text.trim().isNotEmpty) parts.add(DirectTextPart(text));

    // Provider image inputs belong to user prompt messages. Persisted
    // OpenWebUI assistant/system messages may still carry generated-image
    // metadata, but replaying that metadata as model input produces invalid
    // Chat Completions, Responses, and Ollama request shapes.
    if (role == 'user') {
      final files = message.files ?? const <Map<String, dynamic>>[];
      final explicitNonImageReferences = <String>{};
      for (final file in files) {
        if (!_isExplicitNonImageFile(file)) continue;
        for (final key in const ['url', 'id', 'data']) {
          final reference = _normalizeDirectFileReference(
            file[key]?.toString() ?? '',
          );
          if (reference.isNotEmpty) explicitNonImageReferences.add(reference);
        }
      }
      for (final attachment in message.attachmentIds ?? const <String>[]) {
        if (explicitNonImageReferences.contains(
          _normalizeDirectFileReference(attachment),
        )) {
          continue;
        }
        await addImage(
          parts,
          attachment,
          seenImages: seenImages,
          seenImageReferences: seenImageReferences,
        );
      }
      for (final file in files) {
        if (!_isDirectImageFile(file)) continue;
        final value = _firstDirectFileReference(file);
        await addImage(
          parts,
          value,
          seenImages: seenImages,
          seenImageReferences: seenImageReferences,
        );
      }
    }

    if (parts.isNotEmpty) {
      result.add(DirectChatMessage(role: role, parts: parts));
    }
  }
  return List.unmodifiable(result);
}

bool _isDirectImageFile(Map<String, dynamic> file) {
  final type = file['type']?.toString().trim().toLowerCase() ?? '';
  final contentType =
      file['content_type']?.toString().trim().toLowerCase() ?? '';
  return type == 'image' || contentType.startsWith('image/');
}

bool _isExplicitNonImageFile(Map<String, dynamic> file) {
  final type = file['type']?.toString().trim() ?? '';
  final contentType = file['content_type']?.toString().trim() ?? '';
  return (type.isNotEmpty || contentType.isNotEmpty) &&
      !_isDirectImageFile(file);
}

String _firstDirectFileReference(Map<String, dynamic> file) {
  for (final key in const ['url', 'id', 'data']) {
    final reference = file[key]?.toString().trim() ?? '';
    if (reference.isNotEmpty) return reference;
  }
  return '';
}

String _normalizeDirectFileReference(String candidate) {
  final value = candidate.trim();
  if (!value.contains('/api/v1/files/')) return value;
  final path = Uri.tryParse(value)?.path ?? value;
  final match = _directOpenWebUiFileReferencePattern.firstMatch(path);
  return match?.group(1) ?? value;
}

String _formatDirectByteLimit(int bytes) {
  const kibibyte = 1024;
  const mebibyte = 1024 * 1024;
  if (bytes >= mebibyte && bytes % mebibyte == 0) {
    return '${bytes ~/ mebibyte} MB';
  }
  if (bytes >= kibibyte && bytes % kibibyte == 0) {
    return '${bytes ~/ kibibyte} KB';
  }
  return '$bytes ${bytes == 1 ? 'byte' : 'bytes'}';
}

/// Returns the decoded byte size without allocating or copying the payload.
int decodedImageByteLength(
  String dataUrl, {
  int maxDecodedBytes = kDirectMaxDecodedImageBytes,
  String tooLargeMessage = 'A direct image is too large.',
}) {
  if (maxDecodedBytes <= 0) {
    throw DirectChatInputException(tooLargeMessage);
  }
  const maxMetadataCharacters = 256;
  final maxPayloadCharacters = ((maxDecodedBytes + 2) ~/ 3) * 4;
  if (dataUrl.length > maxMetadataCharacters + 1 + maxPayloadCharacters) {
    throw DirectChatInputException(tooLargeMessage);
  }
  final comma = dataUrl.indexOf(',');
  if (!dataUrl.startsWith('data:image/') ||
      comma < 0 ||
      comma > maxMetadataCharacters) {
    throw const DirectChatInputException('A direct image is not a data URL.');
  }
  final metadata = dataUrl.substring(0, comma).toLowerCase();
  if (!metadata.endsWith(';base64')) {
    throw const DirectChatInputException(
      'Direct images must use base64 data URLs.',
    );
  }
  final payloadStart = comma + 1;
  final payloadLength = dataUrl.length - payloadStart;
  if (payloadLength <= 0) {
    throw const DirectChatInputException('A direct image is empty.');
  }
  if (payloadLength > maxPayloadCharacters || payloadLength % 4 == 1) {
    throw DirectChatInputException(tooLargeMessage);
  }
  var padding = 0;
  for (var index = payloadStart; index < dataUrl.length; index++) {
    final code = dataUrl.codeUnitAt(index);
    final isAlphabet =
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A) ||
        (code >= 0x30 && code <= 0x39) ||
        code == 0x2B ||
        code == 0x2F;
    if (isAlphabet && padding == 0) continue;
    if (code == 0x3D && index >= dataUrl.length - 2) {
      padding++;
      continue;
    }
    throw const DirectChatInputException('A direct image is invalid.');
  }
  if (padding > 0 && payloadLength % 4 != 0) {
    throw const DirectChatInputException('A direct image is invalid.');
  }
  final decodedBytes = (payloadLength * 3 ~/ 4) - padding;
  if (decodedBytes > maxDecodedBytes) {
    throw DirectChatInputException(tooLargeMessage);
  }
  return decodedBytes;
}

/// A bounded-cost update for projecting a direct stream into the active chat.
sealed class DirectStreamingProjection {
  const DirectStreamingProjection();
}

/// Appends answer text without rebuilding text that is already visible.
final class DirectStreamingAppend extends DirectStreamingProjection {
  const DirectStreamingAppend(this.content);

  final String content;
}

/// Replaces the visible snapshot when an append cannot preserve its structure.
final class DirectStreamingReplace extends DirectStreamingProjection {
  const DirectStreamingReplace(this.content);

  final String content;
}

/// Accumulates normalized provider events into the ChatMessage representation
/// used by Conduit's renderer.
final class DirectStreamingAccumulator {
  DirectStreamingAccumulator() : _reasoningWatch = Stopwatch();

  final StringBuffer _text = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final List<_DirectToolExecution> _toolExecutions = [];
  final List<ChatSourceReference> _sources = [];
  final Map<String, int> _sourceIndexByUrl = {};
  final Stopwatch _reasoningWatch;
  Map<String, dynamic>? _usage;
  DirectStreamError? _error;
  bool _hasUsableOutput = false;
  bool _hasStreamingProjection = false;
  bool _hasReasoningProjection = false;
  bool _reasoningHasVisibleText = false;
  bool _reasoningProjectionIsVisible = false;
  bool _answerAppendIsPlain = true;
  int _projectedTextLength = 0;
  int _projectedReasoningLength = 0;
  int _nextFullProjectionLength = 1;
  int _fullProjectionCount = 0;
  int _appendProjectionCount = 0;
  int _fullProjectionCharacterCount = 0;

  String get text => _text.toString();
  String get reasoning => _reasoning.toString();
  Map<String, dynamic>? get usage => _usage;
  DirectStreamError? get error => _error;
  bool get hasUsableOutput => _hasUsableOutput;
  List<ChatSourceReference> get sources => List.unmodifiable(_sources);
  List<Map<String, dynamic>> get toolOutput {
    final output = <Map<String, dynamic>>[];
    for (final execution in _toolExecutions) {
      output.add(
        Map<String, dynamic>.unmodifiable({
          'type': 'function_call',
          'id': execution.id,
          'call_id': execution.id,
          'name': execution.name,
          'arguments': execution.arguments,
          'status': execution.done ? 'completed' : 'in_progress',
        }),
      );
      if (execution.done) {
        output.add(
          Map<String, dynamic>.unmodifiable({
            'type': 'function_call_output',
            'call_id': execution.id,
            'output': execution.result,
            if (execution.isError) 'error': true,
          }),
        );
      }
    }
    return List.unmodifiable(output);
  }

  /// Exposed for focused performance regressions. These count projection work,
  /// not provider events or the one final authoritative render.
  int get fullProjectionCount => _fullProjectionCount;
  int get appendProjectionCount => _appendProjectionCount;
  int get fullProjectionCharacterCount => _fullProjectionCharacterCount;

  bool apply(DirectStreamEvent event) {
    switch (event) {
      case DirectContentDelta():
        _text.write(event.content);
        // Fragment-wise HTML escaping is compositional only outside Markdown
        // code. Once a possible code delimiter appears, authoritative full
        // projections preserve code exactly and keep split semantic tags from
        // being interpreted as Conduit-owned UI.
        if (event.content.contains('`') || event.content.contains('~')) {
          _answerAppendIsPlain = false;
        }
        if (event.content.trim().isNotEmpty) _hasUsableOutput = true;
        return event.content.isNotEmpty;
      case DirectReasoningDelta():
        if (!_reasoningWatch.isRunning) _reasoningWatch.start();
        _reasoning.write(event.content);
        if (!_reasoningHasVisibleText && event.content.trim().isNotEmpty) {
          _reasoningHasVisibleText = true;
        }
        if (event.content.trim().isNotEmpty) _hasUsableOutput = true;
        return event.content.isNotEmpty;
      case DirectUsageUpdate():
        _usage = Map<String, dynamic>.from(event.usage);
        return true;
      case DirectToolCallStarted():
        _toolExecutions.add(
          _DirectToolExecution(
            id: event.id,
            name: event.name,
            arguments: event.arguments,
          ),
        );
        _hasUsableOutput = true;
        return true;
      case DirectToolCallCompleted():
        final index = _toolExecutions.lastIndexWhere(
          (execution) => execution.id == event.id,
        );
        final completed = _DirectToolExecution(
          id: event.id,
          name: event.name,
          arguments: event.arguments,
          result: event.result,
          done: true,
          isError: event.isError,
        );
        if (index < 0) {
          _toolExecutions.add(completed);
        } else {
          _toolExecutions[index] = completed;
        }
        if (!event.isError) {
          _applyWebToolSources(event);
        }
        _hasUsableOutput = true;
        return true;
      case DirectStreamError():
        _error = event;
        return true;
      case DirectStreamDone():
        if (_reasoningWatch.isRunning) _reasoningWatch.stop();
        return true;
    }
  }

  /// Returns the smallest safe UI update after [event] has been [apply]ed.
  ///
  /// Answer text is appended while the active assistant remains the tail.
  /// Reasoning lives before that text inside a semantic details block, so it
  /// cannot be appended without corrupting the markup. Those replacements are
  /// emitted only when the accumulated payload crosses a geometric threshold.
  /// The total number of characters materialized by normal replacements is
  /// therefore linear in the final payload size rather than quadratic in the
  /// provider event count.
  DirectStreamingProjection? projectStreamingEvent(
    DirectStreamEvent event, {
    required bool forceReplace,
    required bool canAppend,
  }) {
    final logicalLength =
        _text.length + _reasoning.length + (_toolExecutions.length * 64);
    if (forceReplace && logicalLength > 0) {
      return _fullStreamingProjection(logicalLength);
    }

    switch (event) {
      case DirectContentDelta():
        final content = event.content;
        if (content.isEmpty) return null;
        final textLengthBeforeEvent = _text.length - content.length;
        final appendIsSynchronized =
            _hasStreamingProjection &&
            _projectedTextLength == textLengthBeforeEvent &&
            _projectedReasoningLength == _reasoning.length;
        if (canAppend && _answerAppendIsPlain && appendIsSynchronized) {
          final escapedContent = renderSemanticPlainTextFragment(content);
          final appendContent =
              _projectedTextLength == 0 && _reasoningProjectionIsVisible
              ? '\n$escapedContent'
              : escapedContent;
          _projectedTextLength = _text.length;
          _appendProjectionCount += 1;
          return DirectStreamingAppend(appendContent);
        }
        if (!_hasStreamingProjection ||
            (canAppend &&
                (_answerAppendIsPlain
                    ? !appendIsSynchronized
                    : logicalLength >= _nextFullProjectionLength)) ||
            logicalLength >= _nextFullProjectionLength) {
          return _fullStreamingProjection(logicalLength);
        }
        return null;
      case DirectReasoningDelta():
        if (event.content.isEmpty) return null;
        if (!_hasStreamingProjection ||
            !_hasReasoningProjection ||
            (_reasoningHasVisibleText && !_reasoningProjectionIsVisible) ||
            logicalLength >= _nextFullProjectionLength) {
          return _fullStreamingProjection(logicalLength);
        }
        return null;
      case DirectToolCallStarted() || DirectToolCallCompleted():
        return _fullStreamingProjection(logicalLength);
      case DirectUsageUpdate() || DirectStreamError() || DirectStreamDone():
        return null;
    }
  }

  DirectStreamingReplace _fullStreamingProjection(int logicalLength) {
    final content = render(done: false);
    _hasStreamingProjection = true;
    _hasReasoningProjection = _reasoning.isNotEmpty;
    _reasoningProjectionIsVisible = _reasoningHasVisibleText;
    _projectedTextLength = _text.length;
    _projectedReasoningLength = _reasoning.length;
    _nextFullProjectionLength = logicalLength == 0 ? 1 : logicalLength * 2;
    _fullProjectionCount += 1;
    _fullProjectionCharacterCount += content.length;
    return DirectStreamingReplace(content);
  }

  String render({required bool done}) {
    final blocks = <String>[];
    final reasoningText = _reasoning.toString().trim();
    if (reasoningText.isNotEmpty) {
      blocks.add(
        renderSemanticMessageBlocks([
          SemanticDetailsBlock.reasoning(
            text: reasoningText,
            done: done,
            duration: _reasoningWatch.elapsed.inSeconds.toString(),
          ),
        ]),
      );
    }
    for (final execution in _toolExecutions) {
      blocks.add(
        renderSemanticMessageBlocks([
          SemanticDetailsBlock.toolCall(
            id: execution.id,
            name: execution.name,
            arguments: execution.arguments,
            done: execution.done,
            result: execution.result,
            isError: execution.isError,
          ),
        ]),
      );
    }
    final answerText = _text.toString();
    if (answerText.isNotEmpty) {
      blocks.add(
        answerText.trim().isEmpty || (!done && _answerAppendIsPlain)
            ? renderSemanticPlainTextFragment(answerText)
            : renderSemanticMessageBlocks([SemanticTextBlock(answerText)]),
      );
    }
    return blocks.where((block) => block.isNotEmpty).join('\n');
  }

  void _applyWebToolSources(DirectToolCallCompleted event) {
    switch (event.name.trim()) {
      case 'web_search':
        _applyWebSearchSources(event.result);
      case 'web_fetch':
        _applyWebFetchSource(event.arguments, event.result);
    }
  }

  void _applyWebSearchSources(Object? value) {
    final result = _directStringKeyedMap(value);
    final rawResults = result?['results'];
    if (rawResults is! List) return;

    for (final rawResult in rawResults) {
      if (_sources.length >= _kDirectMaxWebSources) break;
      final result = _directStringKeyedMap(rawResult);
      if (result == null) continue;
      final url = _normalizeDirectWebSourceUrl(result['url']);
      if (url == null) continue;

      final existingIndex = _sourceIndexByUrl[url];
      final title = _boundedDirectSourceText(
        result['title'],
        _kDirectMaxWebSourceTitleCharacters,
      );
      final snippet = _boundedDirectSourceText(
        result['content'],
        _kDirectMaxWebSourceSnippetCharacters,
      );
      if (existingIndex != null) {
        final existing = _sources[existingIndex];
        _sources[existingIndex] = existing.copyWith(
          title: _preferExistingDirectSourceText(existing.title, title),
          snippet: _preferExistingDirectSourceText(existing.snippet, snippet),
        );
        continue;
      }

      _sourceIndexByUrl[url] = _sources.length;
      _sources.add(
        ChatSourceReference(
          title: title,
          url: url,
          snippet: snippet,
          type: 'web',
        ),
      );
    }
  }

  void _applyWebFetchSource(Map<String, dynamic> arguments, Object? value) {
    final url = _normalizeDirectWebSourceUrl(arguments['url']);
    final sourceIndex = url == null ? null : _sourceIndexByUrl[url];
    final result = _directStringKeyedMap(value);
    if (sourceIndex == null || result == null) return;

    final title = _boundedDirectSourceText(
      result['title'],
      _kDirectMaxWebSourceTitleCharacters,
    );
    final snippet = _boundedDirectSourceText(
      result['content'],
      _kDirectMaxWebSourceSnippetCharacters,
    );
    final existing = _sources[sourceIndex];
    _sources[sourceIndex] = existing.copyWith(
      title: title ?? existing.title,
      snippet: snippet ?? existing.snippet,
    );
  }
}

Map<String, dynamic>? _directStringKeyedMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is! Map) return null;
  return <String, dynamic>{
    for (final entry in value.entries) entry.key.toString(): entry.value,
  };
}

String? _normalizeDirectWebSourceUrl(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  try {
    return normalizeOllamaCloudPublicWebUrl(value.trim());
  } on FormatException {
    return null;
  }
}

String? _boundedDirectSourceText(Object? value, int maxCharacters) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  return normalized.length <= maxCharacters
      ? normalized
      : normalized.substring(0, maxCharacters);
}

String? _preferExistingDirectSourceText(String? existing, String? candidate) {
  final normalizedExisting = existing?.trim();
  return normalizedExisting == null || normalizedExisting.isEmpty
      ? candidate
      : existing;
}

final class _DirectToolExecution {
  _DirectToolExecution({
    required this.id,
    required this.name,
    required Map<String, dynamic> arguments,
    Object? result,
    this.done = false,
    this.isError = false,
  }) : arguments = _freezeDirectToolMap(arguments),
       result = _freezeDirectToolJson(result);

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final Object? result;
  final bool done;
  final bool isError;
}

Map<String, dynamic> _freezeDirectToolMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        entry.key: _freezeDirectToolJson(entry.value),
    });

Object? _freezeDirectToolJson(Object? value) {
  if (value is Map<String, dynamic>) {
    return _freezeDirectToolMap(value);
  }
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        entry.key.toString(): _freezeDirectToolJson(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeDirectToolJson));
  }
  return value;
}

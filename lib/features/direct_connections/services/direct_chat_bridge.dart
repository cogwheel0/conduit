import 'dart:convert';

import '../../../core/models/chat_message.dart';
import '../../../core/services/semantic_message_builder.dart';
import '../../../core/utils/tool_calls_parser.dart';
import '../models/direct_completion.dart';

const String kDirectTransport = 'direct';
const int kDirectMaxImages = 4;
const int kDirectMaxDecodedImageBytes = 20 * 1024 * 1024;

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

/// Converts Conduit's persisted message shape into the small protocol-neutral
/// request understood by direct provider adapters.
///
/// Open WebUI file ids are resolved by the caller through an authenticated API
/// client and returned as data URLs. Direct adapters never receive Open WebUI
/// credentials and never fetch those protected URLs themselves.
Future<List<DirectChatMessage>> buildDirectChatMessages({
  required Iterable<ChatMessage> messages,
  DirectImageResolver? resolveImage,
  int maxImages = kDirectMaxImages,
  int maxDecodedImageBytes = kDirectMaxDecodedImageBytes,
}) async {
  final result = <DirectChatMessage>[];
  final seenImages = <String>{};
  final seenImageReferences = <String>{};
  var imageCount = 0;
  var decodedImageBytes = 0;

  Future<void> addImage(List<DirectContentPart> parts, String candidate) async {
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

    final bytes = decodedImageByteLength(value);
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
    final text = ToolCallsParser.sanitizeForApi(message.content).trim();
    if (text.isNotEmpty) parts.add(DirectTextPart(text));

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
      await addImage(parts, attachment);
    }
    for (final file in files) {
      if (!_isDirectImageFile(file)) continue;
      final value = _firstDirectFileReference(file);
      await addImage(parts, value);
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

/// Returns the decoded byte size without allocating the decoded image.
int decodedImageByteLength(String dataUrl) {
  final comma = dataUrl.indexOf(',');
  if (!dataUrl.startsWith('data:image/') || comma < 0) {
    throw const DirectChatInputException('A direct image is not a data URL.');
  }
  final metadata = dataUrl.substring(0, comma).toLowerCase();
  if (!metadata.endsWith(';base64')) {
    throw const DirectChatInputException(
      'Direct images must use base64 data URLs.',
    );
  }
  final payload = dataUrl.substring(comma + 1).replaceAll(RegExp(r'\s'), '');
  if (payload.isEmpty) {
    throw const DirectChatInputException('A direct image is empty.');
  }
  try {
    // Validate the alphabet and padding. The arithmetic below avoids keeping a
    // second full image copy in memory merely to enforce the size limit.
    base64.normalize(payload);
  } on FormatException {
    throw const DirectChatInputException('A direct image is invalid.');
  }
  final padding = payload.endsWith('==')
      ? 2
      : payload.endsWith('=')
      ? 1
      : 0;
  return (payload.length * 3 ~/ 4) - padding;
}

/// Accumulates normalized provider events into the ChatMessage representation
/// used by Conduit's renderer.
final class DirectStreamingAccumulator {
  DirectStreamingAccumulator() : _reasoningWatch = Stopwatch();

  final StringBuffer _text = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final Stopwatch _reasoningWatch;
  Map<String, dynamic>? _usage;
  DirectStreamError? _error;

  String get text => _text.toString();
  String get reasoning => _reasoning.toString();
  Map<String, dynamic>? get usage => _usage;
  DirectStreamError? get error => _error;

  bool apply(DirectStreamEvent event) {
    switch (event) {
      case DirectContentDelta():
        _text.write(event.content);
        return event.content.isNotEmpty;
      case DirectReasoningDelta():
        if (!_reasoningWatch.isRunning) _reasoningWatch.start();
        _reasoning.write(event.content);
        return event.content.isNotEmpty;
      case DirectUsageUpdate():
        _usage = Map<String, dynamic>.from(event.usage);
        return true;
      case DirectStreamError():
        _error = event;
        return true;
      case DirectStreamDone():
        if (_reasoningWatch.isRunning) _reasoningWatch.stop();
        return true;
    }
  }

  String render({required bool done}) {
    final blocks = <String>[];
    final reasoningText = reasoning.trim();
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
    if (text.isNotEmpty) blocks.add(text);
    return blocks.where((block) => block.isNotEmpty).join('\n');
  }
}

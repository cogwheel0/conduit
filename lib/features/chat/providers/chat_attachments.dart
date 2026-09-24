part of 'chat_providers.dart';

// Helper function to validate file size
bool validateFileSize(int fileSize, int? maxSizeMB) {
  if (maxSizeMB == null) return true;
  final maxSizeBytes = maxSizeMB * 1024 * 1024;
  return fileSize <= maxSizeBytes;
}

// Helper function to validate file count
bool validateFileCount(int currentCount, int newFilesCount, int? maxCount) {
  if (maxCount == null) return true;
  return (currentCount + newFilesCount) <= maxCount;
}

// Small internal helper to convert a message with attachments into the
// OpenWebUI content payload format (text + image_url + files).
// - Adds text first (if non-empty)
// - Images (base64 or server-stored) go into content array as image_url
// - Non-image files go into files array for RAG/server-side resolution
Future<Map<String, dynamic>> _buildMessagePayloadWithAttachments({
  required dynamic api,
  required String role,
  required String cleanedText,
  required List<String> attachmentIds,
}) async {
  final List<Map<String, dynamic>> contentArray = [];

  if (cleanedText.isNotEmpty) {
    contentArray.add({'type': 'text', 'text': cleanedText});
  }

  // Collect non-image files for the files array
  final allFiles = <Map<String, dynamic>>[];

  for (final attachmentId in attachmentIds) {
    try {
      // Check if this is a base64 data URL (legacy or inline)
      if (attachmentId.startsWith('data:image/')) {
        // Inline image data URL - add directly to content array for LLM vision
        contentArray.add({
          'type': 'image_url',
          'image_url': {'url': attachmentId},
        });
        continue;
      }

      // For server-stored files, fetch info to determine type
      final fileInfo = await api.getFileInfo(attachmentId);
      final fileName = fileInfo['filename'] ?? fileInfo['name'] ?? 'Unknown';
      final fileSize = fileInfo['size'] ?? fileInfo['meta']?['size'];
      final contentType =
          fileInfo['meta']?['content_type'] ?? fileInfo['content_type'] ?? '';

      // Check if this is an image file
      final isImage = contentType.toString().startsWith('image/');

      if (isImage) {
        // Images must be in content array as image_url for LLM vision
        // Fetch the image content from server and convert to base64 data URL
        try {
          final fileContent = await api.getFileContent(attachmentId);
          String dataUrl;
          if (fileContent.startsWith('data:')) {
            dataUrl = fileContent;
          } else {
            // Determine MIME type from content type or file extension
            final mimeType = contentType.isNotEmpty
                ? contentType.toString()
                : _getMimeTypeFromFileName(fileName) ?? 'image/png';
            dataUrl = 'data:$mimeType;base64,$fileContent';
          }
          contentArray.add({
            'type': 'image_url',
            'image_url': {'url': dataUrl},
          });
        } catch (error) {
          // If we can't fetch the image, skip it
        }
      } else {
        // Non-image files go to files array for RAG/server-side processing
        final filePayload = <String, dynamic>{
          'type': 'file',
          'id': attachmentId,
          // OpenWebUI now stores just the file ID, not the full URL path
          'url': attachmentId,
          'name': fileName,
        };
        if (fileSize != null) {
          filePayload['size'] = fileSize;
        }
        allFiles.add(filePayload);
      }
    } catch (_) {
      // Swallow and continue to keep regeneration robust
    }
  }

  final messageMap = <String, dynamic>{
    'role': role,
    'content': contentArray.isNotEmpty ? contentArray : cleanedText,
  };
  if (allFiles.isNotEmpty) {
    messageMap['files'] = allFiles;
  }
  return messageMap;
}

String? _getMimeTypeFromFileName(String fileName) {
  final ext = fileName.toLowerCase().split('.').last;
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'bmp' => 'image/bmp',
    _ => null,
  };
}

@visibleForTesting
String? mimeTypeFromFileNameForTest(String fileName) {
  return _getMimeTypeFromFileName(fileName);
}

List<Map<String, dynamic>> _contextAttachmentsToFiles(
  List<ChatContextAttachment> attachments,
) {
  return attachments.map((attachment) {
    switch (attachment.type) {
      case ChatContextAttachmentType.web:
        // Web pages use type 'text' with file data nested under 'file' key
        return {
          'type': 'text',
          'name': attachment.url ?? attachment.displayName,
          if (attachment.url != null) 'url': attachment.url,
          if (attachment.collectionName != null)
            'collection_name': attachment.collectionName,
          'file': {
            'data': {'content': attachment.content ?? ''},
            'meta': {
              'name': attachment.displayName,
              if (attachment.url != null) 'source': attachment.url,
            },
          },
        };
      case ChatContextAttachmentType.youtube:
        // YouTube uses type 'text' with context 'full' for full transcript
        return {
          'type': 'text',
          'name': attachment.url ?? attachment.displayName,
          if (attachment.url != null) 'url': attachment.url,
          'context': 'full',
          if (attachment.collectionName != null)
            'collection_name': attachment.collectionName,
          'file': {
            'data': {'content': attachment.content ?? ''},
            'meta': {
              'name': attachment.displayName,
              if (attachment.url != null) 'source': attachment.url,
            },
          },
        };
      case ChatContextAttachmentType.knowledge:
        // Knowledge base files use type 'file' with id for lookup
        final map = <String, dynamic>{
          'type': 'file',
          'id': attachment.fileId ?? attachment.id,
          'name': attachment.displayName,
          'knowledge': true,
          if (attachment.collectionName != null)
            'collection_name': attachment.collectionName,
          if (attachment.url != null) 'source': attachment.url,
        };
        return map;
      case ChatContextAttachmentType.note:
        return <String, dynamic>{
          'type': 'note',
          'id': attachment.id,
          'name': attachment.displayName,
          'title': attachment.displayName,
        };
    }
  }).toList();
}

/// Whether a send/regenerate should be blocked given the current backend state.
///
/// A send needs one of: an OpenWebUI [api], reviewer mode, or a Hermes model
/// (which routes to the direct Hermes transport and doesn't use [api]). A null
/// [selectedModel] always blocks. Extracted so the Hermes-only relaxation is
/// unit-testable independent of the large send pipelines.
@visibleForTesting
bool isSendBlocked({
  required bool reviewerMode,
  required Object? api,
  required Model? selectedModel,
  bool hasTrustedDirectBinding = false,
}) {
  if (selectedModel == null) return true;
  if (reviewerMode) return false;
  if (hasReservedDirectIdentity(selectedModel)) {
    return !hasTrustedDirectBinding;
  }
  if (api != null) return false;
  return !isHermesModel(selectedModel) && !hasTrustedDirectBinding;
}

@visibleForTesting
bool isModelCompatibleWithConversation({
  required Conversation? conversation,
  required bool hasTrustedDirectBinding,
}) {
  return !isDirectLocalConversation(conversation) || hasTrustedDirectBinding;
}

/// Enforces provider capabilities at the final dispatch boundary so images
/// already present in history or supplied by a service cannot bypass composer
/// and upload guards.
@visibleForTesting
void ensureDirectMessagesCompatibleWithModel({
  required Model model,
  required Iterable<DirectChatMessage> messages,
}) {
  if (model.isMultimodal == true) return;
  final containsImage = messages.any(
    (message) => message.parts.any((part) => part is DirectImagePart),
  );
  if (containsImage) {
    throw const DirectChatInputException(
      'This direct model does not support image attachments.',
    );
  }
}

/// Raised when a Hermes run would silently discard composer attachments.
class HermesAttachmentsUnsupportedException implements Exception {
  const HermesAttachmentsUnsupportedException([
    this.message =
        'Hermes cannot use this attachment. Select a local image, text file, '
        'or DOCX document instead.',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// Rejects attachment identities that cannot be resolved locally by Conduit.
/// OpenWebUI file/context ids must never leak into the Hermes request.
@visibleForTesting
void ensureHermesSendSupportsAttachments({
  required Model selectedModel,
  required List<String>? attachments,
  required List<ChatContextAttachment> contextAttachments,
}) {
  if (!isHermesModel(selectedModel)) return;
  if (contextAttachments.isNotEmpty) {
    throw const HermesAttachmentsUnsupportedException(
      'Hermes cannot use OpenWebUI context attachments. Remove them or attach '
      'a local document instead.',
    );
  }
  for (final attachment in attachments ?? const <String>[]) {
    if (attachment.startsWith('data:image/') ||
        attachment.startsWith(kHermesLocalDocumentIdPrefix)) {
      continue;
    }
    throw const HermesAttachmentsUnsupportedException();
  }
}

final class _PreparedHermesTurn {
  const _PreparedHermesTurn({
    required this.input,
    required this.imageUrls,
    required this.files,
    required this.localDocumentPromptText,
    required this.localDocumentEnvelopes,
  });

  final HermesChatInput input;
  final List<String> imageUrls;
  final List<Map<String, dynamic>> files;
  final String? localDocumentPromptText;
  final List<String> localDocumentEnvelopes;
}

final class _PreparedDirectDocuments {
  const _PreparedDirectDocuments({
    required this.files,
    required this.attachmentIds,
    required this.ephemeralFilePartsByAttachmentId,
  });

  final List<Map<String, dynamic>> files;
  final Set<String> attachmentIds;
  final Map<String, DirectFilePart> ephemeralFilePartsByAttachmentId;
}

const int _kDirectMaxAggregatePdfBytes = 2 * kDirectMaxLocalDocumentBytes;

Future<_PreparedDirectDocuments> _prepareDirectDocuments(
  dynamic ref, {
  required List<String>? attachmentIds,
  required bool supportsOpenRouterPdfInputs,
}) async {
  final attachedStates =
      ref.read(attachedFilesProvider) as List<FileUploadState>;
  final stateById = <String, FileUploadState>{
    for (final state in attachedStates)
      if (state.fileId != null) state.fileId!: state,
  };
  final references = <String>{};
  final sources = <DirectLocalDocumentSource>[];
  final pdfStates = <String, FileUploadState>{};

  for (final attachmentId in attachmentIds ?? const <String>[]) {
    if (attachmentId.startsWith('data:image/')) continue;
    if (!references.add(attachmentId)) continue;
    final state = stateById[attachmentId];
    if (state == null || state.isImage == true) {
      if (attachmentId.startsWith(kDirectLocalDocumentAttachmentPrefix) ||
          attachmentId.startsWith(kDirectOpenRouterPdfAttachmentPrefix)) {
        throw const DirectChatInputException(
          'This local document is no longer available. Attach it again.',
        );
      }
      references.remove(attachmentId);
      continue;
    }
    if (!attachmentId.startsWith(kDirectLocalDocumentAttachmentPrefix)) {
      if (supportsOpenRouterPdfInputs &&
          attachmentId.startsWith(kDirectOpenRouterPdfAttachmentPrefix) &&
          isDirectOpenRouterPdfFileNameSupported(state.fileName)) {
        pdfStates[attachmentId] = state;
        continue;
      }
      throw const DirectChatInputException(
        'This direct model does not support this attachment.',
      );
    }
    references.add(attachmentId);
    sources.add(
      await DirectLocalDocumentSource.fromFile(
        state.file,
        displayName: state.fileName,
        sourceId: attachmentId,
      ),
    );
  }

  final documents = await ref
      .read(directLocalDocumentServiceProvider)
      .prepareAll(sources);
  final signingKey = documents.documents.isEmpty
      ? null
      : await ref.read(directDeviceTrustKeyProvider.future);
  final files = <Map<String, dynamic>>[];
  final preparedAttachmentIds = <String>{};
  final ephemeralFileParts = <String, DirectFilePart>{};
  for (final document in documents.documents) {
    final attachmentId = document.sourceId;
    if (attachmentId == null ||
        !references.contains(attachmentId) ||
        !preparedAttachmentIds.add(attachmentId)) {
      throw StateError(
        'Direct document extraction returned invalid source metadata.',
      );
    }
    files.add(
      directLocalDocumentDescriptor(
        document,
        attachmentId: attachmentId,
        signingKey: signingKey!,
      ),
    );
  }
  var aggregatePdfBytes = 0;
  for (final entry in pdfStates.entries) {
    final state = entry.value;
    final projectedBytes = aggregatePdfBytes + await state.file.length();
    if (projectedBytes > _kDirectMaxAggregatePdfBytes) {
      throw const DirectChatInputException(
        'The attached PDFs exceed the Direct attachment size limit.',
      );
    }
    final bytes = await _readBoundedDirectPdf(state.file);
    aggregatePdfBytes += bytes.length;
    if (aggregatePdfBytes > _kDirectMaxAggregatePdfBytes) {
      throw const DirectChatInputException(
        'The attached PDFs exceed the Direct attachment size limit.',
      );
    }
    final attachmentId = entry.key;
    preparedAttachmentIds.add(attachmentId);
    ephemeralFileParts[attachmentId] = DirectFilePart(
      filename: state.fileName,
      dataUrl: 'data:application/pdf;base64,${base64Encode(bytes)}',
    );
    files.add(<String, dynamic>{
      'type': 'file',
      'source': 'direct_openrouter_pdf',
      'url': attachmentId,
      'name': state.fileName,
      'filename': state.fileName,
      'size': bytes.length,
      'content_type': 'application/pdf',
    });
  }
  return _PreparedDirectDocuments(
    files: List<Map<String, dynamic>>.unmodifiable(files),
    attachmentIds: Set<String>.unmodifiable(preparedAttachmentIds),
    ephemeralFilePartsByAttachmentId: Map<String, DirectFilePart>.unmodifiable(
      ephemeralFileParts,
    ),
  );
}

Future<Uint8List> _readBoundedDirectPdf(File file) async {
  final builder = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in file.openRead()) {
    length += chunk.length;
    if (length > kDirectMaxLocalDocumentBytes) {
      throw const DirectChatInputException(
        'This PDF exceeds the Direct attachment size limit.',
      );
    }
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  if (bytes.length < 5 ||
      bytes[0] != 0x25 ||
      bytes[1] != 0x50 ||
      bytes[2] != 0x44 ||
      bytes[3] != 0x46 ||
      bytes[4] != 0x2d) {
    throw const DirectChatInputException(
      'This attachment is not a valid PDF document.',
    );
  }
  return bytes;
}

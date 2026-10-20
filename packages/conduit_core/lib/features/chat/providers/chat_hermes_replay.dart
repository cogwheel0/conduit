part of 'chat_providers.dart';

Future<_PreparedHermesTurn> _prepareHermesTurn(
  dynamic ref, {
  required Model selectedModel,
  required String text,
  required List<String>? attachmentIds,
  required List<ChatContextAttachment> contextAttachments,
}) async {
  ensureHermesSendSupportsAttachments(
    selectedModel: selectedModel,
    attachments: attachmentIds,
    contextAttachments: contextAttachments,
  );

  final attachedStates =
      ref.read(attachedFilesProvider) as List<FileUploadState>;
  final stateById = <String, FileUploadState>{
    for (final state in attachedStates)
      if (state.fileId != null) state.fileId!: state,
  };
  final images = <String>[];
  final seenImages = <String>{};
  final documentSources = <HermesLocalDocumentSource>[];
  final inputFiles = <HermesInputFilePart>[];
  final desktop =
      (ref.read(hermesConfigProvider) as HermesConfig).mode ==
      HermesBackendMode.desktopGateway;
  AsyncValue<HermesCapabilities>? capabilities;
  final requestedAttachmentIds = attachmentIds ?? const <String>[];
  final responsesPdfRequested =
      !desktop &&
      requestedAttachmentIds.any((attachmentId) {
        final state = stateById[attachmentId];
        return state != null &&
            state.isImage != true &&
            isHermesResponsesPdfFileNameSupported(state.fileName);
      });
  if (responsesPdfRequested) {
    capabilities = ref.read(hermesCapabilitiesProvider);
    if (capabilities?.asData == null) {
      capabilities = await AsyncValue.guard(
        () => ref.read(hermesCapabilitiesProvider.future),
      );
    }
  }
  var decodedImageBytes = 0;
  var inputFileBytes = 0;

  for (final attachmentId in requestedAttachmentIds) {
    if (attachmentId.startsWith('data:image/')) {
      capabilities ??= ref.read(hermesCapabilitiesProvider);
      if (capabilities?.asData?.value.inputImages != true) {
        throw const HermesChatInputException(
          'This Hermes server does not advertise image input support.',
        );
      }
      if (!seenImages.add(attachmentId)) continue;
      final int bytes;
      try {
        bytes = decodedImageByteLength(
          attachmentId,
          maxDecodedBytes: kHermesMaxDecodedImageBytes - decodedImageBytes,
        );
      } on DirectChatInputException catch (error) {
        throw HermesChatInputException(error.message);
      }
      decodedImageBytes += bytes;
      if (images.length + 1 > kHermesMaxInlineImages) {
        throw const HermesChatInputException(
          'Hermes supports up to 4 images per message.',
        );
      }
      if (decodedImageBytes > kHermesMaxDecodedImageBytes) {
        throw const HermesChatInputException(
          'Hermes images must be 6 MB or less in total.',
        );
      }
      images.add(attachmentId);
      continue;
    }

    final state = stateById[attachmentId];
    if (state == null || state.isImage == true) {
      throw const HermesAttachmentsUnsupportedException();
    }
    final responsesPdf =
        !desktop && isHermesResponsesPdfFileNameSupported(state.fileName);
    if (responsesPdf && capabilities?.asData?.value.inputFiles != true) {
      throw const HermesChatInputException(
        'This Hermes server does not advertise Responses file input.',
      );
    }
    if (desktop || responsesPdf) {
      final remaining = kHermesMaxAggregateLocalDocumentBytes - inputFileBytes;
      final bytes = await _readBoundedHermesFile(
        state.file,
        maxBytes: math.min(kHermesMaxLocalDocumentBytes, remaining),
      );
      if (bytes.isEmpty) {
        throw const HermesChatInputException(
          'Hermes attachments cannot be empty.',
        );
      }
      inputFileBytes += bytes.length;
      final mediaType = _hermesFileMediaType(state.fileName);
      if (mediaType == 'application/pdf' &&
          (bytes.length < 5 ||
              bytes[0] != 0x25 ||
              bytes[1] != 0x50 ||
              bytes[2] != 0x44 ||
              bytes[3] != 0x46 ||
              bytes[4] != 0x2d)) {
        throw const HermesChatInputException(
          'This attachment is not a valid PDF document.',
        );
      }
      inputFiles.add(
        HermesInputFilePart(
          filename: state.fileName,
          mediaType: mediaType,
          base64Data: base64Encode(bytes),
        ),
      );
      continue;
    }
    documentSources.add(
      await HermesLocalDocumentSource.fromFile(
        state.file,
        displayName: state.fileName,
      ),
    );
  }

  final documentService = ref.read(
    hermesLocalDocumentServiceProvider,
  ) as HermesLocalDocumentService;
  final documents = desktop
      ? const HermesPreparedDocumentBatch(
          documents: [],
          totalSourceBytes: 0,
          totalCharacters: 0,
        )
      : await documentService.prepareAll(documentSources);
  if (documents.totalSourceBytes + inputFileBytes >
      kHermesMaxAggregateLocalDocumentBytes) {
    throw const HermesChatInputException(
      'Hermes files exceed the 16 MB aggregate limit.',
    );
  }
  final promptText = documents.documents.isEmpty
      ? text
      : '$text\n\n${documents.renderForPrompt()}';
  final HermesChatInput input;
  if (images.isEmpty && inputFiles.isEmpty) {
    input = HermesChatInput.text(promptText);
  } else {
    input = HermesChatInput.multimodal(<HermesChatContentPart>[
      if (promptText.trim().isNotEmpty) HermesInputTextPart(promptText),
      for (final image in images) HermesInputImagePart(image),
      ...inputFiles,
    ]);
  }

  final files = <Map<String, dynamic>>[
    for (final image in images)
      <String, dynamic>{
        'type': 'image',
        'source': 'hermes_inline',
        'url': image,
      },
    for (final document in documents.documents)
      _hermesLocalDocumentDescriptor(document),
    for (final file in inputFiles)
      <String, dynamic>{
        'type': 'file',
        'source': desktop ? 'hermes_desktop_file' : 'hermes_responses_file',
        'name': file.filename,
        'content_type': file.mediaType,
      },
  ];
  return _PreparedHermesTurn(
    input: input,
    imageUrls: List.unmodifiable(images),
    files: List.unmodifiable(files),
    localDocumentPromptText: documents.documents.isEmpty ? null : promptText,
    localDocumentEnvelopes: List.unmodifiable(
      documents.documents.map((document) => document.renderForPrompt()),
    ),
  );
}

Future<Uint8List> _readBoundedHermesFile(
  File file, {
  required int maxBytes,
}) async {
  if (maxBytes <= 0) {
    throw const HermesChatInputException(
      'Hermes files exceed the 16 MB aggregate limit.',
    );
  }
  final builder = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in file.openRead()) {
    length += chunk.length;
    if (length > maxBytes) {
      throw const HermesChatInputException(
        'This file exceeds the Hermes attachment size limit.',
      );
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

String _hermesFileMediaType(String filename) {
  final extension = filename.toLowerCase().split('.').last;
  return switch (extension) {
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'md' || 'markdown' => 'text/markdown',
    'json' || 'jsonl' => 'application/json',
    'csv' => 'text/csv',
    'html' || 'htm' => 'text/html',
    'xml' => 'application/xml',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    _ => 'application/octet-stream',
  };
}

Map<String, dynamic> _hermesLocalDocumentDescriptor(
  HermesPreparedDocument document,
) {
  final descriptor = <String, dynamic>{
    'type': 'file',
    'source': 'hermes_local',
    'id': document.id,
    'url': '$kHermesLocalDocumentIdPrefix${document.id}',
    'name': document.name,
    'filename': document.name,
    'size': document.size,
    'content_type': document.mimeType,
    'hermes_extracted_text': document.extractedText,
    'hermes_truncated': document.truncated,
  };
  markTrustedHermesLocalDocumentDescriptor(descriptor);
  return descriptor;
}

final RegExp _hermesLocalDocumentDescriptorIdPattern = RegExp(
  r'^hdoc_[0-9a-f]{24}$',
);

HermesPreparedDocument? _hermesDocumentFromDescriptor(
  Map<String, dynamic> file,
) {
  if (file['source'] != 'hermes_local') return null;
  final idValue = file['id'];
  final nameValue = file['name'] ?? file['filename'];
  final mimeTypeValue = file['content_type'];
  final textValue = file['hermes_extracted_text'];
  final id = idValue is String ? idValue.trim() : '';
  final name = nameValue is String ? nameValue.trim() : '';
  final mimeType = mimeTypeValue is String ? mimeTypeValue.trim() : '';
  final text = textValue is String ? textValue : '';
  final sizeValue = file['size'];
  final size = sizeValue is int ? sizeValue : null;
  final truncated = file['hermes_truncated'];
  if (!_hermesLocalDocumentDescriptorIdPattern.hasMatch(id) ||
      name.isEmpty ||
      sanitizeHermesDocumentFilename(name) != name ||
      mimeType.isEmpty ||
      mimeType.length > 200 ||
      mimeType.contains(RegExp(r'[\r\n\u0000]')) ||
      size == null ||
      size <= 0 ||
      size > kHermesMaxLocalDocumentBytes ||
      text.isEmpty ||
      text.length > kHermesMaxLocalDocumentCharacters * 2 ||
      text.trim() != text ||
      text.contains('\r') ||
      text.contains('\u0000') ||
      truncated is! bool) {
    return null;
  }
  return HermesPreparedDocument(
    id: id,
    name: name,
    mimeType: mimeType,
    size: size,
    extractedText: text,
    truncated: truncated,
  );
}

({String promptText, List<String> documentEnvelopes})?
_trustedHermesReplayDocumentPrompt(ChatMessage? message) {
  if (message == null) return null;
  final documents = <HermesPreparedDocument>[];
  final documentBudget = _HermesReplayDocumentBudget();
  final files = message.files ?? const <Map<String, dynamic>>[];
  for (
    var index = 0;
    index < files.length && index < _maxHermesPersistedAttachmentScanItems;
    index++
  ) {
    final file = files[index];
    if (file['source'] != 'hermes_local') continue;
    if (!isTrustedHermesLocalDocumentDescriptor(file)) return null;
    final document = _hermesDocumentFromDescriptor(file);
    if (document == null || !documentBudget.claim(document)) {
      return null;
    }
    documents.add(document);
  }
  if (documents.isEmpty) return null;
  final envelopes = documents
      .map((document) => document.renderForPrompt())
      .toList(growable: false);
  return (
    promptText: '${message.content}\n\n${envelopes.join('\n\n')}',
    documentEnvelopes: envelopes,
  );
}

final class _HermesReplayImageBudget {
  _HermesReplayImageBudget({
    this.maxImages = kHermesMaxInlineImages,
    this.maxDecodedBytes = kHermesMaxDecodedImageBytes,
  });

  final int maxImages;
  final int maxDecodedBytes;
  int _imageCount = 0;
  int _decodedBytes = 0;

  bool claim(String url) {
    if (_imageCount >= maxImages) return false;
    var decodedBytes = 0;
    if (url.startsWith('data:image/')) {
      try {
        decodedBytes = decodedImageByteLength(
          url,
          maxDecodedBytes: maxDecodedBytes - _decodedBytes,
        );
      } on DirectChatInputException {
        // A malformed persisted data URL must not make every future turn in
        // the conversation unsendable. Omit it from replay instead.
        return false;
      }
      if (_decodedBytes + decodedBytes > maxDecodedBytes) return false;
    } else if (url.length > _maxHermesReplayRemoteImageUrlCharacters) {
      return false;
    }
    _imageCount += 1;
    _decodedBytes += decodedBytes;
    return true;
  }
}

final class _HermesReplayDocumentBudget {
  _HermesReplayDocumentBudget({
    this.maxDocuments = kHermesMaxLocalDocuments,
    this.maxCharacters = kHermesMaxLocalDocumentCharacters,
  });

  final int maxDocuments;
  final int maxCharacters;
  int _documentCount = 0;
  int _characterCount = 0;

  bool claim(HermesPreparedDocument document) {
    if (_documentCount >= maxDocuments) return false;
    final characters = document.extractedText.runes.length;
    if (characters > maxCharacters - _characterCount) return false;
    _documentCount += 1;
    _characterCount += characters;
    return true;
  }
}

final class _HermesReplayHistoryBudget {
  _HermesReplayHistoryBudget({
    this.maxCharacters = _maxHermesReplayHistoryCharacters,
  });

  final int maxCharacters;
  int _characters = 0;

  int get remainingCharacters => maxCharacters - _characters;

  bool claim(Object? value) {
    final cost = _boundedHermesReplayJsonCost(
      value,
      maxCharacters: remainingCharacters,
    );
    if (cost == null) return false;
    _characters += cost;
    return true;
  }
}

int? _boundedHermesReplayJsonCost(Object? root, {required int maxCharacters}) {
  if (maxCharacters <= 0) return null;
  final stack = <Object?>[root];
  var characters = 0;
  var nodes = 0;

  bool consume(int count) {
    if (count < 0 || count > maxCharacters - characters) return false;
    characters += count;
    return true;
  }

  while (stack.isNotEmpty) {
    final value = stack.removeLast();
    nodes++;
    if (nodes > _maxHermesReplayJsonNodes || !consume(1)) return null;
    if (value is String) {
      if (!consume(value.length)) return null;
    } else if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String || !consume(key.length + 1)) return null;
        stack.add(entry.value);
      }
    } else if (value is Iterable) {
      for (final item in value) {
        stack.add(item);
        if (stack.length > _maxHermesReplayJsonNodes) return null;
      }
    } else if (value != null && value is! num && value is! bool) {
      return null;
    } else if (!consume(16)) {
      // Numbers and booleans are locally constructed and small; charge a
      // conservative fixed JSON representation without calling toString on a
      // provider-controlled object.
      return null;
    }
  }
  return characters;
}

HermesChatInput _hermesInputFromPersistedMessage(
  ChatMessage message, {
  required bool inputImagesSupported,
  _HermesReplayImageBudget? replayImageBudget,
  _HermesReplayDocumentBudget? replayDocumentBudget,
}) {
  final documents = <HermesPreparedDocument>[];
  final images = <String>[];
  final seenImages = <String>{};
  final imageBudget = replayImageBudget ?? _HermesReplayImageBudget();
  final documentBudget = replayDocumentBudget ?? _HermesReplayDocumentBudget();
  var scannedItems = 0;
  final files = message.files ?? const <Map<String, dynamic>>[];
  for (
    var index = 0;
    index < files.length &&
        scannedItems < _maxHermesPersistedAttachmentScanItems;
    index++, scannedItems++
  ) {
    final file = files[index];
    if (file['source'] == 'hermes_local' &&
        isTrustedHermesLocalDocumentDescriptor(file)) {
      final document = _hermesDocumentFromDescriptor(file);
      if (document != null && documentBudget.claim(document)) {
        documents.add(document);
      }
    }
    final typeValue = file['type'];
    final isImage =
        typeValue is String &&
        typeValue.length <= 32 &&
        typeValue.toLowerCase() == 'image';
    final urlValue = file['url'];
    if (inputImagesSupported && isImage && urlValue is String) {
      final url = urlValue;
      if (_isHermesReplayImageUrl(url) &&
          !seenImages.contains(url) &&
          imageBudget.claim(url)) {
        seenImages.add(url);
        images.add(url);
      }
    }
  }
  if (inputImagesSupported) {
    final attachmentIds = message.attachmentIds ?? const <String>[];
    for (
      var index = 0;
      index < attachmentIds.length &&
          scannedItems < _maxHermesPersistedAttachmentScanItems;
      index++, scannedItems++
    ) {
      final value = attachmentIds[index];
      if (_isHermesReplayImageUrl(value) &&
          !seenImages.contains(value) &&
          imageBudget.claim(value)) {
        seenImages.add(value);
        images.add(value);
      }
    }
  }
  final renderedDocuments = documents
      .map((document) => document.renderForPrompt())
      .join('\n\n');
  final text = renderedDocuments.isEmpty
      ? message.content
      : '${message.content}\n\n$renderedDocuments';
  if (images.isEmpty) return HermesChatInput.text(text);
  return HermesChatInput.multimodal(<HermesChatContentPart>[
    if (text.trim().isNotEmpty) HermesInputTextPart(text),
    for (final image in images) HermesInputImagePart(image),
  ]);
}

bool _isHermesReplayImageUrl(String value) =>
    value.startsWith('data:image/') ||
    value.startsWith('http://') ||
    value.startsWith('https://');

bool _persistedHermesReplayRequiresResponses(
  List<Map<String, dynamic>> files,
  List<String> attachmentIds,
) {
  var scannedItems = 0;
  for (final file in files) {
    if (scannedItems++ >= _maxHermesPersistedAttachmentScanItems) return true;
    if (file['source'] == 'hermes_local') return true;
    final type = file['type'];
    if (type is String && type.length <= 32 && type.toLowerCase() == 'image') {
      return true;
    }
  }
  for (final attachment in attachmentIds) {
    if (scannedItems++ >= _maxHermesPersistedAttachmentScanItems) return true;
    if (_isHermesReplayImageUrl(attachment)) return true;
  }
  return false;
}

@visibleForTesting
bool persistedHermesReplayRequiresResponsesForTest({
  required List<Map<String, dynamic>> files,
  required List<String> attachmentIds,
}) => _persistedHermesReplayRequiresResponses(files, attachmentIds);

bool _isHermesUserHistoryRole(Object? value) =>
    value is String && value.length <= 32 && value.toLowerCase() == 'user';

@visibleForTesting
bool isHermesUserHistoryRoleForTest(Object? value) =>
    _isHermesUserHistoryRole(value);

List<Map<String, dynamic>> _hermesVisibleHistory(
  Iterable<ChatMessage> messages, {
  required bool inputImagesSupported,
  int maxReplayImages = kHermesMaxInlineImages,
  int maxReplayDecodedImageBytes = kHermesMaxDecodedImageBytes,
  int maxReplayDocuments = kHermesMaxLocalDocuments,
  int maxReplayDocumentCharacters = kHermesMaxLocalDocumentCharacters,
  int maxReplayCharacters = _maxHermesReplayHistoryCharacters,
}) {
  final replayImageBudget = inputImagesSupported
      ? _HermesReplayImageBudget(
          maxImages: maxReplayImages,
          maxDecodedBytes: maxReplayDecodedImageBytes,
        )
      : null;
  final replayDocumentBudget = _HermesReplayDocumentBudget(
    maxDocuments: maxReplayDocuments,
    maxCharacters: maxReplayDocumentCharacters,
  );
  final replayHistoryBudget = _HermesReplayHistoryBudget(
    maxCharacters: maxReplayCharacters,
  );
  final reversedResult = <Map<String, dynamic>>[];
  // Select from newest to oldest so the bounded image/document budgets retain
  // the references most likely to matter to the next turn. Reverse again
  // before returning to preserve chronological provider history.
  final source = messages is List<ChatMessage>
      ? messages
      : messages.toList(growable: false);
  for (var index = source.length - 1; index >= 0; index--) {
    final message = source[index];
    if (message.metadata?['archivedVariant'] == true) continue;
    final role = message.role.toLowerCase();
    if (role != 'user' && role != 'assistant' && role != 'system') continue;
    if (role == 'user') {
      // Avoid constructing a joined text/document value when the serialized
      // message alone cannot fit the remaining request-wide replay budget.
      if (message.content.length > replayHistoryBudget.remainingCharacters) {
        continue;
      }
      final input = _hermesInputFromPersistedMessage(
        message,
        inputImagesSupported: inputImagesSupported,
        replayImageBudget: replayImageBudget,
        replayDocumentBudget: replayDocumentBudget,
      );
      final candidate = <String, dynamic>{
        'role': role,
        'content': input.toJson(),
      };
      if (!replayHistoryBudget.claim(candidate)) continue;
      reversedResult.add(candidate);
    } else {
      final text = outboundProviderReplayText(message);
      if (text.isEmpty ||
          text.length > replayHistoryBudget.remainingCharacters ||
          text.trim().isEmpty) {
        continue;
      }
      final candidate = <String, dynamic>{'role': role, 'content': text};
      if (!replayHistoryBudget.claim(candidate)) continue;
      reversedResult.add(candidate);
    }
    if (reversedResult.length == 50) break;
  }
  return List.unmodifiable(reversedResult.reversed);
}

@visibleForTesting
List<Map<String, dynamic>> buildHermesVisibleHistoryForTest(
  Iterable<ChatMessage> messages, {
  bool inputImagesSupported = true,
  int maxReplayImages = kHermesMaxInlineImages,
  int maxReplayDecodedImageBytes = kHermesMaxDecodedImageBytes,
  int maxReplayDocuments = kHermesMaxLocalDocuments,
  int maxReplayDocumentCharacters = kHermesMaxLocalDocumentCharacters,
  int maxReplayCharacters = _maxHermesReplayHistoryCharacters,
}) => _hermesVisibleHistory(
  messages,
  inputImagesSupported: inputImagesSupported,
  maxReplayImages: maxReplayImages,
  maxReplayDecodedImageBytes: maxReplayDecodedImageBytes,
  maxReplayDocuments: maxReplayDocuments,
  maxReplayDocumentCharacters: maxReplayDocumentCharacters,
  maxReplayCharacters: maxReplayCharacters,
);

Future<bool> _hermesInputImagesSupported(dynamic ref) async {
  try {
    final capabilities = await ref.read(hermesCapabilitiesProvider.future);
    return capabilities.inputImages;
  } catch (error) {
    DebugLogger.warning(
      'Hermes image capability lookup failed; omitting replayed images',
      scope: 'hermes/capabilities',
      data: <String, Object?>{'errorType': error.runtimeType.toString()},
    );
    return false;
  }
}

@visibleForTesting
Future<List<Map<String, dynamic>>>
buildHermesVisibleHistoryAfterCapabilityResolutionForTest(
  dynamic ref,
  Iterable<ChatMessage> messages,
) async => _hermesVisibleHistory(
  messages,
  inputImagesSupported: await _hermesInputImagesSupported(ref),
);

@visibleForTesting
bool usesHermesTransportForRegeneration({
  required Model selectedModel,
  required Conversation? activeConversation,
}) {
  // A fresh chat has no transport-bearing conversation shell yet, so its
  // trusted runtime model selects the backend. Once a conversation is open,
  // its transport binding wins over stale global model selection.
  if (activeConversation == null) return isHermesModel(selectedModel);
  return isNativeHermesConversation(activeConversation);
}

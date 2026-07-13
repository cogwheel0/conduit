import 'package:openai_dart/openai_dart.dart' as openai;

const int kHermesMaxInlineImages = 4;
const int kHermesMaxDecodedImageBytes = 6 * 1024 * 1024;
const String kHermesLocalDocumentIdPrefix = 'hermes-local:';

final class HermesChatInputException implements Exception {
  const HermesChatInputException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Typed input for Hermes's multimodal HTTP endpoints.
///
/// Text-only turns deliberately serialize as the legacy scalar string. Turns
/// containing images serialize as the OpenAI Responses-style content list
/// accepted by Hermes's OpenAI-compatible Responses endpoint.
sealed class HermesChatInput {
  const HermesChatInput();

  factory HermesChatInput.text(String text) = HermesTextChatInput;

  factory HermesChatInput.multimodal(Iterable<HermesChatContentPart> parts) =
      HermesMultimodalChatInput;

  Object toJson();

  /// The SDK-owned Responses input used at the HTTP protocol boundary.
  openai.ResponseInput toResponseInput();

  /// Responses accepts a scalar string for text-only turns, but multimodal
  /// content parts must be nested inside an input message.
  Object toResponsesJson() => toResponseInput().toJson();
}

final class HermesTextChatInput extends HermesChatInput {
  HermesTextChatInput(this.text) {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
  }

  final String text;

  @override
  String toJson() => text;

  @override
  openai.ResponseInput toResponseInput() => openai.ResponseInput.text(text);
}

final class HermesMultimodalChatInput extends HermesChatInput {
  HermesMultimodalChatInput(Iterable<HermesChatContentPart> parts)
    : parts = List.unmodifiable(parts) {
    if (this.parts.isEmpty) {
      throw ArgumentError.value(parts, 'parts', 'must not be empty');
    }
  }

  final List<HermesChatContentPart> parts;

  @override
  List<Map<String, dynamic>> toJson() => [
    for (final part in parts) part.toJson(),
  ];

  @override
  openai.ResponseInput toResponseInput() => openai.ResponseInput.items([
    openai.MessageItem.user([
      for (final part in parts) part.toResponseContent(),
    ]),
  ]);
}

sealed class HermesChatContentPart {
  const HermesChatContentPart();

  Map<String, dynamic> toJson();

  openai.InputContent toResponseContent();
}

final class HermesInputTextPart extends HermesChatContentPart {
  HermesInputTextPart(this.text) {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
  }

  final String text;

  @override
  Map<String, dynamic> toJson() => toResponseContent().toJson();

  @override
  openai.InputContent toResponseContent() => openai.InputContent.text(text);
}

/// An image data URL or remote HTTP(S) URL accepted by Hermes.
final class HermesInputImagePart extends HermesChatContentPart {
  HermesInputImagePart(String imageUrl, {String? detail})
    : imageUrl = imageUrl.trim(),
      detail = detail?.trim() {
    // Only inspect the short scheme prefix. Lowercasing a multi-megabyte data
    // URL would briefly duplicate the entire encoded image in memory.
    final prefixLength = this.imageUrl.length < 16 ? this.imageUrl.length : 16;
    final normalizedPrefix = this.imageUrl
        .substring(0, prefixLength)
        .toLowerCase();
    final isImageDataUrl =
        normalizedPrefix.startsWith('data:image/') &&
        this.imageUrl.contains(',');
    final isRemoteUrl =
        normalizedPrefix.startsWith('https://') ||
        normalizedPrefix.startsWith('http://');
    if (!isImageDataUrl && !isRemoteUrl) {
      throw ArgumentError.value(
        this.imageUrl,
        'imageUrl',
        'must be an HTTP(S) URL or data:image/... URL',
      );
    }
    if (this.detail != null && this.detail!.isEmpty) {
      throw ArgumentError.value(this.detail, 'detail', 'must not be empty');
    }
    if (this.detail != null) {
      try {
        openai.ImageDetail.fromJson(this.detail!);
      } on FormatException {
        throw ArgumentError.value(
          this.detail,
          'detail',
          'must be auto, low, high, or original',
        );
      }
    }
  }

  final String imageUrl;
  final String? detail;

  @override
  Map<String, dynamic> toJson() => toResponseContent().toJson();

  @override
  openai.InputContent toResponseContent() => openai.InputContent.imageUrl(
    imageUrl,
    detail: detail == null ? null : openai.ImageDetail.fromJson(detail!),
  );
}

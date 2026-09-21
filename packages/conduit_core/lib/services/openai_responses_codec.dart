import 'package:openai_dart/openai_dart.dart' as openai;

/// The standard OpenAI Responses protocol boundary shared by direct-provider
/// and backend-specific adapters.
///
/// Conduit deliberately keeps HTTP transport outside this codec so Dio can
/// continue enforcing per-connection redirect, TLS, credential, timeout, and
/// cancellation policy. Request and response protocol shapes are owned by
/// `openai_dart` instead of being duplicated by each adapter.
final class OpenAiResponsesCodec {
  const OpenAiResponsesCodec._();

  static Map<String, dynamic> createRequestBody({
    required String model,
    required openai.ResponseInput input,
    String? instructions,
    String? previousResponseId,
    bool stream = true,
    bool? store,
  }) {
    return openai.CreateResponseRequest(
      model: model,
      input: input,
      instructions: instructions,
      previousResponseId: previousResponseId,
      stream: stream,
      store: store,
    ).toJson();
  }

  static openai.ResponseStreamEvent decodeStreamEvent(
    Map<String, dynamic> json,
  ) => openai.ResponseStreamEvent.fromJson(json);

  static openai.Response decodeResponse(Map<String, dynamic> json) =>
      openai.Response.fromJson(json);

  static OpenAiResponseContent content(openai.Response response) {
    final reasoning = StringBuffer();
    final reasoningText = StringBuffer();
    final reasoningSummary = StringBuffer();
    for (final item in response.reasoningItems) {
      final content = item.content
          ?.map((part) => _textValue(part['text']))
          .whereType<String>()
          .join();
      final summary = item.summary.map((part) => part.text).join();
      final nonEmptyContent = _nonEmpty(content);
      final nonEmptySummary = _nonEmpty(summary);
      _writeSeparated(reasoningText, nonEmptyContent);
      _writeSeparated(reasoningSummary, nonEmptySummary);
      _writeSeparated(reasoning, nonEmptyContent ?? nonEmptySummary);
    }

    final text = StringBuffer();
    for (final item in response.output.whereType<openai.MessageOutputItem>()) {
      for (final part in item.content) {
        switch (part) {
          case openai.OutputTextContent(text: final outputText):
            text.write(outputText);
          case openai.RefusalContent(refusal: final refusal):
            text.write(refusal);
          default:
            break;
        }
      }
    }

    return OpenAiResponseContent(
      text: text.toString(),
      reasoning: reasoning.toString(),
      reasoningText: reasoningText.toString(),
      reasoningSummary: reasoningSummary.toString(),
    );
  }

  static String? statusError(
    openai.Response response, {
    String subject = 'provider response',
  }) {
    return switch (response.status) {
      openai.ResponseStatus.completed => null,
      openai.ResponseStatus.failed =>
        response.error?.message ?? 'The $subject failed.',
      openai.ResponseStatus.incomplete =>
        switch (response.incompleteDetails?.reason) {
          final reason? when reason.isNotEmpty =>
            'The $subject was incomplete: $reason.',
          _ => 'The $subject was incomplete.',
        },
      openai.ResponseStatus.cancelled => 'The $subject was cancelled.',
      openai.ResponseStatus.queued ||
      openai.ResponseStatus.inProgress => 'The $subject is not complete.',
      openai.ResponseStatus.unknown =>
        'The $subject has an unsupported status.',
    };
  }

  static String? _textValue(Object? value) =>
      value is String ? _nonEmpty(value) : null;

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  static void _writeSeparated(StringBuffer buffer, String? value) {
    if (value == null) return;
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write(value);
  }
}

final class OpenAiResponseContent {
  const OpenAiResponseContent({
    required this.text,
    required this.reasoning,
    required this.reasoningText,
    required this.reasoningSummary,
  });

  final String text;

  /// The existing preferred reasoning projection: detailed text when present,
  /// otherwise its summary, for each response reasoning item.
  final String reasoning;

  /// Detailed reasoning content, kept separate from summary text so streaming
  /// prefix reconciliation does not compare two legitimate event categories.
  final String reasoningText;
  final String reasoningSummary;
}

import 'package:freezed_annotation/freezed_annotation.dart';

part 'prompts.freezed.dart';
part 'prompts.g.dart';

/// A saved prompt, as the `/` menu lists it (WP-3.3).
///
/// Without its content: the menu shows what a prompt is called, and the
/// text it expands to is decided by `prompts.render`, which is where its
/// variables are filled in.
@freezed
abstract class PromptSummary with _$PromptSummary {
  const factory PromptSummary({
    /// With its leading slash: `/summarize`.
    required String command,
    required String title,
    String? description,

    /// Whether the text reads the clipboard, so the renderer knows to send
    /// it along. The daemon has no clipboard; the window does.
    @Default(false) bool usesClipboard,
  }) = _PromptSummary;

  factory PromptSummary.fromJson(Map<String, dynamic> json) =>
      _$PromptSummaryFromJson(json);
}

/// Reply to `prompts.list`.
@freezed
abstract class PromptList with _$PromptList {
  const factory PromptList({
    @Default(<PromptSummary>[]) List<PromptSummary> prompts,
  }) = _PromptList;

  factory PromptList.fromJson(Map<String, dynamic> json) =>
      _$PromptListFromJson(json);
}

/// Parameters of `prompts.render`.
@freezed
abstract class RenderPrompt with _$RenderPrompt {
  const factory RenderPrompt({
    required String command,

    /// Answers to the prompt's input fields, by field name. Empty the
    /// first time, which is how the renderer learns what to ask.
    @Default(<String, String>{}) Map<String, String> values,

    /// The clipboard's text, for `{{CLIPBOARD}}`. Sent only when the
    /// prompt uses it.
    String? clipboard,
  }) = _RenderPrompt;

  factory RenderPrompt.fromJson(Map<String, dynamic> json) =>
      _$RenderPromptFromJson(json);
}

/// One thing a prompt asks the user for before it can be used.
///
/// Open WebUI writes these into the prompt as
/// `{{name | select:options=["a","b"]:required=true}}`.
@freezed
abstract class PromptInput with _$PromptInput {
  const factory PromptInput({
    required String name,

    /// A readable name derived from [name]: `due_date` is "Due Date".
    required String label,

    /// `text`, `textarea`, `select` or `number`.
    @Default('text') String type,
    String? placeholder,
    String? defaultValue,
    @Default(false) bool required,
    @Default(<String>[]) List<String> options,
  }) = _PromptInput;

  factory PromptInput.fromJson(Map<String, dynamic> json) =>
      _$PromptInputFromJson(json);
}

/// Reply to `prompts.render`.
///
/// When [inputs] is empty, [content] is final and goes into the composer.
/// Otherwise the renderer asks for those values and renders again.
@freezed
abstract class RenderedPrompt with _$RenderedPrompt {
  const factory RenderedPrompt({
    required String content,
    @Default(<PromptInput>[]) List<PromptInput> inputs,
  }) = _RenderedPrompt;

  factory RenderedPrompt.fromJson(Map<String, dynamic> json) =>
      _$RenderedPromptFromJson(json);
}

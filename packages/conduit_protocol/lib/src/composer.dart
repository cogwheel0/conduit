import 'package:freezed_annotation/freezed_annotation.dart';

part 'composer.freezed.dart';
part 'composer.g.dart';

/// A tool the server offers for a turn.
@freezed
abstract class ToolSummary with _$ToolSummary {
  const factory ToolSummary({
    required String id,
    required String name,
    String? description,
  }) = _ToolSummary;

  factory ToolSummary.fromJson(Map<String, dynamic> json) =>
      _$ToolSummaryFromJson(json);
}

/// What the composer may offer for the next turn (WP-3.3).
///
/// Decided by the daemon from the server's permissions and the selected
/// model, the same way the mobile app decides it, so the two front ends
/// offer the same switches for the same account.
@freezed
abstract class ComposerOptions with _$ComposerOptions {
  const factory ComposerOptions({
    @Default(false) bool webSearch,
    @Default(false) bool imageGeneration,
    @Default(<ToolSummary>[]) List<ToolSummary> tools,
  }) = _ComposerOptions;

  factory ComposerOptions.fromJson(Map<String, dynamic> json) =>
      _$ComposerOptionsFromJson(json);
}

/// A knowledge base, as the `#` menu lists it (WP-3.3).
@freezed
abstract class KnowledgeSummary with _$KnowledgeSummary {
  const factory KnowledgeSummary({
    required String id,
    required String name,
    String? description,
  }) = _KnowledgeSummary;

  factory KnowledgeSummary.fromJson(Map<String, dynamic> json) =>
      _$KnowledgeSummaryFromJson(json);
}

/// Params for `composer.knowledge`.
@freezed
abstract class KnowledgeQuery with _$KnowledgeQuery {
  const factory KnowledgeQuery({@Default('') String query}) = _KnowledgeQuery;

  factory KnowledgeQuery.fromJson(Map<String, dynamic> json) =>
      _$KnowledgeQueryFromJson(json);
}

/// Reply to `composer.knowledge`.
@freezed
abstract class KnowledgeList with _$KnowledgeList {
  const factory KnowledgeList({
    @Default(<KnowledgeSummary>[]) List<KnowledgeSummary> items,
  }) = _KnowledgeList;

  factory KnowledgeList.fromJson(Map<String, dynamic> json) =>
      _$KnowledgeListFromJson(json);
}

import 'package:freezed_annotation/freezed_annotation.dart';

part 'web_search.freezed.dart';
part 'web_search.g.dart';

/// A search engine on-device web search can use.
@freezed
abstract class WebSearchEngineDto with _$WebSearchEngineDto {
  const factory WebSearchEngineDto({
    /// What is stored: `auto` (try each in turn), `duckduckgo`, `brave`,
    /// `bing` or `mojeek`.
    required String id,

    /// The engine's own name; empty for `auto`, which the window names.
    @Default('') String name,
  }) = _WebSearchEngineDto;

  factory WebSearchEngineDto.fromJson(Map<String, dynamic> json) =>
      _$WebSearchEngineDtoFromJson(json);
}

/// A region on-device searches can ask for results from.
@freezed
abstract class WebSearchRegionDto with _$WebSearchRegionDto {
  const factory WebSearchRegionDto({
    /// A `country-language` code (`de-de`); `wt-wt` is worldwide.
    required String code,

    /// The region's own name for itself, so it needs no translating;
    /// empty for worldwide, which the window names.
    @Default('') String name,
  }) = _WebSearchRegionDto;

  factory WebSearchRegionDto.fromJson(Map<String, dynamic> json) =>
      _$WebSearchRegionDtoFromJson(json);
}

/// Reply to `webSearch.get` and `webSearch.set`: how the web search the
/// app runs itself (for direct models with no search of their own) is
/// set up.
@freezed
abstract class WebSearchSettings with _$WebSearchSettings {
  const factory WebSearchSettings({
    /// An [WebSearchEngineDto.id].
    @Default('auto') String engine,
    @Default(<WebSearchEngineDto>[]) List<WebSearchEngineDto> engines,

    /// `strict`, `moderate` or `off`.
    @Default('moderate') String safeSearch,

    /// The region chosen; null follows this Mac's language and region.
    String? region,

    /// The region searches use now: [region], or the one this Mac's
    /// settings give (`wt-wt` when none matches).
    @Default('wt-wt') String effectiveRegion,

    /// Worldwide first, then every region by name.
    @Default(<WebSearchRegionDto>[]) List<WebSearchRegionDto> regions,
  }) = _WebSearchSettings;

  factory WebSearchSettings.fromJson(Map<String, dynamic> json) =>
      _$WebSearchSettingsFromJson(json);
}

/// Params for `webSearch.set`: what changes; null leaves a setting as it
/// is. [region] `auto` goes back to following this Mac.
@freezed
abstract class WebSearchSettingsPatch with _$WebSearchSettingsPatch {
  const factory WebSearchSettingsPatch({
    String? engine,
    String? safeSearch,
    String? region,
  }) = _WebSearchSettingsPatch;

  factory WebSearchSettingsPatch.fromJson(Map<String, dynamic> json) =>
      _$WebSearchSettingsPatchFromJson(json);
}

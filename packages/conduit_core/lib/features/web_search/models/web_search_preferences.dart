import 'package:conduit_ddgs/conduit_ddgs.dart';

/// The engine the user picked for on-device web search.
enum WebSearchEngineChoice {
  /// Try DuckDuckGo, Brave, Bing, Mojeek, then Wikipedia.
  auto(null),
  duckduckgo(SearchEngineId.duckduckgo),
  brave(SearchEngineId.brave),
  bing(SearchEngineId.bing),
  mojeek(SearchEngineId.mojeek);

  const WebSearchEngineChoice(this.engine);

  /// `null` for [auto].
  final SearchEngineId? engine;

  static WebSearchEngineChoice parse(String? name) {
    for (final choice in values) {
      if (choice.name == name) return choice;
    }
    return auto;
  }
}

SafeSearch parseSafeSearch(String? name) {
  for (final value in SafeSearch.values) {
    if (value.name == name) return value;
  }
  return SafeSearch.moderate;
}

/// Stored value meaning "follow the device locale".
const String kWebSearchRegionAuto = 'auto';

/// A selectable search region. [name] is the region's own name for itself,
/// so the list needs no translation.
final class WebSearchRegionOption {
  const WebSearchRegionOption(this.code, this.name);

  /// DuckDuckGo-style `country-language` code.
  final String code;
  final String name;

  SearchRegion get region => SearchRegion(code);
}

/// Regions offered in settings, in DuckDuckGo's `kl` codes.
const List<WebSearchRegionOption> kWebSearchRegions = [
  WebSearchRegionOption('ar-es', 'Argentina'),
  WebSearchRegionOption('au-en', 'Australia'),
  WebSearchRegionOption('at-de', 'Österreich'),
  WebSearchRegionOption('be-fr', 'Belgique'),
  WebSearchRegionOption('be-nl', 'België'),
  WebSearchRegionOption('br-pt', 'Brasil'),
  WebSearchRegionOption('bg-bg', 'България'),
  WebSearchRegionOption('ca-en', 'Canada (English)'),
  WebSearchRegionOption('ca-fr', 'Canada (français)'),
  WebSearchRegionOption('cl-es', 'Chile'),
  WebSearchRegionOption('cn-zh', '中国'),
  WebSearchRegionOption('co-es', 'Colombia'),
  WebSearchRegionOption('cz-cs', 'Česko'),
  WebSearchRegionOption('dk-da', 'Danmark'),
  WebSearchRegionOption('de-de', 'Deutschland'),
  WebSearchRegionOption('es-es', 'España'),
  WebSearchRegionOption('ee-et', 'Eesti'),
  WebSearchRegionOption('fr-fr', 'France'),
  WebSearchRegionOption('gr-el', 'Ελλάδα'),
  WebSearchRegionOption('hk-tzh', '香港'),
  WebSearchRegionOption('in-en', 'India'),
  WebSearchRegionOption('id-id', 'Indonesia'),
  WebSearchRegionOption('ie-en', 'Ireland'),
  WebSearchRegionOption('il-he', 'ישראל'),
  WebSearchRegionOption('it-it', 'Italia'),
  WebSearchRegionOption('jp-jp', '日本'),
  WebSearchRegionOption('kr-kr', '대한민국'),
  WebSearchRegionOption('hu-hu', 'Magyarország'),
  WebSearchRegionOption('mx-es', 'México'),
  WebSearchRegionOption('nl-nl', 'Nederland'),
  WebSearchRegionOption('nz-en', 'New Zealand'),
  WebSearchRegionOption('no-no', 'Norge'),
  WebSearchRegionOption('pl-pl', 'Polska'),
  WebSearchRegionOption('pt-pt', 'Portugal'),
  WebSearchRegionOption('ro-ro', 'România'),
  WebSearchRegionOption('ru-ru', 'Россия'),
  WebSearchRegionOption('ch-de', 'Schweiz'),
  WebSearchRegionOption('sg-en', 'Singapore'),
  WebSearchRegionOption('sk-sk', 'Slovensko'),
  WebSearchRegionOption('za-en', 'South Africa'),
  WebSearchRegionOption('ch-fr', 'Suisse'),
  WebSearchRegionOption('fi-fi', 'Suomi'),
  WebSearchRegionOption('se-sv', 'Sverige'),
  WebSearchRegionOption('tw-tzh', '臺灣'),
  WebSearchRegionOption('th-th', 'ไทย'),
  WebSearchRegionOption('tr-tr', 'Türkiye'),
  WebSearchRegionOption('ua-uk', 'Україна'),
  WebSearchRegionOption('uk-en', 'United Kingdom'),
  WebSearchRegionOption('us-en', 'United States'),
  WebSearchRegionOption('vn-vi', 'Việt Nam'),
];

/// Resolves the stored region preference to a [SearchRegion].
///
/// [stored] is `null`/[kWebSearchRegionAuto] to follow [deviceLocale] (a
/// `Platform.localeName`-style value such as `en_GB` or `pt-BR`),
/// `wt-wt` for worldwide, or one of [kWebSearchRegions]. A device locale
/// with no matching region falls back to worldwide.
SearchRegion resolveWebSearchRegion(String? stored, String deviceLocale) {
  if (stored != null && stored != kWebSearchRegionAuto) {
    if (stored == SearchRegion.worldwide.code) return SearchRegion.worldwide;
    for (final option in kWebSearchRegions) {
      if (option.code == stored) return option.region;
    }
    return SearchRegion.worldwide;
  }

  final parts = deviceLocale
      .split('.')
      .first
      .toLowerCase()
      .split(RegExp('[-_]'));
  if (parts.length < 2) return SearchRegion.worldwide;
  final language = parts.first;
  final country = parts.last;
  SearchRegion? countryMatch;
  for (final option in kWebSearchRegions) {
    final region = option.region;
    if (region.isoCountry != country) continue;
    if (region.language == language) return region;
    countryMatch ??= region;
  }
  return countryMatch ?? SearchRegion.worldwide;
}

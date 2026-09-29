import 'package:meta/meta.dart';

/// How strictly engines filter adult content.
enum SafeSearch { strict, moderate, off }

/// Restricts results to pages published or updated within a window.
enum SearchTimeLimit { day, week, month, year }

/// A search region in DuckDuckGo's `country-language` form: `us-en`,
/// `de-de`, `tw-tzh`, or [worldwide] (`wt-wt`).
///
/// DuckDuckGo's codes are the lingua franca here because they are what the
/// upstream library and most metasearch settings use; each engine maps them
/// onto its own parameters.
@immutable
final class SearchRegion {
  const SearchRegion._(this.code);

  /// Parses [code], throwing [ArgumentError] when it is not a
  /// `country-language` pair.
  factory SearchRegion(String code) {
    final normalized = code.trim().toLowerCase();
    if (!_pattern.hasMatch(normalized)) {
      throw ArgumentError.value(
        code,
        'code',
        'Expected a `country-language` region code such as `us-en`',
      );
    }
    return normalized == worldwide.code
        ? worldwide
        : SearchRegion._(normalized);
  }

  /// No regional bias.
  static const SearchRegion worldwide = SearchRegion._('wt-wt');

  static final RegExp _pattern = RegExp(r'^[a-z]{2}-[a-z]{2,3}$');

  /// DuckDuckGo-style codes whose country half is not an ISO 3166 code.
  static const Map<String, String> _isoCountries = {'uk': 'gb'};

  /// Pseudo-countries (Arabia, Latin America) that other engines can't
  /// express as a single market.
  static const Set<String> _multiCountry = {'xa', 'xl'};

  final String code;

  bool get isWorldwide => identical(this, worldwide) || code == worldwide.code;

  /// Lower-case ISO 3166-1 alpha-2 country, or `null` for [worldwide] and
  /// multi-country regions.
  String? get isoCountry {
    if (isWorldwide) return null;
    final raw = code.substring(0, 2);
    if (_multiCountry.contains(raw)) return null;
    return _isoCountries[raw] ?? raw;
  }

  /// DuckDuckGo-style language halves that are not ISO 639-1 codes.
  static const Map<String, String> _isoLanguages = {
    'tzh': 'zh',
    'jp': 'ja',
    'kr': 'ko',
  };

  /// ISO 639-1 language, e.g. `ja` for DuckDuckGo's `jp-jp`.
  String get language {
    if (isWorldwide) return 'en';
    final raw = code.substring(3);
    return _isoLanguages[raw] ?? raw;
  }

  /// An `Accept-Language` value that matches this region.
  String get acceptLanguage {
    final country = isoCountry;
    final primary = country == null
        ? language
        : '$language-${country.toUpperCase()}';
    if (language == 'en') return '$primary,en;q=0.9';
    return '$primary,$language;q=0.9,en;q=0.5';
  }

  @override
  bool operator ==(Object other) => other is SearchRegion && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => code;
}

/// One text search.
@immutable
final class SearchQuery {
  SearchQuery(
    String text, {
    this.region = SearchRegion.worldwide,
    this.safeSearch = SafeSearch.moderate,
    this.timeLimit,
  }) : text = text.trim() {
    if (this.text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'A search query is required');
    }
  }

  final String text;
  final SearchRegion region;
  final SafeSearch safeSearch;
  final SearchTimeLimit? timeLimit;
}

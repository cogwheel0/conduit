import 'dart:convert';

import '../models/release_note.dart';

/// Reads one bundled asset as text, or returns null when it does not exist.
///
/// The app supplies it (Flutter's `AssetBundle`), so the catalog does not
/// depend on Flutter.
typedef ReleaseNotesAssetLoader = Future<String?> Function(String assetPath);

/// Known icon names usable in release-note JSON `icon` fields. The widget
/// layers map each to a glyph or an image asset.
const releaseNoteIconNames = <String>{'local', 'hermes', 'direct', 'polish'};

/// Loads the baked changelog from `assets/release_notes/<locale>.json`.
///
/// Release-note copy deliberately lives outside the ARB pipeline: adding a
/// version means editing 14 structurally identical JSON files instead of
/// threading new keys through the manifest, a lookup switch, and gen-l10n.
/// Shell strings (sheet title, buttons) stay in ARB.
class ReleaseNotesCatalog {
  const ReleaseNotesCatalog({required ReleaseNotesAssetLoader loadAsset})
    : _loadAsset = loadAsset;

  static const assetDirectory = 'assets/release_notes';
  static const fallbackLocale = 'en';

  final ReleaseNotesAssetLoader _loadAsset;

  /// The notes for the locale given by its parts, falling back from the most
  /// specific asset to the language, then to English, then to nothing.
  Future<List<ReleaseNote>> load({
    required String languageCode,
    String? scriptCode,
    String? countryCode,
  }) async {
    for (final candidate in localeCandidates(
      languageCode: languageCode,
      scriptCode: scriptCode,
      countryCode: countryCode,
    )) {
      final data = await _tryLoad(candidate);
      if (data != null) {
        return data;
      }
    }
    final fallback = await _tryLoad(fallbackLocale);
    return fallback ?? const <ReleaseNote>[];
  }

  /// Asset names to try, most specific first: `zh_Hant`, then `zh`.
  static List<String> localeCandidates({
    required String languageCode,
    String? scriptCode,
    String? countryCode,
  }) {
    return <String>[
      if (scriptCode != null && scriptCode.isNotEmpty)
        '${languageCode}_$scriptCode',
      if (countryCode != null && countryCode.isNotEmpty)
        '${languageCode}_$countryCode',
      languageCode,
    ];
  }

  Future<List<ReleaseNote>?> _tryLoad(String localeName) async {
    final raw = await _loadAsset('$assetDirectory/$localeName.json');
    if (raw == null) {
      return null;
    }
    return parseReleaseNotes(raw);
  }
}

/// Parses a release-notes JSON document. Throws [FormatException] on
/// structural problems so the release validator can surface them.
List<ReleaseNote> parseReleaseNotes(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Release notes document must be an object.');
  }
  final notes = decoded['notes'];
  if (notes is! List) {
    throw const FormatException('Release notes document must have "notes".');
  }
  return notes
      .map((note) {
        if (note is! Map<String, dynamic>) {
          throw const FormatException('Each release note must be an object.');
        }
        final bullets = note['bullets'];
        if (bullets is! List || bullets.isEmpty) {
          throw FormatException(
            'Release note ${note['version']} must have non-empty "bullets".',
          );
        }
        final texts = <String>[];
        final icons = <String?>[];
        for (final bullet in bullets) {
          if (bullet is! Map<String, dynamic> || bullet['text'] is! String) {
            throw FormatException(
              'Release note ${note['version']} has a bullet without "text".',
            );
          }
          texts.add(bullet['text'] as String);
          final iconValue = bullet['icon'];
          if (iconValue != null && iconValue is! String) {
            throw FormatException(
              'Release note ${note['version']} has a bullet with an invalid '
              '"icon".',
            );
          }
          final iconName = iconValue as String?;
          icons.add(releaseNoteIconNames.contains(iconName) ? iconName : null);
        }
        return ReleaseNote(
          version: _requireString(note, 'version'),
          title: _requireString(note, 'title'),
          intro: _requireString(note, 'intro'),
          bullets: texts,
          bulletIcons: icons,
        );
      })
      .toList(growable: false);
}

String _requireString(Map<String, dynamic> note, String key) {
  final value = note[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Release note is missing "$key".');
  }
  return value;
}

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../models/release_note.dart';

/// Loads the baked changelog from `assets/release_notes/<locale>.json`.
///
/// Release-note copy deliberately lives outside the ARB pipeline: adding a
/// version means editing 13 structurally identical JSON files instead of
/// threading new keys through the manifest, a lookup switch, and gen-l10n.
/// Shell strings (sheet title, buttons) stay in ARB.
class ReleaseNotesRepository {
  const ReleaseNotesRepository({AssetBundle? bundle}) : _bundle = bundle;

  static const _assetDir = 'assets/release_notes';
  static const _fallbackLocale = 'en';

  final AssetBundle? _bundle;

  AssetBundle get _effectiveBundle => _bundle ?? rootBundle;

  Future<List<ReleaseNote>> load(Locale locale) async {
    for (final candidate in _localeCandidates(locale)) {
      final data = await _tryLoad(candidate);
      if (data != null) {
        return data;
      }
    }
    final fallback = await _tryLoad(_fallbackLocale);
    return fallback ?? const <ReleaseNote>[];
  }

  /// Most-specific first: `zh_Hant`, then `zh`.
  Iterable<String> _localeCandidates(Locale locale) sync* {
    final language = locale.languageCode;
    final script = locale.scriptCode;
    final country = locale.countryCode;
    if (script != null && script.isNotEmpty) {
      yield '${language}_$script';
    }
    if (country != null && country.isNotEmpty) {
      yield '${language}_$country';
    }
    yield language;
  }

  Future<List<ReleaseNote>?> _tryLoad(String localeName) async {
    final String raw;
    try {
      raw = await _effectiveBundle.loadString('$_assetDir/$localeName.json');
    } on FlutterError {
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
        final icons = <IconData?>[];
        final iconAssets = <String?>[];
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
          icons.add(releaseNoteIcon(iconName));
          iconAssets.add(releaseNoteIconAsset(iconName));
        }
        return ReleaseNote(
          version: _requireString(note, 'version'),
          title: _requireString(note, 'title'),
          intro: _requireString(note, 'intro'),
          bullets: texts,
          bulletIcons: icons,
          bulletIconAssets: iconAssets,
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

/// Known icon names usable in release-note JSON `icon` fields.
const releaseNoteIconNames = <String>{'local', 'hermes', 'direct', 'polish'};

IconData? releaseNoteIcon(String? name) {
  switch (name) {
    case 'local':
      return Icons.storage_rounded;
    case 'hermes':
      return null;
    case 'direct':
      return Icons.bolt_rounded;
    case 'polish':
      return Icons.design_services_rounded;
  }
  return null;
}

String? releaseNoteIconAsset(String? name) {
  return name == 'hermes' ? 'assets/icons/hermes_agent.png' : null;
}

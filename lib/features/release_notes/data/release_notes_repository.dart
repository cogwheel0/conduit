import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/release_notes/data/release_notes_catalog.dart';

import '../models/release_note.dart';

export 'package:conduit_core/features/release_notes/data/release_notes_catalog.dart'
    show parseReleaseNotes;

/// Loads the baked changelog from `assets/release_notes/<locale>.json`
/// through Flutter's asset bundle. Locale fallback and parsing live in
/// conduit_core's [ReleaseNotesCatalog].
class ReleaseNotesRepository {
  const ReleaseNotesRepository({AssetBundle? bundle}) : _bundle = bundle;

  final AssetBundle? _bundle;

  AssetBundle get _effectiveBundle => _bundle ?? rootBundle;

  Future<List<ReleaseNote>> load(Locale locale) {
    return ReleaseNotesCatalog(loadAsset: _loadAsset).load(
      languageCode: locale.languageCode,
      scriptCode: locale.scriptCode,
      countryCode: locale.countryCode,
    );
  }

  Future<String?> _loadAsset(String assetPath) async {
    try {
      return await _effectiveBundle.loadString(assetPath);
    } on FlutterError {
      return null;
    }
  }
}

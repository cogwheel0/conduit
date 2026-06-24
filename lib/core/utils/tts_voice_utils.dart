import '../../l10n/app_localizations.dart';
import '../services/settings_service.dart';

const ttsSystemDefaultVoiceId = '__system_default__';

class TtsVoiceOptionData {
  const TtsVoiceOptionData({
    required this.id,
    required this.label,
    required this.voice,
    this.subtitle,
  });

  final String id;
  final String label;
  final String? subtitle;
  final Map<String, dynamic> voice;
}

List<TtsVoiceOptionData> buildTtsVoiceOptions(
  AppLocalizations l10n,
  TtsEngine engine,
  Iterable<Map<String, dynamic>> voices,
) {
  final seen = <String>{};
  final options = <TtsVoiceOptionData>[];
  for (final voice in voices) {
    final id = ttsVoiceIdFor(engine, voice);
    if (id.isEmpty || !seen.add(id)) {
      continue;
    }
    options.add(
      TtsVoiceOptionData(
        id: id,
        label: ttsVoiceNameFor(l10n, voice),
        subtitle: ttsVoiceSubtitleFor(voice),
        voice: voice,
      ),
    );
  }
  return options;
}

String selectedTtsVoiceOptionId(
  AppSettings settings,
  Iterable<Map<String, dynamic>> voices,
) {
  final storedId = _selectedStoredVoiceId(settings);
  if (storedId == null || storedId.isEmpty) {
    return ttsSystemDefaultVoiceId;
  }

  for (final voice in voices) {
    if (ttsVoiceMatchesSettings(settings, voice)) {
      return ttsVoiceIdFor(settings.ttsEngine, voice);
    }
  }

  return storedId;
}

bool ttsVoiceMatchesSettings(AppSettings settings, Map<String, dynamic> voice) {
  final storedId = _selectedStoredVoiceId(settings);
  final storedName = _selectedStoredVoiceName(settings);
  return ttsVoiceMatches(
    settings.ttsEngine,
    voice,
    storedId: storedId,
    storedName: storedName,
  );
}

bool ttsVoiceMatches(
  TtsEngine engine,
  Map<String, dynamic> voice, {
  String? storedId,
  String? storedName,
}) {
  final aliases = ttsVoiceAliasesFor(engine, voice);
  final normalizedId = _normalizeVoiceKey(storedId);
  if (normalizedId != null && aliases.contains(normalizedId)) {
    return true;
  }

  final normalizedName = _normalizeVoiceKey(storedName);
  return normalizedName != null && aliases.contains(normalizedName);
}

TtsVoiceOptionData? findTtsVoiceOption(
  AppLocalizations l10n,
  TtsEngine engine,
  Iterable<Map<String, dynamic>> voices,
  String selectedId,
) {
  for (final voice in voices) {
    if (ttsVoiceMatches(engine, voice, storedId: selectedId)) {
      return TtsVoiceOptionData(
        id: ttsVoiceIdFor(engine, voice),
        label: ttsVoiceNameFor(l10n, voice),
        subtitle: ttsVoiceSubtitleFor(voice),
        voice: voice,
      );
    }
  }
  return null;
}

Set<String> ttsVoiceAliasesFor(TtsEngine engine, Map<String, dynamic> voice) {
  final keys = switch (engine) {
    TtsEngine.server => const <String>[
      'id',
      'name',
      'identifier',
      'voiceIdentifier',
    ],
    TtsEngine.device => const <String>[
      'identifier',
      'id',
      'voiceIdentifier',
      'name',
      'displayName',
      'locale',
      'language',
    ],
  };

  return {for (final key in keys) ?_normalizeVoiceKey(voice[key]?.toString())};
}

String ttsVoiceIdFor(TtsEngine engine, Map<String, dynamic> voice) {
  final id = _cleanVoiceValue(voice['id']);
  final name = _cleanVoiceValue(voice['name']);
  final identifier = _cleanVoiceValue(voice['identifier']);
  final voiceIdentifier = _cleanVoiceValue(voice['voiceIdentifier']);
  final locale = _cleanVoiceValue(voice['locale'] ?? voice['language']);

  return switch (engine) {
    TtsEngine.server =>
      id ?? name ?? identifier ?? voiceIdentifier ?? locale ?? '',
    TtsEngine.device =>
      identifier ?? id ?? voiceIdentifier ?? name ?? locale ?? '',
  };
}

String ttsVoiceNameFor(AppLocalizations l10n, Map<String, dynamic> voice) {
  final raw =
      _cleanVoiceValue(voice['displayName']) ??
      _cleanVoiceValue(voice['name']) ??
      _cleanVoiceValue(voice['id']) ??
      _cleanVoiceValue(voice['identifier']) ??
      _cleanVoiceValue(voice['voiceIdentifier']) ??
      l10n.unknownLabel;
  return formatTtsVoiceDisplayName(raw);
}

String? ttsVoiceSubtitleFor(Map<String, dynamic> voice) {
  final languageName = _cleanVoiceValue(voice['languageName']);
  final locale = _cleanVoiceValue(voice['locale'] ?? voice['language']);
  final quality = _cleanVoiceValue(voice['qualityName']);
  final parts = <String>[
    ?languageName,
    if (languageName == null) ?locale,
    ?quality,
    if (voice['isPersonalVoice'] == true) 'Personal Voice',
    if (voice['isNoveltyVoice'] == true) 'Novelty',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String formatTtsVoiceDisplayName(String voiceName) {
  if (voiceName.isEmpty) {
    return voiceName;
  }

  if (voiceName.contains('#')) {
    final parts = voiceName.split('#');
    if (parts.length > 1) {
      final friendlyName = _friendlyAndroidVoiceSuffix(parts[1]);
      final localeInfo = parts[0].toUpperCase().replaceAll('_', '-');
      return localeInfo.isEmpty ? friendlyName : '$localeInfo - $friendlyName';
    }
  }

  if (voiceName.contains('-x-') ||
      voiceName.endsWith('-local') ||
      voiceName.endsWith('-network') ||
      voiceName.endsWith('-language')) {
    var localePart = '';
    var qualityPart = '';

    if (voiceName.contains('-x-')) {
      final xParts = voiceName.split('-x-');
      localePart = xParts[0];
      qualityPart = xParts.length > 1 ? xParts[1] : '';
    } else if (voiceName.contains('-language')) {
      localePart = voiceName.replaceAll('-language', '');
    } else {
      final dashIndex = voiceName.indexOf('-', 3);
      localePart = dashIndex > 0
          ? voiceName.substring(0, dashIndex)
          : voiceName;
    }

    final formattedLocale = localePart.toUpperCase();
    if (qualityPart.isEmpty) {
      return formattedLocale;
    }

    final formattedQuality = qualityPart
        .replaceAll('-local', '')
        .replaceAll('-network', '')
        .toUpperCase();
    return '$formattedLocale ($formattedQuality)';
  }

  return voiceName;
}

String? _selectedStoredVoiceId(AppSettings settings) {
  return switch (settings.ttsEngine) {
    TtsEngine.server => _cleanVoiceValue(settings.ttsServerVoiceId),
    TtsEngine.device => _cleanVoiceValue(settings.ttsVoice),
  };
}

String? _selectedStoredVoiceName(AppSettings settings) {
  return switch (settings.ttsEngine) {
    TtsEngine.server => _cleanVoiceValue(settings.ttsServerVoiceName),
    TtsEngine.device => _cleanVoiceValue(settings.ttsVoiceName),
  };
}

String _friendlyAndroidVoiceSuffix(String suffix) {
  return suffix
      .replaceAll('-local', '')
      .replaceAll('-network', '')
      .replaceAll('_', ' ')
      .split(' ')
      .map(
        (word) => word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1),
      )
      .join(' ');
}

String? _cleanVoiceValue(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String? _normalizeVoiceKey(String? value) {
  final cleaned = _cleanVoiceValue(value);
  return cleaned?.toLowerCase();
}

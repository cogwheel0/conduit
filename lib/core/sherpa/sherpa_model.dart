enum SherpaModelKind { stt, tts }

enum SherpaRecognitionMode { offline, streaming }

enum SherpaModelTier { compact, standard, large }

enum SherpaWorkingSet { low, medium, high }

enum SherpaModelFamily {
  whisper,
  senseVoice,
  zipformer,
  parakeet,
  nemotron,
  piper,
  mimic3,
  supertonic,
  kokoro,
}

enum SherpaRuntimeAdapter {
  offlineWhisper,
  offlineSenseVoice,
  offlineNemoCtc,
  offlineNemoTransducer,
  onlineTransducer,
  onlineZipformer2Ctc,
  ttsVits,
  ttsSupertonic,
  ttsKokoro,
}

enum SherpaLanguageQuality { firstClass, supported }

final class SherpaLanguage {
  const SherpaLanguage(
    this.tag, {
    this.quality = SherpaLanguageQuality.supported,
  });

  final String tag;
  final SherpaLanguageQuality quality;
}

final class SherpaSpeaker {
  const SherpaSpeaker({required this.id, this.name});

  final int id;
  final String? name;
}

final class SherpaLicense {
  const SherpaLicense({required this.name, required this.url});

  final String name;
  final Uri url;
}

/// A required runtime file selected by its suffix within an extracted archive.
///
/// Archives use a versioned top-level folder. Suffix matching keeps that folder
/// out of the trusted catalog while still rejecting missing or ambiguous roles.
final class SherpaFileRole {
  const SherpaFileRole(this.name, this.pathSuffix, {this.optional = false});

  final String name;
  final String pathSuffix;
  final bool optional;
}

final class SherpaRuntimeConfig {
  const SherpaRuntimeConfig({
    required this.files,
    this.modelType = '',
    this.language = '',
    this.task = 'transcribe',
    this.ruleFstsRole,
    this.threadCount = 2,
  });

  final List<SherpaFileRole> files;
  final String modelType;
  final String language;
  final String task;
  final String? ruleFstsRole;
  final int threadCount;
}

final class SherpaModel {
  const SherpaModel({
    required this.id,
    required this.release,
    required this.displayName,
    required this.family,
    required this.adapter,
    required this.kind,
    required this.mode,
    required this.languages,
    required this.tier,
    required this.archiveUrl,
    required this.sha256,
    required this.archiveBytes,
    required this.installedBytes,
    required this.workingSet,
    required this.runtime,
    required this.source,
    required this.license,
    required this.minimumSherpaVersion,
    this.speakers = const [],
    this.supportedAbis = const [
      'armeabi-v7a',
      'arm64-v8a',
      'x86',
      'x86_64',
      'arm64',
    ],
    this.platforms = const [PlatformType.android, PlatformType.ios],
    this.recommended = false,
  });

  final String id;
  final String release;
  final String displayName;
  final SherpaModelFamily family;
  final SherpaRuntimeAdapter adapter;
  final SherpaModelKind kind;
  final SherpaRecognitionMode mode;
  final List<SherpaLanguage> languages;
  final List<SherpaSpeaker> speakers;
  final SherpaModelTier tier;
  final Uri archiveUrl;
  final String sha256;
  final int archiveBytes;

  /// Conservative preflight value. Installed models report their measured
  /// on-disk size instead.
  final int installedBytes;
  final SherpaWorkingSet workingSet;
  final SherpaRuntimeConfig runtime;
  final Uri source;
  final SherpaLicense license;
  final String minimumSherpaVersion;
  final List<String> supportedAbis;
  final List<PlatformType> platforms;
  final bool recommended;

  bool supportsLanguage(String tag) {
    final primary = tag.toLowerCase().split(RegExp('[-_]')).first;
    return languages.any(
      (language) => language.tag.toLowerCase().split('-').first == primary,
    );
  }
}

enum PlatformType { android, ios }

extension SherpaModelFamilyLabel on SherpaModelFamily {
  String get label => switch (this) {
    SherpaModelFamily.whisper => 'Whisper',
    SherpaModelFamily.senseVoice => 'SenseVoice',
    SherpaModelFamily.zipformer => 'Zipformer',
    SherpaModelFamily.parakeet => 'NVIDIA Parakeet',
    SherpaModelFamily.nemotron => 'NVIDIA Nemotron',
    SherpaModelFamily.piper => 'Piper',
    SherpaModelFamily.mimic3 => 'Mimic3',
    SherpaModelFamily.supertonic => 'Supertonic',
    SherpaModelFamily.kokoro => 'Kokoro',
  };
}

extension SherpaModelTierLabel on SherpaModelTier {
  String get label => switch (this) {
    SherpaModelTier.compact => 'Compact',
    SherpaModelTier.standard => 'Standard',
    SherpaModelTier.large => 'Large',
  };
}

String formatModelBytes(int bytes) {
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).toStringAsFixed(bytes >= 100 * mb ? 0 : 1)} MB';
}

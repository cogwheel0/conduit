/// Per-chat Open WebUI generation settings (`chat.params`).
///
/// Open WebUI stores a chat's own parameters and system prompt under
/// `chat.params`, and merges them over the user's global parameters on every
/// completion. This file is the one place that knows how: the lossless
/// projection of the stored map, the merge and `stop` normalization, which
/// system message a turn carries, and who may edit what. Pure Dart, so the
/// request builder, the chat providers and the editor all agree.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

/// Version written into [OpenWebUiChatSettingsSnapshot]. A reader that does
/// not recognize the version treats the payload as having no snapshot.
///
/// Version 1 carried only the chat's own params and the reasoning pick, so the
/// user's global defaults were read again at replay. Version 2 adds the
/// [OpenWebUiAdmittedBaseline]. Both stay readable.
const int kOpenWebUiChatSettingsSnapshotVersion = 2;
const int _kSnapshotVersionWithoutBaseline = 1;

/// Keys the editor understands. Everything else a chat carries is preserved
/// untouched and still sent, but never offered for editing.
const String kChatParamSystem = 'system';
const String kChatParamTemperature = 'temperature';
const String kChatParamTopP = 'top_p';
const String kChatParamTopK = 'top_k';
const String kChatParamMinP = 'min_p';
const String kChatParamFrequencyPenalty = 'frequency_penalty';
const String kChatParamPresencePenalty = 'presence_penalty';
const String kChatParamMaxTokens = 'max_tokens';
const String kChatParamSeed = 'seed';
const String kChatParamStop = 'stop';
const String kChatParamReasoningEffort = 'reasoning_effort';
const String kChatParamFunctionCalling = 'function_calling';

/// `chat.params` as a map. Anything that is not a JSON object (absent, null,
/// a corrupt scalar) reads as empty; the raw blob keeps the original bytes,
/// so a read never loses data.
Map<String, dynamic> openWebUiChatParamsFrom(Object? raw) {
  if (raw is! Map) return <String, dynamic>{};
  return <String, dynamic>{
    for (final entry in raw.entries)
      entry.key.toString(): _deepCopyJson(entry.value),
  };
}

/// `params` out of a stored chat envelope (`chats.raw_extra`, a JSON object).
/// Reads leniently: an unreadable envelope has no params.
Map<String, dynamic> openWebUiChatParamsFromRawExtra(String rawExtra) {
  if (rawExtra.isEmpty) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(rawExtra);
    return decoded is Map
        ? openWebUiChatParamsFrom(decoded['params'])
        : <String, dynamic>{};
  } on FormatException {
    return <String, dynamic>{};
  }
}

Object? _deepCopyJson(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _deepCopyJson(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _deepCopyJson(item)];
  }
  return value;
}

/// The user-level half of a turn's settings, as last known when the turn was
/// admitted.
///
/// [globalParams] is the account's global generation defaults exactly as the
/// server stored them (`stop` still un-normalized, so it is normalized once,
/// when the request is composed). [systemMessage] is the system message the
/// turn carries once the chat's own prompt, the legacy `chat.system` and the
/// user's global prompt were resolved: null means "no system message", an
/// empty string is a deliberate empty one.
///
/// When the account's settings were not known at admission (offline, nothing
/// cached for that account) both are what was resolvable then: no global
/// params and a prompt from the chat alone. They are never filled in later.
@immutable
final class OpenWebUiAdmittedBaseline {
  OpenWebUiAdmittedBaseline({
    Map<String, dynamic> globalParams = const <String, dynamic>{},
    this.systemMessage,
  }) : globalParams = Map<String, dynamic>.unmodifiable(
         openWebUiChatParamsFrom(globalParams),
       );

  final Map<String, dynamic> globalParams;
  final String? systemMessage;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'globalParams': globalParams,
    // Present even when null: "no system message" is an admitted result.
    'systemMessage': systemMessage,
  };

  /// Null when [json] is absent or not shaped like a baseline, in which case
  /// the snapshot has none and the globals are read at replay.
  static OpenWebUiAdmittedBaseline? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final globalParams = json['globalParams'];
    if (globalParams is! Map || !json.containsKey('systemMessage')) return null;
    final system = json['systemMessage'];
    if (system != null && system is! String) return null;
    return OpenWebUiAdmittedBaseline(
      globalParams: openWebUiChatParamsFrom(globalParams),
      systemMessage: system as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiAdmittedBaseline &&
      other.systemMessage == systemMessage &&
      jsonEncode(other.globalParams) == jsonEncode(globalParams);

  @override
  int get hashCode => Object.hash(systemMessage, jsonEncode(globalParams));
}

/// The settings one completion was admitted with.
///
/// Stored inside a queued `requestCompletion` so an edit (or a different
/// global setting) made after the user pressed send cannot change the turn
/// when it is finally replayed. A payload with no snapshot predates this
/// field; a snapshot with empty [params] is a deliberate "no overrides"; a
/// snapshot with no [baseline] (version 1) froze only the chat's own half.
@immutable
final class OpenWebUiChatSettingsSnapshot {
  OpenWebUiChatSettingsSnapshot({
    Map<String, dynamic> params = const <String, dynamic>{},
    this.reasoningEffort,
    this.baseline,
  }) : params = Map<String, dynamic>.unmodifiable(
         openWebUiChatParamsFrom(params),
       );

  /// The chat's own `params`, verbatim (including keys this app never edits).
  final Map<String, dynamic> params;

  /// The reasoning-picker value for the turn's model when the chat had no
  /// saved `reasoning_effort`, or null when the picker had no explicit value.
  final String? reasoningEffort;

  /// The global defaults and resolved system message, or null for a version 1
  /// snapshot whose globals are still read when the turn is replayed.
  final OpenWebUiAdmittedBaseline? baseline;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': kOpenWebUiChatSettingsSnapshotVersion,
    'params': params,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
    if (baseline != null) 'baseline': baseline!.toJson(),
  };

  /// Null when [json] is absent, from a version this build does not know, or
  /// malformed: callers then fall back to the chat's stored params exactly as
  /// they did before snapshots existed.
  static OpenWebUiChatSettingsSnapshot? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['v'];
    if (version != kOpenWebUiChatSettingsSnapshotVersion &&
        version != _kSnapshotVersionWithoutBaseline) {
      return null;
    }
    final params = json['params'];
    if (params is! Map) return null;
    final effort = json['reasoningEffort'];
    return OpenWebUiChatSettingsSnapshot(
      params: openWebUiChatParamsFrom(params),
      reasoningEffort: effort is String ? effort : null,
      baseline: version == kOpenWebUiChatSettingsSnapshotVersion
          ? OpenWebUiAdmittedBaseline.tryFromJson(json['baseline'])
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiChatSettingsSnapshot &&
      other.reasoningEffort == reasoningEffort &&
      other.baseline == baseline &&
      jsonEncode(other.params) == jsonEncode(params);

  @override
  int get hashCode =>
      Object.hash(reasoningEffort, baseline, jsonEncode(params));
}

/// Which system message a turn is sent with.
///
/// Open WebUI sends one when `params.system || settings.system` is truthy and
/// fills it with `params.system ?? settings.system ?? ''`. A saved empty
/// string therefore replaces a non-empty global prompt with an empty message,
/// and replaces nothing when there is no global prompt.
///
/// When the chat has no `params.system` (absent or null) the legacy
/// `chat.system` field, then the user's global prompt, apply as before.
///
/// Returns null for "no system message"; an empty string is a real, explicit
/// empty message.
String? resolveOpenWebUiSystemMessage({
  required Map<String, dynamic> chatParams,
  String? legacyChatSystem,
  String? globalSystem,
}) {
  final global = globalSystem?.trim() ?? '';
  final saved = chatParams[kChatParamSystem];
  if (saved is String) {
    if (saved.isNotEmpty) return saved;
    return global.isNotEmpty ? '' : null;
  }
  final legacy = legacyChatSystem?.trim() ?? '';
  if (legacy.isNotEmpty) return legacy;
  return global.isNotEmpty ? global : null;
}

/// The user's global generation params out of their stored settings document.
///
/// The web client keeps them in `ui.params` (`SettingsModal.svelte` saves the
/// whole `ui` object), so a present `ui.params` object wins, an empty one
/// included: clearing the defaults in the browser must not resurrect an older
/// root-level `params`. Only when `ui.params` is absent (or not an object)
/// does the legacy root `params` apply. Null when neither exists.
Map<String, dynamic>? openWebUiGlobalParamsFromSettings(
  Map<String, dynamic>? settings,
) {
  if (settings == null) return null;
  final ui = settings['ui'];
  final modern = ui is Map ? ui['params'] : null;
  if (modern is Map) return openWebUiChatParamsFrom(modern);
  final legacy = settings['params'];
  return legacy is Map ? openWebUiChatParamsFrom(legacy) : null;
}

/// `{...globalParams, ...chatParams}` with `stop` normalized once.
///
/// Mirrors the web client's request composition: the chat's keys win over the
/// global ones (a saved null still wins, and the server skips null values),
/// and `stop` is taken from the chat when it has one, otherwise the global
/// value. Only the keys either side carries are present, so the backend can
/// still supply a model's own defaults for everything else.
Map<String, dynamic> resolveOpenWebUiRequestParams({
  Map<String, dynamic>? globalParams,
  Map<String, dynamic>? chatParams,
}) {
  final merged = <String, dynamic>{...?globalParams, ...?chatParams};
  final stop = normalizeOpenWebUiStopTokens(
    chatParams?[kChatParamStop] ?? globalParams?[kChatParamStop],
  );
  if (stop == null) {
    merged.remove(kChatParamStop);
  } else {
    merged[kChatParamStop] = stop;
  }
  return merged;
}

/// The web client's `getStopTokens()`: a list is used as is, a string is split
/// on commas, empty entries are dropped, and each token has its JSON escapes
/// (`\n`) and percent-escapes decoded. A token that cannot be decoded is kept
/// as typed rather than failing the send. Null when nothing remains, so the
/// server falls back to its own stop sequences.
List<String>? normalizeOpenWebUiStopTokens(Object? stop) {
  final List<String> raw;
  if (stop is List) {
    raw = <String>[
      for (final token in stop)
        if (token is String) token,
    ];
  } else if (stop is String && stop.isNotEmpty) {
    raw = stop.split(',').map((token) => token.trim()).toList();
  } else {
    return null;
  }
  final tokens = <String>[
    for (final token in raw)
      if (token.isNotEmpty) _decodeStopToken(token),
  ];
  return tokens.isEmpty ? null : tokens;
}

final RegExp _percentRun = RegExp(r'(?:%[0-9A-Fa-f]{2})+');

String _decodeStopToken(String token) {
  final String unescaped;
  try {
    final decoded = jsonDecode('"${token.replaceAll('"', r'\"')}"');
    if (decoded is! String) return token;
    unescaped = decoded;
  } on FormatException {
    return token;
  }
  // Only `%XX` runs are percent-decoded: Dart's Uri.decodeComponent rejects
  // non-ASCII text that decodeURIComponent passes through unchanged.
  return unescaped.replaceAllMapped(_percentRun, (match) {
    try {
      return Uri.decodeComponent(match[0]!);
    } on ArgumentError {
      return match[0]!;
    } on FormatException {
      return match[0]!;
    }
  });
}

/// What the signed-in user may change on a chat, per the web client's
/// `settings-access.ts`: an admin always; anyone else needs `chat.controls`
/// plus `chat.system_prompt` / `chat.params`, each defaulting to allowed when
/// the server does not report it.
@immutable
final class OpenWebUiChatSettingsAccess {
  const OpenWebUiChatSettingsAccess({
    required this.canEditSystemPrompt,
    required this.canEditParameters,
  });

  static const denied = OpenWebUiChatSettingsAccess(
    canEditSystemPrompt: false,
    canEditParameters: false,
  );

  static const all = OpenWebUiChatSettingsAccess(
    canEditSystemPrompt: true,
    canEditParameters: true,
  );

  final bool canEditSystemPrompt;
  final bool canEditParameters;

  bool get canEditAnything => canEditSystemPrompt || canEditParameters;

  factory OpenWebUiChatSettingsAccess.fromPermissions({
    required String? role,
    required Map<String, dynamic>? permissions,
  }) {
    if (role == 'admin') return all;
    final chat = permissions?['chat'];
    bool flag(String key) {
      final value = chat is Map ? chat[key] : null;
      return value is bool ? value : true;
    }

    final controls = flag('controls');
    return OpenWebUiChatSettingsAccess(
      canEditSystemPrompt: controls && flag('system_prompt'),
      canEditParameters: controls && flag('params'),
    );
  }
}

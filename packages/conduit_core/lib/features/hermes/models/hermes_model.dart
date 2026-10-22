import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:conduit_core/models/model.dart';

/// Sentinel model id prefix for the synthetic Hermes agent entry in the picker.
const String kHermesModelIdPrefix = 'hermes:agent:';

/// The default synthetic model id used when Hermes is enabled. A single entry is
/// enough for v1 — the Hermes server routes to its configured agent regardless
/// of the specific model id sent.
const String kHermesDefaultModelId = '${kHermesModelIdPrefix}default';

/// Bundled Hermes mark used anywhere a Hermes model needs an avatar.
const String kHermesModelAvatarAsset = 'assets/icons/hermes_agent.png';

final class HermesDesktopModelOption {
  const HermesDesktopModelOption({
    required this.id,
    required this.name,
    required this.provider,
    required this.supportsFast,
    required this.supportsReasoning,
    this.reasoningAvailable,
    this.canDisableReasoning,
    this.baseUrl,
    this.supportedEfforts,
    this.recommended,
    this.isDefault,
    this.popular,
    this.recommendationRank,
    this.deprecated,
    this.retired,
    this.shutdownAt,
  });

  factory HermesDesktopModelOption.fromJson(Map<String, dynamic> json) {
    final capabilities = json['capabilities'];
    return HermesDesktopModelOption(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? json['id']?.toString() ?? '',
      provider: json['provider']?.toString() ?? '',
      baseUrl: json['base_url'] is String ? json['base_url'] as String : null,
      recommended: json['recommended'] is bool
          ? json['recommended'] as bool
          : null,
      isDefault: json['is_default'] is bool
          ? json['is_default'] as bool
          : json['isDefault'] is bool
          ? json['isDefault'] as bool
          : null,
      popular: json['popular'] is bool ? json['popular'] as bool : null,
      recommendationRank:
          json['recommendation_rank'] is num &&
              (json['recommendation_rank'] as num).isFinite &&
              (json['recommendation_rank'] as num) >= 0
          ? (json['recommendation_rank'] as num).toDouble()
          : null,
      deprecated: json['deprecated'] is bool
          ? json['deprecated'] as bool
          : null,
      retired: json['retired'] is bool ? json['retired'] as bool : null,
      shutdownAt:
          hermesModelShutdownAt(json['shutdown_at']) ??
          hermesModelShutdownAt(json['shutdown_date']),
      supportsFast:
          json['fast'] == true ||
          (capabilities is Map && capabilities['fast'] == true),
      supportsReasoning:
          json['reasoning'] == true ||
          (capabilities is Map && capabilities['reasoning'] == true),
      reasoningAvailable:
          capabilities is Map && capabilities['reasoning'] is bool
          ? capabilities['reasoning'] as bool
          : null,
      supportedEfforts:
          capabilities is Map && capabilities['supported_efforts'] is List
          ? (capabilities['supported_efforts'] as List)
                .whereType<String>()
                .where((e) => RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(e))
                .toList(growable: false)
          : null,
      canDisableReasoning:
          capabilities is Map && capabilities['can_disable_reasoning'] is bool
          ? capabilities['can_disable_reasoning'] as bool
          : null,
    );
  }

  final String id;
  final String name;
  final String provider;
  final bool supportsFast;
  final bool supportsReasoning;
  final bool? reasoningAvailable;
  final bool? canDisableReasoning;
  final String? baseUrl;
  final List<String>? supportedEfforts;

  /// Optional gateway catalog hints. Absence is unknown, not an endorsement.
  final bool? recommended;
  final bool? isDefault;
  final bool? popular;
  final double? recommendationRank;
  final bool? deprecated;
  final bool? retired;
  final DateTime? shutdownAt;

  bool isRetiredAt(DateTime now) =>
      retired == true ||
      (shutdownAt != null && !shutdownAt!.isAfter(now.toUtc()));

  /// Applies a read-only provider recommendation to an existing catalog entry.
  /// Negative recommendation and lifecycle hints remain intact.
  HermesDesktopModelOption withRecommendedDefault() => HermesDesktopModelOption(
    id: id,
    name: name,
    provider: provider,
    supportsFast: supportsFast,
    supportsReasoning: supportsReasoning,
    reasoningAvailable: reasoningAvailable,
    canDisableReasoning: canDisableReasoning,
    baseUrl: baseUrl,
    supportedEfforts: supportedEfforts,
    recommended: recommended,
    isDefault: true,
    popular: popular,
    recommendationRank: recommendationRank,
    deprecated: deprecated,
    retired: retired,
    shutdownAt: shutdownAt,
  );
  List<String> get effortLevels => HermesSessionReasoningSettings(
    reasoningAvailable: reasoningAvailable,
    canDisableReasoning: canDisableReasoning,
    supportedEfforts: supportedEfforts,
  ).levels;
}

/// Reads a shutdown date only when a gateway actually supplies one, accepting
/// Unix seconds or an ISO date. A missing date leaves lifecycle unknown.
DateTime? hermesModelShutdownAt(Object? raw) {
  if (raw is num && raw.isFinite && raw >= 0 && raw <= 253402300799) {
    return DateTime.fromMillisecondsSinceEpoch(
      (raw * 1000).round(),
      isUtc: true,
    );
  }
  if (raw is String && raw.length <= 64) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null || parsed.isUtc) return parsed;
    // Provider calendar dates use UTC, not the phone's local time zone.
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }
  return null;
}

/// Current route and catalog from one profile-scoped model.options response.
/// Optional recommendation discovery is deliberately outside screen readiness.
class HermesModelContext {
  const HermesModelContext({
    required this.profile,
    required this.models,
    required this.settings,
  });
  final String profile;
  final List<HermesDesktopModelOption> models;
  final HermesSessionReasoningSettings settings;
}

class HermesSessionReasoningSettings {
  const HermesSessionReasoningSettings({
    this.effort,
    this.display,
    this.model,
    this.reasoningAvailable,
    this.canDisableReasoning,
    this.supportedEfforts,
    this.modelId,
    this.provider,
    this.fast,
    this.supportsFast = false,
  });
  final String? modelId, provider;
  final bool? fast;
  final bool supportsFast;
  final List<String>? supportedEfforts;
  final String? effort;
  final bool? display;
  final String? model;
  final bool? reasoningAvailable;
  final bool? canDisableReasoning;
  List<String> get levels => reasoningAvailable == false
      ? const []
      : supportedEfforts != null
      ? [
          if (canDisableReasoning == true &&
              !supportedEfforts!.contains("none"))
            "none",
          ...supportedEfforts!,
        ]
      : [
          if (canDisableReasoning != false) 'none',
          'minimal',
          'low',
          'medium',
          'high',
          'xhigh',
          'max',
          'ultra',
        ];
}

/// Runtime-only provenance for models minted by [hermesSyntheticModel].
///
/// OpenWebUI controls every field in a model response, including its id and
/// metadata, so neither can safely select a different network backend. An
/// [Expando] is deliberately not serializable or forgeable from JSON.
final Expando<bool> _locallyMintedHermesModels = Expando<bool>(
  'locally-minted-hermes-model',
);

/// Whether [model] is the synthetic Hermes agent (routes to the direct Hermes
/// backend instead of OpenWebUI).
///
/// The decision is intentionally runtime-only. Never infer transport from
/// server-controlled ids or metadata.
bool isHermesModel(Model model) => _locallyMintedHermesModels[model] == true;

/// Whether a remote/cached model collides with Conduit's reserved Hermes
/// namespace. Collisions are removed before models reach selection/routing.
bool hasReservedHermesIdentity(Model model) =>
    model.id.startsWith(kHermesModelIdPrefix) ||
    model.metadata?['backend'] == 'hermes';

/// Drops remote models that attempt to claim the app-owned Hermes identity.
List<Model> sanitizeRemoteHermesModels(Iterable<Model> models) => models
    .where(
      (model) => !isHermesModel(model) && !hasReservedHermesIdentity(model),
    )
    .toList(growable: false);

/// Builds the synthetic Hermes model surfaced in the picker when the feature
/// is enabled, named after the active saved connection ([name]) or
/// "Hermes Agent" without one.
Model hermesSyntheticModel({String? name}) {
  final trimmed = name?.trim();
  final model = Model(
    id: kHermesDefaultModelId,
    name: trimmed == null || trimmed.isEmpty ? 'Hermes Agent' : trimmed,
    description: 'Your self-hosted Hermes agent',
    supportsStreaming: true,
    metadata: const {
      'backend': 'hermes',
      'hermesModelId': 'default',
      'hermesConfiguredDefault': true,
    },
  );
  _locallyMintedHermesModels[model] = true;
  return model;
}

/// Locally mints one provider/model option returned by Desktop's
/// `model.options`; transport routing never trusts its serializable metadata.
Model hermesDesktopModel({
  required String modelId,
  required String name,
  required String provider,
  bool supportsFast = false,
  bool supportsReasoning = false,
}) {
  final digest = base64Url
      .encode(sha256.convert(utf8.encode('$provider\u0000$modelId')).bytes)
      .replaceAll('=', '');
  final model = Model(
    id: '${kHermesModelIdPrefix}desktop:$digest',
    name: name,
    description: provider.isEmpty ? 'Hermes Desktop' : 'Hermes · $provider',
    supportsStreaming: true,
    metadata: {
      'backend': 'hermes',
      'hermesModelId': modelId,
      'hermesProvider': provider,
      'hermesConfiguredDefault': false,
      'hermesFast': supportsFast,
      'hermesReasoning': supportsReasoning,
    },
  );
  _locallyMintedHermesModels[model] = true;
  return model;
}

bool? hermesFastTierSelection({
  required bool supported,
  required bool selected,
}) => supported ? selected : null;

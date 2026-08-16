import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/models/model.dart';

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
  });

  factory HermesDesktopModelOption.fromJson(Map<String, dynamic> json) {
    final capabilities = json['capabilities'];
    return HermesDesktopModelOption(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? json['id']?.toString() ?? '',
      provider: json['provider']?.toString() ?? '',
      supportsFast:
          json['fast'] == true ||
          (capabilities is Map && capabilities['fast'] == true),
      supportsReasoning:
          json['reasoning'] == true ||
          (capabilities is Map && capabilities['reasoning'] == true),
    );
  }

  final String id;
  final String name;
  final String provider;
  final bool supportsFast;
  final bool supportsReasoning;
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

/// Builds the synthetic "Hermes Agent" model surfaced in the picker when the
/// feature is enabled.
Model hermesSyntheticModel() {
  final model = Model(
    id: kHermesDefaultModelId,
    name: 'Hermes Agent',
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

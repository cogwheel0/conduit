import '../../../core/models/model.dart';

/// Sentinel model id prefix for the synthetic Hermes agent entry in the picker.
const String kHermesModelIdPrefix = 'hermes:agent:';

/// The default synthetic model id used when Hermes is enabled. A single entry is
/// enough for v1 — the Hermes server routes to its configured agent regardless
/// of the specific model id sent.
const String kHermesDefaultModelId = '${kHermesModelIdPrefix}default';

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
    metadata: const {'backend': 'hermes', 'hermesModelId': 'default'},
  );
  _locallyMintedHermesModels[model] = true;
  return model;
}

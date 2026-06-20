import '../../../core/models/model.dart';

/// Sentinel model id prefix for the synthetic Hermes agent entry in the picker.
const String kHermesModelIdPrefix = 'hermes:agent:';

/// The default synthetic model id used when Hermes is enabled. A single entry is
/// enough for v1 — the Hermes server routes to its configured agent regardless
/// of the specific model id sent.
const String kHermesDefaultModelId = '${kHermesModelIdPrefix}default';

/// Whether [model] is the synthetic Hermes agent (routes to the direct Hermes
/// backend instead of OpenWebUI).
///
/// Keys off `metadata['backend'] == 'hermes'` (authoritative, survives
/// `Model.toJson`/`fromJson`) with the id prefix as a fallback.
bool isHermesModel(Model model) {
  if (model.metadata?['backend'] == 'hermes') return true;
  return model.id.startsWith(kHermesModelIdPrefix);
}

/// Builds the synthetic "Hermes Agent" model surfaced in the picker when the
/// feature is enabled.
Model hermesSyntheticModel() => const Model(
  id: kHermesDefaultModelId,
  name: 'Hermes Agent',
  description: 'Your self-hosted Hermes agent',
  supportsStreaming: true,
  metadata: {'backend': 'hermes', 'hermesModelId': 'default'},
);

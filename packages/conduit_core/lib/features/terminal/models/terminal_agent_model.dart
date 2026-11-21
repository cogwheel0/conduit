import 'package:conduit_core/models/model.dart';

/// The id prefix Open WebUI (0.13.1 and later) gives a coding agent that one
/// of its terminals offers as a model:
/// `agent:<terminal id>:<agent>:<agent's model>`, the terminal id
/// URL-encoded. Up to 0.13.3 the model is URL-encoded too; 0.13.4 makes it a
/// slug.
const String kTerminalAgentModelPrefix = 'agent:';

/// What a coding agent's model id names: the terminal it runs on, the agent
/// (`codex`, `claude-code`, `pi`, …) and the agent's own model.
typedef TerminalAgentModelRef = ({
  String terminalId,
  String provider,
  String model,
});

/// The parts of a coding agent's model id, or null when [id] is not one.
///
/// Open WebUI splits the id at its first three colons, so only the model
/// part may hold one more, and it never does: the model is URL-encoded.
TerminalAgentModelRef? parseTerminalAgentModelId(String? id) {
  if (id == null || !id.startsWith(kTerminalAgentModelPrefix)) return null;
  final rest = id.substring(kTerminalAgentModelPrefix.length);
  final first = rest.indexOf(':');
  if (first <= 0) return null;
  final second = rest.indexOf(':', first + 1);
  if (second <= first + 1 || second == rest.length - 1) return null;
  final terminalId = _decode(rest.substring(0, first));
  final provider = rest.substring(first + 1, second);
  final model = _decode(rest.substring(second + 1));
  if (terminalId == null || model == null) return null;
  if (terminalId.isEmpty || provider.isEmpty || model.isEmpty) return null;
  return (terminalId: terminalId, provider: provider, model: model);
}

String? _decode(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    // A `%` not followed by two hex digits.
    return null;
  } on FormatException {
    // Escapes that are not UTF-8, such as `%FF`.
    return null;
  }
}

/// Whether [id] names a coding agent on an Open WebUI terminal.
bool isTerminalAgentModelId(String? id) =>
    parseTerminalAgentModelId(id) != null;

/// Whether [model] is a coding agent on an Open WebUI terminal.
bool isTerminalAgentModel(Model? model) => isTerminalAgentModelId(model?.id);

/// The terminal [model] runs on, when it is a coding agent.
String? terminalAgentTerminalId(Model? model) =>
    parseTerminalAgentModelId(model?.id)?.terminalId;

/// Whether any of [modelIds] is a coding agent's. Open WebUI answers a
/// coding agent only in a conversation it has to itself, so such a
/// conversation cannot be branched, regenerated or continued in place.
bool anyTerminalAgentModelId(Iterable<String?> modelIds) =>
    modelIds.any(isTerminalAgentModelId);

/// The agents Open WebUI can run, by the names their makers give them. An
/// agent not listed here keeps the id Open WebUI gives it.
const Map<String, String> _agentNames = {
  'claude-code': 'Claude Code',
  'cline': 'Cline',
  'codex': 'Codex',
  'cursor': 'Cursor',
  'gemini': 'Gemini CLI',
  'grok': 'Grok',
  'opencode': 'OpenCode',
  'pi': 'Pi',
};

/// The agent's own name (`Codex` for `codex`).
String terminalAgentName(String provider) => _agentNames[provider] ?? provider;

/// The end Open WebUI 0.13.4 gives a model's slug when making it changed the
/// model (`gpt-5.1` is `gpt-5-1-e7ee8b01`): the first 8 hex digits of the
/// model's SHA-256. A model the slug leaves as it is has none, and may end
/// in a date of 8 digits (`…-20260101`), so an end with no letter is kept.
final RegExp _slugHash = RegExp(
  r'^([A-Za-z0-9_-]+)-(?=[0-9]*[a-f])[0-9a-f]{8}$',
);

String _modelFromId(String model) =>
    _slugHash.firstMatch(model)?.group(1) ?? model;

/// The agent's own model as a coding agent's [id] names it, for when nothing
/// better is known: 0.13.4's slug without its hash (`gpt-5-1`). Null when
/// [id] is not an agent's.
String? terminalAgentModelNameOfId(String? id) {
  final agent = parseTerminalAgentModelId(id);
  return agent == null ? null : _modelFromId(agent.model);
}

/// The name a coding agent's model goes by in the app (`Codex · gpt-5.1`),
/// or null when [id] is not an agent's. From the id alone, 0.13.4's slug
/// stands for the model (`Codex · gpt-5-1`); [terminalAgentModelFromJson]
/// names a listed agent by the model the server lists it with.
String? terminalAgentDisplayName(String? id) {
  final agent = parseTerminalAgentModelId(id);
  if (agent == null) return null;
  return '${terminalAgentName(agent.provider)} · ${_modelFromId(agent.model)}';
}

/// The agent's own model (`gpt-5.1`) of [model], a coding agent: as the
/// server listed it, else as its id names it. Null when [model] is not an
/// agent's.
String? terminalAgentModelName(Model model) {
  if (!isTerminalAgentModel(model)) return null;
  return switch (model.metadata?['agentModel']) {
    final String listed when listed.trim().isNotEmpty => listed.trim(),
    _ => terminalAgentModelNameOfId(model.id),
  };
}

/// The key under which [terminalAgentModelFromJson] keeps the terminal's
/// name, for the picker's second line.
const String kTerminalAgentTerminalNameKey = 'terminalName';

/// A coding agent's model from Open WebUI's model list, named for the picker
/// (`Codex · gpt-5.1`) and carrying [terminalName], the terminal it runs on.
/// Null when [json] is not a coding agent's.
///
/// The model is the one the server lists under `agent.model`, which 0.13.4's
/// id holds only as a slug.
Model? terminalAgentModelFromJson(
  Map<String, dynamic> json, {
  String? terminalName,
}) {
  final ref = parseTerminalAgentModelId(json['id']?.toString());
  if (ref == null) return null;
  final model = Model.fromJson(json);
  final listed = switch (json['agent']) {
    {'model': final String model} when model.trim().isNotEmpty => model.trim(),
    _ => null,
  };
  final agentModel = listed ?? _modelFromId(ref.model);
  final metadata = <String, dynamic>{
    ...?model.metadata,
    'agentProvider': ref.provider,
    'agentModel': agentModel,
    if (terminalName != null && terminalName.trim().isNotEmpty)
      kTerminalAgentTerminalNameKey: terminalName.trim(),
  };
  return model.copyWith(
    name: '${terminalAgentName(ref.provider)} · $agentModel',
    metadata: metadata,
  );
}

/// The line under a coding agent in a model picker: the terminal it runs on,
/// else the name Open WebUI gives it (`codex/gpt-5.1`).
String? terminalAgentPickerSubtitle(Model model) {
  final ref = parseTerminalAgentModelId(model.id);
  if (ref == null) return null;
  final terminalName = model.metadata?[kTerminalAgentTerminalNameKey];
  if (terminalName is String && terminalName.trim().isNotEmpty) {
    return terminalName.trim();
  }
  return '${ref.provider}/${terminalAgentModelName(model)}';
}

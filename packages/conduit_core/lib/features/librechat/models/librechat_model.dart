import 'package:meta/meta.dart';

import 'package:conduit_core/models/model.dart';

/// Every model id Conduit mints for LibreChat starts with this.
const String kLibreChatModelIdPrefix = 'librechat:';

/// What a LibreChat model entry chats with.
enum LibreChatTargetKind {
  /// An admin-defined model spec: a named preset of endpoint, model and
  /// settings.
  spec,

  /// A saved agent (`endpoint: agents`, `agent_id`).
  agent,

  /// A model on one of the server's endpoints.
  endpoint,
}

/// Where a turn goes when a LibreChat model is selected: the fields of the
/// turn request that pick what answers.
@immutable
final class LibreChatTarget {
  const LibreChatTarget({
    required this.kind,
    required this.endpoint,
    this.endpointType,
    this.model,
    this.agentId,
    this.spec,
    this.preset = const <String, dynamic>{},
    this.section,
    this.sectionOrder = 0,
  });

  final LibreChatTargetKind kind;
  final String endpoint;

  /// `custom` for a custom endpoint, else null.
  final String? endpointType;
  final String? model;
  final String? agentId;
  final String? spec;

  /// A spec's preset: model parameters and tool settings it sends.
  final Map<String, dynamic> preset;

  /// The picker section the entry belongs to, and where that section sorts.
  final String? section;
  final int sectionOrder;
}

/// Runtime-only provenance for models minted here, as for Hermes and
/// Direct: a model's id and metadata can come from a server, so only this
/// [Expando], which no JSON can fill, says a model routes to LibreChat.
final Expando<LibreChatTarget> _mintedTargets = Expando<LibreChatTarget>(
  'locally-minted-librechat-model',
);

/// Whether [model] was minted for LibreChat in this process.
bool isLibreChatModel(Model model) => _mintedTargets[model] != null;

/// Where [model] sends a turn, or null when it is not a LibreChat model.
LibreChatTarget? libreChatTargetOf(Model model) => _mintedTargets[model];

/// The picker section LibreChat [model] is listed in, and where that section
/// sorts; null for any other model.
({String label, int order})? libreChatModelSection(Model model) {
  final target = libreChatTargetOf(model);
  final label = target?.section;
  if (target == null || label == null) return null;
  return (label: label, order: target.sectionOrder);
}

/// Whether a model from elsewhere claims the LibreChat namespace.
bool hasReservedLibreChatIdentity(Model model) =>
    model.id.startsWith(kLibreChatModelIdPrefix) ||
    model.metadata?['backend'] == 'libreChat';

/// Drops models from elsewhere that claim the LibreChat identity.
List<Model> sanitizeRemoteLibreChatModels(Iterable<Model> models) => models
    .where(
      (model) =>
          !isLibreChatModel(model) && !hasReservedLibreChatIdentity(model),
    )
    .toList(growable: false);

/// The picker id of what a conversation or turn ran on: its spec, else its
/// agent, else its endpoint and model. Null when none is known.
///
/// The same id the catalog mints, so a stored conversation finds its model
/// in the picker again.
String? libreChatModelIdFor({
  String? endpoint,
  String? model,
  String? agentId,
  String? spec,
}) {
  if (spec != null && spec.isNotEmpty) {
    return '${kLibreChatModelIdPrefix}spec:$spec';
  }
  if (agentId != null && agentId.isNotEmpty) {
    return '${kLibreChatModelIdPrefix}agent:$agentId';
  }
  if (endpoint == null || endpoint.isEmpty || model == null || model.isEmpty) {
    return null;
  }
  return '${kLibreChatModelIdPrefix}model:${Uri.encodeComponent(endpoint)}/$model';
}

Model _mint(String id, String name, LibreChatTarget target, {String? icon}) {
  final model = Model(
    id: '$kLibreChatModelIdPrefix$id',
    name: name,
    description: target.section,
    supportsStreaming: true,
    isMultimodal: true,
    metadata: <String, dynamic>{
      'backend': 'libreChat',
      'libreChatKind': target.kind.name,
      'libreChatSection': ?target.section,
      'libreChatSectionOrder': target.sectionOrder,
      if (icon != null && icon.startsWith('http')) 'profile_image_url': icon,
    },
  );
  _mintedTargets[model] = target;
  return model;
}

/// Endpoints Conduit does not offer: agents are listed one by one instead,
/// and the Assistants endpoints run on a different API.
const Set<String> _unlistedEndpoints = {
  'agents',
  'assistants',
  'azureAssistants',
};

/// The models a LibreChat server offers, for the picker, in its sections:
/// model specs, then agents, then each endpoint's models in the server's
/// endpoint order.
///
/// When the server enforces specs, only specs are offered. When it hides
/// the model menu (`interface.modelSelect: false`), endpoints are left out
/// and specs and agents stay, as in the web app.
List<Model> libreChatCatalog({
  required Map<String, dynamic> startupConfig,
  required Map<String, dynamic> endpoints,
  required Map<String, List<String>> models,
  List<Map<String, dynamic>> agents = const <Map<String, dynamic>>[],
  String specsSection = 'Specs',
  String agentsSection = 'Agents',
}) {
  final catalog = <Model>[];
  final modelSpecs = startupConfig['modelSpecs'];
  final specs = modelSpecs is Map && modelSpecs['list'] is List
      ? [
          for (final spec in modelSpecs['list'] as List)
            if (spec is Map) Map<String, dynamic>.from(spec),
        ]
      : const <Map<String, dynamic>>[];
  final enforced = modelSpecs is Map && modelSpecs['enforce'] == true;

  for (final spec in specs) {
    final name = spec['name'];
    final preset = spec['preset'];
    if (name is! String || preset is! Map) continue;
    final endpoint = preset['endpoint'];
    if (endpoint is! String) continue;
    // Specs for the Assistants endpoints could not send, and an agent spec
    // without its agent has nothing to run.
    if (endpoint == 'agents'
        ? (_asString(preset['agent_id']) ?? '').isEmpty
        : _unlistedEndpoints.contains(endpoint)) {
      continue;
    }
    final label = spec['label'];
    catalog.add(
      _mint(
        'spec:$name',
        label is String && label.isNotEmpty ? label : name,
        LibreChatTarget(
          kind: LibreChatTargetKind.spec,
          endpoint: endpoint,
          endpointType: _endpointType(endpoints, endpoint),
          model: _asString(preset['model']),
          agentId: _asString(preset['agent_id']),
          spec: name,
          preset: Map<String, dynamic>.from(preset),
          section: spec['group'] is String
              ? spec['group'] as String
              : specsSection,
        ),
        icon: _asString(spec['iconURL']),
      ),
    );
  }
  // The server refuses any turn without one of its specs once it enforces
  // them, which it does whenever it lists any: only usable specs are
  // offered then, none at all if none can send.
  if (enforced && specs.isNotEmpty) return catalog;

  if (endpoints['agents'] is Map) {
    for (final agent in agents) {
      final id = agent['id'];
      if (id is! String || id.isEmpty) continue;
      final name = agent['name'];
      final avatar = agent['avatar'];
      catalog.add(
        _mint(
          'agent:$id',
          name is String && name.trim().isNotEmpty ? name : 'Agent',
          LibreChatTarget(
            kind: LibreChatTargetKind.agent,
            endpoint: 'agents',
            agentId: id,
            model: _asString(agent['model']),
            section: agentsSection,
            sectionOrder: 1,
          ),
          icon: avatar is Map ? _asString(avatar['filepath']) : null,
        ),
      );
    }
  }

  final interface = startupConfig['interface'];
  if (interface is Map && interface['modelSelect'] == false) return catalog;

  final ordered =
      [
        for (final entry in endpoints.entries)
          if (entry.value is Map && !_unlistedEndpoints.contains(entry.key))
            (name: entry.key, config: entry.value as Map),
      ]..sort((a, b) {
        final ao = a.config['order'];
        final bo = b.config['order'];
        return (ao is num ? ao : 1 << 20).compareTo(bo is num ? bo : 1 << 20);
      });
  for (final (index, endpoint) in ordered.indexed) {
    final label = endpoint.config['modelDisplayLabel'];
    final section = label is String && label.isNotEmpty ? label : endpoint.name;
    for (final model in models[endpoint.name] ?? const <String>[]) {
      catalog.add(
        _mint(
          'model:${Uri.encodeComponent(endpoint.name)}/$model',
          model,
          LibreChatTarget(
            kind: LibreChatTargetKind.endpoint,
            endpoint: endpoint.name,
            endpointType: _endpointType(endpoints, endpoint.name),
            model: model,
            section: section,
            sectionOrder: 2 + index,
          ),
          icon: _asString(endpoint.config['iconURL']),
        ),
      );
    }
  }
  return catalog;
}

/// [value] when the server sent a string there, else null: one odd field
/// leaves its entry without it rather than failing the whole catalog.
String? _asString(Object? value) => value is String ? value : null;

/// `custom` for an endpoint the admin defined in librechat.yaml.
String? _endpointType(Map<String, dynamic> endpoints, String endpoint) {
  final config = endpoints[endpoint];
  return config is Map && config['type'] == 'custom' ? 'custom' : null;
}

import 'models/workspace_capabilities.dart';

enum WorkspaceSection { models, knowledge, prompts, tools, skills }

enum WorkspaceRouteMode { collection, create, detail, edit }

class WorkspaceRouteDescriptor {
  const WorkspaceRouteDescriptor({required this.section});

  final WorkspaceSection section;

  String get segment => section.name;
  String get collectionPath => '/workspace/$segment';
  String get createPattern => '$collectionPath/create';
  String get detailPattern => '$collectionPath/:id';
  String get editPattern => '$collectionPath/:id/edit';
  String get collectionName => 'workspace-$segment';
  String get createName => 'workspace-$segment-create';
  String get detailName => 'workspace-${_singular(segment)}-detail';
  String get editName => 'workspace-${_singular(segment)}-edit';

  String detailLocation(String id) =>
      Uri(pathSegments: const ['', 'workspace'] + [segment, id]).toString();
  String editLocation(String id) => Uri(
    pathSegments: const ['', 'workspace'] + [segment, id, 'edit'],
  ).toString();

  static String _singular(String value) => switch (value) {
    'models' => 'model',
    'prompts' => 'prompt',
    'tools' => 'tool',
    'skills' => 'skill',
    _ => value,
  };
}

const workspaceRouteDescriptors = <WorkspaceRouteDescriptor>[
  WorkspaceRouteDescriptor(section: WorkspaceSection.models),
  WorkspaceRouteDescriptor(section: WorkspaceSection.knowledge),
  WorkspaceRouteDescriptor(section: WorkspaceSection.prompts),
  WorkspaceRouteDescriptor(section: WorkspaceSection.tools),
  WorkspaceRouteDescriptor(section: WorkspaceSection.skills),
];

// Keyed lookup so a section resolves to its descriptor by identity rather than
// by list position — inserting a new WorkspaceSection anywhere no longer risks
// silently returning the wrong descriptor.
final Map<WorkspaceSection, WorkspaceRouteDescriptor> _descriptorsBySection = {
  for (final descriptor in workspaceRouteDescriptors)
    descriptor.section: descriptor,
};

extension WorkspaceSectionX on WorkspaceSection {
  WorkspaceRouteDescriptor get routes => _descriptorsBySection[this]!;
  String get path => routes.collectionPath;

  WorkspaceSectionCapabilities capabilities(WorkspaceCapabilities value) {
    return switch (this) {
      WorkspaceSection.models => value.models,
      WorkspaceSection.knowledge => value.knowledge,
      WorkspaceSection.prompts => value.prompts,
      WorkspaceSection.tools => value.tools,
      WorkspaceSection.skills => value.skills,
    };
  }
}

const workspaceSectionOrder = <WorkspaceSection>[
  WorkspaceSection.models,
  WorkspaceSection.knowledge,
  WorkspaceSection.prompts,
  WorkspaceSection.tools,
  WorkspaceSection.skills,
];

List<WorkspaceSection> permittedWorkspaceSections(
  WorkspaceCapabilities capabilities,
) {
  return workspaceSectionOrder
      .where((section) => section.capabilities(capabilities).manage)
      .toList(growable: false);
}

WorkspaceSection? workspaceSectionForPath(String location) {
  final segments = Uri.tryParse(location)?.pathSegments;
  if (segments == null ||
      segments.length < 2 ||
      segments.first != 'workspace') {
    return null;
  }
  for (final descriptor in workspaceRouteDescriptors) {
    if (segments[1] == descriptor.segment) return descriptor.section;
  }
  return null;
}

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/providers/workspace_session.dart';

/// A selectable relationship candidate rendered in the model editor pickers.
@immutable
class WorkspaceRelationshipOption {
  const WorkspaceRelationshipOption({
    required this.id,
    required this.label,
    this.subtitle,
  });

  final String id;
  final String label;
  final String? subtitle;
}

/// An Open WebUI Function (`filter` or `action` type) usable as a model
/// relationship.
@immutable
class WorkspaceFunctionRef {
  const WorkspaceFunctionRef({
    required this.id,
    required this.name,
    required this.type,
  });

  final String id;
  final String name;
  final String type;

  bool get isFilter => type == 'filter';
  bool get isAction => type == 'action';

  factory WorkspaceFunctionRef.fromJson(Map<String, dynamic> json) =>
      WorkspaceFunctionRef(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? json['id']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
      );
}

/// Loads the server's Functions so the editor can offer filter/action pickers.
/// Fails closed (empty) is deliberately avoided — errors surface to the caller
/// so the picker can distinguish "no functions" from "load failed".
final workspaceFunctionsProvider = FutureProvider<List<WorkspaceFunctionRef>>((
  ref,
) async {
  final session = WorkspaceSessionIdentity.watch(ref);
  final raw = await session.api.getFunctions();
  session.ensureCurrent(ref);
  return raw
      .map((json) => WorkspaceFunctionRef.fromJson(json))
      .where((fn) => fn.id.isNotEmpty)
      .toList(growable: false);
});

/// Base models the user can compose a custom model from (the raw connection /
/// pipeline models exposed at `/models/base`).
final workspaceBaseModelsProvider =
    FutureProvider<List<WorkspaceRelationshipOption>>((ref) async {
      final session = WorkspaceSessionIdentity.watch(ref);
      final models = await session.api.getWorkspaceBaseModels();
      session.ensureCurrent(ref);
      final seen = <String>{};
      final options = <WorkspaceRelationshipOption>[];
      for (final model in models) {
        if (model.id.isEmpty || !seen.add(model.id)) continue;
        options.add(
          WorkspaceRelationshipOption(
            id: model.id,
            label: model.name.isEmpty ? model.id : model.name,
            subtitle: model.id,
          ),
        );
      }
      return options;
    });

/// Pretty label for a function's kind, used as a picker subtitle.
String workspaceFunctionKindLabel(WorkspaceFunctionRef fn) => fn.type;

/// Coerces owned-by / owner previews into a display subtitle.
String? workspaceOwnerSubtitle(WorkspaceOwnerPreview? owner) {
  final name = owner?.name.trim();
  if (name == null || name.isEmpty) return null;
  return name;
}

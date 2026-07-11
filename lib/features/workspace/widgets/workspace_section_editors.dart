import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/features/workspace/workspace_navigation.dart';

/// Arguments handed to a section editor when the shell resolves a create,
/// detail, or edit route to a real widget.
@immutable
class WorkspaceEditorArgs {
  const WorkspaceEditorArgs({
    required this.section,
    required this.mode,
    this.resourceId,
  });

  final WorkspaceSection section;

  /// One of [WorkspaceRouteMode.create], `.detail`, or `.edit`. The collection
  /// mode is handled by the shell, never dispatched to an editor.
  final WorkspaceRouteMode mode;
  final String? resourceId;
}

typedef WorkspaceSectionEditorBuilder =
    Widget Function(BuildContext context, WorkspaceEditorArgs args);

/// Registry mapping a [WorkspaceSection] to the widget that renders its
/// create/detail/edit editor.
///
/// This slice ships the infrastructure only; the map is empty by default, so
/// the shell falls back to the "coming soon" placeholder for every section.
/// Later milestones register their editor by overriding
/// [workspaceSectionEditorsProvider] (or extending the default map) without
/// touching the shell dispatch logic.
final workspaceSectionEditorsProvider =
    Provider<Map<WorkspaceSection, WorkspaceSectionEditorBuilder>>((ref) {
      return const <WorkspaceSection, WorkspaceSectionEditorBuilder>{};
    });

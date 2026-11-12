import 'package:flutter/widgets.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit/features/workspace/views/skills/workspace_skill_editor.dart';
import 'package:conduit/features/workspace/views/tools/workspace_tool_editor.dart';
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

typedef WorkspaceSectionEditorBuilder = Widget Function(
  BuildContext context,
  WorkspaceEditorArgs args,
);

/// Registry mapping a [WorkspaceSection] to the widget that renders its
/// create/detail/edit editor. Models, Knowledge and Prompts are edited in
/// pages of Settings's own, so they have none here.
///
/// Sections register their editor here; unregistered sections fall back to the
/// shell's "coming soon" placeholder without touching the shell dispatch logic.
final workspaceSectionEditorsProvider =
    Provider<Map<WorkspaceSection, WorkspaceSectionEditorBuilder>>((ref) {
      return <WorkspaceSection, WorkspaceSectionEditorBuilder>{
        WorkspaceSection.tools: buildWorkspaceToolEditor,
        WorkspaceSection.skills: buildWorkspaceSkillEditor,
      };
    });

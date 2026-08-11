import 'package:flutter/material.dart';

import '../../providers/workspace_model_relationships.dart';
import 'workspace_model_relationship_sheet.dart';

/// Presents a relationship sheet and returns the selected identifiers.
///
/// Data loading, error reporting, and draft mutation stay in the parent editor
/// coordinator so this helper has no provider or model ownership.
final class WorkspaceModelRelationshipPicker {
  const WorkspaceModelRelationshipPicker();

  Future<List<String>?> show(
    BuildContext context, {
    required String title,
    required List<WorkspaceRelationshipOption> options,
    required List<String> selectedIds,
  }) {
    return WorkspaceRelationshipSheet.show(
      context,
      title: title,
      options: options,
      selectedIds: selectedIds,
    );
  }
}

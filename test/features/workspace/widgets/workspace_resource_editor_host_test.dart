import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/widgets/workspace_resource_editor_host.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('route target makes create, existing, and invalid states explicit', () {
    check(
      WorkspaceEditorTarget.fromRoute(
        mode: WorkspaceRouteMode.create,
        resourceId: null,
      ),
    ).isA<WorkspaceCreateEditorTarget>();

    final existing = WorkspaceEditorTarget.fromRoute(
      mode: WorkspaceRouteMode.edit,
      resourceId: '  resource-id  ',
    );
    check(existing).isA<WorkspaceExistingEditorTarget>();
    check(
      (existing as WorkspaceExistingEditorTarget).resourceId,
    ).equals('resource-id');

    check(
      WorkspaceEditorTarget.fromRoute(
        mode: WorkspaceRouteMode.detail,
        resourceId: ' ',
      ),
    ).isA<WorkspaceInvalidEditorTarget>();
  });
}

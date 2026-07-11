import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';

void main() {
  test('first permitted section follows upstream workspace order', () {
    const capabilities = WorkspaceCapabilities(
      prompts: WorkspaceSectionCapabilities.all,
      tools: WorkspaceSectionCapabilities.all,
    );

    final permitted = permittedWorkspaceSections(capabilities);

    check(
      permitted,
    ).deepEquals([WorkspaceSection.prompts, WorkspaceSection.tools]);
    check(permitted.first.path).equals('/workspace/prompts');
  });

  test('detail and edit paths resolve to their protected section', () {
    check(
      workspaceSectionForPath('/workspace/models/model-1/edit'),
    ).equals(WorkspaceSection.models);
    check(
      workspaceSectionForPath('/workspace/knowledge/kb-1'),
    ).equals(WorkspaceSection.knowledge);
    check(workspaceSectionForPath('/profile')).isNull();
  });

  test('descriptors are the source for production paths and names', () {
    check(Routes.workspace).equals('/workspace');
    check(
      WorkspaceSection.models.routes.createPattern,
    ).equals('/workspace/models/create');
    check(
      WorkspaceSection.knowledge.routes.detailPattern,
    ).equals('/workspace/knowledge/:id');
    check(
      WorkspaceSection.prompts.routes.editPattern,
    ).equals('/workspace/prompts/:id/edit');
    check(
      WorkspaceSection.tools.routes.collectionName,
    ).equals('workspace-tools');
    check(
      WorkspaceSection.skills.routes.editName,
    ).equals('workspace-skill-edit');
  });

  test('resource locations encode IDs without changing route matching', () {
    final detail = WorkspaceSection.knowledge.routes.detailLocation(
      'folder/id with spaces?#',
    );
    final edit = WorkspaceSection.models.routes.editLocation('model/one');

    check(
      detail,
    ).equals('/workspace/knowledge/folder%2Fid%20with%20spaces%3F%23');
    check(edit).equals('/workspace/models/model%2Fone/edit');
    check(
      workspaceSectionForPath('$detail?tab=files'),
    ).equals(WorkspaceSection.knowledge);
    check(workspaceSectionForPath('/workspace/models-extra/id')).isNull();
  });
}

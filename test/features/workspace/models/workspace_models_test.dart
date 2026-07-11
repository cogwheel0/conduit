import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/models/knowledge_base.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/prompt.dart';
import 'package:conduit/core/models/tool.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';

void main() {
  test('shared workspace contracts parse grants, owners, and pagination', () {
    final page = WorkspacePagedResponse.fromJson({
      'items': [
        {
          'id': 'model-1',
          'name': 'Model One',
          'user_id': 'owner-1',
          'access_grants': [
            {
              'id': 'grant-1',
              'principal_type': 'user',
              'principal_id': '*',
              'permission': 'read',
            },
          ],
          'write_access': true,
          'user': {'id': 'owner-1', 'name': 'Owner'},
        },
      ],
      'total': 7,
    }, WorkspaceModelSummary.fromJson);

    check(page.total).equals(7);
    check(page.items.single.writeAccess).isTrue();
    check(page.items.single.owner?.name).equals('Owner');
    check(page.items.single.accessGrants.single.isPublic).isTrue();
  });

  test('knowledge file pages retain directories and breadcrumbs', () {
    final page = WorkspaceKnowledgeFilePage.fromJson({
      'items': [
        {'id': 'file-1', 'filename': 'notes.txt', 'directory_id': 'dir-1'},
      ],
      'directories': [
        {
          'id': 'dir-1',
          'knowledge_id': 'kb-1',
          'name': 'Docs',
          'user_id': 'user-1',
        },
      ],
      'breadcrumbs': [
        {
          'id': 'root',
          'knowledge_id': 'kb-1',
          'name': 'Root',
          'user_id': 'user-1',
        },
      ],
      'total': 1,
    });

    check(page.items.single.directoryId).equals('dir-1');
    check(page.directories.single.name).equals('Docs');
    check(page.breadcrumbs.single.name).equals('Root');
  });

  test('legacy core models preserve modern workspace metadata', () {
    final prompt = Prompt.fromJson({
      'id': 'prompt-1',
      'command': 'summarize',
      'name': 'Summarize',
      'content': 'Summarize {{text}}',
      'meta': {'description': 'Shorten text'},
      'tags': ['writing'],
      'write_access': true,
    });
    final tool = Tool.fromJson({
      'id': 'tool-1',
      'name': 'Weather',
      'content': 'class Tools: pass',
      'specs': [
        {'name': 'weather'},
      ],
      'meta': {'description': 'Forecasts'},
    });
    final knowledge = KnowledgeBase.fromJson({
      'id': 'kb-1',
      'name': 'Docs',
      'description': '',
      'created_at': 1710000000,
      'updated_at': 1710000001,
      'meta': {'source': 'local'},
      'user_id': 'user-1',
      'write_access': true,
    });
    final model = Model.fromJson({
      'id': 'workspace-model',
      'name': 'Workspace Model',
      'user_id': 'user-1',
      'base_model_id': 'base-model',
      'access_grants': [
        {'principal_type': 'user', 'principal_id': '*', 'permission': 'read'},
      ],
      'write_access': true,
    });

    check(prompt.command).equals('/summarize');
    check(prompt.description).equals('Shorten text');
    check(tool.content).equals('class Tools: pass');
    check(tool.specs.single['name']).equals('weather');
    check(knowledge.metadata['source']).equals('local');
    check(knowledge.userId).equals('user-1');
    check(model.baseModelId).equals('base-model');
    check(model.hasWorkspaceWriteAccess).isTrue();
    check(model.workspaceAccessGrants).length.equals(1);
  });

  test(
    'workspace parsing tolerates malformed tags but rejects invalid tools',
    () {
      final prompt = WorkspacePromptSummary.fromJson({
        'id': 'prompt-1',
        'command': '/test',
        'name': 'Test',
        'content': '',
        'user_id': 'user-1',
        'tags': 'not-a-list',
      });

      final legacyTool = Tool.fromJson({
        'id': 'legacy-tool',
        'name': 'Legacy Tool',
        'spec': {'name': 'legacy_function'},
      });

      check(prompt.tags).isEmpty();
      check(legacyTool.specs.single['name']).equals('legacy_function');
      check(
        () => Tool.fromJson({'name': 'Missing id'}),
      ).throws<FormatException>();
    },
  );
}

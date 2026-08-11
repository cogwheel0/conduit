import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit/features/workspace/views/models/workspace_model_editor_controller.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('controller owns text synchronization and typed JSON failures', () {
    final controller = WorkspaceModelEditorController(
      mode: WorkspaceRouteMode.create,
      initialDraft: WorkspaceModelDraft.empty(),
      writeAccess: true,
    );
    addTearDown(controller.dispose);

    controller.fields.id.text = ' model-id ';
    controller.fields.name.text = 'Model name';
    controller.fields.stop.text = 'one, two\nthree';
    controller.fields.params.text = '[]';

    check(controller.syncTextIntoDraft()).isFalse();
    check(controller.syncIssue).equals(WorkspaceModelDraftSyncIssue.params);
    check(controller.advancedExpanded).isTrue();

    controller.fields.params.text = '{"temperature": 0.5}';
    controller.fields.builtinTools.text = 'not-json';
    check(controller.syncTextIntoDraft()).isFalse();
    check(
      controller.syncIssue,
    ).equals(WorkspaceModelDraftSyncIssue.builtinTools);

    controller.fields.builtinTools.text = '{"search": true}';
    check(controller.syncTextIntoDraft()).isTrue();
    check(controller.syncIssue).isNull();
    check(controller.draft.id).equals('model-id');
    check(controller.draft.stop).deepEquals(['one', 'two', 'three']);
    check(controller.draft.advancedParams['temperature']).equals(0.5);
    check(controller.draft.builtinTools['search']).equals(true);
  });

  test(
    'relationship coordinator owns load, present, and apply ordering',
    () async {
      final draft = WorkspaceModelDraft.empty()..toolIds = ['tool-a'];
      final controller = WorkspaceModelEditorController(
        mode: WorkspaceRouteMode.edit,
        initialDraft: draft,
        writeAccess: true,
      );
      addTearDown(controller.dispose);
      final coordinator = WorkspaceModelRelationshipCoordinator(controller);
      final calls = <String>[];

      final result = await coordinator.pick(
        WorkspaceModelRelationshipKind.tools,
        load: () async {
          calls.add('load');
          return const [
            WorkspaceRelationshipOption(id: 'tool-a', label: 'Tool A'),
            WorkspaceRelationshipOption(id: 'tool-b', label: 'Tool B'),
          ];
        },
        present: (options, selectedIds) async {
          calls.add('present:${selectedIds.join(',')}');
          check(
            options.map((option) => option.id).toList(),
          ).deepEquals(['tool-a', 'tool-b']);
          return ['tool-b'];
        },
      );

      check(
        result.outcome,
      ).equals(WorkspaceModelRelationshipPickOutcome.updated);
      check(calls).deepEquals(['load', 'present:tool-a']);
      check(controller.draft.toolIds).deepEquals(['tool-b']);
      check(controller.session.dirty).isTrue();
    },
  );

  test('knowledge relationship updates preserve existing raw references', () {
    final existing = WorkspaceModelKnowledgeRef(
      id: 'knowledge-a',
      name: 'Original',
      raw: const {'id': 'knowledge-a', 'server': 'preserved'},
    );
    final draft = WorkspaceModelDraft.empty()..knowledge = [existing];
    final controller = WorkspaceModelEditorController(
      mode: WorkspaceRouteMode.edit,
      initialDraft: draft,
      writeAccess: true,
    );
    addTearDown(controller.dispose);

    controller.applyRelationshipSelection(
      WorkspaceModelRelationshipKind.knowledge,
      ['knowledge-a', 'knowledge-b'],
      const [
        WorkspaceRelationshipOption(id: 'knowledge-a', label: 'Renamed'),
        WorkspaceRelationshipOption(id: 'knowledge-b', label: 'Knowledge B'),
      ],
    );

    check(controller.draft.knowledge[0].raw['server']).equals('preserved');
    check(controller.draft.knowledge[1].name).equals('Knowledge B');
  });
}

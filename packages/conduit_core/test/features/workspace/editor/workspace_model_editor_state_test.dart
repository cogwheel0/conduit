import 'package:checks/checks.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/workspace/editor/workspace_model_editor_state.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit_core/features/workspace/providers/workspace_model_relationships.dart';
import 'package:conduit_core/navigation/routes.dart';

WorkspaceModelEditorState _state(
  WorkspaceModelDraft draft, {
  WorkspaceRouteMode mode = WorkspaceRouteMode.edit,
}) {
  final state = WorkspaceModelEditorState(
    mode: mode,
    initialDraft: draft,
    writeAccess: true,
  );
  addTearDown(state.dispose);
  return state;
}

void main() {
  test('session changes flow through the state notification stream', () {
    final state = _state(
      WorkspaceModelDraft.empty(),
      mode: WorkspaceRouteMode.create,
    );
    var notifications = 0;
    state.addListener(() => notifications++);

    state.session.beginOperation();
    state.session.setError('failed');
    state.session.endOperation();

    check(notifications).equals(3);
  });

  test('a disposed state notifies no one and ignores new listeners', () {
    final state = WorkspaceModelEditorState(
      mode: WorkspaceRouteMode.edit,
      initialDraft: WorkspaceModelDraft.empty(),
      writeAccess: true,
    );
    var notifications = 0;
    state.addListener(() => notifications++);
    state.dispose();
    state.addListener(() => notifications++);

    state.setAdvancedExpanded(true);

    check(notifications).equals(0);
    check(state.isDisposed).isTrue();
  });

  test('state copies drafts directly and clones without grants', () {
    final initial = WorkspaceModelDraft(
      id: 'model',
      name: 'Model',
      description: '  unsaved spacing  ',
      advancedParams: {
        'nested': {
          'values': [1],
        },
      },
      accessGrants: const [
        WorkspaceAccessGrantInput(
          principalType: WorkspacePrincipalType.user,
          principalId: 'user-1',
          permission: WorkspaceGrantPermission.write,
        ),
      ],
    );
    final state = _state(initial);

    final clone = state.buildClone('Copy');
    ((clone.advancedParams['nested'] as Map)['values'] as List).add(2);

    check(state.draft.description).equals('  unsaved spacing  ');
    check(clone.id).equals('model-copy');
    check(clone.name).equals('Model Copy');
    check(clone.accessGrants).isEmpty();
    check(((state.draft.advancedParams['nested'] as Map)['values'] as List))
        .deepEquals([1]);
  });

  test(
    'field text starts from the draft with lists joined and JSON indented',
    () {
      final draft = WorkspaceModelDraft.empty()
        ..id = 'model'
        ..stop = ['one', 'two']
        ..defaultFeatureIds = ['web_search']
        ..advancedParams = {'temperature': 0.5};

      final text = WorkspaceModelFieldText.fromDraft(draft);

      check(text.id).equals('model');
      check(text.stop).equals('one, two');
      check(text.defaultFeatures).equals('web_search');
      check(text.params).equals('{\n  "temperature": 0.5\n}');
      check(text.builtinTools).equals('');
    },
  );

  test('state owns text synchronization and typed JSON failures', () {
    final state = _state(
      WorkspaceModelDraft.empty(),
      mode: WorkspaceRouteMode.create,
    );

    check(
      state.syncFieldText(
        const WorkspaceModelFieldText(
          id: ' model-id ',
          name: 'Model name',
          stop: 'one, two\nthree',
          params: '[]',
        ),
      ),
    ).isFalse();
    check(state.syncIssue).equals(WorkspaceModelDraftSyncIssue.params);
    check(state.advancedExpanded).isTrue();

    check(
      state.syncFieldText(
        const WorkspaceModelFieldText(
          params: '{"temperature": 0.5}',
          builtinTools: 'not-json',
        ),
      ),
    ).isFalse();
    check(state.syncIssue).equals(WorkspaceModelDraftSyncIssue.builtinTools);

    check(
      state.syncFieldText(
        const WorkspaceModelFieldText(
          id: ' model-id ',
          name: 'Model name',
          stop: 'one, two\nthree',
          params: '{"temperature": 0.5}',
          builtinTools: '{"search": true}',
        ),
      ),
    ).isTrue();
    check(state.syncIssue).isNull();
    check(state.draft.id).equals('model-id');
    check(state.draft.stop).deepEquals(['one', 'two', 'three']);
    check(state.draft.advancedParams['temperature']).equals(0.5);
    check(state.draft.builtinTools['search']).equals(true);
  });

  test(
    'relationship coordinator owns load, present, and apply ordering',
    () async {
      final state = _state(WorkspaceModelDraft.empty()..toolIds = ['tool-a']);
      final coordinator = WorkspaceModelRelationshipCoordinator(state);
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
          check(options.map((option) => option.id).toList())
              .deepEquals(['tool-a', 'tool-b']);
          return ['tool-b'];
        },
      );

      check(result.outcome)
          .equals(WorkspaceModelRelationshipPickOutcome.updated);
      check(calls).deepEquals(['load', 'present:tool-a']);
      check(state.draft.toolIds).deepEquals(['tool-b']);
      check(state.session.dirty).isTrue();
    },
  );

  test('relationship coordinator reports cancel and load failures', () async {
    final state = _state(WorkspaceModelDraft.empty()..skillIds = ['skill-a']);
    final coordinator = WorkspaceModelRelationshipCoordinator(state);

    final cancelled = await coordinator.pick(
      WorkspaceModelRelationshipKind.skills,
      load: () async => const [],
      present: (_, _) async => null,
    );
    final failed = await coordinator.pick(
      WorkspaceModelRelationshipKind.skills,
      load: () async => throw StateError('offline'),
      present: (_, _) async => ['skill-b'],
    );

    check(cancelled.outcome)
        .equals(WorkspaceModelRelationshipPickOutcome.cancelled);
    check(failed.outcome).equals(WorkspaceModelRelationshipPickOutcome.failed);
    check(failed.error).isA<StateError>();
    check(state.draft.skillIds).deepEquals(['skill-a']);
    check(state.session.dirty).isFalse();
  });

  test('knowledge relationship updates preserve existing raw references', () {
    final existing = WorkspaceModelKnowledgeRef(
      id: 'knowledge-a',
      name: 'Original',
      raw: const {'id': 'knowledge-a', 'server': 'preserved'},
    );
    final state = _state(WorkspaceModelDraft.empty()..knowledge = [existing]);

    state.applyRelationshipSelection(
      WorkspaceModelRelationshipKind.knowledge,
      ['knowledge-a', 'knowledge-b'],
      const [
        WorkspaceRelationshipOption(id: 'knowledge-a', label: 'Renamed'),
        WorkspaceRelationshipOption(id: 'knowledge-b', label: 'Knowledge B'),
      ],
    );

    check(state.draft.knowledge[0].raw['server']).equals('preserved');
    check(state.draft.knowledge[1].name).equals('Knowledge B');
  });
}

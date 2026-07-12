import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';

void main() {
  group('WorkspaceModelDraft.fromSummary', () {
    test('hydrates typed fields from meta and params', () {
      final summary = WorkspaceModelSummary(
        id: 'gpt-custom',
        name: 'Custom GPT',
        userId: 'owner-1',
        baseModelId: 'gpt-4',
        isActive: false,
        meta: const {
          'description': 'A helpful model',
          'profile_image_url': 'data:image/png;base64,AAA',
          'tags': [
            {'name': 'internal'},
            {'name': 'beta'},
          ],
          'capabilities': {'vision': true, 'usage': false},
          'suggestion_prompts': ['Hi', 'Summarize this'],
          'knowledge': [
            {'id': 'kb-1', 'name': 'Handbook'},
          ],
          'toolIds': ['tool-a'],
          'skillIds': ['skill-a', 'skill-b'],
          'filterIds': ['filter-a'],
          'defaultFilterIds': ['filter-a'],
          'actionIds': ['action-a'],
          'defaultFeatureIds': ['web_search'],
          'builtinTools': {'calc': true},
          'terminalId': 'term-1',
          'tts': {'voice': 'alloy'},
          'hidden': true,
          'unknown_meta': 'preserve-me',
        },
        params: const {
          'system': 'You are helpful',
          'stop': ['STOP', 'END'],
          'temperature': 0.7,
        },
      );

      final draft = WorkspaceModelDraft.fromSummary(summary);

      check(draft.id).equals('gpt-custom');
      check(draft.baseModelId).equals('gpt-4');
      check(draft.isActive).isFalse();
      check(draft.description).equals('A helpful model');
      check(draft.tags).deepEquals(['internal', 'beta']);
      check(draft.system).equals('You are helpful');
      check(draft.stop).deepEquals(['STOP', 'END']);
      check(draft.suggestionPrompts).deepEquals(['Hi', 'Summarize this']);
      check(draft.capabilities['vision']).equals(true);
      check(draft.capabilities['usage']).equals(false);
      check(draft.knowledge.single.id).equals('kb-1');
      check(draft.toolIds).deepEquals(['tool-a']);
      check(draft.skillIds).deepEquals(['skill-a', 'skill-b']);
      check(draft.filterIds).deepEquals(['filter-a']);
      check(draft.defaultFilterIds).deepEquals(['filter-a']);
      check(draft.actionIds).deepEquals(['action-a']);
      check(draft.defaultFeatureIds).deepEquals(['web_search']);
      check(draft.builtinTools['calc']).equals(true);
      check(draft.terminalId).equals('term-1');
      check(draft.ttsVoice).equals('alloy');
      check(draft.hidden).isTrue();
      check(draft.advancedParams['temperature']).equals(0.7);
      check(draft.advancedParams.containsKey('system')).isFalse();
      check(draft.extraMeta['unknown_meta']).equals('preserve-me');
    });
  });

  group('WorkspaceModelDraft.buildMeta / toForm', () {
    test('emits {name:...} tags and drops empty managed keys', () {
      final draft = WorkspaceModelDraft(id: 'm1', name: 'M1', tags: ['x', 'y']);
      final meta = draft.buildMeta();

      check(meta['tags'] as List).deepEquals([
        {'name': 'x'},
        {'name': 'y'},
      ]);
      // No description/knowledge/tools etc. when unset.
      check(meta.containsKey('description')).isFalse();
      check(meta.containsKey('knowledge')).isFalse();
      check(meta.containsKey('hidden')).isFalse();
      // capabilities are always emitted.
      check(meta.containsKey('capabilities')).isTrue();
    });

    test('round-trips through fromSummary without losing data', () {
      final original = WorkspaceModelDraft(
        id: 'm1',
        name: 'M1',
        description: 'desc',
        tags: ['a'],
        system: 'sys',
        stop: ['STOP'],
        toolIds: ['t1'],
        skillIds: ['s1'],
        filterIds: ['f1'],
        actionIds: ['a1'],
        terminalId: 'term',
        ttsVoice: 'echo',
        hidden: true,
        advancedParams: {'temperature': 0.5},
        extraMeta: {'custom': 1},
      );

      final summary = WorkspaceModelSummary(
        id: original.id,
        name: original.name,
        userId: 'u',
        meta: original.buildMeta(),
        params: original.buildParams(),
      );
      final restored = WorkspaceModelDraft.fromSummary(summary);

      check(restored.description).equals('desc');
      check(restored.tags).deepEquals(['a']);
      check(restored.system).equals('sys');
      check(restored.stop).deepEquals(['STOP']);
      check(restored.toolIds).deepEquals(['t1']);
      check(restored.actionIds).deepEquals(['a1']);
      check(restored.hidden).isTrue();
      check(restored.advancedParams['temperature']).equals(0.5);
      check(restored.extraMeta['custom']).equals(1);
    });

    test('toForm builds a valid WorkspaceModelForm payload', () {
      final draft = WorkspaceModelDraft(
        id: '  m1  ',
        name: '  Model One  ',
        baseModelId: 'base',
        system: 'sys',
      );
      final form = draft.toForm();

      check(form.id).equals('m1');
      check(form.name).equals('Model One');
      check(form.baseModelId).equals('base');
      check(form.params['system']).equals('sys');

      final json = form.toJson();
      check(json['id']).equals('m1');
      check(json['base_model_id']).equals('base');
    });

    test('isValid requires id and name', () {
      check(WorkspaceModelDraft(id: '', name: 'x').isValid).isFalse();
      check(WorkspaceModelDraft(id: 'x', name: '  ').isValid).isFalse();
      check(WorkspaceModelDraft(id: 'x', name: 'y').isValid).isTrue();
    });

    test('normalizedAccessGrants de-duplicates grants', () {
      final draft = WorkspaceModelDraft(
        id: 'm',
        name: 'M',
        accessGrants: const [
          WorkspaceAccessGrantInput(
            principalType: WorkspacePrincipalType.user,
            principalId: 'u1',
            permission: WorkspaceGrantPermission.read,
          ),
          WorkspaceAccessGrantInput(
            principalType: WorkspacePrincipalType.user,
            principalId: 'u1',
            permission: WorkspaceGrantPermission.read,
          ),
          WorkspaceAccessGrantInput(
            principalType: WorkspacePrincipalType.user,
            principalId: '',
            permission: WorkspaceGrantPermission.read,
          ),
        ],
      );
      check(draft.normalizedAccessGrants.length).equals(1);
    });
  });
}

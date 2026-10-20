import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit/features/workspace/views/models/workspace_model_editor_controller.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

// The editor state's rules are tested in conduit_core
// (workspace_model_editor_state_test.dart). These cover the Flutter text
// controllers around it.
void main() {
  test('bindings seed from the draft and sync their text back', () {
    final draft = WorkspaceModelDraft.empty()
      ..id = 'model'
      ..stop = ['one', 'two'];
    final controller = WorkspaceModelEditorController(
      mode: WorkspaceRouteMode.edit,
      initialDraft: draft,
      writeAccess: true,
    );
    addTearDown(controller.dispose);

    check(controller.fields.id.text).equals('model');
    check(controller.fields.stop.text).equals('one, two');

    controller.fields.name.text = 'Renamed';
    controller.fields.stop.text = 'three\nfour';
    controller.fields.params.text = '[]';
    check(controller.syncTextIntoDraft()).isFalse();
    check(controller.syncIssue).equals(WorkspaceModelDraftSyncIssue.params);

    controller.fields.params.text = '{"top_k": 3}';
    check(controller.syncTextIntoDraft()).isTrue();
    check(controller.draft.name).equals('Renamed');
    check(controller.draft.stop).deepEquals(['three', 'four']);
    check(controller.draft.advancedParams['top_k']).equals(3);
  });

  test('controller notifications cover session and draft changes', () {
    final controller = WorkspaceModelEditorController(
      mode: WorkspaceRouteMode.create,
      initialDraft: WorkspaceModelDraft.empty(),
      writeAccess: true,
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.addTag('a');
    controller.addTag('b');
    controller.session.setError('failed');

    check(notifications).equals(3);
    check(controller.session.dirty).isTrue();
  });
}

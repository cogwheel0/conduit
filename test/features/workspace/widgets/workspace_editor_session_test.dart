import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_session.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session owns mode and publishes meaningful state changes', () {
    final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
    addTearDown(session.dispose);
    var notifications = 0;
    session.addListener(() => notifications++);

    check(session.isEdit).isTrue();
    check(session.isCreate).isFalse();
    session.dirty = true;
    session.dirty = true;
    check(notifications).equals(1);

    session.errorMessage = 'stale';
    session.beginSaving();
    check(session.saving).isTrue();
    check(session.errorMessage).isNull();

    session.finishSaving(errorMessage: 'failed', dirty: false);
    check(session.saving).isFalse();
    check(session.dirty).isFalse();
    check(session.errorMessage).equals('failed');
    check(notifications).equals(4);
  });
}

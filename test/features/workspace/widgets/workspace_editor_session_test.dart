import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_session.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session groups route and mutation state', () {
    final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
    addTearDown(session.dispose);
    var notifications = 0;
    session.addListener(() => notifications++);

    check(session.isEdit).isTrue();
    check(session.isCreate).isFalse();
    session.markDirty();

    session.setError('stale');
    check(session.beginOperation(clearError: true)).isTrue();
    check(session.saving).isTrue();
    check(session.errorMessage).isNull();

    check(session.beginOperation()).isFalse();
    check(session.saving).isTrue();

    session.finishOperation(errorMessage: 'failed', dirty: false);
    check(session.saving).isFalse();
    check(session.dirty).isFalse();
    check(session.errorMessage).equals('failed');
    check(notifications).equals(4);
  });

  test('session rejects a second mutation until the owner finishes', () {
    final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
    addTearDown(session.dispose);

    check(session.beginOperation()).isTrue();
    check(session.beginOperation(clearError: true)).isFalse();
    session.endOperation();
    check(session.beginOperation()).isTrue();
  });

  test('session suppresses notifications for no-op mutations', () {
    final session = WorkspaceEditorSession(WorkspaceRouteMode.create);
    addTearDown(session.dispose);
    var notifications = 0;
    session.addListener(() => notifications++);

    session.markClean();
    session.clearError();
    session.endOperation();
    session.markDirty();
    session.markDirty();

    check(notifications).equals(1);
  });
}

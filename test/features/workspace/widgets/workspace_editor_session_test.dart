import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_mutation_coordinator.dart';
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

  test('operation runner owns admission and success cleanup', () async {
    final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
    addTearDown(session.dispose);
    var operations = 0;

    final succeeded = await WorkspaceEditorOperationRunner.stay<int>(
      session: session,
      scope: 'workspace/test',
      operationLabel: 'test mutation',
      editorMounted: () => true,
      operation: () async => ++operations,
    );

    check(succeeded).isTrue();
    check(operations).equals(1);
    check(session.saving).isFalse();
  });

  test('exit operations leave cleanup to successful navigation', () async {
    final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
    addTearDown(session.dispose);
    var completed = false;

    final succeeded = await WorkspaceEditorOperationRunner.exit<void>(
      session: session,
      scope: 'workspace/test',
      operationLabel: 'test exit',
      editorMounted: () => true,
      operation: () async {},
      onSuccess: (_) => completed = true,
    );

    check(succeeded).isTrue();
    check(completed).isTrue();
    check(session.saving).isTrue();
  });

  test('captured-route operations complete after editor disposal', () async {
    final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
    addTearDown(session.dispose);
    var completed = false;

    final succeeded = await WorkspaceEditorOperationRunner.capturedRoute<void>(
      session: session,
      scope: 'workspace/test',
      operationLabel: 'test captured route',
      editorMounted: () => false,
      operation: () async {},
      onSuccess: (_) => completed = true,
    );

    check(succeeded).isTrue();
    check(completed).isTrue();
  });

  test('operation runner maps failure and releases the lock', () async {
    final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
    addTearDown(session.dispose);
    Object? observedError;

    final succeeded = await WorkspaceEditorOperationRunner.stay<void>(
      session: session,
      scope: 'workspace/test',
      operationLabel: 'test mutation',
      editorMounted: () => true,
      operation: () => Future<void>.error(StateError('failed')),
      onFailure: (error) => observedError = error,
      errorMessage: (_) => 'mapped failure',
    );

    check(succeeded).isFalse();
    check(observedError).isA<StateError>();
    check(session.saving).isFalse();
    check(session.errorMessage).equals('mapped failure');
  });
}

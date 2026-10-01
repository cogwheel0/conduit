import 'package:checks/checks.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/workspace/editor/workspace_editor_operations.dart';
import 'package:conduit_core/features/workspace/editor/workspace_editor_session.dart';
import 'package:conduit_core/navigation/routes.dart';

final class _FakeNavigator implements WorkspaceEditorNavigator {
  _FakeNavigator({this.isRouteCurrent = true, this.poppable = true});

  @override
  bool isRouteCurrent;
  bool poppable;
  final List<String> calls = <String>[];

  @override
  bool canPop() => poppable;

  @override
  void pop() => calls.add('pop');

  @override
  void pushReplacement(String location) => calls.add('replace $location');

  @override
  void go(String location) => calls.add('go $location');

  @override
  void showMessage(
    String message, {
    required WorkspaceEditorMessageType type,
  }) => calls.add('${type.name} $message');
}

void main() {
  group('WorkspaceEditorSession', () {
    test('groups route and mutation state', () {
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

    test('rejects a second mutation until the owner finishes', () {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      addTearDown(session.dispose);

      check(session.beginOperation()).isTrue();
      check(session.beginOperation(clearError: true)).isFalse();
      session.endOperation();
      check(session.beginOperation()).isTrue();
    });

    test('suppresses notifications for no-op mutations', () {
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

    test('a listener removed during a notification is skipped', () {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      addTearDown(session.dispose);
      final calls = <String>[];
      void second() => calls.add('second');
      session.addListener(() {
        calls.add('first');
        session.removeListener(second);
      });
      session.addListener(second);

      session.markDirty();

      check(calls).deepEquals(['first']);
    });

    test('keeps state but notifies no one after dispose', () {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      var notifications = 0;
      session.addListener(() => notifications++);
      session.dispose();
      session.addListener(() => notifications++);

      session.markDirty();

      check(session.dirty).isTrue();
      check(notifications).equals(0);
    });
  });

  group('WorkspaceEditorOperationRunner', () {
    test('owns admission and success cleanup', () async {
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

    test('refuses to start while another operation holds the lock', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      addTearDown(session.dispose);
      session.beginOperation();
      var operations = 0;

      final succeeded = await WorkspaceEditorOperationRunner.stay<int>(
        session: session,
        scope: 'workspace/test',
        operationLabel: 'test mutation',
        editorMounted: () => true,
        operation: () async => ++operations,
      );

      check(succeeded).isFalse();
      check(operations).equals(0);
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

      final succeeded =
          await WorkspaceEditorOperationRunner.capturedRoute<void>(
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

    test('stay and exit skip success work after editor disposal', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      addTearDown(session.dispose);
      var completed = false;

      final succeeded = await WorkspaceEditorOperationRunner.exit<void>(
        session: session,
        scope: 'workspace/test',
        operationLabel: 'test exit',
        editorMounted: () => false,
        operation: () async {},
        onSuccess: (_) => completed = true,
      );

      check(succeeded).isTrue();
      check(completed).isFalse();
    });

    test('maps failure and releases the lock', () async {
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

    test('a failure without a message only releases the lock', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      addTearDown(session.dispose);

      await WorkspaceEditorOperationRunner.stay<void>(
        session: session,
        scope: 'workspace/test',
        operationLabel: 'test mutation',
        editorMounted: () => true,
        operation: () => Future<void>.error(StateError('failed')),
      );

      check(session.saving).isFalse();
      check(session.errorMessage).isNull();
    });
  });

  group('WorkspaceEditorMutationFlow', () {
    const section = WorkspaceSection.prompts;

    Future<bool> save(
      WorkspaceEditorSession session,
      WorkspaceEditorNavigator navigator, {
      bool mounted = true,
      bool fail = false,
      List<bool>? createFlags,
    }) => WorkspaceEditorMutationFlow.run<String>(
      navigator: navigator,
      session: session,
      section: section,
      scope: 'workspace/test',
      resourceLabel: 'prompt',
      successMessage: 'Saved',
      failureMessage: 'Save failed',
      editorMounted: () => mounted,
      mutate: (isCreate) async {
        createFlags?.add(isCreate);
        if (fail) throw StateError('boom');
        return 'p1';
      },
      resourceId: (id) => id,
    );

    test('create replaces the editor with the new resource', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.create)
        ..markDirty();
      addTearDown(session.dispose);
      final navigator = _FakeNavigator();
      final createFlags = <bool>[];

      check(await save(session, navigator, createFlags: createFlags)).isTrue();

      check(createFlags).deepEquals([true]);
      check(session.dirty).isFalse();
      check(navigator.calls).deepEquals([
        'success Saved',
        'replace ${section.routes.detailLocation('p1')}',
      ]);
    });

    test('edit pops back when it can', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      addTearDown(session.dispose);
      final navigator = _FakeNavigator();

      await save(session, navigator);

      check(navigator.calls).deepEquals(['success Saved', 'pop']);
    });

    test('edit on a root route stays and releases the lock', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      addTearDown(session.dispose);
      final navigator = _FakeNavigator(poppable: false);

      await save(session, navigator);

      check(navigator.calls).deepEquals(['success Saved']);
      check(session.saving).isFalse();
    });

    test('a route that is no longer current gets no feedback', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      addTearDown(session.dispose);
      final navigator = _FakeNavigator(isRouteCurrent: false);

      await save(session, navigator);

      check(navigator.calls).isEmpty();
      check(session.saving).isFalse();
    });

    test('save failure shows the message inline, not as feedback', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.edit);
      addTearDown(session.dispose);
      final navigator = _FakeNavigator();

      check(await save(session, navigator, fail: true)).isFalse();

      check(navigator.calls).isEmpty();
      check(session.errorMessage).equals('Save failed');
      check(session.saving).isFalse();
    });

    test('clone replaces the editor with the clone editor', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.detail);
      addTearDown(session.dispose);
      final navigator = _FakeNavigator();

      await WorkspaceEditorMutationFlow.replaceWithClone<String>(
        navigator: navigator,
        session: session,
        section: section,
        scope: 'workspace/test',
        resourceLabel: 'prompt',
        successMessage: 'Cloned',
        failureMessage: 'Clone failed',
        editorMounted: () => true,
        clone: () async => 'p2',
        resourceId: (id) => id,
      );

      check(navigator.calls).deepEquals([
        'success Cloned',
        'replace ${section.routes.editLocation('p2')}',
      ]);
    });

    test('clone failure shows error feedback', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.detail);
      addTearDown(session.dispose);
      final navigator = _FakeNavigator();

      await WorkspaceEditorMutationFlow.replaceWithClone<String>(
        navigator: navigator,
        session: session,
        section: section,
        scope: 'workspace/test',
        resourceLabel: 'prompt',
        successMessage: 'Cloned',
        failureMessage: 'Clone failed',
        editorMounted: () => true,
        clone: () => Future<String>.error(StateError('boom')),
        resourceId: (id) => id,
      );

      check(navigator.calls).deepEquals(['error Clone failed']);
      check(session.saving).isFalse();
    });

    test('delete goes to the collection when it cannot pop', () async {
      final session = WorkspaceEditorSession(WorkspaceRouteMode.detail);
      addTearDown(session.dispose);
      final navigator = _FakeNavigator(poppable: false);

      await WorkspaceEditorMutationFlow.exitAfterDelete(
        navigator: navigator,
        session: session,
        section: section,
        scope: 'workspace/test',
        resourceLabel: 'prompt',
        successMessage: 'Deleted',
        failureMessage: 'Delete failed',
        editorMounted: () => true,
        delete: () async {},
      );

      check(
        navigator.calls,
      ).deepEquals(['success Deleted', 'go ${section.routes.collectionPath}']);
    });
  });
}

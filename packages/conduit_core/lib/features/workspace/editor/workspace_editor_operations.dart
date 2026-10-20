import 'dart:async';

import '../../../navigation/routes.dart'
    show WorkspaceSection, WorkspaceSectionX;
import '../../../utils/debug_logger.dart';
import 'workspace_editor_session.dart';

typedef WorkspaceEditorMutation<T> = Future<T> Function(bool isCreate);
typedef WorkspaceEditorResourceId<T> = String Function(T result);
typedef WorkspaceEditorErrorMessage = String Function(Object error);

enum _WorkspaceEditorSuccessDisposition { stay, exit, capturedRoute }

/// Runs the common admission, diagnostics, mounted-state, and lock lifecycle
/// for every workspace editor mutation.
final class WorkspaceEditorOperationRunner {
  const WorkspaceEditorOperationRunner._();

  static Future<bool> stay<T>({
    required WorkspaceEditorSession session,
    required String scope,
    required String operationLabel,
    required bool Function() editorMounted,
    required Future<T> Function() operation,
    FutureOr<void> Function(T result)? onSuccess,
    FutureOr<void> Function(Object error)? onFailure,
    WorkspaceEditorErrorMessage? errorMessage,
    bool clearError = false,
  }) => _run<T>(
    session: session,
    scope: scope,
    operationLabel: operationLabel,
    editorMounted: editorMounted,
    operation: operation,
    onSuccess: onSuccess,
    onFailure: onFailure,
    errorMessage: errorMessage,
    clearError: clearError,
    successDisposition: _WorkspaceEditorSuccessDisposition.stay,
  );

  static Future<bool> capturedRoute<T>({
    required WorkspaceEditorSession session,
    required String scope,
    required String operationLabel,
    required bool Function() editorMounted,
    required Future<T> Function() operation,
    required FutureOr<void> Function(T result) onSuccess,
    FutureOr<void> Function(Object error)? onFailure,
    WorkspaceEditorErrorMessage? errorMessage,
    bool clearError = false,
  }) => _run<T>(
    session: session,
    scope: scope,
    operationLabel: operationLabel,
    editorMounted: editorMounted,
    operation: operation,
    onSuccess: onSuccess,
    onFailure: onFailure,
    errorMessage: errorMessage,
    clearError: clearError,
    successDisposition: _WorkspaceEditorSuccessDisposition.capturedRoute,
  );

  static Future<bool> exit<T>({
    required WorkspaceEditorSession session,
    required String scope,
    required String operationLabel,
    required bool Function() editorMounted,
    required Future<T> Function() operation,
    required FutureOr<void> Function(T result) onSuccess,
    FutureOr<void> Function(Object error)? onFailure,
    WorkspaceEditorErrorMessage? errorMessage,
    bool clearError = false,
  }) => _run<T>(
    session: session,
    scope: scope,
    operationLabel: operationLabel,
    editorMounted: editorMounted,
    operation: operation,
    onSuccess: onSuccess,
    onFailure: onFailure,
    errorMessage: errorMessage,
    clearError: clearError,
    successDisposition: _WorkspaceEditorSuccessDisposition.exit,
  );

  static Future<bool> _run<T>({
    required WorkspaceEditorSession session,
    required String scope,
    required String operationLabel,
    required bool Function() editorMounted,
    required Future<T> Function() operation,
    required _WorkspaceEditorSuccessDisposition successDisposition,
    FutureOr<void> Function(T result)? onSuccess,
    FutureOr<void> Function(Object error)? onFailure,
    WorkspaceEditorErrorMessage? errorMessage,
    bool clearError = false,
  }) async {
    if (!session.beginOperation(clearError: clearError)) return false;
    try {
      final result = await operation();
      if (!editorMounted() &&
          successDisposition !=
              _WorkspaceEditorSuccessDisposition.capturedRoute) {
        return true;
      }
      await onSuccess?.call(result);
      if (successDisposition == _WorkspaceEditorSuccessDisposition.stay &&
          editorMounted()) {
        session.endOperation();
      }
      return true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        '$operationLabel failed',
        scope: scope,
        error: error,
        stackTrace: stackTrace,
      );
      if (!editorMounted()) return false;
      await onFailure?.call(error);
      if (!editorMounted()) return false;
      final message = errorMessage?.call(error);
      if (message == null) {
        session.endOperation();
      } else {
        session.finishOperation(errorMessage: message);
      }
      return false;
    }
  }
}

/// The feedback an editor shows after a mutation.
enum WorkspaceEditorMessageType { success, error }

/// The navigation an editor mutation needs, captured when the mutation
/// starts, before the operation can dispose the editor.
///
/// The app implements it over go_router and the editor's `ModalRoute`.
abstract interface class WorkspaceEditorNavigator {
  /// Whether the editor's route is still the one on screen.
  bool get isRouteCurrent;

  bool canPop();

  void pop();

  /// Replaces the editor's route with [location].
  void pushReplacement(String location);

  void go(String location);

  /// Shows [message] from a context that outlives the editor.
  void showMessage(String message, {required WorkspaceEditorMessageType type});
}

/// Runs the shared mutation lifecycle for every workspace resource editor.
///
/// Validation and request construction stay resource-specific. This object
/// owns admission, diagnostics, lock release, feedback, and success
/// navigation so those async invariants cannot drift between editors. The
/// caller captures [WorkspaceEditorNavigator] before
/// calling.
final class WorkspaceEditorMutationFlow {
  const WorkspaceEditorMutationFlow._();

  static Future<bool> run<T>({
    required WorkspaceEditorNavigator navigator,
    required WorkspaceEditorSession session,
    required WorkspaceSection section,
    required String scope,
    required String resourceLabel,
    required String successMessage,
    required String failureMessage,
    required bool Function() editorMounted,
    required WorkspaceEditorMutation<T> mutate,
    required WorkspaceEditorResourceId<T> resourceId,
    WorkspaceEditorErrorMessage? errorMessage,
  }) {
    final completion = _WorkspaceEditorMutationCompletion(
      navigator,
      session: session,
      section: section,
    );
    return WorkspaceEditorOperationRunner.capturedRoute<T>(
      session: session,
      scope: scope,
      operationLabel: '$resourceLabel save',
      editorMounted: editorMounted,
      clearError: true,
      operation: () => mutate(completion.isCreate),
      onSuccess: (result) {
        final id = resourceId(result);
        DebugLogger.log(
          '$resourceLabel saved',
          scope: scope,
          data: {'id': id, 'create': completion.isCreate},
        );
        completion.succeed(
          resourceId: id,
          message: successMessage,
          editorMounted: editorMounted(),
        );
      },
      errorMessage: (error) => errorMessage?.call(error) ?? failureMessage,
    );
  }

  static Future<bool> replaceWithClone<T>({
    required WorkspaceEditorNavigator navigator,
    required WorkspaceEditorSession session,
    required WorkspaceSection section,
    required String scope,
    required String resourceLabel,
    required String successMessage,
    required String failureMessage,
    required bool Function() editorMounted,
    required Future<T> Function() clone,
    required WorkspaceEditorResourceId<T> resourceId,
  }) {
    final completion = _WorkspaceEditorMutationCompletion(
      navigator,
      session: session,
      section: section,
    );
    return WorkspaceEditorOperationRunner.exit<T>(
      session: session,
      scope: scope,
      operationLabel: '$resourceLabel clone',
      editorMounted: editorMounted,
      operation: clone,
      onSuccess: (created) => completion.replaceWithEditor(
        resourceId: resourceId(created),
        message: successMessage,
        editorMounted: editorMounted(),
      ),
      onFailure: (_) => navigator.showMessage(
        failureMessage,
        type: WorkspaceEditorMessageType.error,
      ),
    );
  }

  static Future<bool> exitAfterDelete({
    required WorkspaceEditorNavigator navigator,
    required WorkspaceEditorSession session,
    required WorkspaceSection section,
    required String scope,
    required String resourceLabel,
    required String successMessage,
    required String failureMessage,
    required bool Function() editorMounted,
    required Future<void> Function() delete,
  }) {
    final completion = _WorkspaceEditorMutationCompletion(
      navigator,
      session: session,
      section: section,
    );
    return WorkspaceEditorOperationRunner.exit<void>(
      session: session,
      scope: scope,
      operationLabel: '$resourceLabel delete',
      editorMounted: editorMounted,
      operation: delete,
      onSuccess: (_) => completion.exitToCollection(
        message: successMessage,
        editorMounted: editorMounted(),
      ),
      onFailure: (_) => navigator.showMessage(
        failureMessage,
        type: WorkspaceEditorMessageType.error,
      ),
    );
  }
}

/// Success navigation over the navigator captured before the mutation.
final class _WorkspaceEditorMutationCompletion {
  _WorkspaceEditorMutationCompletion(
    this._navigator, {
    required WorkspaceEditorSession session,
    required WorkspaceSection section,
  }) : _session = session,
       _section = section,
       isCreate = session.isCreate;

  final WorkspaceEditorNavigator _navigator;
  final WorkspaceEditorSession _session;
  final WorkspaceSection _section;

  final bool isCreate;

  void succeed({
    required String resourceId,
    required String message,
    required bool editorMounted,
  }) {
    if (editorMounted) _session.markClean();
    if (!_navigator.isRouteCurrent) {
      if (editorMounted) _session.endOperation();
      return;
    }
    _navigator.showMessage(message, type: WorkspaceEditorMessageType.success);

    if (isCreate) {
      _navigator.pushReplacement(_section.routes.detailLocation(resourceId));
    } else if (_navigator.canPop()) {
      _navigator.pop();
    } else if (editorMounted) {
      _session.endOperation();
    }
  }

  void replaceWithEditor({
    required String resourceId,
    required String message,
    required bool editorMounted,
  }) {
    if (!_navigator.isRouteCurrent) {
      if (editorMounted) _session.endOperation();
      return;
    }
    _navigator.showMessage(message, type: WorkspaceEditorMessageType.success);
    _navigator.pushReplacement(_section.routes.editLocation(resourceId));
  }

  void exitToCollection({
    required String message,
    required bool editorMounted,
  }) {
    if (editorMounted) _session.markClean();
    if (!_navigator.isRouteCurrent) {
      if (editorMounted) _session.endOperation();
      return;
    }
    _navigator.showMessage(message, type: WorkspaceEditorMessageType.success);
    if (_navigator.canPop()) {
      _navigator.pop();
    } else {
      _navigator.go(_section.routes.collectionPath);
    }
  }
}

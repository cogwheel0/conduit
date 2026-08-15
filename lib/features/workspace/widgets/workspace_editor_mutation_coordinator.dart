import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import '../workspace_navigation.dart';
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

/// Runs the shared mutation lifecycle for every workspace resource editor.
///
/// Validation and request construction stay resource-specific. This object
/// owns admission, route capture, diagnostics, lock release, feedback, and
/// success navigation so those async invariants cannot drift between editors.
final class WorkspaceEditorMutationCoordinator {
  const WorkspaceEditorMutationCoordinator._();

  static Future<bool> run<T>({
    required BuildContext context,
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
  }) async {
    final completion = _WorkspaceEditorMutationCompletion.capture(
      context,
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
    required BuildContext context,
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
    final completion = _WorkspaceEditorMutationCompletion.capture(
      context,
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
      onFailure: (_) => completion.showMessage(
        failureMessage,
        type: AdaptiveSnackBarType.error,
      ),
    );
  }

  static Future<bool> exitAfterDelete({
    required BuildContext context,
    required WorkspaceEditorSession session,
    required WorkspaceSection section,
    required String scope,
    required String resourceLabel,
    required String successMessage,
    required String failureMessage,
    required bool Function() editorMounted,
    required Future<void> Function() delete,
  }) {
    final completion = _WorkspaceEditorMutationCompletion.capture(
      context,
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
      onFailure: (_) => completion.showMessage(
        failureMessage,
        type: AdaptiveSnackBarType.error,
      ),
    );
  }
}

/// Captures navigation ownership before a mutation can dispose its editor.
final class _WorkspaceEditorMutationCompletion {
  _WorkspaceEditorMutationCompletion.capture(
    BuildContext context, {
    required WorkspaceEditorSession session,
    required WorkspaceSection section,
  }) : _router = GoRouter.of(context),
       _overlayContext = Navigator.of(context, rootNavigator: true).context,
       _route = ModalRoute.of(context),
       _session = session,
       _section = section,
       isCreate = session.isCreate;

  final GoRouter _router;
  final BuildContext _overlayContext;
  final ModalRoute<dynamic>? _route;
  final WorkspaceEditorSession _session;
  final WorkspaceSection _section;

  final bool isCreate;

  void succeed({
    required String resourceId,
    required String message,
    required bool editorMounted,
  }) {
    if (editorMounted) _session.markClean();
    if (_route?.isCurrent != true) {
      if (editorMounted) _session.endOperation();
      return;
    }
    showMessage(message, type: AdaptiveSnackBarType.success);

    if (isCreate) {
      _router.pushReplacement(_section.routes.detailLocation(resourceId));
    } else if (_router.canPop()) {
      _router.pop();
    } else if (editorMounted) {
      _session.endOperation();
    }
  }

  void replaceWithEditor({
    required String resourceId,
    required String message,
    required bool editorMounted,
  }) {
    if (_route?.isCurrent != true) {
      if (editorMounted) _session.endOperation();
      return;
    }
    showMessage(message, type: AdaptiveSnackBarType.success);
    _router.pushReplacement(_section.routes.editLocation(resourceId));
  }

  void exitToCollection({
    required String message,
    required bool editorMounted,
  }) {
    if (editorMounted) _session.markClean();
    if (_route?.isCurrent != true) {
      if (editorMounted) _session.endOperation();
      return;
    }
    showMessage(message, type: AdaptiveSnackBarType.success);
    if (_router.canPop()) {
      _router.pop();
    } else {
      _router.go(_section.routes.collectionPath);
    }
  }

  void showMessage(String message, {required AdaptiveSnackBarType type}) {
    if (!_overlayContext.mounted) return;
    AdaptiveSnackBar.show(_overlayContext, message: message, type: type);
  }
}

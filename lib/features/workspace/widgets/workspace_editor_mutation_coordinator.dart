import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import '../workspace_navigation.dart';
import 'workspace_editor_session.dart';

typedef WorkspaceEditorMutation<T> = Future<T> Function(bool isCreate);
typedef WorkspaceEditorResourceId<T> = String Function(T result);
typedef WorkspaceEditorErrorMessage = String Function(Object error);

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
    if (!session.beginOperation(clearError: true)) return false;
    final completion = _WorkspaceEditorMutationCompletion.capture(
      context,
      session: session,
      section: section,
    );
    try {
      final result = await mutate(completion.isCreate);
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
      return true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        '$resourceLabel save failed',
        scope: scope,
        error: error,
        stackTrace: stackTrace,
      );
      if (!editorMounted()) return false;
      session.finishOperation(
        errorMessage: errorMessage?.call(error) ?? failureMessage,
      );
      return false;
    }
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
    if (_overlayContext.mounted) {
      AdaptiveSnackBar.show(
        _overlayContext,
        message: message,
        type: AdaptiveSnackBarType.success,
      );
    }

    if (isCreate) {
      _router.pushReplacement(_section.routes.detailLocation(resourceId));
    } else if (_router.canPop()) {
      _router.pop();
    } else if (editorMounted) {
      _session.endOperation();
    }
  }
}

import 'package:conduit_core/features/workspace/editor/workspace_editor_operations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import '../workspace_navigation.dart';
import 'workspace_editor_session.dart';

export 'package:conduit_core/features/workspace/editor/workspace_editor_operations.dart'
    show
        WorkspaceEditorErrorMessage,
        WorkspaceEditorMutation,
        WorkspaceEditorOperationRunner,
        WorkspaceEditorResourceId;

/// Runs the shared mutation lifecycle for every workspace resource editor.
///
/// The lifecycle (admission, lock release, diagnostics, feedback and success
/// navigation) is conduit_core's [WorkspaceEditorMutationFlow]; this adapter
/// captures the editor's go_router, route and overlay before the mutation can
/// dispose the editor.
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
  }) => WorkspaceEditorMutationFlow.run<T>(
    navigator: _GoRouterWorkspaceEditorNavigator.capture(context),
    session: session,
    section: section,
    scope: scope,
    resourceLabel: resourceLabel,
    successMessage: successMessage,
    failureMessage: failureMessage,
    editorMounted: editorMounted,
    mutate: mutate,
    resourceId: resourceId,
    errorMessage: errorMessage,
  );

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
  }) => WorkspaceEditorMutationFlow.replaceWithClone<T>(
    navigator: _GoRouterWorkspaceEditorNavigator.capture(context),
    session: session,
    section: section,
    scope: scope,
    resourceLabel: resourceLabel,
    successMessage: successMessage,
    failureMessage: failureMessage,
    editorMounted: editorMounted,
    clone: clone,
    resourceId: resourceId,
  );

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
  }) => WorkspaceEditorMutationFlow.exitAfterDelete(
    navigator: _GoRouterWorkspaceEditorNavigator.capture(context),
    session: session,
    section: section,
    scope: scope,
    resourceLabel: resourceLabel,
    successMessage: successMessage,
    failureMessage: failureMessage,
    editorMounted: editorMounted,
    delete: delete,
  );
}

/// Captures navigation ownership before a mutation can dispose its editor.
final class _GoRouterWorkspaceEditorNavigator
    implements WorkspaceEditorNavigator {
  _GoRouterWorkspaceEditorNavigator.capture(BuildContext context)
    : _router = GoRouter.of(context),
      _overlayContext = Navigator.of(context, rootNavigator: true).context,
      _route = ModalRoute.of(context);

  final GoRouter _router;
  final BuildContext _overlayContext;
  final ModalRoute<dynamic>? _route;

  @override
  bool get isRouteCurrent => _route?.isCurrent == true;

  @override
  bool canPop() => _router.canPop();

  @override
  void pop() => _router.pop();

  @override
  void pushReplacement(String location) => _router.pushReplacement(location);

  @override
  void go(String location) => _router.go(location);

  @override
  void showMessage(String message, {required WorkspaceEditorMessageType type}) {
    if (!_overlayContext.mounted) return;
    AdaptiveSnackBar.show(
      _overlayContext,
      message: message,
      type: switch (type) {
        WorkspaceEditorMessageType.success => AdaptiveSnackBarType.success,
        WorkspaceEditorMessageType.error => AdaptiveSnackBarType.error,
      },
    );
  }
}

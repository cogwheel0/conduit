import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import '../workspace_navigation.dart';
import 'workspace_editor_session.dart';

/// Owns the UI completion path for a workspace editor mutation.
///
/// Detail providers are invalidated by successful writes. Capture route and
/// overlay ownership before awaiting the write so navigation and feedback do
/// not depend on the editor form still being mounted afterward.
final class WorkspaceEditorMutationCompletion {
  WorkspaceEditorMutationCompletion.capture(
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
      // The user navigated elsewhere while the write was in flight. Reconcile
      // the retained editor state without popping or notifying the newer route.
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
      // Deep-linked edits have no route to pop. Release the operation lock so
      // the refreshed form remains usable.
      _session.endOperation();
    }
  }
}

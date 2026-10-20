import 'package:checks/checks.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a Workspace collection opened from Settings has no transition', () {
    check(
      usesNoTransitionForWorkspaceRoute(
        WorkspaceRouteMode.collection,
        const NativeSheetNavigationOrigin(),
      ),
    ).isTrue();
  });

  test('Workspace resource pages keep a swipe-back transition', () {
    for (final mode in [
      WorkspaceRouteMode.create,
      WorkspaceRouteMode.detail,
      WorkspaceRouteMode.edit,
    ]) {
      check(
        usesNoTransitionForWorkspaceRoute(
          mode,
          const NativeSheetNavigationOrigin(),
        ),
      ).isFalse();
      check(usesNoTransitionForWorkspaceRoute(mode, null)).isFalse();
    }
  });
}

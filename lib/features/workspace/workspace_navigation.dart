import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../shared/services/navigation_service.dart';

export 'package:conduit_core/navigation/routes.dart'
    show
        WorkspaceRouteDescriptor,
        WorkspaceRouteMode,
        WorkspaceSection,
        WorkspaceSectionX,
        permittedWorkspaceSections,
        workspaceRouteDescriptors,
        workspaceSectionForPath,
        workspaceSectionOrder;

/// Keeps the launch context attached while navigating between Workspace
/// sections and editor routes. Native Settings dismisses before opening
/// Workspace, so its Flutter route must not become the Workspace back target.
class WorkspaceNavigationScope extends InheritedWidget {
  const WorkspaceNavigationScope({
    super.key,
    required this.openedFromNativeSheet,
    required super.child,
  });

  final bool openedFromNativeSheet;

  static WorkspaceNavigationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkspaceNavigationScope>();

  @override
  bool updateShouldNotify(WorkspaceNavigationScope oldWidget) =>
      openedFromNativeSheet != oldWidget.openedFromNativeSheet;
}

Object? workspaceNavigationExtra(BuildContext context) =>
    WorkspaceNavigationScope.maybeOf(context)?.openedFromNativeSheet == true
    ? const NativeSheetNavigationOrigin()
    : null;

extension WorkspaceNavigationContext on BuildContext {
  Future<T?> pushWorkspace<T extends Object?>(String location) =>
      push<T>(location, extra: workspaceNavigationExtra(this));

  void replaceWorkspace(String location) =>
      pushReplacement(location, extra: workspaceNavigationExtra(this));

  void goWorkspace(String location) =>
      go(location, extra: workspaceNavigationExtra(this));
}

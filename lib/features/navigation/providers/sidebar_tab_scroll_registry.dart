import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';

part 'sidebar_tab_scroll_registry.g.dart';

typedef SidebarScrollControllerResolver = ScrollController? Function();

/// Coordinates native status-bar taps and selected-tab reselection without
/// exposing feature-specific scroll controllers to the sidebar shell.
class SidebarTabScrollRegistry {
  final Map<
    SidebarTabId,
    ({Object owner, SidebarScrollControllerResolver resolve})
  >
  _controllers =
      <
        SidebarTabId,
        ({Object owner, SidebarScrollControllerResolver resolve})
      >{};

  void registerController(
    SidebarTabId tabId, {
    required Object owner,
    required SidebarScrollControllerResolver resolve,
  }) {
    _controllers[tabId] = (owner: owner, resolve: resolve);
  }

  void unregister(SidebarTabId tabId, {required Object owner}) {
    final entry = _controllers[tabId];
    if (entry?.owner == owner) _controllers.remove(tabId);
  }

  Future<void> scrollToTop(
    SidebarTabId tabId, {
    required Duration duration,
  }) async {
    final controller = _controllers[tabId]?.resolve();
    if (controller == null || !controller.hasClients) return;
    if (duration == Duration.zero) {
      controller.jumpTo(0);
      return;
    }
    await controller.animateTo(
      0,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }
}

/// Gives the tab lists below it a registry of their own.
///
/// A page in the main pane shows the same lists as the sidebar, such as Hermes
/// sessions, and would otherwise replace the sidebar's entry, so status-bar
/// taps and reselection would scroll a list the sidebar does not show.
class SidebarTabScrollRegistryScope extends InheritedWidget {
  const SidebarTabScrollRegistryScope({
    super.key,
    required this.registry,
    required super.child,
  });

  final SidebarTabScrollRegistry registry;

  static SidebarTabScrollRegistry? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<SidebarTabScrollRegistryScope>()
      ?.registry;

  @override
  bool updateShouldNotify(SidebarTabScrollRegistryScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}

/// Registers a sidebar tab's scroll controller and owns its registry lifecycle.
mixin SidebarTabScrollRegistration<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  SidebarTabId get sidebarTabId;

  /// May choose between controllers, as the terminal tab does for its panels.
  ScrollController? get sidebarScrollController;

  late final SidebarTabScrollRegistry _sidebarScrollRegistry;

  @override
  void initState() {
    super.initState();
    _sidebarScrollRegistry =
        SidebarTabScrollRegistryScope.maybeOf(context) ??
        ref.read(sidebarTabScrollRegistryProvider);
    _sidebarScrollRegistry.registerController(
      sidebarTabId,
      owner: this,
      resolve: () => sidebarScrollController,
    );
  }

  @override
  void dispose() {
    _sidebarScrollRegistry.unregister(sidebarTabId, owner: this);
    super.dispose();
  }
}

@Riverpod(keepAlive: true)
SidebarTabScrollRegistry sidebarTabScrollRegistry(Ref ref) =>
    SidebarTabScrollRegistry();

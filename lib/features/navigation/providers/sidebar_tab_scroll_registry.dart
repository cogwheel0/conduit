import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sidebar_tab_scroll_registry.g.dart';

enum SidebarTabId { chats, hermes, terminal, notes, channels }

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
    _sidebarScrollRegistry = ref.read(sidebarTabScrollRegistryProvider);
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

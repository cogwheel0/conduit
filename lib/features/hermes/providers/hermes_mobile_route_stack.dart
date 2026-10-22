import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/platform_ui/src/compact_modal_owner.dart';

/// The persistent conversation navigator belongs to the mobile shell, even
/// while the conversation stage keeps it offstage.
final hermesMobileRouteStackProvider = Provider<HermesMobileRouteStack>((ref) {
  final stack = HermesMobileRouteStack();
  ref.onDispose(stack.compactModalOwner.dismiss);
  return stack;
});

class HermesMobileRouteStack extends NavigatorObserver {
  final compactModalOwner = CompactModalOwner();
  final navigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'hermesConversationNavigator',
  );
  final _routes = <Route<dynamic>>[];

  bool get hasPanels => navigatorKey.currentState?.canPop() ?? false;

  /// Consume Back even when the current panel's PopScope prevents its pop.
  /// A child route's guard must never turn into logical conversation Back.
  Future<bool> maybePopPanel() async {
    final owner = navigatorKey.currentState;
    if (owner == null || !owner.canPop()) return false;
    await owner.maybePop();
    return true;
  }

  /// Drop only pushed panels when their logical owner changes. The base chat
  /// page stays mounted, preserving composer state and running subscriptions.
  void dismissPanels() {
    compactModalOwner.dismiss();
    final owner = navigatorKey.currentState;
    if (owner == null || _routes.length < 2) return;
    final panels = _routes.skip(1).toList().reversed.toList();
    void dismiss() {
      if (!identical(navigatorKey.currentState, owner)) return;
      for (final route in panels) {
        if (_routes.contains(route) && route.isActive) owner.removeRoute(route);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // Provider invalidation can happen during build. Capture the old routes
      // now so a destination panel opened later cannot be removed with them.
      WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
    } else {
      dismiss();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Leaving the ShellRoute disposes its navigator without removing every
    // route through observer callbacks. A later shell starts a fresh stack.
    if (previousRoute == null) _routes.clear();
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index < 0) return;
    if (newRoute == null) {
      _routes.removeAt(index);
    } else {
      _routes[index] = newRoute;
    }
  }
}

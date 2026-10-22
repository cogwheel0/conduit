import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Keeps root modal routes attached to the content that opened them.
class CompactModalOwner {
  final _routes = <Route<dynamic>>{};
  int _generation = 0;

  int get generation => _generation;
  bool isCurrent(int generation) => generation == _generation;

  void register(Route<dynamic> route, int generation) {
    if (!isCurrent(generation)) {
      _remove([route]);
      return;
    }
    _routes.add(route);
  }

  void unregister(Route<dynamic> route) => _routes.remove(route);

  /// Removes captured routes only, including when another route covers them.
  void dismiss() {
    _generation++;
    final routes = _routes.toList().reversed.toList();
    _routes.clear();
    _remove(routes);
  }

  void _remove(List<Route<dynamic>> routes) {
    void remove() {
      for (final route in routes) {
        final navigator = route.navigator;
        if (navigator != null && route.isActive) navigator.removeRoute(route);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => remove());
    } else {
      remove();
    }
  }
}

class CompactModalOwnerScope extends InheritedWidget {
  const CompactModalOwnerScope({
    super.key,
    required this.owner,
    required super.child,
  });

  final CompactModalOwner owner;

  static CompactModalOwner? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CompactModalOwnerScope>()?.owner;

  @override
  bool updateShouldNotify(CompactModalOwnerScope oldWidget) =>
      !identical(owner, oldWidget.owner);
}

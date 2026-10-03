import 'package:conduit_core/conduit_core.dart';

import '../shared/services/navigation_service.dart';

/// The Flutter app's [RouteNavigatorPort]: the global `GoRouter` behind
/// [NavigationService].
class GoRouterNavigator implements RouteNavigatorPort {
  const GoRouterNavigator();

  @override
  String? get currentRoute => NavigationService.currentRoute;

  @override
  void go(String location) => NavigationService.router.go(location);
}

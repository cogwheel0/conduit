/// Reads and replaces the location the app is showing.
///
/// The core needs this in exactly one place: when sync remaps a local id to
/// its server id, an open `/folder/<id>` or `/notes/<id>` route must follow
/// it. Routing itself belongs to the host (`go_router` in the Flutter app),
/// so the core sees only the location string.
abstract interface class RouteNavigatorPort {
  /// The location currently shown, or null when no router is attached.
  String? get currentRoute;

  /// Replaces the current location. May throw if the host rejects it.
  void go(String location);
}

/// No router: nothing is ever open, so nothing needs to follow a remap.
class NullRouteNavigator implements RouteNavigatorPort {
  const NullRouteNavigator();

  @override
  String? get currentRoute => null;

  @override
  void go(String location) {}
}

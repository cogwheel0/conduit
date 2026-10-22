class CallAudioRoute {
  const CallAudioRoute(this.id, this.name, this.kind);
  final String id, name, kind;
}

class CallAudioRoutes {
  const CallAudioRoutes({
    this.routes = const [],
    this.selected,
    this.changing = false,
  });
  final List<CallAudioRoute> routes;
  final String? selected;
  final bool changing;
  CallAudioRoute? get current =>
      routes.where((r) => r.id == selected).firstOrNull;
  CallAudioRoute? get next {
    if (routes.length < 2) return null;
    final index = routes.indexWhere((r) => r.id == selected);
    return routes[(index + 1) % routes.length];
  }
}

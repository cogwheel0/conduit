import 'package:material_ui/material_ui.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sidebar_search_providers.g.dart';

/// Whether the sidebar header search field is expanded.
@Riverpod(keepAlive: true)
class SidebarHeaderSearchExpanded extends _$SidebarHeaderSearchExpanded {
  @override
  bool build() => false;

  void setExpanded(bool value) => state = value;
}

/// Shared search input for every searchable sidebar destination.
@Riverpod(keepAlive: true)
TextEditingController sidebarSearchFieldController(Ref ref) {
  final controller = TextEditingController();
  ref.onDispose(controller.dispose);
  return controller;
}

@Riverpod(keepAlive: true)
FocusNode sidebarSearchFieldFocusNode(Ref ref) {
  final node = FocusNode(debugLabel: 'sidebar_header_search');
  ref.onDispose(node.dispose);
  return node;
}

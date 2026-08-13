import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef SidebarTabSelectionHandler = void Function(WidgetRef ref);
typedef SidebarTabContextualActionsBuilder =
    List<AdaptiveAppBarAction> Function(BuildContext context, Color tintColor);

/// Executable behavior owned by a sidebar tab definition.
final class SidebarTabBehavior {
  const SidebarTabBehavior({
    SidebarTabSelectionHandler onSelected = _noSelectionAction,
    SidebarTabSelectionHandler onDeselected = _noSelectionAction,
    SidebarTabContextualActionsBuilder contextualActions = _noActions,
  }) : _onSelected = onSelected,
       _onDeselected = onDeselected,
       _contextualActions = contextualActions;

  final SidebarTabSelectionHandler _onSelected;
  final SidebarTabSelectionHandler _onDeselected;
  final SidebarTabContextualActionsBuilder _contextualActions;

  void onSelected(WidgetRef ref) => _onSelected(ref);
  void onDeselected(WidgetRef ref) => _onDeselected(ref);

  List<AdaptiveAppBarAction> contextualActions(
    BuildContext context,
    Color tintColor,
  ) => _contextualActions(context, tintColor);
}

List<AdaptiveAppBarAction> _noActions(BuildContext context, Color tintColor) =>
    const [];

void _noSelectionAction(WidgetRef ref) {}

const standardSidebarTabBehavior = SidebarTabBehavior();

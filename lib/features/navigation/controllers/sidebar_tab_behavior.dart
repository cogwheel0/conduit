import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../terminal/models/terminal_models.dart';
import '../../terminal/providers/terminal_providers.dart';
import '../../terminal/widgets/terminal_sidebar_controls_sheet.dart';

typedef SidebarTabSelectionHandler = void Function(WidgetRef ref);
typedef SidebarTabContextualActionsBuilder =
    List<AdaptiveAppBarAction> Function(BuildContext context, Color tintColor);

/// Executable behavior owned by a sidebar tab definition.
final class SidebarTabBehavior {
  const SidebarTabBehavior({
    required SidebarTabSelectionHandler onSelected,
    SidebarTabContextualActionsBuilder contextualActions = _noActions,
  }) : _onSelected = onSelected,
       _contextualActions = contextualActions;

  final SidebarTabSelectionHandler _onSelected;
  final SidebarTabContextualActionsBuilder _contextualActions;

  void onSelected(WidgetRef ref) => _onSelected(ref);

  List<AdaptiveAppBarAction> contextualActions(
    BuildContext context,
    Color tintColor,
  ) => _contextualActions(context, tintColor);
}

List<AdaptiveAppBarAction> _noActions(BuildContext context, Color tintColor) =>
    const [];

void _selectStandardTab(WidgetRef ref) {
  ref
      .read(terminalSidebarPanelProvider.notifier)
      .setPanel(TerminalSidebarPanel.console);
}

void _selectTerminalTab(WidgetRef ref) {
  final servers = ref.read(terminalAvailableServersProvider).asData?.value;
  if (servers != null && servers.length == 1) {
    ref
        .read(terminalSidebarPanelProvider.notifier)
        .setPanel(TerminalSidebarPanel.files);
  }
}

List<AdaptiveAppBarAction> _terminalActions(
  BuildContext context,
  Color tintColor,
) => [
  AdaptiveAppBarAction(
    iosSymbol: 'chevron.down.circle',
    icon: Icons.arrow_drop_down_circle_outlined,
    tintColor: tintColor,
    onPressed: () {
      unawaited(showTerminalSidebarControlsSheet(context));
    },
  ),
];

const standardSidebarTabBehavior = SidebarTabBehavior(
  onSelected: _selectStandardTab,
);

const terminalSidebarTabBehavior = SidebarTabBehavior(
  onSelected: _selectTerminalTab,
  contextualActions: _terminalActions,
);

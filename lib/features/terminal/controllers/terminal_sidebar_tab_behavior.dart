import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../navigation/controllers/sidebar_tab_behavior.dart';
import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
import '../widgets/terminal_sidebar_controls_sheet.dart';

void _selectTerminalTab(WidgetRef ref) {
  final servers = ref.read(terminalAvailableServersProvider).asData?.value;
  if (servers != null && servers.length == 1) {
    ref
        .read(terminalSidebarPanelProvider.notifier)
        .setPanel(TerminalSidebarPanel.files);
  }
}

void _deselectTerminalTab(WidgetRef ref) {
  ref
      .read(terminalSidebarPanelProvider.notifier)
      .setPanel(TerminalSidebarPanel.console);
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

const terminalSidebarTabBehavior = SidebarTabBehavior(
  onSelected: _selectTerminalTab,
  onDeselected: _deselectTerminalTab,
  contextualActions: _terminalActions,
);

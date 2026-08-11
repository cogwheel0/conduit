import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../terminal/models/terminal_models.dart';
import '../../terminal/providers/terminal_providers.dart';
import '../../terminal/widgets/terminal_sidebar_controls_sheet.dart';
import '../widgets/sidebar_tab_registry.dart';

/// Owns feature-specific effects and toolbar contributions for sidebar tabs.
final class SidebarTabBehaviorCoordinator {
  const SidebarTabBehaviorCoordinator();

  void onSelected(WidgetRef ref, SidebarTabDescriptor descriptor) {
    if (descriptor.selectionPolicy != SidebarSelectionPolicy.terminal) {
      ref
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.console);
      return;
    }

    final servers = ref.read(terminalAvailableServersProvider).asData?.value;
    if (servers != null && servers.length == 1) {
      ref
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.files);
    }
  }

  List<AdaptiveAppBarAction> contextualAppBarActions({
    required BuildContext context,
    required SidebarTabDescriptor descriptor,
    required Color tintColor,
  }) => switch (descriptor.selectionPolicy) {
    SidebarSelectionPolicy.standard => const [],
    SidebarSelectionPolicy.terminal => [
      AdaptiveAppBarAction(
        iosSymbol: 'chevron.down.circle',
        icon: Icons.arrow_drop_down_circle_outlined,
        tintColor: tintColor,
        onPressed: () {
          unawaited(showTerminalSidebarControlsSheet(context));
        },
      ),
    ],
  };
}

const sidebarTabBehaviorCoordinator = SidebarTabBehaviorCoordinator();

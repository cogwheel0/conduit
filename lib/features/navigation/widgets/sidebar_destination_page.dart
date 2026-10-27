import 'dart:async';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/vocabulary.dart';

import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../providers/sidebar_providers.dart';
import 'sidebar_tab_registry.dart';
import '../../../l10n/app_localizations.dart';

/// A full main-pane destination, independent of the chat-history sidebar.
class SidebarDestinationPage extends ConsumerStatefulWidget {
  const SidebarDestinationPage({super.key, required this.destination});

  final SidebarTabId destination;

  @override
  ConsumerState<SidebarDestinationPage> createState() =>
      _SidebarDestinationPageState();
}

class _SidebarDestinationPageState
    extends ConsumerState<SidebarDestinationPage> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navigation = ref.watch(sidebarNavigationSnapshotProvider);
    if (!navigation.tabs.contains(widget.destination)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) NavigationService.router.go(Routes.chat);
      });
      return const SizedBox.shrink();
    }
    final tab = sidebarTabDescriptor(widget.destination);
    final l10n = AppLocalizations.of(context)!;
    final color = context.conduitTheme.textPrimary;
    return AdaptiveRouteShell(
      backgroundColor: context.conduitTheme.surfaceBackground,
      appBar: buildConduitCenteredAdaptiveAppBar(
        context: context,
        tintColor: color,
        leading: ConduitAdaptiveAppBarIconButton(
          key: const ValueKey<String>('destination-menu-button'),
          icon: Icons.menu,
          semanticLabel: l10n.sidebarButtonLabel,
          onPressed: () =>
              SidebarDrawerControllerScope.maybeOf(context)?.toggle(),
        ),
        title: Text(tab.label(l10n)),
        actions: [
          for (final action in tab.behavior.contextualActions(context, color))
            ConduitAdaptiveAppBarIconButton(
              icon: action.icon ?? Icons.more_horiz,
              iosSymbol: action.iosSymbol,
              iconColor: color,
              onPressed: action.onPressed,
            ),
          if (tab.createAction case final action?)
            ConduitAdaptiveAppBarIconButton(
              icon: action.icon,
              iosSymbol: action.sfSymbol,
              semanticLabel: action.label(l10n),
              onPressed: () => unawaited(action.run(context, ref)),
            ),
        ],
      ),
      bodySafeArea: true,
      body: Column(
        children: [
          if (widget.destination != SidebarTabId.hermes)
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: ConduitGlassSearchField(
                controller: _searchController,
                focusNode: _searchFocus,
                hintText: tab.searchHint(l10n),
                query: _searchController.text,
                onChanged: (_) => setState(() {}),
                onClear: () => setState(_searchController.clear),
              ),
            ),
          Expanded(
            child: SidebarTabLayoutScope(
              parentOwnsHeaderInset: true,
              bottomNavigationVisible: false,
              child: tab.bodyBuilder(
                showBottomNavigation: false,
                active: true,
                searchController: _searchController,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

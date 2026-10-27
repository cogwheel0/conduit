import 'dart:async';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../providers/sidebar_providers.dart';
import '../utils/chat_list_back.dart';
import 'sidebar_tab_registry.dart';

/// Keeps retained destination bodies informed of the visible route.
class SidebarDestinationScope extends InheritedWidget {
  const SidebarDestinationScope({
    super.key,
    required this.destination,
    required super.child,
  });

  final SidebarTabId destination;

  static bool isActive(BuildContext context, SidebarTabId destination) =>
      context
          .dependOnInheritedWidgetOfExactType<SidebarDestinationScope>()
          ?.destination ==
      destination;

  @override
  bool updateShouldNotify(SidebarDestinationScope oldWidget) =>
      destination != oldWidget.destination;
}

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
  bool _searchExpanded = false;

  void _toggleSearch() {
    setState(() => _searchExpanded = !_searchExpanded);
    if (!_searchExpanded) {
      _searchController.clear();
      _searchFocus.unfocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navigation = ref.watch(sidebarNavigationSnapshotProvider);
    final active = SidebarDestinationScope.isActive(
      context,
      widget.destination,
    );
    if (!navigation.tabs.contains(widget.destination)) {
      if (active) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) NavigationService.router.go(Routes.chat);
        });
      }
      return const SizedBox.shrink();
    }
    final tab = sidebarTabDescriptor(widget.destination);
    final l10n = AppLocalizations.of(context)!;
    final color = context.conduitTheme.textPrimary;
    final page = AdaptiveRouteShell(
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
        title: _searchExpanded
            ? ConduitGlassSearchField(
                controller: _searchController,
                focusNode: _searchFocus,
                hintText: tab.searchHint(l10n),
                query: _searchController.text,
                onChanged: (_) => setState(() {}),
                onClear: () => setState(_searchController.clear),
              )
            : Text(tab.label(l10n)),
        actions: buildConduitAdaptiveToolbarActionWidgets([
          if (widget.destination != SidebarTabId.hermes)
            ConduitAdaptiveAppBarIconButton(
              key: const ValueKey<String>('destination-search-button'),
              icon: _searchExpanded ? Icons.close : Icons.search,
              iosSymbol: _searchExpanded ? 'xmark' : 'magnifyingglass',
              semanticLabel: _searchExpanded
                  ? l10n.close
                  : tab.searchHint(l10n),
              onPressed: _toggleSearch,
            ),
          if (!_searchExpanded) ...[
            for (final action in tab.behavior.contextualActions(context, color))
              ConduitAdaptiveAppBarIconButton(
                icon: action.icon ?? Icons.more_horiz,
                iosSymbol: action.iosSymbol,
                iconColor: color,
                semanticLabel: action.title,
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
        ]),
      ),
      bodySafeArea: true,
      body: SidebarTabLayoutScope(
        parentOwnsHeaderInset: true,
        bottomNavigationVisible: false,
        child: tab.bodyBuilder(
          showBottomNavigation: false,
          active: active,
          searchController: _searchController,
        ),
      ),
    );
    return ChatListBackScope(child: page);
  }
}

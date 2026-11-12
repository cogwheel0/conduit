import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit_core/services/settings_service.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../shared/services/navigation_service.dart';
import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/sidebar_layout_constants.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../providers/sidebar_providers.dart';
import '../utils/chat_list_back.dart';
import 'responsive_drawer_layout.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import 'sidebar_page.dart';
import 'sidebar_tab_registry.dart';
import '../../terminal/providers/terminal_providers.dart';

/// Shell widget that wraps child routes with a persistent
/// [ResponsiveDrawerLayout] + [SidebarPage] drawer.
///
/// Used inside a [ShellRoute] so the drawer survives navigation
/// between chat, channel, and note-editor pages on tablets.
///
/// This shell intentionally does not own an `AdaptiveRouteShell` because the
/// child routes still need route-specific app bars, native tab bars, and
/// fullscreen overlays.
class DrawerShellPage extends ConsumerWidget {
  final Widget child;

  const DrawerShellPage({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTablet = usesPersistentTabletSidebar(context);
    final sliding = ref.watch(
      appSettingsProvider.select((s) => s.slidingSidebarEnabled),
    );
    final tabletWidth = ref.watch(sidebarTabletWidthProvider);
    final localizations = AppLocalizations.of(context)!;
    final scrim = Platform.isIOS
        ? context.colorTokens.scrimMedium
        : context.colorTokens.scrimStrong;

    return ResponsiveDrawerLayout(
      maxFraction: isTablet
          ? 0.42
          : sliding
          ? 0.84
          : 1.0,
      roundPushedContent: sliding,
      settleHaptics: sliding,
      edgeFraction: isTablet ? 0.36 : 1.0,
      settleFraction: 0.06,
      scrimColor: scrim,
      pushContent: true,
      contentScaleDelta: 0.0,
      mobileBottomDragGestureExclusion: isTablet
          ? 0.0
          : sidebarBottomBarGestureExclusionHeight(context),
      tabletDrawerWidth: tabletWidth,
      tabletDrawerMinWidth: minimumSidebarTabletWidth,
      tabletDrawerMaxWidth: maximumSidebarTabletWidth,
      tabletMinimumContentWidth: defaultSidebarTabletWidth,
      tabletResizable: isTablet,
      tabletResizeSemanticsLabel: localizations.sidebarResizeHandle,
      tabletResizeSemanticsHint: localizations.sidebarResizeResetHint,
      tabletResizeSemanticsValueBuilder: (width) =>
          localizations.sidebarWidthValue(width.round()),
      onTabletDrawerWidthChanged: (width) {
        ref.read(sidebarTabletWidthProvider.notifier).setWidth(width);
        ConduitHaptics.selectionClick();
      },
      onOpenStart: () {
        // Suppress composer auto-focus when drawer opens on mobile
        try {
          ref.read(composerAutofocusEnabledProvider.notifier).set(false);
        } catch (_) {}
      },
      drawer: const SidebarPage(),
      layoutBuilder: (layout) => SidebarOverlayDismissListener(
        child: AppKeyboardShortcuts(child: layout),
      ),
      child: NestedNavigatorBackScope(child: child),
    );
  }
}

/// Closes the overlay sidebar when [sidebarOverlayDismissRequestProvider]
/// asks. It sits under the drawer, where the drawer's controller is in scope.
class SidebarOverlayDismissListener extends ConsumerStatefulWidget {
  const SidebarOverlayDismissListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SidebarOverlayDismissListener> createState() =>
      _SidebarOverlayDismissListenerState();
}

class _SidebarOverlayDismissListenerState
    extends ConsumerState<SidebarOverlayDismissListener> {
  /// The file request this listener last saw, and the route and backend
  /// choices when it did, until it is handled. Opening Terminal for it after
  /// the person chose another page or history would override that choice.
  Object? _request;
  int? _requestRouteRevision;
  int? _requestHistoryRevision;

  /// Counts backend history choices, which leave the route as it is.
  int _historyRevision = 0;

  void _displayRequestedFile() {
    final request = ref.read(terminalDisplayFileProvider);
    if (!ref.read(appSettingsProvider).slidingSidebarEnabled ||
        request == null) {
      return;
    }
    if (!identical(request, _request)) {
      _request = request;
      _requestRouteRevision = NavigationService.currentRouteRevision;
      _requestHistoryRevision = _historyRevision;
    }
    final hasBackend =
        !ref.read(hermesOnlyModeProvider) &&
        ref.read(openWebUiAccountAvailableProvider);
    final servers = ref.read(terminalAvailableServersProvider);
    if (hasBackend && (servers.isLoading || servers.hasError)) return;
    if (!hasBackend || servers.requireValue.isEmpty) {
      ref.read(terminalDisplayFileProvider.notifier).clear();
      return;
    }
    final requestedRoute = _requestRouteRevision;
    final requestedHistory = _requestHistoryRevision;
    _requestRouteRevision = null;
    _requestHistoryRevision = null;
    // Terminal still shows the file when the person opens it.
    if (requestedRoute != NavigationService.currentRouteRevision ||
        requestedHistory != _historyRevision) {
      return;
    }
    if (NavigationService.currentRoute != Routes.terminal) {
      NavigationService.router.go(Routes.terminal);
    }
    closeSidebarDrawerIfOverlay(context);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sidebarOverlayDismissRequestProvider, (_, _) {
      closeSidebarDrawerIfOverlay(context);
    });
    ref.listen(sidebarHistoryTabProvider, (_, _) => _historyRevision++);
    ref.listen(terminalDisplayFileProvider, (_, _) => _displayRequestedFile());
    ref.listen(
      terminalAvailableServersProvider,
      (_, _) => _displayRequestedFile(),
    );
    ref.listen(
      sidebarNavigationSnapshotProvider,
      (_, _) => _displayRequestedFile(),
    );
    return widget.child;
  }
}

/// Hardware keyboard shortcuts: Command-N starts something new for the
/// sidebar's backend or tab, Command-K searches, Command-1 to Command-5 pick
/// a sidebar tab, Command-comma opens Settings, and Escape closes search,
/// then an overlay sidebar, then leaves the focused field.
///
/// On every iOS device: an iPad or iPhone with a keyboard attached, and the
/// iPad app on a Mac. None of these keys edits text, so a focused field
/// keeps its own editing shortcuts. Escape is left to whatever in front
/// owns it: an input method still composing text cancels the composition,
/// and a dialog, sheet or menu dismisses itself.
class AppKeyboardShortcuts extends ConsumerStatefulWidget {
  const AppKeyboardShortcuts({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppKeyboardShortcuts> createState() =>
      _AppKeyboardShortcutsState();
}

class _AppKeyboardShortcutsState extends ConsumerState<AppKeyboardShortcuts> {
  /// Where Escape leaves focus when it takes it from a field: inside these
  /// bindings, so the next shortcut still reaches them. Unfocusing instead
  /// hands focus to the enclosing scope, which can sit above them, where
  /// Command-K and the rest would never see a key.
  final FocusNode _restingFocus = FocusNode(
    debugLabel: 'AppKeyboardShortcuts',
    skipTraversal: true,
  );

  @override
  void dispose() {
    _restingFocus.dispose();
    super.dispose();
  }

  void _createForActiveTab() {
    final destination = ref.read(appSettingsProvider).slidingSidebarEnabled
        ? ref.read(sidebarSelectedHistoryTabProvider)
        : ref.read(sidebarNavigationSnapshotProvider).selectedTab;
    final action = sidebarTabDescriptor(destination).createAction;
    if (action != null) unawaited(action.run(context, ref));
  }

  void _focusSidebarSearch() {
    final drawer = SidebarDrawerControllerScope.maybeOf(context);
    if (drawer?.isOpen == false) drawer?.open();
    openSidebarSearch(ref);
  }

  void _dismissTopLayer() {
    if (ref.read(sidebarHeaderSearchExpandedProvider)) {
      closeSidebarSearch(ref);
      return;
    }
    final drawer = SidebarDrawerControllerScope.maybeOf(context);
    if (!usesPersistentTabletSidebar(context) && drawer?.isOpen == true) {
      drawer?.close();
      return;
    }
    _restingFocus.requestFocus();
  }

  void _openSettings() {
    final path = Uri.tryParse(NavigationService.currentRoute ?? '')?.path;
    if (path == Routes.profile ||
        path?.startsWith('${Routes.profile}/') == true) {
      return;
    }
    unawaited(NavigationService.pushTo(Routes.profile));
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfo.isIOS) return widget.child;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(
          LogicalKeyboardKey.keyN,
          meta: true,
          includeRepeats: false,
        ): _createForActiveTab,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _focusSidebarSearch,
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () =>
            selectSidebarTab(context, ref, 0),
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () =>
            selectSidebarTab(context, ref, 1),
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () =>
            selectSidebarTab(context, ref, 2),
        const SingleActivator(LogicalKeyboardKey.digit4, meta: true): () =>
            selectSidebarTab(context, ref, 3),
        const SingleActivator(LogicalKeyboardKey.digit5, meta: true): () =>
            selectSidebarTab(context, ref, 4),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            _openSettings,
        const _ShellEscape(): _dismissTopLayer,
      },
      child: Focus(focusNode: _restingFocus, child: widget.child),
    );
  }
}

/// Escape, unless what has focus owns it. The refused key then reaches the
/// app's default Escape (`DismissIntent`), as it would without the shell.
class _ShellEscape extends ShortcutActivator {
  const _ShellEscape();

  static const SingleActivator _escape = SingleActivator(
    LogicalKeyboardKey.escape,
  );

  @override
  Iterable<LogicalKeyboardKey> get triggers => _escape.triggers;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      _escape.accepts(event, state) && !_focusOwnsEscape();

  @override
  String debugDescribeKeys() => _escape.debugDescribeKeys();
}

/// Whether Escape belongs to what has focus rather than to the shell:
/// - a field whose input method is still composing text, which Escape
///   cancels;
/// - a route the app's default Escape would pop: one whose barrier
///   dismisses it, as `DismissIntent` checks;
/// - a dialog, sheet or menu route in front even when Escape cannot dismiss
///   it, which keeps the layers behind it out of reach;
/// - a selection's menu that is showing (the menu over selected reply
///   text), which Escape hides first: the selection's own `DismissIntent`
///   does that.
///
/// Widgets that merely pass `DismissIntent` on (a text field or selectable
/// message text with no toolbar showing) do not own Escape: the shell's
/// order (close search, then the overlay sidebar, then leave the focus)
/// still runs there. An open menu needs no check: its anchor and panel map
/// Escape themselves, nearer the focus than these bindings.
bool _focusOwnsEscape() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final composing = context
      .findAncestorStateOfType<EditableTextState>()
      ?.textEditingValue
      .composing;
  if (composing != null && composing.isValid && !composing.isCollapsed) {
    return true;
  }
  if (AdaptiveTextSelectionMenu.isShowing) return true;
  final route = ModalRoute.of(context);
  return route is PopupRoute || (route?.barrierDismissible ?? false);
}

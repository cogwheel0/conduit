import 'dart:async';

import 'package:flutter/semantics.dart' show OrdinalSortKey;
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../calendar/views/calendar_page.dart';
import '../settings_pages.dart';
import 'settings_page_view.dart';

/// The window width from which the Flutter Settings pages show the root
/// list beside the page it opened: Material's expanded window class. A
/// narrower window keeps one column, each page pushed over the last.
const settingsTwoColumnMinWidth = 840.0;

/// The root list's width beside a page.
const settingsListColumnWidth = 360.0;

/// Router `extra` for a page opened again as the window narrows past two
/// columns: under another such page, it waits to describe itself until it
/// shows, so it doesn't describe the pages it leads to -- the one above it
/// among them -- after they have.
final class SettingsPageReopened {
  const SettingsPageReopened();
}

/// A page of Settings whose unsaved changes switching to another root row
/// would drop -- it is asked first, with its own question -- and whose
/// typed text goes with it when it moves between the columns.
abstract interface class SettingsColumnMember {
  /// The page's id.
  String get pageId;

  /// Whether the page holds changes not yet saved.
  bool get holdsUnsavedChanges;

  /// The question the page asks before its changes go, when it has one.
  NativeSheetDiscardPrompt? get discardPrompt;

  /// What the page holds that its owner may not show yet: text typed and
  /// not done, text done, and whether anything was changed.
  SettingsPageDraft get draft;

  /// Sends text typed and not yet done, as the page does when it is left.
  void commitPendingText();
}

/// What a page holds of its own, carried when it moves between columns.
typedef SettingsPageDraft = ({
  Map<String, String> pending,
  Map<String, String> committed,
  bool edits,
});

/// Pages moving between the page column and routes of their own as the
/// window crosses [settingsTwoColumnMinWidth]. A page moved has not been
/// left, nor opened anew: what it holds goes with it, unsent -- on Change
/// Password, sending it would change the password -- the page left behind
/// is not told it closed, and the one in its place does not describe
/// itself again, which would start its draft over.
final class SettingsColumnMove {
  final Set<SettingsColumnMember> _pages = {};
  final Map<String, SettingsPageDraft> _drafts = {};
  final Set<String> _toColumn = {};
  final Set<String> _arriving = {};

  /// Pages whose visit has described itself: only those, moved, are
  /// already showing where they arrive. One added a moment before a move,
  /// never drawn, describes itself where it opens.
  final Set<String> _shown = {};
  final Map<String, Route<Object?>> _routes = {};

  void register(SettingsColumnMember page) => _pages.add(page);
  void unregister(SettingsColumnMember page) => _pages.remove(page);

  /// Keeps what pages [ids] hold for the pages that open again in their
  /// place. A page not drawn yet (opened by the last move a frame ago)
  /// keeps what that move kept for it.
  void carry(Iterable<String> ids) {
    final moving = ids.toSet();
    _drafts.removeWhere((id, _) => !moving.contains(id));
    for (final page in _pages) {
      if (!moving.contains(page.pageId)) continue;
      final draft = page.draft;
      if (draft.pending.isEmpty && draft.committed.isEmpty && !draft.edits) {
        _drafts.remove(page.pageId);
      } else {
        _drafts[page.pageId] = draft;
      }
    }
    _arriving
      ..clear()
      ..addAll(moving.where(_shown.contains));
  }

  /// Page [pageId]'s visit described itself.
  void appeared(String pageId) => _shown.add(pageId);

  /// Page [pageId] was left, its visit over.
  void left(String pageId) => _shown.remove(pageId);

  /// What page [pageId] held before it moved, once.
  SettingsPageDraft? take(String pageId) => _drafts.remove(pageId);

  /// Whether page [pageId] opens again where a move put it: true once.
  bool arrives(String pageId) => _arriving.remove(pageId);

  /// Pages [ids], open as routes over the list, move beside it.
  void moveToColumn(Iterable<String> ids) => _toColumn
    ..clear()
    ..addAll(ids);

  /// Whether page [pageId] is a route over the list that moves beside it.
  bool movesToColumn(String pageId) => _toColumn.contains(pageId);

  /// The route page [pageId] is gone, moved beside the list: true once.
  bool movedToColumn(String pageId) => _toColumn.remove(pageId);

  /// Page [pageId] shows as [route] over the list.
  void routeOpened(String pageId, Route<Object?> route) =>
      _routes[pageId] = route;

  void routeClosed(String pageId, Route<Object?> route) {
    if (identical(_routes[pageId], route)) _routes.remove(pageId);
  }

  /// The route page [pageId] shows as over the list, if it does.
  Route<Object?>? routeOf(String pageId) => _routes[pageId];
}

final settingsColumnMoveProvider = Provider<SettingsColumnMove>(
  (_) => SettingsColumnMove(),
);

/// The page column of Settings in two columns, for the pages in it: they
/// open the pages they lead to here rather than as routes of the app, and
/// say whether they hold unsaved changes.
class SettingsPageColumn extends InheritedWidget {
  const SettingsPageColumn({
    super.key,
    required this.controller,
    required super.child,
  });

  final SettingsColumnController controller;

  /// The page column [context] is in, or null outside two columns.
  static SettingsColumnController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SettingsPageColumn>()?.controller;

  @override
  bool updateShouldNotify(SettingsPageColumn oldWidget) =>
      controller != oldWidget.controller;
}

/// What the page column's pages ask of it.
abstract interface class SettingsColumnController {
  /// Opens page [id] on top of the page column; completes once it closes.
  Future<void> open(String id);

  /// Whether the column's pages are moving to one column, where they open
  /// again: they have not been left, and keep what they hold.
  bool get isMoving;

  void register(SettingsColumnMember member);
  void unregister(SettingsColumnMember member);
}

/// Settings's root [list] beside the page it opened, with the pages that
/// page leads to stacked in that column. The row of the page shown stays
/// selected; another row asks first when the pages shown would lose
/// unsaved changes.
///
/// [buildList] draws the root list, given the row to keep selected and
/// what opening a root row's page does.
class SettingsColumns extends ConsumerStatefulWidget {
  const SettingsColumns({
    super.key,
    required this.buildList,
    required this.firstPageId,
    this.initialPageIds = const [],
    this.onSelected,
  });

  final Widget Function(
    String? selectedId,
    Future<void> Function(String id) openRootPage,
  )
  buildList;

  /// The root row whose page shows first, before any is chosen.
  final String? Function() firstPageId;

  /// The pages the column opens with, first to top: those that were open
  /// before the window widened, or the page chosen last.
  final List<String> initialPageIds;

  /// Told the root row whose page the column shows, as it changes.
  final ValueChanged<String>? onSelected;

  @override
  ConsumerState<SettingsColumns> createState() => SettingsColumnsState();
}

/// One page in the page column, with what its opener waits on.
final class _ColumnEntry {
  _ColumnEntry(this.id);

  final String id;
  final key = UniqueKey();
  final closed = Completer<void>();

  void close() {
    if (!closed.isCompleted) closed.complete();
  }
}

/// Counts what is open in the page column besides its pages: the sheets and
/// questions those pages open there.
final class _OverPages extends NavigatorObserver {
  int open = 0;

  static bool _overPage(Route<dynamic> route) => route.settings is! _ColumnPage;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_overPage(route)) open++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_overPage(route)) open--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_overPage(route)) open--;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null && _overPage(oldRoute)) open--;
    if (newRoute != null && _overPage(newRoute)) open++;
  }
}

class SettingsColumnsState extends ConsumerState<SettingsColumns>
    implements SettingsColumnController {
  final _pane = GlobalKey<NavigatorState>();
  final _overPages = _OverPages();

  /// Whether a sheet or question one of the column's pages opened is open
  /// in the column: moving the pages to one column would close it, with
  /// what it holds.
  bool get holdsOverPages => _overPages.open > 0;
  final List<_ColumnEntry> _entries = [];
  final List<SettingsColumnMember> _members = [];
  String? _selected;
  bool _moving = false;

  /// The ids of the pages the column shows, first to top.
  List<String> get openPageIds => [for (final entry in _entries) entry.id];

  /// The root row whose page the column shows.
  String? get selectedId => _selected;

  @override
  bool get isMoving => _moving;

  @override
  void initState() {
    super.initState();
    final ids = widget.initialPageIds;
    if (ids.isNotEmpty) {
      _selected = ids.first;
      _entries.addAll([for (final id in ids) _ColumnEntry(id)]);
    }
  }

  @override
  void register(SettingsColumnMember member) => _members.add(member);

  @override
  void unregister(SettingsColumnMember member) => _members.remove(member);

  /// The column's pages move to one column: they keep what they hold,
  /// text typed in them too, which is not sent.
  void prepareToMove() {
    ref.read(settingsColumnMoveProvider).carry(openPageIds);
    _moving = true;
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.close();
    }
    super.dispose();
  }

  @override
  Future<void> open(String id) {
    final entry = _ColumnEntry(id);
    setState(() => _entries.add(entry));
    return entry.closed.future;
  }

  /// Root row [id] opens its page in the column, asking first when the
  /// pages there would lose unsaved changes. Its own row again goes back to
  /// its page's top.
  Future<void> openRootPage(String id) async {
    // A sheet or question one of the pages opened is open beside the list:
    // replacing the pages would close it, with what it holds, unasked. The
    // root row waits until it has gone.
    if (holdsOverPages) return;
    final again = id == _selected && _entries.isNotEmpty;
    if (again && _entries.length == 1) return;
    // Its own row again keeps its page: only the pages above it go.
    final leaving = {
      for (final entry in again ? _entries.skip(1) : _entries) entry.id,
    };
    if (!await _mayLeave(leaving)) return;
    if (!mounted) return;
    // Left for another page, a page that asks nothing keeps the text typed
    // into it, as Back does; one whose changes were discarded sends none.
    for (final member in List.of(_members)) {
      if (leaving.contains(member.pageId) && member.discardPrompt == null) {
        member.commitPendingText();
      }
    }
    setState(() {
      if (again) {
        for (final entry in _entries.skip(1)) {
          entry.close();
        }
        _entries.removeRange(1, _entries.length);
        return;
      }
      for (final entry in _entries) {
        entry.close();
      }
      _entries
        ..clear()
        ..add(_ColumnEntry(id));
      _selected = id;
    });
    widget.onSelected?.call(id);
  }

  /// Asks each page of [leaving] that holds unsaved changes, the highest
  /// first, whether they may go. True when there are none, or the person
  /// chose to discard every one.
  Future<bool> _mayLeave(Set<String> leaving) async {
    final asking = [
      for (final member in _members.reversed)
        if (leaving.contains(member.pageId) &&
            member.holdsUnsavedChanges &&
            member.discardPrompt != null)
          member,
    ];
    for (final member in asking) {
      final prompt = member.discardPrompt!;
      final discard = await ThemedDialogs.confirm(
        context,
        title: prompt.title,
        message: prompt.message,
        confirmText: prompt.discardLabel,
        cancelText: prompt.keepLabel,
        isDestructive: true,
      );
      if (!discard || !mounted) return false;
    }
    return true;
  }

  /// Back on the column's only page: Settings closes, once that page may
  /// lose what it holds.
  Future<void> _leaveSettings() async {
    if (!await _mayLeave(openPageIds.toSet()) || !mounted) return;
    final outer = Navigator.of(context);
    if (outer.canPop()) {
      outer.pop();
    } else {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // The first root row's page shows until another is chosen; the pages
    // known change as the root registers them.
    ref.watch(settingsPagesProvider.select((pages) => pages.pages.length));
    if (_entries.isEmpty) {
      final first = _selected ?? widget.firstPageId();
      if (first != null) {
        _selected = first;
        _entries.add(_ColumnEntry(first));
        widget.onSelected?.call(first);
      }
    }
    final theme = context.conduitTheme;
    final list = widget.buildList(_selected, openRootPage);
    final pane = _entries.isEmpty
        ? const SizedBox.expand()
        : PopScope<Object?>(
            // Back closes what is on top of the column first -- a sheet a
            // page opened, then the pages above the first; on its first
            // page, Back leaves Settings, asking first when that page would
            // lose unsaved changes. A nested navigator alone would let the
            // window's Back past a page asking nothing of it.
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              final pane = _pane.currentState;
              if (pane != null && pane.canPop()) {
                unawaited(pane.maybePop());
              } else {
                unawaited(_leaveSettings());
              }
            },
            child: Navigator(
              key: _pane,
              observers: [_overPages],
              pages: [
                for (final entry in _entries)
                  _ColumnPage(entry: entry, child: _pageFor(entry.id)),
              ],
              onDidRemovePage: (page) {
                final entry = _entries
                    .where((entry) => entry.key == page.key)
                    .firstOrNull;
                if (entry == null) return;
                setState(() {
                  _entries.remove(entry);
                  // Its first page closed itself: the column shows the first
                  // root row's page, as the iPad's does, opened afresh when
                  // it was that one.
                  if (_entries.isEmpty) _selected = null;
                });
                entry.close();
              },
            ),
          );
    return Row(
      children: [
        SizedBox(
          width: settingsListColumnWidth,
          // A screen reader reads the list, then the page beside it.
          child: Semantics(
            container: true,
            sortKey: const OrdinalSortKey(0),
            child: list,
          ),
        ),
        SizedBox(width: 1, child: ColoredBox(color: theme.sidebarBorder)),
        Expanded(
          child: Semantics(
            container: true,
            sortKey: const OrdinalSortKey(1),
            child: SettingsPageColumn(controller: this, child: pane),
          ),
        ),
      ],
    );
  }

  Widget _pageFor(String id) => id == NativeSheetRoutes.calendar
      // Settings's Calendar is the Flutter calendar wherever Flutter draws
      // Settings, as the router opens it.
      ? const CalendarPage()
      : SettingsDetailPage(
          key: ValueKey<String>('settings-page-$id'),
          detailId: id,
        );
}

/// A page of the page column: it slides a little and fades in, or simply
/// appears with motion reduced.
final class _ColumnPage extends Page<void> {
  _ColumnPage({required _ColumnEntry entry, required this.child})
    : super(key: entry.key, name: entry.id);

  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return PageRouteBuilder<void>(
      settings: this,
      transitionDuration: still
          ? Duration.zero
          : const Duration(milliseconds: 250),
      reverseTransitionDuration: still
          ? Duration.zero
          : const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) => child,
      transitionsBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        final direction = Directionality.of(context) == TextDirection.rtl
            ? -1.0
            : 1.0;
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0.06 * direction, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}

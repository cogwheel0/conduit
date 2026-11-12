import 'dart:async';

import 'package:flutter/semantics.dart' show OrdinalSortKey;
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

/// A page of the page column whose unsaved changes switching to another
/// root row would drop: it is asked first, with its own question.
abstract interface class SettingsColumnMember {
  /// Whether the page holds changes not yet saved.
  bool get holdsUnsavedChanges;

  /// The question the page asks before its changes go, when it has one.
  NativeSheetDiscardPrompt? get discardPrompt;

  /// Sends text typed and not yet done, as the page would on leaving.
  void commitPendingText();
}

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
  });

  final Widget Function(
    String? selectedId,
    Future<void> Function(String id) openRootPage,
  )
  buildList;

  /// The root row whose page shows first, before any is chosen.
  final String? Function() firstPageId;

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

class SettingsColumnsState extends ConsumerState<SettingsColumns>
    implements SettingsColumnController {
  final _pane = GlobalKey<NavigatorState>();
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
  void register(SettingsColumnMember member) => _members.add(member);

  @override
  void unregister(SettingsColumnMember member) => _members.remove(member);

  /// The column's pages move to one column: they keep what they hold, and
  /// text typed in them is sent first.
  void prepareToMove() {
    for (final member in List.of(_members)) {
      member.commitPendingText();
    }
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
    final again = id == _selected && _entries.isNotEmpty;
    if (again && _entries.length == 1) return;
    if (!await _mayLeave()) return;
    if (!mounted) return;
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
  }

  /// Asks the page with unsaved changes, the highest one first, whether
  /// they may go. True when there are none, or the person chose to discard.
  Future<bool> _mayLeave() async {
    final dirty = _members.lastWhere(
      (member) => member.holdsUnsavedChanges,
      orElse: () => const _NoMember(),
    );
    if (dirty is _NoMember) return true;
    final prompt = dirty.discardPrompt;
    if (prompt == null) return true;
    return ThemedDialogs.confirm(
      context,
      title: prompt.title,
      message: prompt.message,
      confirmText: prompt.discardLabel,
      cancelText: prompt.keepLabel,
      isDestructive: true,
    );
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
      }
    }
    final theme = context.conduitTheme;
    final list = widget.buildList(_selected, openRootPage);
    final pane = _entries.isEmpty
        ? const SizedBox.expand()
        : NavigatorPopHandler(
            // Back closes the column's top page first; on its first page,
            // Back leaves Settings.
            enabled: _entries.length > 1,
            onPopWithResult: (_) => _pane.currentState?.maybePop(),
            child: Navigator(
              key: _pane,
              pages: [
                for (final entry in _entries)
                  _ColumnPage(entry: entry, child: _pageFor(entry.id)),
              ],
              onDidRemovePage: (page) {
                final entry = _entries
                    .where((entry) => entry.key == page.key)
                    .firstOrNull;
                if (entry == null) return;
                setState(() => _entries.remove(entry));
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

final class _NoMember implements SettingsColumnMember {
  const _NoMember();

  @override
  bool get holdsUnsavedChanges => false;

  @override
  NativeSheetDiscardPrompt? get discardPrompt => null;

  @override
  void commitPendingText() {}
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

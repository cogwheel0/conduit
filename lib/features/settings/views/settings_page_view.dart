import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/semantics.dart' show SemanticsService;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/native_sheet_hydration_service.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart'
    show ConduitGlassSearchField;
import '../../../shared/widgets/discard_changes.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/sign_out_options_dialog.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../settings_controller.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'settings_option_picker.dart';
import 'settings_profile_editors.dart';
import 'settings_rows.dart';
import 'settings_symbols.dart';

/// Space between two groups of rows.
const _sectionGap = SizedBox(height: Spacing.lg);

/// A Settings page opened by id, drawn from its definition.
///
/// It asks for its rows when it appears and again whenever a page opened
/// from it closes, as the native sheet fills a page in each time it shows.
class SettingsDetailPage extends ConsumerStatefulWidget {
  const SettingsDetailPage({super.key, required this.detailId});

  final String detailId;

  @override
  ConsumerState<SettingsDetailPage> createState() => _SettingsDetailPageState();
}

class _SettingsDetailPageState extends ConsumerState<SettingsDetailPage> {
  /// Read while the page is up: a page that follows something live stops
  /// when it closes, after `ref` can no longer be read.
  late final NativeSheetHydrationService _hydration;
  late final SettingsController _controller;
  late final List<SettingsPageModule> _modules;

  @override
  void dispose() {
    _hydration.stopFollowing(widget.detailId);
    _controller.pageClosed(widget.detailId, modules: _modules);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Providers can't change while the tree builds, so the page asks once
    // this first frame is done.
    _hydration = ref.read(nativeSheetHydrationServiceProvider);
    _controller = ref.read(settingsControllerProvider);
    _modules = ref.read(settingsPageModulesProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _appeared();
    });
  }

  void _appeared() {
    final l10n = AppLocalizations.of(context);
    // Opened straight from a link, before the root registered it: show it
    // loading so its rows have somewhere to land.
    if (l10n != null &&
        !ref.read(settingsPagesProvider).contains(widget.detailId)) {
      ref.read(settingsPagesProvider.notifier).register([
        buildNativeLoadingDetail(l10n: l10n, id: widget.detailId, title: ''),
      ]);
    }
    ref
        .read(settingsControllerProvider)
        .handle(
          NativeSheetDetailAppeared(detailId: widget.detailId),
          source: SettingsEventSource.flutter,
        );
  }

  /// Goes back to the page that opened this one, closing any page above.
  void _close() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    navigator.popUntil((candidate) => candidate == route);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    // Forgotten while open, as when another account takes over: the page
    // describes itself again, for the account there is now.
    ref.listen(
      settingsPagesProvider.select((pages) => pages.contains(widget.detailId)),
      (wasKnown, isKnown) {
        if (wasKnown != true || isKnown) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _appeared();
        });
      },
    );
    ref.listen(
      settingsPagesProvider.select(
        (pages) => pages.closeRequests[widget.detailId],
      ),
      (previous, next) {
        // Only a new request closes the page; a count forgotten (Settings
        // cleared) is not one.
        if (next != null && next > (previous ?? 0) && mounted) _close();
      },
    );
    final detail = ref.watch(
      settingsPagesProvider.select((pages) => pages[widget.detailId]),
    );
    if (detail == null) {
      return UtilityPageScaffold.settings(
        title: '',
        children: const [Center(child: AdaptiveProgressIndicator())],
      );
    }
    return SettingsPageView(detail: detail, onReturned: _appeared);
  }
}

/// One Settings page: its definition's groups and rows, and the native
/// sheet's rules for what each row does.
///
/// A row whose id names a known page opens that page; a picker row opens
/// its choices; a switch, slider or choice sends its new value; text is a
/// draft until Done (the check in the bar) or Return commits it. Values the
/// person set stay drawn until the page is described again.
class SettingsPageView extends ConsumerStatefulWidget {
  const SettingsPageView({
    super.key,
    required this.detail,
    this.onReturned,
    this.leading = const [],
    this.leadingFor,
  });

  final NativeSheetDetailConfig detail;

  /// A row's own leading picture, when the page has one its definition
  /// cannot carry; null keeps the row's glyph.
  final Widget? Function(NativeSheetItemConfig item)? leadingFor;

  /// Called when a page opened from this one has closed.
  final VoidCallback? onReturned;

  /// Drawn above the first group.
  final List<Widget> leading;

  @override
  ConsumerState<SettingsPageView> createState() => _SettingsPageViewState();
}

class _SettingsPageViewState extends ConsumerState<SettingsPageView> {
  final Map<String, String> _pendingText = {};
  final Map<String, String> _committedText = {};
  final Map<String, Object?> _chosen = {};
  final Map<String, List<String>> _order = {};

  /// Bumped when the page is described again, so text fields restart from
  /// the new values.
  int _generation = 0;

  /// Whether anything changed on the page since it appeared. On a page that
  /// confirms with Done the changes wait as a draft until then, so a page
  /// described again (with why a save failed) still holds them.
  bool _controlEdits = false;

  /// Unsaved changes, by the native sheet's rule: text not yet done, or, on
  /// a page that confirms with Done, anything changed since it appeared.
  bool get _hasUnsavedChanges {
    final detail = widget.detail;
    if (detail.discardPrompt == null) return false;
    final confirms = detail.confirmActionId?.isNotEmpty ?? false;
    return detail.edited ||
        _pendingText.isNotEmpty ||
        (confirms && _controlEdits);
  }

  @override
  void didUpdateWidget(covariant SettingsPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final announcement = widget.detail.announcement;
    if (announcement != null &&
        announcement.isNotEmpty &&
        announcement != oldWidget.detail.announcement) {
      // As the native sheet posts it: read out once, as the page says it.
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          announcement,
          Directionality.of(context),
        ),
      );
    }
    // Its owner had it edited and says it no longer is: what was changed on
    // it has been saved, as the native sheet takes it.
    if (oldWidget.detail.edited && !widget.detail.edited) {
      _controlEdits = false;
    }
    if (!identical(oldWidget.detail, widget.detail)) {
      // Text typed and not yet done stays in a field the update leaves as
      // it was (another row filled in meanwhile, say): that field is kept,
      // with what is in it. Every other field starts from the page.
      final before = {
        for (final item in _itemsOf(oldWidget.detail)) item.id: item.value,
      };
      final kept = {
        for (final item in _itemsOf(widget.detail))
          if (_pendingText[item.id] case final text?
              when before.containsKey(item.id) && before[item.id] == item.value)
            item.id: text,
      };
      _pendingText
        ..clear()
        ..addAll(kept);
      _committedText.clear();
      _chosen.clear();
      _order.clear();
      _generation++;
      _textKeys.removeWhere((id, _) => !kept.containsKey(id));
    }
  }

  /// The key generation of each text field kept through an update.
  final Map<String, int> _textKeys = {};

  static Iterable<NativeSheetItemConfig> _itemsOf(
    NativeSheetDetailConfig detail,
  ) => [
    ...detail.items,
    for (final section in detail.sections) ...section.items,
  ];

  /// The groups as the native sheet lays out a page: its own groups, or its
  /// rows with the subtitle as their footer and destructive rows apart.
  List<NativeSheetSectionConfig> get _sections {
    final detail = widget.detail;
    if (detail.sections.isNotEmpty) return detail.sections;
    final plain = detail.items.where((item) => !item.destructive).toList();
    final destructive = detail.items.where((item) => item.destructive).toList();
    return [
      if (plain.isNotEmpty)
        NativeSheetSectionConfig(footer: detail.subtitle, items: plain),
      if (destructive.isNotEmpty) NativeSheetSectionConfig(items: destructive),
    ];
  }

  Iterable<NativeSheetItemConfig> get _items =>
      _sections.expand((section) => section.items);

  bool _navigable(NativeSheetItemConfig item) =>
      ref.read(settingsPagesProvider).contains(item.id);

  void _send(String id, Object? value) {
    ref
        .read(settingsControllerProvider)
        .handle(
          NativeSheetControlChanged(id: id, value: value),
          source: SettingsEventSource.flutter,
        );
  }

  void _changed(NativeSheetItemConfig item, Object? value) {
    // Text typed on the page goes first: the change can describe the page
    // again, which would drop it.
    _commitPendingText();
    setState(() {
      _chosen[item.id] = value;
      _controlEdits = true;
    });
    _send(item.id, value);
  }

  String _baselineText(NativeSheetItemConfig item) =>
      _committedText[item.id] ??
      (item.value is String ? item.value as String : '');

  String _currentText(NativeSheetItemConfig item) =>
      _pendingText[item.id] ?? _baselineText(item);

  void _textChanged(NativeSheetItemConfig item, String value) {
    setState(() {
      if (value == _baselineText(item)) {
        _pendingText.remove(item.id);
      } else {
        _pendingText[item.id] = value;
      }
    });
  }

  /// Sends every text draft. Returns whether there was one.
  bool _commitPendingText() {
    if (_pendingText.isEmpty) return false;
    FocusManager.instance.primaryFocus?.unfocus();
    final changes = Map<String, String>.of(_pendingText);
    setState(() {
      _pendingText.clear();
      _committedText.addAll(changes);
      _controlEdits = true;
    });
    for (final MapEntry(:key, :value) in changes.entries) {
      _send(key, value);
    }
    return true;
  }

  /// Done for text: sends the drafts, then the page's own confirming row or
  /// action, when it has one.
  void _confirmPendingText() {
    if (!_commitPendingText()) return;
    final action = _items
        .where(
          (item) =>
              item.kind == NativeSheetItemKind.navigation &&
              !item.destructive &&
              item.url == null &&
              !_navigable(item) &&
              item.sfSymbol.contains('checkmark'),
        )
        .firstOrNull;
    final confirm = widget.detail.confirmActionId;
    if (action != null) {
      unawaited(_select(action));
    } else if (confirm != null && confirm.isNotEmpty) {
      _send(confirm, true);
    }
  }

  Future<void> _select(NativeSheetItemConfig item) async {
    final l10n = AppLocalizations.of(context)!;
    // Text typed on the page is sent before any row acts, as the native
    // sheet does: a choice can describe the page again, dropping drafts.
    _commitPendingText();
    switch (item.kind) {
      case NativeSheetItemKind.segment:
      case NativeSheetItemKind.dropdown:
      case NativeSheetItemKind.searchablePicker:
        final current = _chosen[item.id] ?? item.value;
        final picked = await showSettingsOptionPicker(
          context,
          item: item,
          selectedId: current is String ? current : null,
        );
        if (picked == null || !mounted) return;
        _changed(item, picked);
        return;
      default:
        break;
    }

    if (item.id == 'sign-out') {
      final keepServerDetails = await showSignOutOptionsDialog(context);
      if (keepServerDetails == null || !mounted) return;
      _send(item.id, keepServerDetails);
      return;
    }

    final question = item.confirmMessage;
    if (question != null && question.isNotEmpty) {
      final confirmed = await ThemedDialogs.confirm(
        context,
        title: item.title,
        message: question,
        confirmText: item.title,
        isDestructive: item.destructive,
      );
      if (!confirmed || !mounted) return;
    }

    if (item.dismissOnSelect) {
      final actionId = item.actionId?.isNotEmpty == true
          ? item.actionId!
          : item.id;
      _send(actionId, item.actionValue ?? item.value ?? true);
      return;
    }

    if (settingsProfileEditorIds.contains(item.id)) {
      await editSettingsProfileField(context, ref, item.id);
      return;
    }

    if (item.destructive &&
        (item.id == 'memory-clear-all' ||
            item.id.startsWith('memory-delete:'))) {
      final confirmed = await ThemedDialogs.confirm(
        context,
        title: item.title,
        message: item.subtitle ?? item.title,
        confirmText: item.title,
        isDestructive: true,
      );
      if (confirmed && mounted) _send(item.id, true);
      return;
    }

    final url = item.url;
    if (url != null) {
      final opened = await launchExternalLink(url, scope: 'settings/link');
      if (!opened && mounted) {
        UiUtils.showMessage(context, l10n.errorMessage);
      }
      return;
    }

    if (_navigable(item)) {
      await context.pushNamed<void>(
        RouteNames.settingsPage,
        pathParameters: {'id': item.id},
      );
      if (mounted) widget.onReturned?.call();
      return;
    }

    _send(item.id, item.value ?? true);
  }

  Widget? _barAction(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final detail = widget.detail;
    if (detail.busy) {
      // Done is working: it turns until the page is described again.
      return const SizedBox.square(
        dimension: 22,
        child: AdaptiveProgressIndicator(strokeWidth: 2),
      );
    }
    final confirm = detail.confirmActionId;
    if (confirm != null && confirm.isNotEmpty) {
      return ConduitAdaptiveAppBarIconButton(
        icon: Icons.check,
        semanticLabel: detail.confirmActionLabel ?? l10n.done,
        onPressed: () {
          _commitPendingText();
          _send(confirm, true);
        },
      );
    }
    if (_pendingText.isNotEmpty) {
      return ConduitAdaptiveAppBarIconButton(
        icon: Icons.check,
        semanticLabel: l10n.done,
        onPressed: _confirmPendingText,
      );
    }
    final page = detail.trailingActionDetailId;
    if (page != null && page.isNotEmpty) {
      final symbol = detail.trailingActionSfSymbol ?? 'plus';
      // As a row leading to the page: it pushes it.
      return ConduitAdaptiveAppBarIconButton(
        icon: settingsMaterialIcon(symbol),
        iosSymbol: symbol,
        // Read by what it does, not by its icon.
        semanticLabel: symbol == 'plus' ? l10n.settingsAddAction : null,
        onPressed: () =>
            unawaited(_select(NativeSheetItemConfig(id: page, title: page))),
      );
    }
    final trailing = detail.trailingActionId;
    if (trailing != null && trailing.isNotEmpty) {
      final symbol = detail.trailingActionSfSymbol ?? 'plus';
      return ConduitAdaptiveAppBarIconButton(
        icon: settingsMaterialIcon(symbol),
        iosSymbol: symbol,
        // Read by what it does, not by its icon.
        semanticLabel: symbol == 'plus' ? l10n.settingsAddAction : null,
        onPressed: () => _send(trailing, true),
      );
    }
    return null;
  }

  Widget _row(NativeSheetItemConfig item) {
    final text =
        item.kind == NativeSheetItemKind.textField ||
        item.kind == NativeSheetItemKind.secureTextField ||
        item.kind == NativeSheetItemKind.multilineTextField ||
        item.kind == NativeSheetItemKind.code;
    return SettingsRow(
      key: text
          ? ValueKey<String>(
              '${_textKeys.putIfAbsent(item.id, () => _generation)}:${item.id}',
            )
          : null,
      item: item,
      leading: widget.leadingFor?.call(item),
      navigable: _navigable(item),
      value: _chosen[item.id],
      textValue: text ? _currentText(item) : null,
      onTextChanged: text ? (value) => _textChanged(item, value) : null,
      onTextSubmitted: text ? _confirmPendingText : null,
      onSelected: (item) => unawaited(_select(item)),
      onChanged: _changed,
      // One of the row's other actions acts as a row of its own would:
      // asking first when it has a question, opening a page it names.
      onAction: (action) => unawaited(
        _select(switch (action.detailId) {
          final page? when page.isNotEmpty => NativeSheetItemConfig(
            id: page,
            title: action.label,
            destructive: action.destructive,
            confirmMessage: action.confirmMessage,
          ),
          _ => NativeSheetItemConfig(
            id: action.id,
            title: action.label,
            destructive: action.destructive,
            confirmMessage: action.confirmMessage,
            showsDisclosure: false,
          ),
        }),
      ),
      inactive: widget.detail.busy,
    );
  }

  Widget _section(NativeSheetSectionConfig section) {
    final actionId = section.reorderActionId;
    if (actionId != null) return _reorderableSection(section, actionId);
    return InsetGroupedList(
      title: section.title,
      footer: section.footer,
      children: [for (final item in section.items) _row(item)],
    );
  }

  /// A group whose rows are dragged into order by their handles; the new
  /// order is sent as the group's action, with every row's id.
  Widget _reorderableSection(
    NativeSheetSectionConfig section,
    String actionId,
  ) {
    final theme = context.conduitTheme;
    final byId = {for (final item in section.items) item.id: item};
    final items = [for (final id in _order[actionId] ?? byId.keys) ?byId[id]];
    return InsetGroupedSection(
      title: section.title,
      footer: section.footer,
      padding: EdgeInsets.zero,
      child: ReorderableList(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: items.length,
        onReorderItem: (from, to) {
          final next = [...items];
          final moved = next.removeAt(from);
          next.insert(to, moved);
          final ids = [for (final item in next) item.id];
          setState(() => _order[actionId] = ids);
          _send(actionId, ids);
        },
        itemBuilder: (context, index) {
          final item = items[index];
          return Row(
            key: ValueKey<String>('settings-reorder-${item.id}'),
            children: [
              Expanded(child: _row(item)),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(right: Spacing.md),
                  child: Icon(
                    Icons.drag_handle,
                    color: theme.iconSecondary,
                    size: IconSize.medium,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rows that open pages gain their chevron once the page is known.
    ref.watch(settingsPagesProvider);
    final sections = _sections;
    final search = widget.detail.search;
    final page = UtilityPageScaffold.settings(
      title: widget.detail.title,
      trailing: _barAction(context),
      children: [
        if (search != null) ...[
          SettingsSearchField(
            search: search,
            onQuery: (query) => _send(search.id, query),
          ),
          _sectionGap,
        ],
        ...widget.leading,
        for (var index = 0; index < sections.length; index++) ...[
          if (index > 0 || widget.leading.isNotEmpty) _sectionGap,
          _section(sections[index]),
        ],
      ],
    );
    // A form asks before Back or a swipe drops its unsaved changes; closing
    // it after a save does not ask.
    // A page with no discard question keeps, as it is popped, the text
    // typed into it, as if done -- as the native sheet does.
    if (widget.detail.discardPrompt == null) {
      return PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _commitPendingText();
        },
        child: page,
      );
    }
    final prompt = widget.detail.discardPrompt!;
    return DiscardChangesScope(
      dirty: _hasUnsavedChanges,
      confirm: (context) => ThemedDialogs.confirm(
        context,
        title: prompt.title,
        message: prompt.message,
        confirmText: prompt.discardLabel,
        cancelText: prompt.keepLabel,
        isDestructive: true,
      ),
      child: page,
    );
  }
}

/// How long typing in a page's search field pauses before the query goes.
@visibleForTesting
const settingsSearchDebounce = Duration(milliseconds: 250);

/// A page's search field above its rows, as a long list's filter. What is
/// typed goes to [onQuery] once typing pauses for [settingsSearchDebounce],
/// and clearing it goes at once. The page described again keeps the text
/// being typed unless its query is a new one the field did not send: the
/// page echoing a query back must not drop what was typed since.
@visibleForTesting
class SettingsSearchField extends StatefulWidget {
  const SettingsSearchField({
    super.key,
    required this.search,
    required this.onQuery,
  });

  final NativeSheetSearchConfig search;
  final ValueChanged<String> onQuery;

  @override
  State<SettingsSearchField> createState() => _SettingsSearchFieldState();
}

class _SettingsSearchFieldState extends State<SettingsSearchField> {
  late final _controller = TextEditingController(text: widget.search.value);
  Timer? _debounce;

  /// The queries this field sent that the page has not echoed yet, oldest
  /// first, trimmed as the page echoes them.
  final List<String> _unechoed = [];

  @override
  void didUpdateWidget(covariant SettingsSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final value = widget.search.value;
    if (value == oldWidget.search.value) return;
    // An echo of a query this field sent -- the last one or an earlier one
    // answered late -- leaves what is typed (a trailing space included).
    final echo = _unechoed.indexOf(value.trim());
    if (echo >= 0) {
      _unechoed.removeRange(0, echo + 1);
      return;
    }
    // A query from elsewhere -- Show All -- replaces the text, and the send
    // still waiting for the typing to pause is dropped.
    if (value.trim() != _controller.text.trim()) {
      _debounce?.cancel();
      _unechoed.clear();
      _controller.text = value;
    }
  }

  void _send(String query) {
    _unechoed.add(query.trim());
    widget.onQuery(query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String query) {
    setState(() {});
    _debounce?.cancel();
    // Emptied: the whole list comes back at once, as the field shows it.
    if (query.isEmpty) {
      _send('');
      return;
    }
    _debounce = Timer(settingsSearchDebounce, () => _send(query));
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {});
    _send('');
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey<String>('settings-search-${widget.search.id}'),
    child: ConduitGlassSearchField(
      controller: _controller,
      hintText: widget.search.placeholder ?? '',
      query: _controller.text,
      onChanged: _changed,
      onClear: _clear,
    ),
  );
}

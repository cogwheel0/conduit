import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Uses UIKit's edit menu for read-only iOS selections, retaining Flutter's
/// selection/actions and its standard toolbar on other or unavailable hosts.
class AdaptiveTextSelectionMenu extends StatefulWidget {
  /// Callers retain selection ownership and remove the menu on dismissal.
  const AdaptiveTextSelectionMenu({
    super.key,
    required this.selectionRect,
    required this.anchors,
    required this.buttonItems,
    required this.onDismiss,
  });

  /// Selection-menu builder for read-only [SelectableText] surfaces. Flutter
  /// still owns the selection geometry, available actions and clipboard work.
  static Widget editableText(BuildContext context, EditableTextState state) {
    final renderEditable = state.renderEditable;
    final heights = state.getGlyphHeights();
    return AdaptiveTextSelectionMenu(
      selectionRect: TextSelectionToolbarAnchors.getSelectionRect(
        renderEditable,
        heights.startGlyphHeight,
        heights.endGlyphHeight,
        renderEditable.getEndpointsForSelection(
          state.textEditingValue.selection,
        ),
      ),
      anchors: state.contextMenuAnchors,
      buttonItems: state.contextMenuButtonItems,
      onDismiss: () => state.hideToolbar(false),
    );
  }

  final Rect selectionRect;
  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;
  final VoidCallback onDismiss;

  /// Creates the presentation's session and fallback state.
  @override
  State<AdaptiveTextSelectionMenu> createState() =>
      _AdaptiveTextSelectionMenuState();
}

class _AdaptiveTextSelectionMenuState extends State<AdaptiveTextSelectionMenu> {
  static const _channel = MethodChannel(
    'app.cogwheel.conduit/text_selection_menu',
  );
  static int _nextSession = 0;
  int? _session;
  bool _fallback = false;
  bool _scheduled = false;

  /// Refreshes presentation after view, theme, or localization changes.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedulePresentation();
  }

  /// Replaces the menu when its selection geometry or actions change.
  @override
  void didUpdateWidget(AdaptiveTextSelectionMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_samePresentation(oldWidget, widget)) return;
    _schedulePresentation();
  }

  static bool _samePresentation(
    AdaptiveTextSelectionMenu a,
    AdaptiveTextSelectionMenu b,
  ) {
    if (a.selectionRect != b.selectionRect ||
        a.buttonItems.length != b.buttonItems.length) {
      return false;
    }
    for (var i = 0; i < a.buttonItems.length; i++) {
      final x = a.buttonItems[i];
      final y = b.buttonItems[i];
      if (x.type != y.type || x.label != y.label) return false;
    }
    return true;
  }

  /// Invalidates old replies immediately, then waits for consistent geometry.
  void _schedulePresentation() {
    final session = _session;
    _session = null;
    if (session != null) unawaited(_hide(session));
    if (_fallback || _scheduled || !SystemContextMenu.isSupported(context)) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_show());
    });
  }

  /// Fences replies against a newer selection while retaining current callbacks.
  Future<void> _show() async {
    final session = _nextSession++;
    final items = List<ContextMenuButtonItem>.of(widget.buttonItems);
    final view = View.of(context);
    final size = view.physicalSize / view.devicePixelRatio;
    final rect = Rect.fromPoints(
      widget.selectionRect.topLeft,
      widget.selectionRect.bottomRight,
    );
    _session = session;
    try {
      final action = await _channel.invokeMethod<int>('show', {
        'session': session,
        'rect': [rect.left, rect.top, rect.width, rect.height],
        'viewWidth': size.width,
        'viewHeight': size.height,
        'dark': Theme.of(context).brightness == Brightness.dark,
        'labels': [
          for (final item in items)
            AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
        ],
      });
      if (!mounted || _session != session) return;
      if (action != null && action >= 0 && action < widget.buttonItems.length) {
        widget.buttonItems[action].onPressed?.call();
      } else {
        widget.onDismiss();
      }
    } on MissingPluginException {
      _useFallback(session);
    } on PlatformException {
      _useFallback(session);
    }
  }

  /// Keeps selection usable when this presentation's native host is unavailable.
  void _useFallback(int session) {
    if (mounted && _session == session) setState(() => _fallback = true);
  }

  /// The native bridge ignores a hide belonging to an older menu.
  Future<void> _hide(int session) async {
    try {
      await _channel.invokeMethod<void>('hide', {'session': session});
    } on MissingPluginException {
      // An unavailable host is already using the Flutter toolbar.
    } on PlatformException {
      // Engine teardown can race selection disposal.
    }
  }

  /// Removes this session's menu without dismissing a newer selection's menu.
  @override
  void dispose() {
    final session = _session;
    if (session != null) unawaited(_hide(session));
    super.dispose();
  }

  /// Leaves the overlay empty while UIKit owns rendering and hit testing.
  @override
  Widget build(BuildContext context) =>
      _fallback || !SystemContextMenu.isSupported(context)
      ? AdaptiveTextSelectionToolbar.buttonItems(
          anchors: widget.anchors,
          buttonItems: widget.buttonItems,
        )
      : const SizedBox.shrink();
}

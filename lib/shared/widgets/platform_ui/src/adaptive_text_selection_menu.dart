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
    _schedulePresentation();
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

  /// Freezes this presentation's callbacks and fences replies against a newer
  /// selection, so a dismissed menu cannot act on a replacement selection.
  Future<void> _show() async {
    final session = _nextSession++;
    final items = List<ContextMenuButtonItem>.of(widget.buttonItems);
    final view = View.of(context);
    final size = view.physicalSize / view.devicePixelRatio;
    final rect = widget.selectionRect;
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
      if (action != null && action >= 0 && action < items.length) {
        items[action].onPressed?.call();
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

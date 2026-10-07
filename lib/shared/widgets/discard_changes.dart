import 'package:material_ui/material_ui.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';

/// Asks whether to throw away unsaved edits. Returns true when the user
/// chooses to discard them.
///
/// Forms and sheets with edits call this from their Cancel or close action and
/// from `PopScope.onPopInvokedWithResult`, so swiping a sheet away or going
/// back asks the same question as tapping Cancel.
Future<bool> confirmDiscardChanges(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return ThemedDialogs.confirm(
    context,
    title: l10n.workspaceEditorDiscardTitle,
    message: l10n.workspaceEditorDiscardMessage,
    confirmText: l10n.workspaceEditorDiscardConfirm,
    cancelText: l10n.workspaceEditorKeepEditing,
    isDestructive: true,
  );
}

/// Keeps [child] from being popped while [dirty] without first confirming the
/// discard. A confirmed discard pops with [discardResult].
///
/// While [busy], as when a save is on its way, nothing pops it and nothing
/// asks: closing could not stop the request, so back, a barrier tap and a
/// swipe are ignored until it ends.
class DiscardChangesScope extends StatelessWidget {
  const DiscardChangesScope({
    super.key,
    required this.dirty,
    required this.child,
    this.busy = false,
    this.discardResult,
  });

  final bool dirty;
  final bool busy;
  final Widget child;
  final Object? discardResult;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !dirty && !busy,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || busy) return;
        final navigator = Navigator.of(context);
        if (await confirmDiscardChanges(context)) {
          navigator.pop(discardResult);
        }
      },
      child: child,
    );
  }
}

/// Sends a downward swipe on a sheet with unsaved edits through the route's
/// pop handling, so the sheet's [PopScope] can ask before discarding them.
///
/// A modal bottom sheet closes itself on a downward drag with
/// `Navigator.pop`, which does not consult [PopScope]; a barrier tap, the
/// system back gesture and a close button that calls `maybePop` all do. A
/// sheet guards while it has edits and while a save is on its way, which a
/// busy [DiscardChangesScope] then ignores. While
/// [guarded], this widget claims vertical drags that start on the sheet's own
/// chrome (lists inside keep their scrolling) and turns a deliberate downward
/// swipe into [onDismissRequest], `Navigator.maybePop` by default. Otherwise it
/// stays out of the way and the sheet drags as usual. A
/// `DraggableScrollableSheet` also needs `shouldCloseOnMinExtent: !guarded`.
///
/// The widget keeps the same shape either way, so turning the guard on or off
/// never rebuilds [child] from scratch.
class SheetDismissGuard extends StatefulWidget {
  const SheetDismissGuard({
    super.key,
    required this.guarded,
    required this.child,
    this.onDismissRequest,
  });

  final bool guarded;
  final Widget child;

  /// Asks to close the sheet. Defaults to `Navigator.maybePop`.
  final VoidCallback? onDismissRequest;

  @override
  State<SheetDismissGuard> createState() => _SheetDismissGuardState();
}

class _SheetDismissGuardState extends State<SheetDismissGuard> {
  /// A fling faster than this, in logical pixels per second, asks to close.
  static const _closingVelocity = 300.0;

  /// A slow drag further than this asks to close too.
  static const _closingDistance = 64.0;

  double _dragged = 0;

  void _onStart(DragStartDetails _) => _dragged = 0;

  void _onUpdate(DragUpdateDetails details) => _dragged += details.delta.dy;

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final dragged = _dragged;
    _dragged = 0;
    if (velocity > _closingVelocity || dragged > _closingDistance) {
      final request = widget.onDismissRequest;
      if (request != null) {
        request();
      } else {
        Navigator.maybePop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final guarded = widget.guarded;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: guarded ? _onStart : null,
      onVerticalDragUpdate: guarded ? _onUpdate : null,
      onVerticalDragEnd: guarded ? _onEnd : null,
      child: widget.child,
    );
  }
}

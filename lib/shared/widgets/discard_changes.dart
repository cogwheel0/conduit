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
class DiscardChangesScope extends StatelessWidget {
  const DiscardChangesScope({
    super.key,
    required this.dirty,
    required this.child,
    this.discardResult,
  });

  final bool dirty;
  final Widget child;
  final Object? discardResult;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await confirmDiscardChanges(context)) {
          navigator.pop(discardResult);
        }
      },
      child: child,
    );
  }
}

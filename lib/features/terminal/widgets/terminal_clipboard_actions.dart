import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/utils/utf16_sanitizer.dart';

void _showTerminalSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(sanitizeUtf16(message))));
}

/// Copies the current xterm selection to the system clipboard, surfacing a
/// snackbar (via [context]) when there is nothing selected.
Future<void> copyTerminalSelection(
  BuildContext context,
  Terminal terminal,
  TerminalController controller,
) async {
  final l10n = AppLocalizations.of(context)!;
  final selection = controller.selection;
  if (selection == null) {
    _showTerminalSnackBar(context, l10n.terminalNothingToCopy);
    return;
  }

  final text = terminal.buffer.getText(selection);
  await Clipboard.setData(ClipboardData(text: sanitizeUtf16(text)));
  controller.clearSelection();
  if (context.mounted) {
    _showTerminalSnackBar(context, l10n.terminalCopied);
  }
}

/// Pastes clipboard text into the terminal (bracketed-paste aware). When the
/// terminal is not [connected], surfaces a snackbar instead of swallowing the
/// keystrokes.
Future<void> pasteIntoTerminal(
  BuildContext context,
  Terminal terminal, {
  required bool connected,
}) async {
  final l10n = AppLocalizations.of(context)!;
  if (!connected) {
    _showTerminalSnackBar(context, l10n.terminalPasteWhileDisconnected);
    return;
  }

  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text;
  if (text != null && text.isNotEmpty) {
    terminal.paste(text);
  }
}

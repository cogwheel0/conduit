import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../l10n/strings.g.dart';
import '../shortcuts.dart';

/// The `Cmd+/` sheet (WP-3.7).
///
/// Reads the same [defaultShortcuts] table the dispatcher matches against,
/// so the list cannot drift from what the keys actually do -- which is the
/// usual failure of a shortcut overlay and the reason it stops being read.
class ShortcutsOverlay extends StatelessComponent {
  const ShortcutsOverlay({
    required this.isMac,
    required this.onClose,
    this.table = defaultShortcuts,
    super.key,
  });

  final bool isMac;
  final void Function() onClose;
  final List<Shortcut> table;

  @override
  Component build(BuildContext context) => div(
    classes:
        'fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-6',
    // Clicking the scrim dismisses, which is what everyone tries first.
    // Esc is not handled here: the document-level dispatcher owns it, and
    // closes whatever is in front before it reaches the running turn.
    events: <String, EventCallback>{'click': (event) => onClose()},
    [
      div(
        classes:
            'max-h-full w-full max-w-md overflow-y-auto rounded border '
            'border-border bg-popover p-5 text-popover-foreground shadow-lg',
        attributes: <String, String>{
          'role': 'dialog',
          'aria-modal': 'true',
          'aria-label': t.desktop.desktopShortcutsTitle,
        },
        // Otherwise the scrim's handler fires for every click inside the
        // dialog and it closes as soon as it is touched.
        events: <String, EventCallback>{
          'click': (event) => event.stopPropagation(),
        },
        [
          div(classes: 'mb-4 flex items-center justify-between', [
            h2(classes: 'text-ui-lg font-semibold', [
              Component.text(t.desktop.desktopShortcutsTitle),
            ]),
            button(
              [Component.text('✕')],
              classes: 'rounded px-2 py-1 text-ui-base hover:bg-accent',
              type: ButtonType.button,
              attributes: <String, String>{'aria-label': t.app.close},
              onClick: onClose,
            ),
          ]),
          dl(classes: 'space-y-2', [
            for (final shortcut in table) ...<Component>[
              div(classes: 'flex items-baseline justify-between gap-4', [
                dt(classes: 'text-ui-base', [
                  Component.text(shortcutLabel(shortcut.action)),
                ]),
                dd(
                  classes:
                      'shrink-0 rounded border border-border bg-muted px-2 '
                      'py-0.5 font-mono text-xs text-muted-foreground',
                  [
                    Component.text(
                      describeStroke(shortcut.stroke, isMac: isMac),
                    ),
                  ],
                ),
              ]),
            ],
          ]),
        ],
      ),
    ],
  );
}

/// Reuses the label the matching control already carries, so the overlay
/// and the button it stands in for say the same words.
String shortcutLabel(ShortcutAction action) => switch (action) {
  ShortcutAction.newChat => t.app.newChat,
  ShortcutAction.openPalette => t.desktop.desktopShortcutOpenPalette,
  ShortcutAction.focusComposer => t.desktop.desktopShortcutFocusComposer,
  ShortcutAction.focusModelPicker => t.desktop.desktopShortcutFocusModelPicker,
  ShortcutAction.stopGenerating => t.app.stopGenerating,
  ShortcutAction.openSettings => t.desktop.desktopSettingsTitle,
  ShortcutAction.showShortcuts => t.desktop.desktopShortcutShowShortcuts,
  ShortcutAction.copyLastResponse => t.desktop.desktopShortcutCopyLastResponse,
  ShortcutAction.copyLastCodeBlock =>
    t.desktop.desktopShortcutCopyLastCodeBlock,
  ShortcutAction.allowRequest => t.desktop.desktopShortcutAllowRequest,
  ShortcutAction.denyRequest => t.desktop.desktopShortcutDenyRequest,
  ShortcutAction.dictate => t.desktop.desktopShortcutDictate,
  ShortcutAction.toggleSidebar => t.desktop.desktopShortcutToggleSidebar,
  ShortcutAction.toggleSidePane => t.desktop.desktopShortcutToggleSidePane,
};

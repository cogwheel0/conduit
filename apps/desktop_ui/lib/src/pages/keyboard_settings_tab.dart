import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../keyboard.dart';
import '../l10n/strings.g.dart';
import '../rpc/rpc_providers.dart';
import '../shortcuts.dart';
import '../widgets/desktop_integration.dart';
import '../widgets/shortcuts_overlay.dart' show shortcutLabel;
import 'workspace/workspace_common.dart' show actionButton, statusLine;

/// Settings → Keyboard (WP-9.4): every shortcut, rebound by pressing the
/// new keys. A key another command already has is refused, and says which.
class KeyboardSettingsTab extends StatefulComponent {
  const KeyboardSettingsTab({super.key});

  @override
  State<KeyboardSettingsTab> createState() => _KeyboardSettingsTabState();
}

class _KeyboardSettingsTabState extends State<KeyboardSettingsTab> {
  /// The shortcut being recorded, if any.
  ShortcutAction? _recording;
  String? _problem;

  Future<void> _store(Map<String, String> overrides) async {
    await context.read(desktopShellProvider).settings(<String, Object?>{
      'shortcuts': overrides,
    });
    if (mounted) context.invalidate(shellSettingsProvider);
  }

  Map<String, String> get _overrides => Map<String, String>.of(
    context.read(shellSettingsProvider).value?.shortcuts ??
        const <String, String>{},
  );

  /// Gives [action] the keys [stroke], unless another command has them.
  void assign(ShortcutAction action, KeyStroke stroke, {required bool isMac}) {
    final table = context.read(shortcutTableProvider);
    final other = shortcutConflict(table, action, stroke);
    if (other != null) {
      setState(
        () => _problem = t.desktop.desktopShortcutConflict(
          shortcut: describeStroke(stroke, isMac: isMac),
          command: shortcutLabel(other),
        ),
      );
      return;
    }
    final overrides = _overrides;
    final fallback = defaultShortcuts.firstWhere(
      (entry) => entry.action == action,
    );
    // Back to the default is no override at all.
    if (fallback.stroke == stroke) {
      overrides.remove(action.name);
    } else {
      overrides[action.name] = encodeStroke(stroke);
    }
    setState(() {
      _recording = null;
      _problem = null;
    });
    unawaited(_store(overrides));
  }

  void _reset(ShortcutAction action) {
    final overrides = _overrides..remove(action.name);
    unawaited(_store(overrides));
  }

  @override
  Component build(BuildContext context) {
    final shell = context.read(desktopShellProvider);
    if (!shell.available) return const Component.empty();
    final isMac = context.read(shellBridgeProvider).platform == 'darwin';
    final table = context.watch(shortcutTableProvider);
    final overrides =
        context.watch(shellSettingsProvider).value?.shortcuts ??
        const <String, String>{};
    return div(classes: 'space-y-4', [
      if (_problem case final problem?) statusLine(problem, error: true),
      ul(classes: 'divide-y divide-border rounded border border-border', [
        for (final shortcut in table)
          li(
            classes: 'flex items-center gap-3 px-3 py-2 text-ui-base',
            attributes: <String, String>{'data-shortcut': shortcut.action.name},
            [
              span(classes: 'min-w-0 flex-1', [
                Component.text(shortcutLabel(shortcut.action)),
              ]),
              if (_recording == shortcut.action)
                input<String>(
                  id: 'shortcut-capture',
                  classes:
                      'w-56 rounded border border-primary bg-background '
                      'px-2 py-1 text-ui-sm',
                  attributes: <String, String>{
                    'readonly': '',
                    'autofocus': '',
                    'placeholder': t.desktop.desktopShortcutPressKeys,
                    'aria-label': t.desktop.desktopShortcutPressKeys,
                  },
                  events: <String, EventCallback>{
                    'keydown': captureStroke(
                      isMac: isMac,
                      onStroke: (stroke) =>
                          assign(shortcut.action, stroke, isMac: isMac),
                      cancel: () => setState(() {
                        _recording = null;
                        _problem = null;
                      }),
                    ),
                    'blur': (_) => setState(() => _recording = null),
                  },
                )
              else
                Component.element(
                  tag: 'kbd',
                  classes: 'rounded border border-border px-1.5 text-ui-sm',
                  children: [
                    Component.text(
                      describeStroke(shortcut.stroke, isMac: isMac),
                    ),
                  ],
                ),
              button(
                [Component.text(t.desktop.desktopShortcutChange)],
                classes:
                    'rounded border border-border px-2 py-0.5 text-ui-sm '
                    'hover:bg-accent',
                type: ButtonType.button,
                attributes: <String, String>{
                  'aria-label': t.desktop.desktopShortcutChangeLabel(
                    command: shortcutLabel(shortcut.action),
                  ),
                },
                onClick: () {
                  setState(() {
                    _recording = shortcut.action;
                    _problem = null;
                  });
                  // Inserted after load, so `autofocus` alone does nothing.
                  Future<void>.microtask(
                    () => context
                        .read(windowCommandsProvider)
                        .focus('shortcut-capture'),
                  );
                },
              ),
              if (overrides.containsKey(shortcut.action.name))
                button(
                  [Component.text(t.desktop.desktopShortcutReset)],
                  classes:
                      'rounded px-2 py-0.5 text-ui-sm text-muted-foreground '
                      'hover:bg-accent',
                  type: ButtonType.button,
                  onClick: () => _reset(shortcut.action),
                ),
            ],
          ),
      ]),
      if (overrides.isNotEmpty)
        actionButton(
          t.desktop.desktopShortcutResetAll,
          id: 'shortcuts-reset-all',
          onClick: () => unawaited(_store(const <String, String>{})),
        ),
    ]);
  }
}

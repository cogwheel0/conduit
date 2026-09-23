import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../desktop_shell.dart';
import '../l10n/strings.g.dart';
import '../rpc/rpc_providers.dart';
import '../widgets/desktop_integration.dart';
import '../widgets/form_field.dart';
import 'workspace/workspace_common.dart' show statusLine;

/// The same check the main process makes, so a shortcut that would be
/// refused is said to be wrong here instead.
final RegExp quickAskShortcutPattern = RegExp(
  r'^((Command|Cmd|Control|Ctrl|CommandOrControl|CmdOrCtrl|Alt|Option|AltGr|Shift|Super|Meta)\+)+'
  r"([A-Z0-9]|F([1-9]|1[0-9]|2[0-4])|Space|Enter|Tab|Up|Down|Left|Right|[`\-=\[\];',./\\])$",
);

/// Settings → Desktop (M9): the tray, login, quick ask and notifications.
class DesktopSettingsTab extends StatelessComponent {
  const DesktopSettingsTab({super.key});

  @override
  Component build(BuildContext context) {
    final shell = context.read(desktopShellProvider);
    final settings = context.watch(shellSettingsProvider);
    final value = settings.value;
    // The dev browser has no shell to configure.
    if (!shell.available) return const Component.empty();
    if (value == null) {
      return statusLine(
        settings.hasError ? t.app.couldNotConnectGeneric : t.app.loadingShort,
        error: settings.hasError,
      );
    }
    return _DesktopSettings(key: ValueKey(value.quickAskShortcut), value);
  }
}

class _DesktopSettings extends StatefulComponent {
  const _DesktopSettings(this.settings, {super.key});

  final ShellSettings settings;

  @override
  State<_DesktopSettings> createState() => _DesktopSettingsState();
}

class _DesktopSettingsState extends State<_DesktopSettings> {
  late String _shortcut = component.settings.quickAskShortcut;

  bool get _shortcutValid => quickAskShortcutPattern.hasMatch(_shortcut.trim());

  Future<void> _save(Map<String, Object?> patch) async {
    await context.read(desktopShellProvider).settings(patch);
    if (mounted) context.invalidate(shellSettingsProvider);
  }

  Component _check(
    String id,
    String text,
    String description,
    bool checked,
    String key,
  ) => div(classes: 'space-y-1', [
    checkboxField(
      id: id,
      text: text,
      checked: checked,
      onChanged: ({required value}) =>
          unawaited(_save(<String, Object?>{key: value})),
    ),
    p(classes: 'pl-6 text-xs text-muted-foreground', [
      Component.text(description),
    ]),
  ]);

  Component _section(String title, List<Component> children) => section(
    classes: 'space-y-4',
    attributes: <String, String>{'aria-label': title},
    [
      h3(classes: 'text-sm font-semibold text-foreground', [
        Component.text(title),
      ]),
      ...children,
    ],
  );

  @override
  Component build(BuildContext context) {
    final settings = component.settings;
    return div(classes: 'space-y-8', [
      _section(t.desktop.desktopSettingsDesktopTab, [
        _check(
          'shell-close-to-tray',
          t.desktop.desktopCloseToTray,
          t.desktop.desktopCloseToTrayDescription,
          settings.closeToTray,
          'closeToTray',
        ),
        _check(
          'shell-launch-at-login',
          t.desktop.desktopLaunchAtLogin,
          t.desktop.desktopLaunchAtLoginDescription,
          settings.launchAtLogin,
          'launchAtLogin',
        ),
      ]),
      _section(t.desktop.desktopQuickAskTitle, [
        checkboxField(
          id: 'shell-quick-ask',
          text: t.desktop.desktopQuickAskEnabled,
          checked: settings.quickAskEnabled,
          onChanged: ({required value}) =>
              unawaited(_save(<String, Object?>{'quickAskEnabled': value})),
        ),
        textField(
          id: 'shell-quick-ask-shortcut',
          labelText: t.desktop.desktopQuickAskShortcut,
          value: _shortcut,
          disabled: !settings.quickAskEnabled,
          error: _shortcutValid
              ? null
              : t.desktop.desktopQuickAskShortcutInvalid,
          onInput: (value) {
            setState(() => _shortcut = value);
            final trimmed = value.trim();
            if (quickAskShortcutPattern.hasMatch(trimmed) &&
                trimmed != settings.quickAskShortcut) {
              unawaited(_save(<String, Object?>{'quickAskShortcut': trimmed}));
            }
          },
        ),
        if (settings.quickAskEnabled &&
            !settings.quickAskRegistered &&
            _shortcutValid)
          statusLine(t.desktop.desktopQuickAskShortcutTaken, error: true),
      ]),
      _section(t.desktop.desktopNotificationsSection, [
        _check(
          'shell-notify-answers',
          t.app.notificationChatTitle,
          t.app.notificationChatDescription,
          settings.notifyAnswers,
          'notifyAnswers',
        ),
        _check(
          'shell-notify-channels',
          t.app.notificationChannelTitle,
          t.app.notificationChannelDescription,
          settings.notifyChannels,
          'notifyChannels',
        ),
      ]),
    ]);
  }
}

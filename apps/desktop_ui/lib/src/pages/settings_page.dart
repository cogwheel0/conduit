import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_theme/conduit_theme.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../l10n/strings.g.dart';
import '../rpc/rpc_providers.dart';
import '../rpc/session_providers.dart';
import '../rpc/settings_providers.dart';
import '../widgets/form_field.dart';
import 'direct_connections_tab.dart';
import 'mcp_servers_tab.dart';

/// The tabs, and the order they appear in.
enum SettingsTab {
  appearance,
  connections,
  direct,
  mcp,
  data,
  about;

  static SettingsTab parse(String? raw) =>
      SettingsTab.values.where((tab) => tab.name == raw).firstOrNull ??
      SettingsTab.appearance;
}

/// The settings modal (WP-2.4).
///
/// A route rather than a component toggled by a flag, so the tab is in the
/// URL: "settings, connections tab" is then a thing a menu item, a keyboard
/// shortcut and a deep link can all name, and the back button does what it
/// looks like it does.
class SettingsPage extends StatelessComponent {
  const SettingsPage({required this.tab, super.key});

  final String tab;

  @override
  Component build(BuildContext context) {
    final current = SettingsTab.parse(tab);
    return div(
      classes:
          'fixed inset-0 z-50 flex items-center justify-center bg-black/50 '
          'p-6',
      // `dialog`, and labelled by its own heading: without this a screen
      // reader treats the overlay as ordinary content further down the page
      // and never announces that a dialog opened.
      attributes: const <String, String>{
        'role': 'dialog',
        'aria-modal': 'true',
        'aria-labelledby': 'settings-title',
      },
      [
        div(
          classes:
              'flex h-[min(40rem,90vh)] w-[min(56rem,95vw)] overflow-hidden '
              'rounded border border-border bg-card shadow-xl',
          [_sidebar(context, current), _panel(context, current)],
        ),
      ],
    );
  }

  Component _sidebar(
    BuildContext context,
    SettingsTab current,
  ) => nav(classes: 'w-56 shrink-0 border-r border-border bg-background p-3', [
    h2(
      id: 'settings-title',
      classes: 'px-2 pb-3 pt-1 text-sm font-semibold text-foreground',
      [Component.text(t.desktop.desktopSettingsTitle)],
    ),
    ul(classes: 'space-y-0.5', [
      for (final tab in SettingsTab.values)
        li([
          a(
            href: '/settings/${tab.name}',
            classes:
                'block rounded px-2 py-1.5 text-sm '
                '${tab == current ? 'bg-accent text-accent-foreground' : 'text-muted-foreground hover:bg-accent/50'}',
            // `page`, not `selected`: these are navigation links, and
            // `aria-current="page"` is what a screen reader reports for
            // "this is where you are".
            attributes: tab == current
                ? const <String, String>{'aria-current': 'page'}
                : null,
            [Component.text(_label(tab))],
          ),
        ]),
    ]),
  ]);

  String _label(SettingsTab tab) => switch (tab) {
    SettingsTab.appearance => t.app.settingsAppearance,
    SettingsTab.connections => t.app.settingsCategoryServer,
    SettingsTab.direct => t.app.directConnectionsTitle,
    SettingsTab.mcp => t.app.directMcpServersTitle,
    SettingsTab.data => t.app.settingsDataAndConnection,
    SettingsTab.about => t.app.aboutConduit,
  };

  Component _panel(BuildContext context, SettingsTab current) =>
      div(classes: 'flex min-w-0 flex-1 flex-col', [
        header(
          classes:
              'flex items-center justify-between border-b border-border px-5 '
              'py-3',
          [
            span(classes: 'text-sm font-medium text-card-foreground', [
              Component.text(_label(current)),
            ]),
            button(
              [Component.text('×')],
              classes:
                  'size-7 rounded text-lg leading-none '
                  'text-muted-foreground hover:bg-accent',
              type: ButtonType.button,
              attributes: <String, String>{'aria-label': t.app.close},
              // `Router` exposes no pop, and a settings dialog opened from a
              // deep link has nothing to pop to anyway -- closing means going
              // back to the app, which is `/`.
              onClick: () => Router.of(context).replace('/'),
            ),
          ],
        ),
        div(classes: 'min-h-0 flex-1 overflow-y-auto p-5', [
          switch (current) {
            SettingsTab.appearance => const _AppearanceTab(),
            SettingsTab.connections => const _ConnectionsTab(),
            SettingsTab.direct => const DirectConnectionsTab(),
            SettingsTab.mcp => const McpServersTab(),
            SettingsTab.data => const _DataTab(),
            SettingsTab.about => const _AboutTab(),
          },
        ]),
      ]);
}

class _AppearanceTab extends StatelessComponent {
  const _AppearanceTab();

  @override
  Component build(BuildContext context) {
    final preferences = context.watch(appPreferencesProvider);
    return preferences.when(
      loading: () => _loading(),
      error: (error, _) => formError('$error'),
      data: (prefs) => div(classes: 'space-y-8', [
        _modeSection(context, prefs),
        _paletteSection(context, prefs),
        _languageSection(context, prefs),
      ]),
    );
  }

  Component _modeSection(BuildContext context, AppPreferences prefs) =>
      fieldset(classes: 'space-y-2 border-0 p-0', [
        legend(classes: 'text-sm font-medium text-foreground', [
          Component.text(t.app.darkMode),
        ]),
        div(classes: 'flex gap-4', [
          for (final mode in AppThemeMode.values)
            div(classes: 'flex items-center gap-1.5', [
              input<bool>(
                id: 'mode-${mode.name}',
                type: InputType.radio,
                name: 'theme-mode',
                checked: prefs.themeMode == mode,
                onChange: (_) => unawaited(
                  context
                      .read(settingsActionsProvider)
                      .update(AppPreferencesPatch(themeMode: mode)),
                ),
              ),
              label(
                [Component.text(_modeLabel(mode))],
                htmlFor: 'mode-${mode.name}',
                classes: 'text-sm',
              ),
            ]),
        ]),
      ]);

  String _modeLabel(AppThemeMode mode) => switch (mode) {
    AppThemeMode.light => t.app.themeLight,
    AppThemeMode.dark => t.app.themeDark,
    AppThemeMode.system => t.app.system,
  };

  /// The palette grid.
  ///
  /// Each swatch is a radio, not a div with a click handler: a colour choice
  /// is one-of-several, and the native control brings arrow-key navigation
  /// and the announcement with it. The swatches are `aria-hidden` because
  /// three unlabelled colours read as noise; the palette's name is the label.
  Component _paletteSection(
    BuildContext context,
    AppPreferences prefs,
  ) => fieldset(classes: 'space-y-2 border-0 p-0', [
    legend(classes: 'text-sm font-medium text-foreground', [
      Component.text(t.app.themePalette),
    ]),
    div(classes: 'grid grid-cols-2 gap-2 sm:grid-cols-3', [
      for (final palette in kConduitPalettes)
        label(
          [
            input<bool>(
              id: 'palette-${palette.id}',
              type: InputType.radio,
              name: 'theme-palette',
              classes: 'sr-only',
              checked: prefs.themePaletteId == palette.id,
              onChange: (_) => unawaited(
                context
                    .read(settingsActionsProvider)
                    .update(AppPreferencesPatch(themePaletteId: palette.id)),
              ),
            ),
            div(
              classes: 'flex gap-1',
              attributes: const <String, String>{'aria-hidden': 'true'},
              [
                for (final swatch in palette.preview)
                  span(
                    classes: 'size-4 rounded-full border border-border',
                    styles: Styles(
                      raw: <String, String>{
                        'background-color': cssColor(swatch),
                      },
                    ),
                    const [],
                  ),
              ],
            ),
            span(classes: 'text-sm', [Component.text(_paletteLabel(palette))]),
          ],
          htmlFor: 'palette-${palette.id}',
          classes:
              'flex cursor-pointer items-center gap-2 rounded '
              'border p-2 '
              '${prefs.themePaletteId == palette.id ? 'border-primary bg-accent/40' : 'border-border hover:bg-accent/20'}',
        ),
    ]),
  ]);

  /// The registry stores ARB *keys*, not strings, because it has no locale of
  /// its own -- so the label is looked up rather than read off the palette.
  String _paletteLabel(ThemePalette palette) =>
      (t['app.${palette.labelKey}'] as String?) ?? palette.id;

  Component _languageSection(BuildContext context, AppPreferences prefs) => div(
    classes: 'space-y-2',
    [
      label(
        [Component.text(t.app.language)],
        htmlFor: 'locale',
        classes: 'block text-sm font-medium text-foreground',
      ),
      select(
        [
          // The empty value is "follow the system", which is a choice a
          // user can come back to -- not the absence of one.
          option(value: '', selected: prefs.localeCode == null, [
            Component.text(t.app.system),
          ]),
          for (final locale in AppLocale.values)
            option(
              value: locale.languageTag,
              selected: prefs.localeCode == locale.languageTag,
              [Component.text(locale.languageTag)],
            ),
        ],
        id: 'locale',
        classes:
            'w-full rounded border border-border bg-background '
            'px-3 py-2 text-sm text-foreground',
        onChange: (values) =>
            unawaited(_setLocale(context, values.isEmpty ? '' : values.first)),
      ),
    ],
  );

  Future<void> _setLocale(BuildContext context, String value) async {
    await context
        .read(settingsActionsProvider)
        .update(
          value.isEmpty
              ? const AppPreferencesPatch(clearLocaleCode: true)
              : AppPreferencesPatch(localeCode: value),
        );
    // Slang holds the active locale in a global, so the strings only change
    // once it is told. The daemon stores the preference; this makes the
    // window reflect it without a reload.
    LocaleSettings.setLocaleRaw(
      value.isEmpty ? AppLocale.en.languageTag : value,
    );
  }
}

/// The server list, which is a list now rather than a single entry.
class _ConnectionsTab extends StatelessComponent {
  const _ConnectionsTab();

  @override
  Component build(BuildContext context) {
    final servers = context.watch(serverListProvider);
    return servers.when(
      loading: () => _loading(),
      error: (error, _) => formError('$error'),
      data: (list) => div(classes: 'space-y-4', [
        if (list.servers.isEmpty)
          p(classes: 'text-sm text-muted-foreground', [
            Component.text(t.desktop.desktopSettingsNoServers),
          ]),
        ul(classes: 'space-y-2', [
          for (final server in list.servers) _row(context, server),
        ]),
        a(
          href: '/onboarding',
          classes:
              'inline-block rounded border border-border px-3 '
              'py-1.5 text-sm text-foreground hover:bg-accent',
          [Component.text(t.desktop.desktopSettingsAddServer)],
        ),
      ]),
    );
  }

  Component _row(BuildContext context, ServerSummary server) => li(
    classes:
        'flex items-center gap-3 rounded border border-border '
        'p-3',
    [
      div(classes: 'min-w-0 flex-1', [
        div(classes: 'flex items-center gap-2', [
          span(classes: 'truncate text-sm font-medium text-foreground', [
            Component.text(server.name),
          ]),
          if (server.isActive)
            span(
              classes:
                  'rounded-full bg-primary/15 px-2 py-0.5 text-xs '
                  'text-primary',
              [Component.text(t.app.connectedToServer)],
            ),
        ]),
        span(classes: 'truncate font-mono text-xs text-muted-foreground', [
          Component.text(server.url),
        ]),
      ]),
      // Only for the servers it is true of, and only when they are not the
      // one you are on: "signed in" next to the server you are using says
      // nothing, while next to another it is the whole reason to switch.
      if (server.hasStoredSession && !server.isActive)
        span(classes: 'text-xs text-muted-foreground', [
          Component.text(t.desktop.desktopSettingsSignedIn),
        ]),
      if (!server.isActive)
        button(
          [Component.text(t.desktop.desktopSettingsSwitchServer)],
          classes:
              'rounded border border-border px-2.5 py-1 text-xs '
              'text-foreground hover:bg-accent',
          type: ButtonType.button,
          onClick: () => unawaited(
            context.read(sessionActionsProvider).connectToServer(server.id),
          ),
        ),
      button(
        [Component.text(t.desktop.desktopSettingsRemoveServer)],
        classes:
            'rounded px-2.5 py-1 text-xs text-destructive '
            'hover:bg-destructive/10',
        type: ButtonType.button,
        onClick: () => unawaited(
          context.read(sessionActionsProvider).removeServer(server.id),
        ),
      ),
    ],
  );
}

/// Sign-out, with the choice the mobile app also makes the user make.
class _DataTab extends StatefulComponent {
  const _DataTab();

  @override
  State<_DataTab> createState() => _DataTabState();
}

class _DataTabState extends State<_DataTab> {
  bool _keepServerDetails = true;
  bool _busy = false;
  SignOutOutcome? _outcome;
  String? _error;

  @override
  Component build(BuildContext context) => div(classes: 'space-y-6', [
    div(classes: 'space-y-2', [
      h3(classes: 'text-sm font-medium text-foreground', [
        Component.text(t.app.signOut),
      ]),
      checkboxField(
        id: 'keep-server-details',
        text: t.app.keepServerDetails,
        checked: _keepServerDetails,
        disabled: _busy,
        onChanged: ({required value}) =>
            setState(() => _keepServerDetails = value),
      ),
      p(classes: 'text-xs text-muted-foreground', [
        Component.text(t.app.keepServerDetailsDescription),
      ]),
    ]),
    if (_error case final message?) formError(message),
    if (_outcome case final outcome?) _outcomeNotice(outcome),
    button(
      [Component.text(_busy ? t.desktop.desktopSigningOut : t.app.signOut)],
      classes:
          'rounded bg-destructive px-4 py-2 text-sm '
          'text-destructive-foreground disabled:opacity-60',
      type: ButtonType.button,
      disabled: _busy,
      onClick: () => unawaited(_signOut(context)),
    ),
  ]);

  /// Sign-out can half-succeed, and saying so is the point of reporting it.
  ///
  /// The core keeps a fence that suppresses cookie reuse until cleanup
  /// finishes, so "you are signed out here, but this device has not finished
  /// forgetting" is a real and temporary state the user is entitled to see.
  Component _outcomeNotice(SignOutOutcome outcome) => switch (outcome) {
    SignOutOutcome.cleared => p(classes: 'text-sm text-muted-foreground', [
      Component.text(t.desktop.desktopSignedOut),
    ]),
    SignOutOutcome.ownershipYielded => p(
      classes: 'text-sm text-muted-foreground',
      [Component.text(t.desktop.desktopSignOutSuperseded)],
    ),
    SignOutOutcome.localDataClearedSessionCleanupIncomplete ||
    SignOutOutcome.incomplete => formError(t.desktop.desktopSignOutIncomplete),
  };

  Future<void> _signOut(BuildContext context) async {
    setState(() {
      _busy = true;
      _outcome = null;
      _error = null;
    });
    try {
      final result = await context
          .read(sessionActionsProvider)
          .signOut(SignOutRequest(keepServerDetails: _keepServerDetails));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _outcome = result.outcome;
      });
      // Only on a clean sign-out. Navigating away from a partial one would
      // hide the notice explaining what is still on the device.
      if (result.outcome == SignOutOutcome.cleared) {
        Router.of(context).replace('/');
      }
    } on RpcError catch (error) {
      if (!mounted) return;
      // A failed sign-out is the one worth being loud about: the user asked
      // to end a session and may believe it ended. Say plainly that it did
      // not, rather than leaving the button looking idle.
      setState(() {
        _busy = false;
        _error = error.code == ConduitErrorCodes.daemonUnavailable
            ? t.desktop.desktopCoreUnavailable
            : t.desktop.desktopSignOutIncomplete;
      });
    }
  }
}

class _AboutTab extends StatelessComponent {
  const _AboutTab();

  @override
  Component build(BuildContext context) {
    final connection = context.watch(coreConnectionProvider).value;
    final handshake = connection?.handshake;
    return dl(classes: 'grid grid-cols-2 gap-y-1 text-sm', [
      ..._row(t.app.appVersion, kDesktopUiVersion),
      if (handshake != null) ...<Component>[
        ..._row('Daemon', handshake.daemonVersion),
        ..._row('Protocol', handshake.protocolVersion),
        ..._row('Platform', handshake.platform),
        ..._row('User data', handshake.paths.userData),
        ..._row('Logs', handshake.paths.logs),
      ],
    ]);
  }

  List<Component> _row(String term, String value) => <Component>[
    dt(classes: 'text-muted-foreground', [Component.text(term)]),
    dd(classes: 'truncate font-mono text-card-foreground', [
      Component.text(value),
    ]),
  ];
}

Component _loading() =>
    p(classes: 'text-sm text-muted-foreground', [Component.text('…')]);

/// A language's name in that language.
///
/// Not translated, and deliberately not: an endonym is the same string in
/// every UI language, which is the point -- someone who has accidentally set
/// the app to Korean needs to find their own language in a list they cannot
/// otherwise read. A localized list would be unreadable exactly when it
/// matters.
String languageEndonym(String tag) => switch (tag) {
  'en' => 'English',
  'cs' => 'Čeština',
  'de' => 'Deutsch',
  'es' => 'Español',
  'fr' => 'Français',
  'it' => 'Italiano',
  'ja' => '日本語',
  'ko' => '한국어',
  'nl' => 'Nederlands',
  'pl' => 'Polski',
  'ru' => 'Русский',
  'sk' => 'Slovenčina',
  'zh' => '简体中文',
  'zh-Hant' => '繁體中文',
  // A locale added to the ARB catalog without a name here still appears,
  // under its tag, rather than vanishing from the list.
  _ => tag,
};

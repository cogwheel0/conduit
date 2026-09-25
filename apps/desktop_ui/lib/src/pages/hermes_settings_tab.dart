import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/hermes_providers.dart';
import '../widgets/form_field.dart';
import 'workspace/workspace_common.dart' show actionButton, badge, statusLine;

/// Settings → Hermes Agent: the connection, what the server can do,
/// and its skills and toolsets.
class HermesSettingsTab extends StatelessComponent {
  const HermesSettingsTab({super.key});

  @override
  Component build(BuildContext context) {
    final settings = context.watch(hermesSettingsProvider);
    final value = settings.value;
    if (value == null) {
      return statusLine(
        settings.hasError ? t.app.hermesActionFailed : t.app.loadingShort,
        error: settings.hasError,
      );
    }
    return div(classes: 'space-y-6', [
      p(classes: 'text-ui-base text-foreground-subtle', [
        Component.text(t.app.hermesNativeSettingsSubtitle),
      ]),
      HermesConnectionForm(
        key: ValueKey('hermes-${value.baseUrl}'),
        saved: value,
      ),
      if (value.usable) const _HermesStatusSection(),
    ]);
  }
}

class HermesConnectionForm extends StatefulComponent {
  const HermesConnectionForm({required this.saved, super.key});

  final HermesSettings saved;

  @override
  State<HermesConnectionForm> createState() => _HermesConnectionFormState();
}

class _HermesConnectionFormState extends State<HermesConnectionForm> {
  late bool _enabled = component.saved.enabled;
  late String _url = component.saved.baseUrl;
  late String _mode = component.saved.mode;
  String _apiKey = '';
  String _memoryKey = '';
  late String _profile = component.saved.desktopProfile;
  late String _authKind = component.saved.desktopAuthKind;
  late bool _selfSigned = component.saved.allowSelfSignedCertificates;
  bool _busy = false;
  String? _status;
  bool _statusIsError = false;

  HermesSettingsEdit get _edit => HermesSettingsEdit(
    enabled: _enabled,
    baseUrl: _url.trim(),
    mode: _mode,
    // Blank keeps the saved key.
    apiKey: _apiKey.trim().isEmpty ? null : _apiKey.trim(),
    sessionKey: _memoryKey.trim().isEmpty ? null : _memoryKey.trim(),
    desktopProfile: _profile.trim().isEmpty ? 'default' : _profile.trim(),
    desktopAuthKind: _authKind,
    allowSelfSignedCertificates: _selfSigned,
  );

  void _say(String text, {bool error = false}) => setState(() {
    _status = text;
    _statusIsError = error;
  });

  Future<void> _run(Future<void> Function(HermesActions actions) action) async {
    setState(() => _busy = true);
    try {
      await action(context.read(hermesActionsProvider));
    } on RpcError {
      _say(t.app.hermesActionFailed, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Component build(BuildContext context) {
    final saved = component.saved;
    final desktop = _mode == 'desktop';
    return section(
      classes: 'space-y-4 rounded-lg border border-border p-4',
      attributes: <String, String>{
        'aria-label': t.app.hermesConnectionDetailsTitle,
      },
      [
        checkboxField(
          id: 'hermes-enabled',
          text: t.app.hermesEnableTitle,
          checked: _enabled,
          onChanged: ({required value}) => setState(() => _enabled = value),
        ),
        p(classes: '-mt-3 pl-6 text-ui-sm text-foreground-subtle', [
          Component.text(t.app.hermesEnableSubtitle),
        ]),
        textField(
          id: 'hermes-url',
          labelText: t.app.hermesServerUrlTitle,
          placeholder: 'https://hermes.example.com/v1',
          value: _url,
          onInput: (value) => setState(() => _url = value),
        ),
        div(classes: 'space-y-1.5', [
          label(
            htmlFor: 'hermes-mode',
            classes: 'block text-ui-base font-medium',
            [Component.text(t.desktop.desktopHermesMode)],
          ),
          select(
            [
              option(value: 'responses', selected: !desktop, [
                Component.text(t.app.hermesSelfHostedAgentLabel),
              ]),
              option(value: 'desktop', selected: desktop, [
                Component.text(t.app.hermesDesktopGateway),
              ]),
            ],
            id: 'hermes-mode',
            classes:
                'w-full rounded-lg border border-border bg-panel px-3 py-2 '
                'text-ui-base',
            onChange: (values) => setState(
              () => _mode = values.isEmpty ? 'responses' : values.first,
            ),
          ),
        ]),
        if (!desktop) ...[
          textField(
            id: 'hermes-api-key',
            labelText: t.app.hermesApiKeyTitle,
            type: InputType.password,
            placeholder: saved.hasApiKey
                ? t.app.hermesConfiguredReplacePlaceholder
                : t.app.hermesApiKeyPlaceholder,
            value: _apiKey,
            onInput: (value) => setState(() => _apiKey = value),
          ),
          textField(
            id: 'hermes-memory-key',
            labelText: t.app.hermesMemoryKeyTitle,
            type: InputType.password,
            placeholder: saved.hasSessionKey
                ? t.app.hermesConfiguredReplacePlaceholder
                : t.app.hermesMemoryKeyPlaceholder,
            value: _memoryKey,
            onInput: (value) => setState(() => _memoryKey = value),
          ),
          p(classes: '-mt-2 text-ui-sm text-foreground-subtle', [
            Component.text(t.app.hermesMemoryKeyShortDescription),
          ]),
        ] else ...[
          textField(
            id: 'hermes-profile',
            labelText: t.app.hermesProfileLabel,
            value: _profile,
            onInput: (value) => setState(() => _profile = value),
          ),
          div(classes: 'space-y-1.5', [
            label(
              htmlFor: 'hermes-auth',
              classes: 'block text-ui-base font-medium',
              [Component.text(t.app.hermesDesktopAuthentication)],
            ),
            select(
              [
                for (final (value, text) in <(String, String)>[
                  ('legacyToken', t.app.hermesAuthLegacy),
                  ('nativePkce', t.app.hermesAuthNative),
                  ('dashboardCookie', t.app.hermesAuthDashboard),
                ])
                  option(value: value, selected: _authKind == value, [
                    Component.text(text),
                  ]),
              ],
              id: 'hermes-auth',
              classes:
                  'w-full rounded-lg border border-border bg-panel px-3 '
                  'py-2 text-ui-base',
              onChange: (values) => setState(
                () => _authKind = values.isEmpty ? 'legacyToken' : values.first,
              ),
            ),
          ]),
        ],
        checkboxField(
          id: 'hermes-self-signed',
          text: t.app.allowSelfSignedCertificates,
          checked: _selfSigned,
          onChanged: ({required value}) => setState(() => _selfSigned = value),
        ),
        if (_status case final status?)
          statusLine(status, error: _statusIsError),
        div(classes: 'flex flex-wrap gap-2', [
          actionButton(
            t.app.directMcpTestConnection,
            id: 'hermes-test',
            disabled: _busy || _url.trim().isEmpty,
            onClick: () => unawaited(
              _run((actions) async {
                final result = await actions.test(_edit);
                _say(
                  result.ok
                      ? t.desktop.desktopHermesTestOk
                      : result.reason == 'unauthorized'
                      ? t.desktop.desktopHermesTestUnauthorized
                      : t.desktop.desktopHermesTestUnreachable,
                  error: !result.ok,
                );
              }),
            ),
          ),
          actionButton(
            t.app.save,
            primary: true,
            id: 'hermes-save',
            disabled: _busy || _url.trim().isEmpty,
            onClick: () => unawaited(
              _run((actions) async {
                final saved = await actions.save(_edit);
                _apiKey = '';
                _memoryKey = '';
                // Saved is not done while the gateway still waits for its
                // sign-in, which the button beside this starts.
                _say(
                  saved.mode == 'desktop' &&
                          saved.desktopAuthKind == 'nativePkce' &&
                          !saved.desktopSignedIn
                      ? t.desktop.desktopHermesSignInToFinish
                      : t.app.saved,
                );
              }),
            ),
          ),
          if (desktop && saved.mode == 'desktop' && _authKind == 'nativePkce')
            saved.desktopSignedIn
                ? actionButton(
                    t.app.hermesSignOut,
                    onClick: () =>
                        unawaited(_run((actions) => actions.signOut())),
                  )
                : actionButton(
                    t.app.hermesNativeSignIn,
                    onClick: () =>
                        unawaited(_run((actions) => actions.signIn())),
                  ),
        ]),
      ],
    );
  }
}

class _HermesStatusSection extends StatelessComponent {
  const _HermesStatusSection();

  @override
  Component build(BuildContext context) {
    final status = context.watch(hermesStatusProvider).value;
    final catalog = context.watch(hermesCatalogProvider).value;
    final capabilities = status?.capabilities;
    return div(classes: 'space-y-4', [
      section(
        classes: 'space-y-2 rounded-lg border border-border p-4',
        attributes: <String, String>{
          'aria-label': t.app.hermesServerStatusTitle,
        },
        [
          h3(classes: 'text-ui-base font-semibold', [
            Component.text(t.app.hermesServerStatusTitle),
          ]),
          if (status == null)
            statusLine(t.app.loadingShort)
          else ...[
            statusLine(
              status.reachable
                  ? t.desktop.desktopHermesTestOk
                  : t.desktop.desktopHermesTestUnreachable,
              error: !status.reachable,
            ),
            if (capabilities != null)
              div(classes: 'flex flex-wrap gap-1', [
                for (final (on, text) in <(bool, String)>[
                  (capabilities.runApproval, t.app.hermesCapabilityApproval),
                  (capabilities.skills, t.app.hermesCapabilitySkills),
                  (capabilities.toolsets, t.app.hermesCapabilityToolsets),
                  (capabilities.jobs, t.app.hermesCapabilityJobs),
                  (capabilities.sessions, t.app.hermesCapabilitySessions),
                ])
                  if (on) badge(text, muted: false),
              ]),
          ],
        ],
      ),
      section(
        classes: 'space-y-2 rounded-lg border border-border p-4',
        attributes: <String, String>{
          'aria-label': t.app.hermesCapabilityToolsets,
        },
        [
          h3(classes: 'text-ui-base font-semibold', [
            Component.text(t.app.hermesCapabilityToolsets),
          ]),
          if (catalog == null)
            statusLine(t.app.loadingShort)
          else if (catalog.toolsets.isEmpty)
            statusLine(t.app.hermesNoToolsets)
          else
            ul(classes: 'space-y-1', [
              for (final toolset in catalog.toolsets)
                li(classes: 'text-ui-base', [
                  span(classes: 'font-medium', [
                    Component.text(
                      toolset.label.isEmpty ? toolset.name : toolset.label,
                    ),
                  ]),
                  span(classes: 'ml-2 text-ui-sm text-foreground-subtle', [
                    Component.text(
                      t.app.hermesToolCount(count: toolset.tools.length),
                    ),
                  ]),
                  if (!toolset.enabled) badge(t.app.hermesJobPaused),
                ]),
            ]),
          if (catalog != null && catalog.skills.isNotEmpty) ...[
            h3(classes: 'pt-2 text-ui-base font-semibold', [
              Component.text(t.app.hermesCapabilitySkills),
            ]),
            ul(classes: 'space-y-1', [
              for (final skill in catalog.skills)
                li(classes: 'text-ui-base', [
                  code([Component.text('/${skill.name}')]),
                  if (skill.description case final description?)
                    span(classes: 'ml-2 text-ui-sm text-foreground-subtle', [
                      Component.text(description),
                    ]),
                ]),
            ]),
          ],
        ],
      ),
    ]);
  }
}

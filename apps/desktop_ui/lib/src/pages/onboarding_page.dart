import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../file_picker.dart';
import '../l10n/strings.g.dart';
import '../rpc/rpc_providers.dart';
import '../rpc/session_providers.dart';
import '../rpc/direct_providers.dart';
import '../rpc/hermes_providers.dart';
import '../widgets/form_field.dart';
import 'direct_connections_tab.dart';
import '../widgets/ui.dart';
import 'hermes_settings_tab.dart' show HermesConnectionForm;

/// How the app connects: the first thing a fresh install shows.
///
/// A choice first (M4), as on mobile: an Open WebUI server, or direct
/// connections to model APIs with no server at all. Hermes and Apple
/// Intelligence join the list when they are built (M7, M8) -- an entry that
/// leads nowhere is worse than no entry.
///
/// Server setup (WP-2.2):
/// Adds a server and connects to it in one gesture, because from the user's
/// side those are one act. They are two RPCs because `servers.add` must not
/// be destructive -- `servers.connect` supersedes every other configured
/// server, and a typo in the URL field should not be able to do that.
class OnboardingPage extends StatefulComponent {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

/// Where the welcome screen is.
enum _Step { choose, server, direct, hermes }

class _OnboardingPageState extends State<OnboardingPage> {
  _Step _step = _Step.choose;
  bool _advancedOpen = false;
  String _name = '';
  String _url = '';
  bool _allowSelfSigned = false;
  String _headers = '';

  // The PEM text is held here, not just the filename, because the daemon
  // needs the contents -- the renderer has no filesystem path it could hand
  // over, and the daemon has no business reading arbitrary paths anyway.
  String? _certificatePem;
  String? _certificateLabel;
  String? _privateKeyPem;
  String? _privateKeyLabel;

  bool _busy = false;
  String? _error;
  String? _headerError;

  @override
  Component build(BuildContext context) => switch (_step) {
    _Step.choose => _chooser(context),
    _Step.server => _serverForm(context),
    _Step.direct => _direct(context),
    _Step.hermes => _hermes(context),
  };

  Component _chooser(BuildContext context) => div(
    classes:
        'mx-auto flex min-h-full w-full max-w-lg flex-col justify-center '
        'gap-6 px-8 text-foreground',
    [
      header(classes: 'space-y-2', [
        h1(classes: 'text-2xl font-semibold', [
          Component.text(t.app.backendChooserWelcome),
        ]),
        p(classes: 'text-ui-base text-foreground-subtle', [
          Component.text(t.app.backendChooserPrompt),
        ]),
      ]),
      _choice(
        section: t.app.backendChooserSelfHostedSectionTitle,
        title: t.app.backendChooserOpenWebUITitle,
        subtitle: t.app.backendChooserOpenWebUISubtitle,
        onChoose: () => _choose(context, _Step.server),
      ),
      _choice(
        section: t.app.backendChooserSelfHostedSectionTitle,
        title: t.app.backendChooserHermesTitle,
        subtitle: t.app.backendChooserHermesSubtitle,
        onChoose: () => _choose(context, _Step.hermes),
      ),
      _choice(
        section: t.app.backendChooserModelApisSectionTitle,
        title: t.app.backendChooserDirectTitle,
        subtitle: t.app.backendChooserDirectSubtitle,
        onChoose: () => _choose(context, _Step.direct),
      ),
      button(
        [Component.text(t.app.skipServerSetupTryDemo)],
        classes:
            'self-start text-ui-base text-foreground-subtle underline '
            'underline-offset-4 disabled:opacity-60',
        type: ButtonType.button,
        disabled: _busy,
        onClick: () => unawaited(_enterDemo(context)),
      ),
    ],
  );

  Component _choice({
    required String section,
    required String title,
    required String subtitle,
    required void Function() onChoose,
  }) => div(classes: 'space-y-2', [
    h2(classes: 'text-ui-sm font-medium uppercase text-foreground-subtle', [
      Component.text(section),
    ]),
    button(
      [
        span(classes: 'block text-ui-base font-medium', [
          Component.text(title),
        ]),
        span(classes: 'block text-ui-sm text-foreground-subtle', [
          Component.text(subtitle),
        ]),
      ],
      classes:
          'w-full rounded-lg border border-border bg-card p-4 text-left '
          'hover:bg-hover disabled:opacity-60',
      type: ButtonType.button,
      disabled: _busy,
      onClick: onChoose,
    ),
  ]);

  /// Remembers the choice, which is what lets a window with a working
  /// direct connection skip server setup from then on.
  void _choose(BuildContext context, _Step step) {
    setState(() => _step = step);
    unawaited(
      context
          .read(directActionsProvider)
          .setPreferred(preferred: step == _Step.direct)
          .catchError((Object _) {}),
    );
  }

  Component _back(BuildContext context) => button(
    [
      icon(LucideIcon.arrowLeft, classes: 'size-4 shrink-0'),
      Component.text(t.app.backendChooserWelcome),
    ],
    classes:
        'inline-flex items-center gap-1.5 self-start text-ui-base '
        'text-foreground-subtle hover:text-foreground '
        'disabled:opacity-60',
    type: ButtonType.button,
    disabled: _busy,
    onClick: () => setState(() => _step = _Step.choose),
  );

  /// Direct connections, set up in place. Once one works the session gate
  /// takes the window to the chat on its own.
  Component _direct(BuildContext context) => div(
    classes:
        'mx-auto flex min-h-full w-full max-w-2xl flex-col justify-center '
        'gap-6 px-8 py-8 text-foreground',
    [
      _back(context),
      header(classes: 'space-y-2', [
        h1(classes: 'text-2xl font-semibold', [
          Component.text(t.app.backendChooserDirectTitle),
        ]),
      ]),
      const DirectConnectionsTab(),
    ],
  );

  /// Hermes Agent, set up in place (M7). Once it is usable the session
  /// gate takes the window to the chat, with the agent to talk to.
  Component _hermes(BuildContext context) {
    final saved = context.watch(hermesSettingsProvider).value;
    return div(
      classes:
          'mx-auto flex min-h-full w-full max-w-lg flex-col justify-center '
          'gap-6 px-8 py-8 text-foreground',
      [
        _back(context),
        header(classes: 'space-y-2', [
          h1(classes: 'text-2xl font-semibold', [
            Component.text(t.app.backendChooserHermesTitle),
          ]),
          p(classes: 'text-ui-base text-foreground-subtle', [
            Component.text(t.app.hermesNativeSettingsSubtitle),
          ]),
        ]),
        if (saved == null)
          p(classes: 'text-ui-base text-foreground-subtle', [
            Component.text(t.app.loadingShort),
          ])
        else
          HermesConnectionForm(
            saved: saved.enabled ? saved : saved.copyWith(enabled: true),
          ),
      ],
    );
  }

  Component _serverForm(BuildContext context) {
    return div(
      classes:
          'mx-auto flex min-h-full w-full max-w-lg flex-col justify-center '
          'gap-6 px-8 text-foreground',
      [
        _back(context),
        header(classes: 'space-y-2', [
          h1(classes: 'text-2xl font-semibold', [
            Component.text(t.app.connectToServer),
          ]),
          p(classes: 'text-ui-base text-foreground-subtle', [
            Component.text(t.app.signInServerDescription),
          ]),
        ]),
        form(
          [
            textField(
              id: 'server-url',
              labelText: t.app.serverUrl,
              placeholder: t.app.serverUrlHint,
              value: _url,
              // `url` rather than `text` so the shell offers the right
              // keyboard and autofill. Validation stays ours: a browser is
              // happy with `file:` here and the daemon must not be.
              type: InputType.url,
              autofocus: true,
              disabled: _busy,
              onInput: (value) => setState(() => _url = value),
            ),
            textField(
              id: 'server-name',
              labelText: t.app.serverNameLabel,
              placeholder: 'Home',
              value: _name,
              disabled: _busy,
              onInput: (value) => setState(() => _name = value),
            ),
            _advanced(),
            if (_error case final message?) formError(message),
            submitButton(
              labelText: t.app.connectToServerButton,
              busyLabel: t.app.connecting,
              busy: _busy,
              enabled: _url.trim().isNotEmpty,
            ),
          ],
          classes: 'space-y-4',
          events: <String, EventCallback>{
            'submit': (event) {
              // Without this the browser navigates away and the SPA unloads.
              event.preventDefault();
              unawaited(_submit(context));
            },
          },
        ),
        button(
          [Component.text(t.app.skipServerSetupTryDemo)],
          classes:
              'text-ui-base text-foreground-subtle underline underline-offset-4 '
              'disabled:opacity-60',
          type: ButtonType.button,
          disabled: _busy,
          onClick: () => unawaited(_enterDemo(context)),
        ),
      ],
    );
  }

  /// Collapsed by default. Self-signed certificates and custom headers are
  /// for the minority who need them, and putting them in front of everyone
  /// else turns a two-field form into a configuration chore.
  ///
  /// A toggle this component owns rather than a native `<details>`: the
  /// rebuild that checking a box in it causes closed the section again.
  Component _advanced() => div([
    button(
      [
        icon(
          _advancedOpen ? LucideIcon.chevronDown : LucideIcon.chevronRight,
          classes: 'size-4 shrink-0 text-foreground-subtle',
        ),
        Component.text(t.app.advancedSettings),
      ],
      classes: 'inline-flex items-center gap-1 text-ui-base font-medium',
      type: ButtonType.button,
      attributes: <String, String>{'aria-expanded': '$_advancedOpen'},
      onClick: () => setState(() => _advancedOpen = !_advancedOpen),
    ),
    if (_advancedOpen)
      div(classes: 'mt-4 space-y-4', [
        checkboxField(
          id: 'allow-self-signed',
          text: t.app.allowSelfSignedCertificates,
          checked: _allowSelfSigned,
          disabled: _busy,
          onChanged: ({required value}) =>
              setState(() => _allowSelfSigned = value),
        ),
        _pemPicker(
          context,
          id: 'mtls-certificate',
          labelText: t.app.mutualTlsSelectCertificate,
          accept: '.pem,.crt,.cer',
          marker: 'CERTIFICATE',
          invalidMessage: t.app.mutualTlsCertificatePemRequired,
          label: _certificateLabel,
          onPicked: (file) => setState(() {
            _certificatePem = file.content;
            _certificateLabel = file.name;
          }),
          onCleared: () => setState(() {
            _certificatePem = null;
            _certificateLabel = null;
          }),
        ),
        _pemPicker(
          context,
          id: 'mtls-private-key',
          labelText: t.app.mutualTlsSelectPrivateKey,
          accept: '.pem,.key',
          marker: 'PRIVATE KEY',
          invalidMessage: t.app.mutualTlsPrivateKeyPemRequired,
          label: _privateKeyLabel,
          onPicked: (file) => setState(() {
            _privateKeyPem = file.content;
            _privateKeyLabel = file.name;
          }),
          onCleared: () => setState(() {
            _privateKeyPem = null;
            _privateKeyLabel = null;
          }),
        ),
        textAreaField(
          monospace: true,
          id: 'custom-headers',
          labelText: t.app.customHeaders,
          // One `Name: value` per line. A JSON box would be stricter, but
          // this is the shape people paste out of a proxy's documentation.
          placeholder: 'X-Proxy-Token: abc123',
          value: _headers,
          disabled: _busy,
          error: _headerError,
          onInput: (value) => setState(() {
            _headers = value;
            _headerError = null;
          }),
        ),
      ]),
  ], classes: 'rounded-lg border border-border p-4');

  /// A button plus the chosen filename, not an `<input type="file">` in the
  /// form.
  ///
  /// The element the port creates is detached and clicked programmatically,
  /// so there is no hidden input in the tree collecting focus. What the user
  /// sees is the filename they picked, which is also all the daemon ever
  /// reports back -- the PEM itself never returns across the wire.
  Component _pemPicker(
    BuildContext context, {
    required String id,
    required String labelText,
    required String accept,
    required String marker,
    required String invalidMessage,
    required String? label,
    required void Function(PickedTextFile file) onPicked,
    required void Function() onCleared,
  }) => div(classes: 'space-y-1.5', [
    span(
      id: '$id-label',
      classes: 'block text-ui-base font-medium text-foreground',
      [Component.text(labelText)],
    ),
    div(classes: 'flex items-center gap-2', [
      button(
        [
          Component.text(
            label == null
                ? t.desktop.desktopChooseFile
                : t.desktop.desktopReplaceFile,
          ),
        ],
        id: id,
        classes:
            'rounded-lg border border-border px-3 py-1.5 text-ui-base '
            'text-foreground hover:bg-hover disabled:opacity-60',
        type: ButtonType.button,
        disabled: _busy,
        // Both, so the button announces which field it belongs to. "Choose
        // file" twice on one form is otherwise indistinguishable.
        attributes: <String, String>{'aria-labelledby': '$id-label $id'},
        onClick: () =>
            unawaited(_pick(context, accept, marker, invalidMessage, onPicked)),
      ),
      if (label != null) ...<Component>[
        span(classes: 'truncate font-mono text-xs text-foreground-subtle', [
          Component.text(label),
        ]),
        button(
          [Component.text(t.app.clear)],
          classes: 'text-ui-sm text-foreground-subtle underline',
          type: ButtonType.button,
          disabled: _busy,
          onClick: onCleared,
        ),
      ],
    ]),
  ]);

  Future<void> _pick(
    BuildContext context,
    String accept,
    String marker,
    String invalidMessage,
    void Function(PickedTextFile file) onPicked,
  ) async {
    try {
      final file = await context
          .read(filePickerProvider)
          .pickText(accept: accept);
      if (file == null || !mounted) return;
      // The accept list is a filter, not a guarantee -- every picker lets a
      // determined user choose anything. Saying "that is not a certificate"
      // here beats a TLS handshake failing minutes later with a message
      // about the server.
      if (!containsPemBlock(file.content, marker)) {
        setState(() => _error = invalidMessage);
        return;
      }
      setState(() => _error = null);
      onPicked(file);
    } on UnsupportedError {
      if (!mounted) return;
      setState(() => _error = t.app.proxyAuthPlatformNotSupported);
    }
  }

  Future<void> _submit(BuildContext context) async {
    if (_busy) return;
    final Map<String, String> headers;
    try {
      headers = parseCustomHeaders(_headers);
    } on FormatException catch (error) {
      // On the field, not the form: the user needs to know which line.
      setState(() => _headerError = error.message);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final actions = context.read(sessionActionsProvider);
    try {
      final added = await actions.addServer(
        ServerDraft(
          // The URL is the only thing a user must type; defaulting the name
          // to the host beats making them invent one.
          name: _name.trim().isEmpty ? _defaultName(_url) : _name.trim(),
          url: _url.trim(),
          allowSelfSignedCertificates: _allowSelfSigned,
          customHeaders: headers,
          mtlsCertificateChainPem: _certificatePem,
          mtlsCertificateLabel: _certificateLabel,
          mtlsPrivateKeyPem: _privateKeyPem,
          mtlsPrivateKeyLabel: _privateKeyLabel,
        ),
      );
      await actions.connectToServer(added.id);
      if (mounted) Router.of(context).replace('/sign-in');
    } on RpcError catch (error) {
      setState(() {
        _busy = false;
        _error = _describe(error);
      });
    }
  }

  Future<void> _enterDemo(BuildContext context) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read(sessionActionsProvider).setReviewerMode(enabled: true);
      if (mounted) Router.of(context).replace('/');
    } on RpcError catch (error) {
      setState(() {
        _busy = false;
        _error = _describe(error);
      });
    }
  }

  /// Codes, not server prose: the daemon has no locale (WP-1.6).
  String _describe(RpcError error) => switch (error.code) {
    ConduitErrorCodes.invalidParams => t.app.serverNotOpenWebUI,
    ConduitErrorCodes.connectionFailed => t.app.weCouldntReachServer,
    ConduitErrorCodes.timeout => t.app.connectionTimedOut,
    ConduitErrorCodes.tlsUntrusted => t.app.serverNotOpenWebUI,
    _ => t.app.couldNotConnectGeneric,
  };

  static String _defaultName(String url) {
    final host = Uri.tryParse(url.trim())?.host;
    return host == null || host.isEmpty ? 'Open WebUI' : host;
  }
}

/// Parses the "one `Name: value` per line" custom-header box.
///
/// Throws [FormatException] with a message naming the offending line, rather
/// than dropping it: a header the user believed they had set, silently
/// missing, is a support ticket that looks like a server bug.
Map<String, String> parseCustomHeaders(String raw) {
  final headers = <String, String>{};
  var lineNumber = 0;
  for (final line in raw.split('\n')) {
    lineNumber++;
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final separator = trimmed.indexOf(':');
    if (separator <= 0) {
      throw FormatException('Line $lineNumber is not "Name: value".');
    }
    final name = trimmed.substring(0, separator).trim();
    final value = trimmed.substring(separator + 1).trim();
    if (name.isEmpty) {
      throw FormatException('Line $lineNumber has no header name.');
    }
    // A header name with a space or a colon in it cannot be sent, and the
    // failure would happen far from here.
    if (name.contains(RegExp(r'[\s:]'))) {
      throw FormatException('Line $lineNumber has an invalid header name.');
    }
    headers[name] = value;
  }
  return headers;
}

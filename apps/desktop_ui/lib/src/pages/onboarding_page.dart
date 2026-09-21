import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../l10n/strings.g.dart';
import '../rpc/session_providers.dart';
import '../widgets/form_field.dart';

/// Server setup: the first thing a fresh install shows (WP-2.2).
///
/// Adds a server and connects to it in one gesture, because from the user's
/// side those are one act. They are two RPCs because `servers.add` must not
/// be destructive -- `servers.connect` supersedes every other configured
/// server, and a typo in the URL field should not be able to do that.
class OnboardingPage extends StatefulComponent {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  String _name = '';
  String _url = '';
  bool _allowSelfSigned = false;
  String _headers = '';

  bool _busy = false;
  String? _error;
  String? _headerError;

  @override
  Component build(BuildContext context) {
    return div(
      classes:
          'mx-auto flex min-h-screen w-full max-w-lg flex-col justify-center '
          'gap-6 px-8 text-foreground',
      [
        header(classes: 'space-y-2', [
          h1(classes: 'text-2xl font-semibold', [
            Component.text(t.app.connectToServer),
          ]),
          p(classes: 'text-sm text-muted-foreground', [
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
              labelText: t.app.openWebUIServer,
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
              'text-sm text-muted-foreground underline underline-offset-4 '
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
  Component _advanced() => details([
    summary(classes: 'cursor-pointer text-sm font-medium', [
      Component.text(t.app.settingsCategoryServer),
    ]),
    div(classes: 'mt-4 space-y-4', [
      checkboxField(
        id: 'allow-self-signed',
        text: t.app.allowSelfSignedCertificates,
        checked: _allowSelfSigned,
        disabled: _busy,
        onChanged: ({required value}) =>
            setState(() => _allowSelfSigned = value),
      ),
      textAreaField(
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
  ], classes: 'rounded-[--radius] border border-border p-4');

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

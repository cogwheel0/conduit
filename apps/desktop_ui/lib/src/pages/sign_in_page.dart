import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../l10n/strings.g.dart';
import '../rpc/session_providers.dart';
import '../widgets/form_field.dart';

/// How to prove who you are to the configured server.
///
/// Which of these a server actually offers comes from its backend config;
/// until `capabilities.*` carries that, all three are shown and the
/// server rejects what it does not support. That is worse than hiding them
/// and better than guessing wrong and hiding the only one that works.
enum SignInMethod { password, ldap, apiKey }

/// Credentials against the connected server.
class SignInPage extends StatefulComponent {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  SignInMethod _method = SignInMethod.password;
  String _username = '';
  String _password = '';
  String _apiKey = '';

  bool _busy = false;
  String? _error;

  bool get _canSubmit => switch (_method) {
    SignInMethod.password ||
    SignInMethod.ldap => _username.trim().isNotEmpty && _password.isNotEmpty,
    SignInMethod.apiKey => _apiKey.trim().isNotEmpty,
  };

  @override
  Component build(BuildContext context) {
    final servers = context.watch(serverListProvider);
    final serverUrl = servers.value?.servers
        .where((server) => server.isActive)
        .map((server) => server.url)
        .firstOrNull;

    return div(
      classes:
          'mx-auto flex min-h-full w-full max-w-lg flex-col justify-center '
          'gap-6 px-8 text-foreground',
      [
        header(classes: 'space-y-2', [
          h1(classes: 'text-2xl font-semibold', [Component.text(t.app.signIn)]),
          p(classes: 'text-ui-base text-foreground-subtle', [
            Component.text(t.app.enterCredentials),
          ]),
          if (serverUrl != null)
            p(classes: 'truncate font-mono text-xs text-foreground-subtle', [
              Component.text(serverUrl),
            ]),
        ]),
        _methodTabs(),
        form(
          [
            ..._fields(),
            if (_error case final message?) formError(message),
            submitButton(
              labelText: t.app.signIn,
              busyLabel: t.app.signingIn,
              busy: _busy,
              enabled: _canSubmit,
            ),
          ],
          classes: 'space-y-4',
          events: <String, EventCallback>{
            'submit': (event) {
              event.preventDefault();
              unawaited(_submit(context));
            },
          },
        ),
        _ssoButton(context, serverUrl),
        button(
          [Component.text(t.app.backToServerSetup)],
          classes:
              'text-ui-base text-foreground-subtle underline underline-offset-4 '
              'disabled:opacity-60',
          type: ButtonType.button,
          disabled: _busy,
          onClick: () => Router.of(context).replace('/onboarding'),
        ),
      ],
    );
  }

  /// Opens the server's own sign-in page in a real browser window.
  ///
  /// One button for SSO, OAuth and every reverse proxy, because from here
  /// they are the same act: go to the server in a browser, come back with
  /// whatever that left. Which of them actually happens is the server's and
  /// the proxy's business, and the daemon works out what was achieved.
  Component _ssoButton(BuildContext context, String? serverUrl) => button(
    [Component.text(t.app.signInWithSso)],
    classes:
        'w-full rounded-lg border border-border px-4 py-2 '
        'text-foreground disabled:opacity-60',
    type: ButtonType.button,
    disabled: _busy || serverUrl == null,
    onClick: serverUrl == null
        ? null
        : () => unawaited(_signInExternally(context, serverUrl)),
  );

  Future<void> _signInExternally(BuildContext context, String serverUrl) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = await context
          .read(sessionActionsProvider)
          .signInExternally(serverUrl: serverUrl);
      if (!mounted) return;
      // Null is a closed window. Not a failure, and not worth an error
      // message -- the user closed it on purpose.
      if (snapshot == null) {
        setState(() => _busy = false);
        return;
      }
      if (snapshot.isAuthenticated) {
        Router.of(context).replace('/');
        return;
      }
      // The proxy let us through and Open WebUI still wants credentials, so
      // the form below is the next step rather than an error.
      setState(() {
        _busy = false;
        _error = snapshot.errorCode == null
            ? null
            : _describeCode(snapshot.errorCode);
      });
    } on RpcError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describeCode(error.code);
      });
    } on UnsupportedError {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.app.proxyAuthPlatformNotSupported;
      });
    }
  }

  /// A radio group, not a row of buttons.
  ///
  /// These are three mutually exclusive answers to one question, which is
  /// what a radio group *is* -- so arrow keys move between them and a screen
  /// reader announces "1 of 3" without any ARIA of our own.
  Component _methodTabs() => fieldset([
    // Not `t.app.credentials`, which is the string "Password" -- the same
    // word as the first radio below. A group and its first option sharing
    // a name is exactly what makes a radio group unusable by ear.
    legend(classes: 'sr-only', [Component.text(t.desktop.desktopSignInMethod)]),
    div(classes: 'flex gap-4', [
      for (final method in SignInMethod.values)
        div(classes: 'flex items-center gap-1.5', [
          input<bool>(
            id: 'method-${method.name}',
            type: InputType.radio,
            name: 'sign-in-method',
            checked: _method == method,
            disabled: _busy,
            onChange: (_) => setState(() {
              _method = method;
              _error = null;
            }),
          ),
          label(
            [Component.text(_methodLabel(method))],
            htmlFor: 'method-${method.name}',
            classes: 'text-ui-base',
          ),
        ]),
    ]),
  ], classes: 'border-0 p-0');

  String _methodLabel(SignInMethod method) => switch (method) {
    SignInMethod.password => t.app.password,
    SignInMethod.ldap => t.app.ldap,
    SignInMethod.apiKey => t.app.apiKey,
  };

  List<Component> _fields() => switch (_method) {
    SignInMethod.password || SignInMethod.ldap => <Component>[
      textField(
        id: 'username',
        labelText: t.app.usernameOrEmail,
        value: _username,
        // `username` type so a password manager recognises the pair and
        // offers to fill both.
        autofocus: true,
        disabled: _busy,
        onInput: (value) => setState(() => _username = value),
      ),
      textField(
        id: 'password',
        labelText: t.app.password,
        value: _password,
        type: InputType.password,
        disabled: _busy,
        onInput: (value) => setState(() => _password = value),
      ),
    ],
    SignInMethod.apiKey => <Component>[
      textField(
        id: 'api-key',
        labelText: t.app.apiKey,
        value: _apiKey,
        // `password`, not `text`: an API key is a bearer credential and
        // should not sit in plain view on a shared screen.
        type: InputType.password,
        autofocus: true,
        disabled: _busy,
        onInput: (value) => setState(() => _apiKey = value),
      ),
    ],
  };

  Future<void> _submit(BuildContext context) async {
    if (_busy || !_canSubmit) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final actions = context.read(sessionActionsProvider);
    try {
      final snapshot = await switch (_method) {
        SignInMethod.password => actions.signInWithPassword(
          PasswordLogin(username: _username.trim(), password: _password),
        ),
        SignInMethod.ldap => actions.signInWithLdap(
          PasswordLogin(username: _username.trim(), password: _password),
        ),
        SignInMethod.apiKey => actions.signInWithApiKey(
          ApiKeyLogin(apiKey: _apiKey.trim()),
        ),
      };

      if (!mounted) return;
      if (snapshot.isAuthenticated) {
        Router.of(context).replace('/');
        return;
      }
      // A rejected sign-in is a successful RPC returning an unauthenticated
      // snapshot, not a thrown error -- so this branch is the common failure,
      // not an edge case.
      setState(() {
        _busy = false;
        _error = _describeCode(snapshot.errorCode);
      });
    } on RpcError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describeCode(error.code);
      });
    }
  }

  String _describeCode(String? code) => switch (code) {
    ConduitErrorCodes.invalidCredentials => t.app.invalidCredentials,
    ConduitErrorCodes.sessionExpired => t.app.authSessionExpired,
    ConduitErrorCodes.offline ||
    ConduitErrorCodes.connectionFailed => t.app.weCouldntReachServer,
    ConduitErrorCodes.timeout => t.app.connectionTimedOut,
    _ => t.app.loginFailed,
  };
}

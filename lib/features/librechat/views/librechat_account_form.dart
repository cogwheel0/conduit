import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/services.dart' show TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../auth/widgets/auth_grouped_form.dart';
import '../controllers/librechat_sign_in_controller.dart';
import 'librechat_sso_page.dart';

/// Places the form's [body] and its step's primary [action] -- a page pins
/// the action under its content, as the Open WebUI pages do, and titles
/// itself for the [step]. [action] is null for a step without one, such as
/// a server that only offers single sign-on.
typedef LibreChatFormLayout =
    Widget Function(
      BuildContext context,
      Widget body,
      Widget? action,
      LibreChatSignInStep step,
    );

/// One step of the form: what goes above its primary action, the action,
/// and what follows it -- the other ways on, such as single sign-on.
typedef _Step = ({List<Widget> body, Widget? action, List<Widget> after});

/// Adds a LibreChat account: the server's address, then a password (local
/// or LDAP, with two-step verification) or one of its single sign-on
/// providers. Calls [onSignedIn] with the saved account.
///
/// Embedded in the account sheet's LibreChat tab and in the full-screen
/// LibreChat sign-in page. On iOS each step is the inset-grouped form the
/// Open WebUI server and sign-in steps use: the address as a labelled row
/// with a footer, then the server as a row with Change over the grouped
/// fields; errors take the footer's place. Elsewhere it keeps its Material
/// fields.
class LibreChatAccountForm extends ConsumerStatefulWidget {
  const LibreChatAccountForm({
    super.key,
    required this.onSignedIn,
    this.initialServer,
    this.notice,
    this.layout,
    this.autofocus = false,
  });

  /// Called once the account is saved, to put it in use.
  final Future<void> Function(LibreChatAccount account) onSignedIn;

  /// A server to start at, skipping the address: signing in again to an
  /// account whose session ended.
  final String? initialServer;

  /// A note about the server, such as why it asks to sign in again: the
  /// footer of the server's group on iOS, above the form elsewhere.
  final String? notice;

  /// Where the step's primary action goes. Without one it follows the
  /// fields, as in the account sheet.
  final LibreChatFormLayout? layout;

  /// Whether the address field takes the keyboard as the form opens. Not in
  /// the account sheet, where a hidden tab's field would take it.
  final bool autofocus;

  @override
  ConsumerState<LibreChatAccountForm> createState() =>
      _LibreChatAccountFormState();
}

class _LibreChatAccountFormState extends ConsumerState<LibreChatAccountForm> {
  /// The address placeholder on iOS, written as the Open WebUI one is.
  static const _addressPlaceholder = 'https://chat.example.com';

  /// Space between grouped sections, and above an action under them.
  static const _groupGap = Spacing.lg + Spacing.xs;

  late final LibreChatSignInController _controller = LibreChatSignInController(
    // Saved without being put in use: [LibreChatAccountForm.onSignedIn]
    // switches to it, asking first when that would stop a reply, and only
    // while the form is still open.
    saveSignedIn: ({required server, required session, info}) => ref
        .read(libreChatAccountsProvider)
        .saveSignedIn(
          server: server,
          session: session,
          info: info,
          activate: false,
        ),
    adapter: ref.read(libreChatHttpAdapterProvider),
  );

  final _serverFocus = FocusNode();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _codeFocus = FocusNode();

  /// The step last built, to hand the keyboard to a new step's first field.
  late LibreChatSignInStep _shownStep = _controller.step;

  /// Whether the saved account is being put in use.
  bool _finishing = false;

  bool _obscurePassword = true;

  /// Whether single sign-on was the last way tried, so its group, not the
  /// password's, says why it failed.
  bool _singleSignOnTried = false;

  List<TextEditingController> get _fields => [
    _controller.address,
    _controller.email,
    _controller.password,
    _controller.code,
  ];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    // The step's action waits for what it needs to be typed.
    for (final field in _fields) {
      field.addListener(_typed);
    }
    final initial = widget.initialServer;
    if (initial != null) unawaited(_controller.startAt(initial));
  }

  void _typed() {
    if (mounted) setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    final step = _controller.step;
    if (step != _shownStep) {
      _shownStep = step;
      _obscurePassword = true;
      // The step that just opened takes the keyboard at its first field, as
      // the Open WebUI sign-in does.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusStep();
      });
    }
    setState(() {});
  }

  void _focusStep() {
    final node = switch (_controller.step) {
      LibreChatSignInStep.server => _serverFocus,
      LibreChatSignInStep.methods =>
        _controller.info?.passwordSignInEnabled ?? false ? _emailFocus : null,
      LibreChatSignInStep.twoFactor => _codeFocus,
    };
    node?.requestFocus();
  }

  @override
  void dispose() {
    for (final field in _fields) {
      field.removeListener(_typed);
    }
    _controller.removeListener(_changed);
    _controller.dispose();
    _serverFocus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  Future<void> _finish(LibreChatAccount? account) async {
    if (account == null || !mounted) return;
    setState(() => _finishing = true);
    try {
      await widget.onSignedIn(account);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'librechat-use-account-failed',
        scope: 'librechat/sign-in',
        error: error,
        stackTrace: stackTrace,
      );
      // Saved, but not in use: the form says so, and signing in again
      // tries once more.
      if (mounted) _controller.reportFailed();
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  /// Whether the password step has what signing in needs.
  bool get _canSignIn =>
      _controller.email.text.trim().isNotEmpty &&
      _controller.password.text.isNotEmpty;

  Future<void> _signIn() async {
    _singleSignOnTried = false;
    await _finish(await _controller.signIn());
  }

  Future<void> _verify() async => _finish(await _controller.verifyCode());

  /// Back to the address, from the ways to sign in or from two-step
  /// verification.
  void _changeServer() {
    while (_controller.step != LibreChatSignInStep.server) {
      _controller.back();
    }
  }

  Future<void> _singleSignOn(LibreChatSsoProvider provider) async {
    _singleSignOnTried = true;
    if (!provider.supportedInApp) {
      _controller.reportGoogleUnsupported();
      return;
    }
    final server = _controller.server;
    final info = _controller.info;
    if (server == null || info == null) return;
    final cookies = await LibreChatSsoPage.open(
      context,
      server: server,
      info: info,
      provider: provider,
    );
    if (!mounted) return;
    if (cookies == null) {
      _controller.reportSingleSignOnUnfinished();
      return;
    }
    await _finish(await _controller.completeSingleSignOn(cookies));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final busy = _controller.busy || _finishing;
    final cupertino = context.usesCupertinoChrome;
    final _Step step = cupertino
        ? switch (_controller.step) {
            LibreChatSignInStep.server => _cupertinoServerStep(l10n, busy),
            LibreChatSignInStep.methods => _cupertinoMethodsStep(l10n, busy),
            LibreChatSignInStep.twoFactor => _cupertinoTwoFactorStep(
              l10n,
              busy,
            ),
          }
        : switch (_controller.step) {
            LibreChatSignInStep.server => _serverStep(l10n, busy),
            LibreChatSignInStep.methods => _methodsStep(l10n, busy),
            LibreChatSignInStep.twoFactor => _twoFactorStep(l10n, busy),
          };
    // On iOS errors are footers of the groups they belong to.
    final issue = cupertino ? null : _issueText(l10n);
    final issueText = issue == null
        ? const <Widget>[]
        : [
            const SizedBox(height: Spacing.md),
            Text(
              issue,
              key: const Key('librechat-form-issue'),
              textAlign: TextAlign.center,
              style: AppTypography.bodySmallStyle.copyWith(
                color: context.conduitTheme.error,
              ),
            ),
          ];
    final action = step.action;
    final layout = widget.layout;
    if (layout != null) {
      return layout(
        context,
        _column([...step.body, ...step.after, ...issueText]),
        action,
        _controller.step,
      );
    }
    return _column([
      ...step.body,
      if (action != null) ...[
        SizedBox(height: cupertino ? _groupGap : Spacing.lg),
        action,
      ],
      ...step.after,
      ...issueText,
    ]);
  }

  Widget _column(List<Widget> children) => Column(
    key: const Key('librechat-account-form'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );

  // iOS: inset-grouped steps.

  _Step _cupertinoServerStep(AppLocalizations l10n, bool busy) => (
    body: [
      AuthGroupedSection(
        key: const Key('librechat-server-section'),
        footer: widget.notice ?? l10n.serverAddressFooter,
        error: busy ? null : _issueText(l10n),
        children: [
          AuthGroupedTextField(
            key: const Key('librechat-server-field'),
            controller: _controller.address,
            focusNode: _serverFocus,
            label: l10n.authFieldServer,
            placeholder: _addressPlaceholder,
            semanticLabel: l10n.libreChatAddAccountMessage,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            autofocus: widget.autofocus && widget.initialServer == null,
            readOnly: busy,
            autofillHints: const [AutofillHints.url],
            onSubmitted: (_) => _controller.probe(),
          ),
        ],
      ),
    ],
    action: AuthPrimaryButton(
      key: const Key('librechat-continue'),
      label: l10n.connectToServerButton,
      busyLabel: l10n.connecting,
      busy: busy,
      onPressed: _controller.address.text.trim().isEmpty
          ? null
          : _controller.probe,
    ),
    after: const <Widget>[],
  );

  _Step _cupertinoMethodsStep(AppLocalizations l10n, bool busy) {
    final info = _controller.info!;
    final password = info.passwordSignInEnabled;
    final issue = busy ? null : _issueText(l10n);
    // Without a password group, single sign-on's group says everything.
    final singleSignOnIssue = !password || _singleSignOnTried;
    final username = info.ldapUsesUsername;
    return (
      body: [
        _cupertinoServerRow(l10n, busy),
        if (password) ...[
          const SizedBox(height: _groupGap),
          AuthGroupedSection(
            key: const Key('librechat-password-section'),
            footer: info.ldapEnabled ? l10n.ldapDescription : null,
            error: singleSignOnIssue ? null : issue,
            children: [
              AuthGroupedTextField(
                key: const Key('librechat-email-field'),
                controller: _controller.email,
                focusNode: _emailFocus,
                label: username ? l10n.ldapUsername : l10n.authFieldEmail,
                placeholder: username
                    ? l10n.authFieldRequired
                    : l10n.authEmailPlaceholder,
                semanticLabel: username ? l10n.ldapUsername : l10n.emailLabel,
                keyboardType: username
                    ? TextInputType.text
                    : TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                readOnly: busy,
                autofillHints: [
                  username ? AutofillHints.username : AutofillHints.email,
                ],
                onSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
              AuthGroupedTextField(
                key: const Key('librechat-password-field'),
                controller: _controller.password,
                focusNode: _passwordFocus,
                label: l10n.password,
                placeholder: l10n.authFieldRequired,
                semanticLabel: l10n.password,
                obscureText: _obscurePassword,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.go,
                readOnly: busy,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) {
                  if (_canSignIn) unawaited(_signIn());
                },
                trailing: AuthPasswordVisibilityButton(
                  key: const Key('librechat-password-visibility'),
                  obscured: _obscurePassword,
                  label: _obscurePassword
                      ? l10n.showPassword
                      : l10n.hidePassword,
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ],
          ),
        ],
      ],
      // On the page the step's title says Sign In; the button goes on
      // rather than repeat it, as the Open WebUI sign-in's does.
      action: password
          ? AuthPrimaryButton(
              key: const Key('librechat-sign-in'),
              label: l10n.continueButton,
              busyLabel: l10n.signingIn,
              busy: busy,
              onPressed: _canSignIn ? _signIn : null,
            )
          : null,
      after: [
        if (info.ssoProviders.isNotEmpty || !password) ...[
          const SizedBox(height: _groupGap),
          AuthGroupedSection(
            key: const Key('librechat-sso-section'),
            footer: password ? null : l10n.libreChatPasswordSignInOff,
            error: singleSignOnIssue ? issue : null,
            children: [
              for (final provider in info.ssoProviders)
                AuthGroupedRow(
                  key: Key('librechat-sso-${provider.kind.name}'),
                  title:
                      provider.label ??
                      l10n.continueWithProvider(_name(provider)),
                  showChevron: true,
                  onTap: busy ? null : () => _singleSignOn(provider),
                ),
            ],
          ),
        ],
      ],
    );
  }

  _Step _cupertinoTwoFactorStep(AppLocalizations l10n, bool busy) {
    final backup = _controller.useBackupCode;
    final label = backup
        ? l10n.twoStepRecoveryCodeLabel
        : l10n.twoStepCodeLabel;
    return (
      body: [
        _cupertinoServerRow(l10n, busy),
        const SizedBox(height: _groupGap),
        AuthGroupedSection(
          key: const Key('librechat-code-section'),
          header: l10n.twoStepVerifyTitle,
          footer: backup
              ? l10n.twoStepRecoveryCodeDescription
              : l10n.twoStepVerifyDescription,
          error: busy ? null : _issueText(l10n),
          children: [
            // The group's header and footer say what the code is; the
            // placeholder names it until it is typed, as a lone code field
            // does in iOS.
            AuthGroupedTextField(
              key: const Key('librechat-code-field'),
              controller: _controller.code,
              focusNode: _codeFocus,
              placeholder: label,
              semanticLabel: label,
              keyboardType: backup ? TextInputType.text : TextInputType.number,
              textInputAction: TextInputAction.go,
              readOnly: busy,
              autofillHints: backup ? null : const [AutofillHints.oneTimeCode],
              onSubmitted: (_) => _verify(),
            ),
          ],
        ),
      ],
      action: AuthPrimaryButton(
        key: const Key('librechat-verify'),
        label: l10n.continueButton,
        busyLabel: l10n.signingIn,
        busy: busy,
        onPressed: _controller.code.text.trim().isEmpty ? null : _verify,
      ),
      after: [
        const SizedBox(height: Spacing.sm),
        AdaptiveButton(
          key: const Key('librechat-toggle-backup'),
          label: backup
              ? l10n.twoStepUseAuthenticatorCode
              : l10n.twoStepUseRecoveryCode,
          style: AdaptiveButtonStyle.plain,
          useNative: false,
          onPressed: busy ? null : _controller.toggleBackupCode,
        ),
        AdaptiveButton(
          key: const Key('librechat-two-step-back'),
          label: l10n.twoStepBackToSignIn,
          style: AdaptiveButtonStyle.plain,
          useNative: false,
          onPressed: busy ? null : _controller.back,
        ),
      ],
    );
  }

  /// The server as the Open WebUI sign-in shows it: a grouped row with the
  /// LibreChat glyph, the address over the server's name, and Change.
  Widget _cupertinoServerRow(AppLocalizations l10n, bool busy) {
    final server = _controller.server!;
    final info = _controller.info!;
    final address = server.baseUrl
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'/+$'), '');
    return AuthGroupedSection(
      key: const Key('librechat-server-row-section'),
      footer: widget.notice,
      children: [
        AuthGroupedRow(
          key: const Key('librechat-server-row'),
          leading: const AuthIconTile(
            icon: CupertinoIcons.chat_bubble_2,
            size: 30,
          ),
          title: address,
          subtitle: info.appTitle,
          semanticLabel: '${info.appTitle}. ${server.baseUrl}',
          verticalPadding: Spacing.sm,
          trailing: AuthRowTextButton(
            key: const Key('librechat-change-server'),
            label: l10n.signInChangeServer,
            onPressed: busy ? null : _changeServer,
          ),
        ),
      ],
    );
  }

  // Elsewhere: Material fields.

  List<Widget> _notice() {
    final notice = widget.notice;
    if (notice == null) return const <Widget>[];
    return [
      Text(
        notice,
        key: const Key('librechat-session-ended'),
        textAlign: TextAlign.center,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: context.conduitTheme.textPrimary,
        ),
      ),
      const SizedBox(height: Spacing.lg),
    ];
  }

  _Step _serverStep(AppLocalizations l10n, bool busy) => (
    body: [
      ..._notice(),
      _intro(l10n.libreChatAddAccountMessage),
      const SizedBox(height: Spacing.lg),
      _materialFields([
        AccessibleFormField(
          key: const Key('librechat-server-field'),
          enabled: !busy,
          label: l10n.serverUrl,
          hint: 'chat.example.com',
          controller: _controller.address,
          focusNode: _serverFocus,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          autofocus: widget.autofocus && widget.initialServer == null,
          onSubmitted: (_) => _controller.probe(),
          isRequired: true,
        ),
      ]),
    ],
    action: ConduitButton(
      key: const Key('librechat-continue'),
      text: l10n.continueButton,
      isLoading: busy,
      isFullWidth: true,
      onPressed: busy || _controller.address.text.trim().isEmpty
          ? null
          : _controller.probe,
    ),
    after: const <Widget>[],
  );

  _Step _methodsStep(AppLocalizations l10n, bool busy) {
    final info = _controller.info!;
    final server = _controller.server!;
    final host = Uri.parse(server.baseUrl).host;
    return (
      body: [
        ..._notice(),
        _intro(
          info.appTitle == 'LibreChat' ? host : '${info.appTitle} · $host',
        ),
        const SizedBox(height: Spacing.lg),
        if (info.passwordSignInEnabled)
          _materialFields([
            AccessibleFormField(
              key: const Key('librechat-email-field'),
              enabled: !busy,
              label: info.ldapUsesUsername
                  ? l10n.ldapUsername
                  : l10n.emailLabel,
              controller: _controller.email,
              focusNode: _emailFocus,
              keyboardType: info.ldapUsesUsername
                  ? TextInputType.text
                  : TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              autofillHints: [
                info.ldapUsesUsername
                    ? AutofillHints.username
                    : AutofillHints.email,
              ],
              onSubmitted: (_) => _passwordFocus.requestFocus(),
            ),
            AccessibleFormField(
              key: const Key('librechat-password-field'),
              enabled: !busy,
              label: l10n.password,
              controller: _controller.password,
              focusNode: _passwordFocus,
              obscureText: true,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) {
                if (_canSignIn) unawaited(_signIn());
              },
            ),
          ])
        else
          _intro(l10n.libreChatPasswordSignInOff),
      ],
      action: info.passwordSignInEnabled
          ? ConduitButton(
              key: const Key('librechat-sign-in'),
              text: l10n.signIn,
              isLoading: busy,
              isFullWidth: true,
              onPressed: busy || !_canSignIn ? null : _signIn,
            )
          : null,
      after: [
        for (final provider in info.ssoProviders) ...[
          const SizedBox(height: Spacing.sm),
          ConduitButton(
            key: Key('librechat-sso-${provider.kind.name}'),
            text: provider.label ?? l10n.continueWithProvider(_name(provider)),
            isSecondary: true,
            isFullWidth: true,
            onPressed: busy ? null : () => _singleSignOn(provider),
          ),
        ],
        const SizedBox(height: Spacing.md),
        AdaptiveButton(
          key: const Key('librechat-change-server'),
          label: l10n.libreChatChangeServer,
          style: AdaptiveButtonStyle.plain,
          useNative: false,
          onPressed: busy ? null : _changeServer,
        ),
      ],
    );
  }

  _Step _twoFactorStep(AppLocalizations l10n, bool busy) {
    final backup = _controller.useBackupCode;
    return (
      body: [
        ..._notice(),
        Text(
          l10n.twoStepVerifyTitle,
          textAlign: TextAlign.center,
          style: AppTypography.bodyLargeStyle.copyWith(
            color: context.conduitTheme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        _intro(
          backup
              ? l10n.twoStepRecoveryCodeDescription
              : l10n.twoStepVerifyDescription,
        ),
        const SizedBox(height: Spacing.lg),
        _materialFields([
          AccessibleFormField(
            key: const Key('librechat-code-field'),
            enabled: !busy,
            label: backup
                ? l10n.twoStepRecoveryCodeLabel
                : l10n.twoStepCodeLabel,
            controller: _controller.code,
            focusNode: _codeFocus,
            keyboardType: backup ? TextInputType.text : TextInputType.number,
            textInputAction: TextInputAction.go,
            autocorrect: false,
            autofillHints: backup ? null : const [AutofillHints.oneTimeCode],
            onSubmitted: (_) => _verify(),
          ),
        ]),
      ],
      action: ConduitButton(
        key: const Key('librechat-verify'),
        text: l10n.continueButton,
        isLoading: busy,
        isFullWidth: true,
        onPressed: busy || _controller.code.text.trim().isEmpty
            ? null
            : _verify,
      ),
      after: [
        const SizedBox(height: Spacing.sm),
        AdaptiveButton(
          key: const Key('librechat-toggle-backup'),
          label: backup
              ? l10n.twoStepUseAuthenticatorCode
              : l10n.twoStepUseRecoveryCode,
          style: AdaptiveButtonStyle.plain,
          useNative: false,
          onPressed: busy ? null : _controller.toggleBackupCode,
        ),
        AdaptiveButton(
          key: const Key('librechat-two-step-back'),
          label: l10n.twoStepBackToSignIn,
          style: AdaptiveButtonStyle.plain,
          useNative: false,
          onPressed: busy ? null : _controller.back,
        ),
      ],
    );
  }

  Widget _intro(String text) => Text(
    text,
    textAlign: TextAlign.center,
    style: AppTypography.bodyMediumStyle.copyWith(
      color: context.conduitTheme.textSecondary,
    ),
  );

  /// Material fields, stacked.
  Widget _materialFields(List<Widget> fields) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (index, field) in fields.indexed) ...[
        if (index > 0) const SizedBox(height: Spacing.md),
        field,
      ],
    ],
  );

  String? _issueText(AppLocalizations l10n) =>
      switch (_controller.issue) {
        null => null,
        LibreChatSignInIssue.invalidAddress => l10n.libreChatInvalidAddress,
        LibreChatSignInIssue.unreachable => l10n.libreChatUnreachable,
        LibreChatSignInIssue.notLibreChat => l10n.libreChatNotLibreChat,
        LibreChatSignInIssue.isOpenWebUi => l10n.libreChatIsOpenWebUi,
        LibreChatSignInIssue.invalidCode => l10n.twoStepInvalidCode,
        LibreChatSignInIssue.googleUnsupported =>
          l10n.libreChatGoogleUnsupported,
        LibreChatSignInIssue.ssoUnfinished => l10n.libreChatSsoUnfinished,
        LibreChatSignInIssue.failed => l10n.errorMessage,
        LibreChatSignInIssue.rejected =>
          _controller.serverMessage ?? l10n.errorMessage,
      };

  static String _name(LibreChatSsoProvider provider) =>
      switch (provider.kind) {
        LibreChatSsoKind.openid => 'OpenID',
        LibreChatSsoKind.saml => 'SAML',
        LibreChatSsoKind.google => 'Google',
        LibreChatSsoKind.github => 'GitHub',
        LibreChatSsoKind.discord => 'Discord',
        LibreChatSsoKind.facebook => 'Facebook',
        LibreChatSsoKind.apple => 'Apple',
      };
}

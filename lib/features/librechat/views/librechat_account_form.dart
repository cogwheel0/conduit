import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/services.dart' show TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../controllers/librechat_sign_in_controller.dart';
import 'librechat_sso_page.dart';

/// Adds a LibreChat account: the server's address, then a password (local
/// or LDAP, with two-step verification) or one of its single sign-on
/// providers. Calls [onSignedIn] with the saved account.
///
/// Embedded in the account sheet's LibreChat tab and in the full-screen
/// LibreChat sign-in page.
class LibreChatAccountForm extends ConsumerStatefulWidget {
  const LibreChatAccountForm({
    super.key,
    required this.onSignedIn,
    this.initialServer,
  });

  /// Called once the account is saved, to put it in use.
  final Future<void> Function(LibreChatAccount account) onSignedIn;

  /// A server to start at, skipping the address: signing in again to an
  /// account whose session ended.
  final String? initialServer;

  @override
  ConsumerState<LibreChatAccountForm> createState() =>
      _LibreChatAccountFormState();
}

class _LibreChatAccountFormState extends ConsumerState<LibreChatAccountForm> {
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

  /// Whether the saved account is being put in use.
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    final initial = widget.initialServer;
    if (initial != null) unawaited(_controller.startAt(initial));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
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

  Future<void> _signIn() async => _finish(await _controller.signIn());

  Future<void> _verify() async => _finish(await _controller.verifyCode());

  Future<void> _singleSignOn(LibreChatSsoProvider provider) async {
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
    final children = switch (_controller.step) {
      LibreChatSignInStep.server => _serverStep(l10n, busy),
      LibreChatSignInStep.methods => _methodsStep(l10n, busy),
      LibreChatSignInStep.twoFactor => _twoFactorStep(l10n, busy),
    };
    return Column(
      key: const Key('librechat-account-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...children,
        if (_issueText(l10n) case final message?) ...[
          const SizedBox(height: Spacing.md),
          Text(
            message,
            key: const Key('librechat-form-issue'),
            textAlign: TextAlign.center,
            style: AppTypography.bodySmallStyle.copyWith(
              color: context.conduitTheme.error,
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _serverStep(AppLocalizations l10n, bool busy) => [
    _intro(l10n.libreChatAddAccountMessage),
    const SizedBox(height: Spacing.lg),
    _fields([
      AccessibleFormField(
        key: const Key('librechat-server-field'),
        enabled: !busy,
        label: l10n.serverUrl,
        hint: 'chat.example.com',
        controller: _controller.address,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        autocorrect: false,
        onSubmitted: (_) => _controller.probe(),
        isRequired: true,
        iosSettingsRow: PlatformInfo.isIOS,
      ),
    ]),
    const SizedBox(height: Spacing.lg),
    ConduitButton(
      key: const Key('librechat-continue'),
      text: l10n.continueButton,
      isLoading: busy,
      isFullWidth: true,
      onPressed: busy ? null : _controller.probe,
    ),
  ];

  List<Widget> _methodsStep(AppLocalizations l10n, bool busy) {
    final info = _controller.info!;
    final server = _controller.server!;
    final host = Uri.parse(server.baseUrl).host;
    return [
      _intro(
        info.appTitle == 'LibreChat' ? host : '${info.appTitle} · $host',
      ),
      const SizedBox(height: Spacing.lg),
      if (info.passwordSignInEnabled) ...[
        _fields([
          AccessibleFormField(
            key: const Key('librechat-email-field'),
            enabled: !busy,
            label: info.ldapUsesUsername ? l10n.ldapUsername : l10n.emailLabel,
            controller: _controller.email,
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
            iosSettingsRow: PlatformInfo.isIOS,
          ),
          AccessibleFormField(
            key: const Key('librechat-password-field'),
            enabled: !busy,
            label: l10n.password,
            controller: _controller.password,
            obscureText: true,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.go,
            autocorrect: false,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _signIn(),
            iosSettingsRow: PlatformInfo.isIOS,
          ),
        ]),
        const SizedBox(height: Spacing.lg),
        ConduitButton(
          key: const Key('librechat-sign-in'),
          text: l10n.signIn,
          isLoading: busy,
          isFullWidth: true,
          onPressed: busy ? null : _signIn,
        ),
      ] else
        _intro(l10n.libreChatPasswordSignInOff),
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
        onPressed: busy ? null : _controller.back,
      ),
    ];
  }

  List<Widget> _twoFactorStep(AppLocalizations l10n, bool busy) {
    final backup = _controller.useBackupCode;
    return [
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
      _fields([
        AccessibleFormField(
          key: const Key('librechat-code-field'),
          enabled: !busy,
          label: backup ? l10n.twoStepRecoveryCodeLabel : l10n.twoStepCodeLabel,
          controller: _controller.code,
          keyboardType: backup ? TextInputType.text : TextInputType.number,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          autofillHints: backup ? null : const [AutofillHints.oneTimeCode],
          onSubmitted: (_) => _verify(),
          iosSettingsRow: PlatformInfo.isIOS,
        ),
      ]),
      const SizedBox(height: Spacing.lg),
      ConduitButton(
        key: const Key('librechat-verify'),
        text: l10n.continueButton,
        isLoading: busy,
        isFullWidth: true,
        onPressed: busy ? null : _verify,
      ),
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
        label: l10n.back,
        style: AdaptiveButtonStyle.plain,
        useNative: false,
        onPressed: busy ? null : _controller.back,
      ),
    ];
  }

  Widget _intro(String text) => Text(
    text,
    textAlign: TextAlign.center,
    style: AppTypography.bodyMediumStyle.copyWith(
      color: context.conduitTheme.textSecondary,
    ),
  );

  /// Fields as iOS settings rows in one group, or stacked elsewhere.
  Widget _fields(List<Widget> fields) {
    if (PlatformInfo.isIOS) {
      return InsetGroupedList(useNativeSurface: true, children: fields);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, field) in fields.indexed) ...[
          if (index > 0) const SizedBox(height: Spacing.md),
          field,
        ],
      ],
    );
  }

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

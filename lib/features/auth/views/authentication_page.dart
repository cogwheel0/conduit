import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show mapEquals, visibleForTesting;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/services/api_service.dart';

import '../../../shared/services/input_validation_service.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../profile/widgets/account_actions.dart'
    show abandonAddedAccount, confirmLeavingActiveAccount;

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit/l10n/app_localizations.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../../../platform/webview_cookie_helper.dart' show isWebViewSupported;
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../widgets/openwebui_two_step_form.dart';

/// Authentication mode options
enum AuthMode {
  credentials, // Email/password
  token, // JWT token
  sso, // OAuth/OIDC via WebView
  ldap, // LDAP username/password
}

@visibleForTesting
String normalizeAuthenticationServerUrl(String value) {
  final trimmed = value.trim();
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
    return trimmed;
  }

  var path = parsed.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path == '/') path = '';
  return parsed
      .replace(
        scheme: parsed.scheme.toLowerCase(),
        host: parsed.host.toLowerCase(),
        path: path,
      )
      .toString();
}

@visibleForTesting
bool authenticationServerMatchesSelection(
  ServerConfig? actual,
  ServerConfig expected,
) {
  return actual != null &&
      actual.id == expected.id &&
      actual.apiKey == null &&
      normalizeAuthenticationServerUrl(actual.url) ==
          normalizeAuthenticationServerUrl(expected.url) &&
      mapEquals(actual.customHeaders, expected.customHeaders) &&
      actual.allowSelfSignedCertificates ==
          expected.allowSelfSignedCertificates &&
      actual.mtlsCertificateChainPem == expected.mtlsCertificateChainPem &&
      actual.mtlsPrivateKeyPem == expected.mtlsPrivateKeyPem &&
      actual.mtlsPrivateKeyPassword == expected.mtlsPrivateKeyPassword;
}

/// Whether the selected server's newly-created API client is safe for sign-in.
///
/// Selection deliberately strips legacy [ServerConfig.apiKey] values, and the
/// replacement client must not inherit a bearer from the prior session.
@visibleForTesting
bool authenticationApiMatchesSelection(
  ApiService? actual,
  ServerConfig expected,
) {
  return actual != null &&
      actual.authToken == null &&
      authenticationServerMatchesSelection(actual.serverConfig, expected);
}

class AuthenticationPage extends ConsumerStatefulWidget {
  final ServerConfig? serverConfig;
  final BackendConfig? backendConfig;

  const AuthenticationPage({super.key, this.serverConfig, this.backendConfig});

  @override
  ConsumerState<AuthenticationPage> createState() => _AuthenticationPageState();
}

class _AuthenticationPageState extends ConsumerState<AuthenticationPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _ldapUsernameController = TextEditingController();
  final TextEditingController _ldapPasswordController = TextEditingController();

  bool _obscurePassword = true;
  AuthMode _authMode = AuthMode.credentials;

  // The route hands these over in its `extra`, which go_router does not keep
  // when it rebuilds the page from restored route information (it happened
  // on the refresh after a failed sign-in). Keep what this page was opened
  // with, so the methods, the selected tab and its form stay in step.
  late ServerConfig? _serverConfig = widget.serverConfig;
  late BackendConfig? _backendConfig = widget.backendConfig;
  String? _loginError;
  bool _isSigningIn = false;

  /// The second step a password or LDAP sign-in stopped at, while it is
  /// taken, and the username that sign-in began with.
  OpenWebUiTwoStepChallenge? _twoStep;
  String _twoStepAccount = '';
  bool _serverConfigSaved = false;

  /// Whether the addition this page's server was saved for is still under
  /// way, when it was saved for one.
  bool Function()? _additionInProgress;

  ConnectionAttemptState get _attemptState {
    final l10n = AppLocalizations.of(context)!;
    if (_isSigningIn) {
      return ConnectionAttemptState.connecting(l10n.signingIn);
    }
    final error = _loginError;
    if (error != null) return ConnectionAttemptState.failed(error);
    return const ConnectionAttemptState.idle();
  }

  /// Whether the server has OAuth/SSO providers configured.
  bool get _hasSsoEnabled =>
      isWebViewSupported && (_backendConfig?.hasSsoEnabled ?? true);

  /// Whether LDAP authentication is enabled on the server.
  bool get _hasLdapEnabled => _backendConfig?.enableLdap == true;

  /// Whether the login form (email/password) is enabled on the server.
  bool get _hasLoginFormEnabled => _backendConfig?.enableLoginForm ?? true;

  /// OAuth providers available on the server.
  OAuthProviders get _oauthProviders =>
      _backendConfig?.oauthProviders ?? const OAuthProviders();

  /// Available sign-in methods for this server.
  List<AuthMode> get _availableAuthModes {
    final modes = <AuthMode>[];
    if (_hasLoginFormEnabled) modes.add(AuthMode.credentials);
    if (_hasSsoEnabled) modes.add(AuthMode.sso);
    if (_hasLdapEnabled) modes.add(AuthMode.ldap);
    modes.add(AuthMode.token);
    return modes;
  }

  /// Label for each auth mode segment.
  String _authModeLabel(AuthMode mode) {
    final l10n = AppLocalizations.of(context)!;
    switch (mode) {
      case AuthMode.credentials:
        return l10n.credentials;
      case AuthMode.sso:
        return l10n.sso;
      case AuthMode.ldap:
        return l10n.ldap;
      case AuthMode.token:
        return l10n.jwt;
    }
  }

  @override
  void initState() {
    super.initState();
    for (final controller in [
      _usernameController,
      _passwordController,
      _apiKeyController,
      _ldapUsernameController,
      _ldapPasswordController,
    ]) {
      controller.addListener(_resetTransientLogin);
    }
    _setDefaultAuthMode();
    // Hydrate programmatic field values before surfacing auth errors so the
    // controller listeners cannot immediately clear the message.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _loadSavedCredentials();
      } finally {
        if (mounted) _checkAuthStateError();
      }
    });
  }

  @override
  void didUpdateWidget(AuthenticationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _serverConfig = widget.serverConfig ?? _serverConfig;
    _backendConfig = widget.backendConfig ?? _backendConfig;
  }

  void _resetTransientLogin() {
    if (!mounted || _isSigningIn) return;
    setState(() => _loginError = null);
  }

  bool get _canSubmit => switch (_authMode) {
    AuthMode.credentials =>
      _usernameController.text.trim().isNotEmpty &&
          _passwordController.text.isNotEmpty,
    AuthMode.ldap =>
      _ldapUsernameController.text.trim().isNotEmpty &&
          _ldapPasswordController.text.isNotEmpty,
    AuthMode.token => _apiKeyController.text.trim().isNotEmpty,
    AuthMode.sso => true,
  };

  /// Set the default auth mode based on what the server supports.
  void _setDefaultAuthMode() {
    // Priority: SSO > Credentials > LDAP > Token
    if (_hasSsoEnabled && _oauthProviders.enabledProviders.length == 1) {
      // If only one SSO provider, that's probably the intended method
      _authMode = AuthMode.sso;
    } else if (_hasLoginFormEnabled) {
      _authMode = AuthMode.credentials;
    } else if (_hasLdapEnabled) {
      _authMode = AuthMode.ldap;
    } else {
      // Fallback to token if nothing else is enabled
      _authMode = AuthMode.token;
    }

    // Keep the selected segment and rendered form in sync with the methods
    // supported by both the server and this platform.
    final selectableModes = _availableAuthModes;
    if (selectableModes.length > 1 && !selectableModes.contains(_authMode)) {
      _authMode = selectableModes.first;
    }
  }

  void _checkAuthStateError() {
    final authState = ref.read(authStateManagerProvider).asData?.value;
    if (authState?.error != null && authState!.error!.isNotEmpty) {
      setState(() {
        _loginError = _formatLoginError(authState.error!);
        // Switch to token tab if the error is about API keys
        if (authState.error!.contains('apiKey')) {
          _authMode = AuthMode.token;
        }
      });
    }
  }

  Future<void> _loadSavedCredentials() async {
    // While another account is added, the saved sign-in is the one of the
    // account it was added from, not of the one being signed in to.
    if (ref.read(accountAdditionOriginProvider) != null) return;
    final storage = ref.read(optimizedStorageServiceProvider);
    final savedCredentials = await storage.getSavedCredentials();
    if (mounted && savedCredentials != null) {
      setState(() {
        _usernameController.text = savedCredentials['username'] ?? '';
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _apiKeyController.dispose();
    _ldapUsernameController.dispose();
    _ldapPasswordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_isSigningIn) return;

    final l10n = AppLocalizations.of(context)!;
    if (!_formKey.currentState!.validate()) return;
    if (!await _mayLeaveActiveAccount() || !mounted) return;

    setState(() {
      _isSigningIn = true;
      _loginError = null;
    });
    // As submitted: the fields can change while the sign-in is under way.
    final submittedAccount = _authMode == AuthMode.ldap
        ? _ldapUsernameController.text.trim()
        : _usernameController.text.trim();

    try {
      // Save server config on first sign-in attempt if it's a new config
      // This persists the server so user can retry with different credentials
      if (_serverConfig != null && !_serverConfigSaved) {
        await _saveServerConfig(_serverConfig!);
        _serverConfigSaved = true;
      }
      if (!await _signInTargetStillSelected()) {
        throw StateError('The selected server changed before sign-in was ready.');
      }
      if (!mounted) return;

      final actions = ref.read(authActionsProvider);
      bool success;

      switch (_authMode) {
        case AuthMode.credentials:
          success = await actions.login(
            _usernameController.text.trim(),
            _passwordController.text,
            rememberCredentials: true,
          );
        case AuthMode.token:
          success = await actions.loginWithApiKey(
            _apiKeyController.text.trim(),
            rememberCredentials: true,
          );
        case AuthMode.ldap:
          success = await actions.ldapLogin(
            _ldapUsernameController.text.trim(),
            _ldapPasswordController.text,
            rememberCredentials: true,
          );
        case AuthMode.sso:
          // SSO is handled by navigating to SsoAuthPage
          return;
      }

      if (!success) {
        final authState = ref.read(authStateManagerProvider);
        throw Exception(authState.error ?? l10n.loginFailed);
      }

      if (!mounted) return;

      ConduitHaptics.success();

      // Success - navigation will be handled by auth state change
    } on OpenWebUiTwoStepRequired catch (e) {
      // The password was right; the server asks for a second step before it
      // issues a session.
      if (!mounted) return;
      setState(() {
        _twoStep = e.challenge;
        _twoStepAccount = submittedAccount;
      });
    } catch (e) {
      if (!mounted) return;
      // Don't clear server config on auth failure - user should be able to retry
      // The server config is valid (passed OpenWebUI verification), only the
      // credentials were wrong or there was a network issue
      setState(() {
        _loginError = _formatLoginError(e.toString());
      });
      ConduitHaptics.error();
    } finally {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
        });
      }
    }
  }

  /// Back to server setup, except while adding another account: then back
  /// to where that began, or -- once this sign-in has become the active
  /// account -- Cancel, which drops it and returns to the previous account.
  UtilityBackNavigation _backNavigation(
    AppLocalizations l10n, {
    required bool abandonable,
  }) {
    const key = ValueKey<String>('authentication-back-button');
    if (abandonable) {
      return UtilityBackNavigation(
        label: l10n.cancel,
        buttonKey: key,
        onPressed: _cancelAddition,
      );
    }
    if (ref.watch(accountAdditionOriginProvider) != null && context.canPop()) {
      return UtilityBackNavigation(
        label: l10n.back,
        buttonKey: key,
        onPressed: () => context.pop(),
      );
    }
    return UtilityBackNavigation(
      label: l10n.backToServerSetup,
      buttonKey: key,
      onPressed: () => context.go(Routes.serverConnection),
    );
  }

  /// The first attempt makes the server's new account the active one. While
  /// another account is added that leaves the one it was added from, and
  /// stops a reply still being written there, so ask first.
  Future<bool> _mayLeaveActiveAccount() async {
    if (_serverConfig == null ||
        _serverConfigSaved ||
        ref.read(accountAdditionOriginProvider) == null) {
      return true;
    }
    return confirmLeavingActiveAccount(context, ref);
  }

  Future<void> _saveServerConfig(ServerConfig config) async {
    // Saved for an added account, the server is that addition's. Left while
    // the save is slow -- Back is then only Back, with the account it was
    // added from still active -- the addition ends, and so must the save:
    // it would make the new account active, signed out, over chat.
    final addition = ref.read(accountAdditionOriginProvider) == null
        ? null
        : ref.read(accountAdditionOriginProvider.notifier).stillInProgress();
    _additionInProgress = addition;
    await ref
        .read(authStateManagerProvider.notifier)
        .selectUnauthenticatedServerConfig(config, canCommit: addition);

    final selectedServer = await ref.read(activeServerProvider.future);
    if (!authenticationServerMatchesSelection(selectedServer, config)) {
      throw StateError('The selected server changed before sign-in was ready.');
    }
    await _waitForApiService(config);

    final backendConfig = _backendConfig;
    if (backendConfig != null) {
      // The config was already verified for this server before sign-in. Keep it
      // associated with the newly active server so capability warnings and
      // transport options do not wait for another fetch after authentication.
      await ref.read(backendConfigProvider.future);
      await ref
          .read(backendConfigProvider.notifier)
          .cacheForServer(backendConfig, config.id);
    }
  }

  /// Whether what this sign-in signs in to is still selected. Cancel, or
  /// Back, while it is prepared ends the addition and makes the account it
  /// began from active again; a sign-in then would save this user's session
  /// under that account.
  ///
  /// Unreadable, it is not known to be: false, which each sign-in reports as
  /// a failure, letting the user try again.
  Future<bool> _signInTargetStillSelected() async {
    final addition = _additionInProgress;
    if (addition != null && !addition()) return false;
    final config = _serverConfig;
    if (config == null) return true;
    try {
      final selected = await ref.read(activeServerProvider.future);
      return mounted && authenticationServerMatchesSelection(selected, config);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'sign-in-selection-read-failed',
        scope: 'auth/page',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Cancel: drops the added account and returns to the account it was
  /// added from, or stays and says so when it could not be dropped.
  Future<void> _cancelAddition() async {
    if (!await abandonAddedAccount(context, ref) && mounted) {
      setState(() => _loginError = AppLocalizations.of(context)!.errorMessage);
    }
  }

  Future<void> _waitForApiService(ServerConfig selectedServer) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      final api = ref.read(apiServiceProvider);
      if (authenticationApiMatchesSelection(api, selectedServer)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('The selected server connection was not ready in time.');
  }

  String _formatLoginError(String error) {
    final l10n = AppLocalizations.of(context)!;
    if (error.contains('twoStepVerificationRequired')) {
      return l10n.signInTwoStepVerificationRequired;
    } else if (error.contains('twoStepSessionRejected')) {
      return l10n.twoStepExpired;
    } else if (error.contains('accountPendingApproval')) {
      return l10n.signInAccountPendingApproval;
    } else if (error.contains('apiKeyNotSupported')) {
      return l10n.apiKeyNotSupported;
    } else if (error.contains('apiKeyNoLongerSupported')) {
      return l10n.apiKeyNoLongerSupported;
    } else if (error.contains('LDAP authentication is not enabled')) {
      return l10n.ldapNotEnabled;
    } else if (error.contains('401') || error.contains('Unauthorized')) {
      return l10n.invalidCredentials;
    } else if (error.contains('redirect')) {
      return l10n.serverRedirectingHttps;
    } else if (error.contains('SocketException')) {
      return l10n.unableToConnectServer;
    } else if (error.contains('timeout')) {
      return l10n.requestTimedOut;
    }
    return l10n.genericSignInFailed;
  }

  @override
  Widget build(BuildContext context) {
    // Listen for auth state changes to run post-login side effects.
    ref.listen<AsyncValue<AuthState>>(authStateManagerProvider, (
      previous,
      next,
    ) {
      final nextState = next.asData?.value;
      final prevState = previous?.asData?.value;
      if (mounted &&
          nextState?.isAuthenticated == true &&
          prevState?.isAuthenticated != true) {
        DebugLogger.auth(
          'Authentication successful, initializing background resources',
        );

        // Model selection will be handled by the chat page
        // to avoid widget disposal issues

        // Navigation is handled automatically by the router when auth state
        // changes to authenticated. Calling context.go() here can race with
        // the redirect and duplicate the shell navigator during auth recovery.
      }
    });

    final l10n = AppLocalizations.of(context)!;
    final abandonable =
        ref.watch(pendingSignInAbandonableProvider).value ?? false;

    final twoStep = _twoStep;

    // The system back and the edge swipe leave as Cancel does, so they cannot
    // leave an added account that never signed in as the active one. During
    // a second step they return to the sign-in form.
    return PopScope(
      canPop: !abandonable && twoStep == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_twoStep != null) {
          _leaveTwoStep();
        } else {
          _cancelAddition();
        }
      },
      child: UtilityPageScaffold.auth(
        title: l10n.signIn,
        backNavigation: _backNavigation(l10n, abandonable: abandonable),
        bottomAction: twoStep == null ? _buildSignInButton() : null,
        body: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              const SizedBox(height: Spacing.xl),
              if (twoStep != null)
                OpenWebUiTwoStepForm(
                  key: ObjectKey(twoStep),
                  challenge: twoStep,
                  account: _twoStepAccount,
                  onCancel: _leaveTwoStep,
                  mayFinish: _signInTargetStillSelected,
                  formatSignInError: _formatLoginError,
                )
              else ...[
                _buildAuthMethodSection(),
                const SizedBox(height: Spacing.xl),
                _buildAuthForm(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _leaveTwoStep() {
    setState(() {
      _twoStep = null;
      _loginError = null;
    });
  }

  Widget _buildHeader() {
    return Text(
      _serverAddressForDisplay(_resolvedServerConfig?.url),
      textAlign: TextAlign.center,
      style: AppTypography.bodySmallStyle.copyWith(
        color: context.conduitTheme.textSecondary,
        fontFamily: AppTypography.monospaceFontFamily,
      ),
    );
  }

  /// Leaving the page commits the autofill context, which makes iOS offer to
  /// save the password. Not for one the server just rejected.
  AutofillContextAction get _autofillDisposeAction => _loginError == null
      ? AutofillContextAction.commit
      : AutofillContextAction.cancel;

  ServerConfig? get _resolvedServerConfig {
    final activeServerAsync = ref.watch(activeServerProvider);
    return _serverConfig ??
        activeServerAsync.maybeWhen(data: (s) => s, orElse: () => null);
  }

  Widget _buildAuthMethodSection() {
    final methods = _availableAuthModes;
    if (methods.length <= 1) return const SizedBox.shrink();

    var selectedIndex = methods.indexOf(_authMode);
    if (selectedIndex < 0) selectedIndex = 0;

    return InsetGroupedSection(
      key: const ValueKey<String>('authentication-mode-selector'),
      flat: true,
      padding: EdgeInsets.zero,
      child: AdaptiveSegmentedControl(
        labels: methods.map(_authModeLabel).toList(growable: false),
        selectedIndex: selectedIndex,
        onValueChanged: (index) {
          final mode = methods[index];
          if (mode == _authMode) return;
          setState(() {
            _authMode = mode;
            _loginError = null;
            _obscurePassword = true;
          });
        },
      ),
    );
  }

  String _ssoSubtitle(AppLocalizations l10n) {
    final providers = _oauthProviders.enabledProviders;
    if (providers.length > 1) {
      return providers.map(_oauthProviders.getProviderDisplayName).join(' · ');
    }
    return l10n.ssoDescription;
  }

  String _serverAddressForDisplay(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return AppLocalizations.of(context)!.serverAddressUnavailable;
    }

    final value = rawUrl.trim();
    final uri = Uri.tryParse(value);
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        uri.host.isEmpty ||
        (scheme != 'http' && scheme != 'https')) {
      return AppLocalizations.of(context)!.serverAddressUnavailable;
    }

    final path = uri.path == '/' ? '' : uri.path;
    return '${uri.origin}$path';
  }

  Widget _buildAuthForm() {
    final form = switch (_authMode) {
      AuthMode.credentials when _hasLoginFormEnabled => _buildCredentialsForm(),
      AuthMode.ldap when _hasLdapEnabled => _buildLdapForm(),
      AuthMode.token => _buildApiKeyForm(),
      AuthMode.sso => _buildSsoMethodDescription(),
      _ => const SizedBox.shrink(),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InsetGroupedSection(flat: true, child: form),
        if (_attemptState.isVisible) ...[
          const SizedBox(height: Spacing.md),
          ConnectionAttemptBanner(state: _attemptState),
        ],
      ],
    );
  }

  Widget _buildSsoMethodDescription() => Text(
    _ssoSubtitle(AppLocalizations.of(context)!),
    key: const ValueKey<String>('sso_form'),
    style: context.conduitTheme.bodyMedium?.copyWith(
      color: context.conduitTheme.textSecondary,
      height: 1.4,
    ),
  );

  /// Validates that a token is a JWT and not an API key.
  /// API keys (sk-, api-, key-) don't work with WebSocket authentication.
  String? _validateJwtToken(String? value) {
    if (value == null || value.isEmpty) {
      return AppLocalizations.of(context)!.validationMissingRequired;
    }

    final trimmed = value.trim();
    final lowerTrimmed = trimmed.toLowerCase();

    // Reject API keys - they don't work with socket authentication
    // Case-insensitive check to catch SK-, API-, KEY- variants
    if (lowerTrimmed.startsWith('sk-') ||
        lowerTrimmed.startsWith('api-') ||
        lowerTrimmed.startsWith('key-')) {
      return AppLocalizations.of(context)!.apiKeyNotSupported;
    }

    // Check minimum length
    if (trimmed.length < 10) {
      return AppLocalizations.of(context)!.tokenTooShort;
    }

    return null;
  }

  Widget _buildApiKeyForm() {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      key: const ValueKey('api_key_form'),
      children: [
        AccessibleFormField(
          label: l10n.token,
          hint: 'eyJ...',
          controller: _apiKeyController,
          validator: (value) =>
              _validateJwtToken(value ?? _apiKeyController.text),
          obscureText: _obscurePassword,
          isRequired: true,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          suffixIcon: ConduitIconButton(
            icon: _obscurePassword
                ? (context.usesCupertinoChrome
                      ? CupertinoIcons.eye_slash
                      : Icons.visibility_off)
                : (context.usesCupertinoChrome
                      ? CupertinoIcons.eye
                      : Icons.visibility),
            iconColor: context.conduitTheme.iconSecondary,
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
            tooltip: _obscurePassword ? l10n.showPassword : l10n.hidePassword,
            isCompact: true,
          ),
          onSubmitted: (_) => _signIn(),
          autofillHints: const [AutofillHints.password],
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          AppLocalizations.of(context)!.tokenHint,
          style: context.conduitTheme.bodySmall?.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildCredentialsForm() {
    final l10n = AppLocalizations.of(context)!;

    return AutofillGroup(
      onDisposeAction: _autofillDisposeAction,
      child: Column(
        key: const ValueKey('credentials_form'),
        children: [
          AccessibleFormField(
            label: l10n.usernameOrEmail,
            hint: l10n.usernameOrEmailHint,
            controller: _usernameController,
            validator: (value) {
              final v = value ?? _usernameController.text;
              return InputValidationService.combine([
                InputValidationService.validateRequired,
                (val) => InputValidationService.validateEmailOrUsername(val),
              ])(v);
            },
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            isRequired: true,
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            autofillHints: const [AutofillHints.username, AutofillHints.email],
          ),
          const SizedBox(height: Spacing.lg),
          AccessibleFormField(
            label: l10n.password,
            hint: l10n.passwordHint,
            controller: _passwordController,
            validator: (value) {
              final v = value ?? _passwordController.text;
              return InputValidationService.combine([
                InputValidationService.validateRequired,
                (val) => InputValidationService.validateMinLength(
                  val,
                  1,
                  fieldName: AppLocalizations.of(context)!.password,
                ),
              ])(v);
            },
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            isRequired: true,
            suffixIcon: ConduitIconButton(
              icon: _obscurePassword
                  ? (context.usesCupertinoChrome
                        ? CupertinoIcons.eye_slash
                        : Icons.visibility_off)
                  : (context.usesCupertinoChrome
                        ? CupertinoIcons.eye
                        : Icons.visibility),
              iconColor: context.conduitTheme.iconSecondary,
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              tooltip: _obscurePassword ? l10n.showPassword : l10n.hidePassword,
              isCompact: true,
            ),
            onSubmitted: (_) => _signIn(),
            autofillHints: const [AutofillHints.password],
          ),
        ],
      ),
    );
  }

  Widget _buildLdapForm() {
    final l10n = AppLocalizations.of(context)!;

    return AutofillGroup(
      onDisposeAction: _autofillDisposeAction,
      child: Column(
        key: const ValueKey('ldap_form'),
        children: [
          AccessibleFormField(
            label: l10n.ldapUsername,
            hint: l10n.ldapUsernameHint,
            controller: _ldapUsernameController,
            validator: (value) => InputValidationService.validateRequired(
              value ?? _ldapUsernameController.text,
            ),
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            isRequired: true,
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            autofillHints: const [AutofillHints.username],
          ),
          const SizedBox(height: Spacing.lg),
          AccessibleFormField(
            label: l10n.password,
            hint: l10n.passwordHint,
            controller: _ldapPasswordController,
            validator: (value) {
              final v = value ?? _ldapPasswordController.text;
              return InputValidationService.combine([
                InputValidationService.validateRequired,
                (val) => InputValidationService.validateMinLength(
                  val,
                  1,
                  fieldName: l10n.password,
                ),
              ])(v);
            },
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            isRequired: true,
            suffixIcon: ConduitIconButton(
              icon: _obscurePassword
                  ? (context.usesCupertinoChrome
                        ? CupertinoIcons.eye_slash
                        : Icons.visibility_off)
                  : (context.usesCupertinoChrome
                        ? CupertinoIcons.eye
                        : Icons.visibility),
              iconColor: context.conduitTheme.iconSecondary,
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              tooltip: _obscurePassword ? l10n.showPassword : l10n.hidePassword,
              isCompact: true,
            ),
            onSubmitted: (_) => _signIn(),
            autofillHints: const [AutofillHints.password],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            l10n.ldapDescription,
            style: context.conduitTheme.bodySmall?.copyWith(
              color: context.conduitTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _navigateToSso() async {
    if (!mounted || _isSigningIn) return;
    if (!await _mayLeaveActiveAccount() || !mounted) return;
    setState(() {
      _isSigningIn = true;
      _loginError = null;
    });

    // Save server config first if needed. _saveServerConfig can throw (for
    // example when the selected server's API client is not ready in time), so
    // surface that like the credentials path instead of silently doing
    // nothing; the user can then retry the SSO button.
    if (_serverConfig != null && !_serverConfigSaved) {
      try {
        await _saveServerConfig(_serverConfig!);
        _serverConfigSaved = true;
      } catch (e) {
        DebugLogger.error(
          'sso-server-config-save-failed',
          scope: 'auth/page',
          data: {'errorType': e.runtimeType.toString()},
        );
        if (mounted) {
          setState(() {
            _loginError = _formatLoginError(e.toString());
          });
          ConduitHaptics.error();
        }
        if (mounted) setState(() => _isSigningIn = false);
        return;
      }
      if (!mounted) return;
    }
    if (!await _signInTargetStillSelected() || !mounted) {
      if (mounted) {
        setState(() {
          _loginError = AppLocalizations.of(context)!.genericSignInFailed;
          _isSigningIn = false;
        });
      }
      return;
    }

    await context.pushNamed(RouteNames.ssoAuth, extra: _serverConfig);
    if (mounted) setState(() => _isSigningIn = false);
  }

  Widget _buildSignInButton() {
    final l10n = AppLocalizations.of(context)!;

    String buttonText;
    if (_isSigningIn) {
      buttonText = l10n.signingIn;
    } else {
      switch (_authMode) {
        case AuthMode.credentials:
          buttonText = l10n.signIn;
        case AuthMode.token:
          buttonText = l10n.signInWithToken;
        case AuthMode.ldap:
          buttonText = l10n.signInWithLdap;
        case AuthMode.sso:
          buttonText = l10n.signInWithSso;
      }
    }

    return ConduitButton(
      text: buttonText,
      onPressed: _isSigningIn || !_canSubmit
          ? null
          : _authMode == AuthMode.sso
          ? _navigateToSso
          : _signIn,
      isLoading: _isSigningIn,
      isFullWidth: true,
    );
  }
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show mapEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/backend_config.dart';
import '../../../core/models/server_config.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/input_validation_service.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../core/auth/auth_state_manager.dart';
import '../../../core/utils/debug_logger.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../providers/unified_auth_providers.dart';
import '../../../core/auth/webview_cookie_helper.dart' show isWebViewSupported;
import '../../profile/widgets/adaptive_segmented_selector.dart';
import '../widgets/adaptive_auth_scaffold.dart';

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
  String? _loginError;
  bool _isSigningIn = false;
  bool _serverConfigSaved = false;

  /// Whether the server has OAuth/SSO providers configured.
  bool get _hasSsoEnabled =>
      widget.backendConfig?.hasSsoEnabled == true && isWebViewSupported;

  /// Whether LDAP authentication is enabled on the server.
  bool get _hasLdapEnabled => widget.backendConfig?.enableLdap == true;

  /// Whether the login form (email/password) is enabled on the server.
  bool get _hasLoginFormEnabled =>
      widget.backendConfig?.enableLoginForm ?? true;

  /// OAuth providers available on the server.
  OAuthProviders get _oauthProviders =>
      widget.backendConfig?.oauthProviders ?? const OAuthProviders();

  /// Available auth modes for the segmented control.
  List<AuthMode> get _availableAuthModes {
    final modes = <AuthMode>[];
    if (_hasLoginFormEnabled) modes.add(AuthMode.credentials);
    if (isWebViewSupported && !_hasSsoEnabled) modes.add(AuthMode.sso);
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
        return l10n.token;
    }
  }

  @override
  void initState() {
    super.initState();
    _setDefaultAuthMode();
    _loadSavedCredentials();
    // Check for auth errors (e.g., forced logout due to API key)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAuthStateError();
    });
  }

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

    // Configured OAuth providers are rendered as their own buttons and are
    // intentionally omitted from the alternate-method selector. When other
    // methods are available, keep the selected segment and rendered form in
    // sync instead of passing an out-of-range value to the native control.
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

    setState(() {
      _isSigningIn = true;
      _loginError = null;
    });

    try {
      // Save server config on first sign-in attempt if it's a new config
      // This persists the server so user can retry with different credentials
      if (widget.serverConfig != null && !_serverConfigSaved) {
        await _saveServerConfig(widget.serverConfig!);
        _serverConfigSaved = true;
      }

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

      // Success - navigation will be handled by auth state change
    } catch (e) {
      // Don't clear server config on auth failure - user should be able to retry
      // The server config is valid (passed OpenWebUI verification), only the
      // credentials were wrong or there was a network issue
      setState(() {
        _loginError = _formatLoginError(e.toString());
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
        });
      }
    }
  }

  Future<void> _saveServerConfig(ServerConfig config) async {
    await ref
        .read(authStateManagerProvider.notifier)
        .selectUnauthenticatedServerConfig(config);

    final selectedServer = await ref.read(activeServerProvider.future);
    if (!authenticationServerMatchesSelection(selectedServer, config)) {
      throw StateError('The selected server changed before sign-in was ready.');
    }
    await _waitForApiService(config);

    final backendConfig = widget.backendConfig;
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
    if (error.contains('apiKeyNotSupported')) {
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

    return ErrorBoundary(
      child: AdaptiveAuthScaffold(
        title: l10n.signIn,
        backLabel: l10n.backToServerSetup,
        backButtonKey: const ValueKey<String>('authentication-back-button'),
        onBack: () => context.go(Routes.serverConnection),
        bottomAction: _buildSignInButton(),
        body: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              if (_availableAuthModes.length > 1) ...[
                const SizedBox(height: Spacing.xl),
                _buildAuthModeSelector(),
              ],
              const SizedBox(height: Spacing.lg),
              _buildAuthForm(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppLocalizations.of(context)!.signInServerDescription,
          style: theme.bodyMedium?.copyWith(
            color: theme.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: Spacing.md),
        ConduitCard(
          isElevated: false,
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocalizations.of(context)!.openWebUIServer,
                style: theme.bodySmall?.copyWith(
                  color: theme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: Spacing.xxs),
              _buildServerDomain(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAuthModeSelector() {
    final modes = _availableAuthModes;
    return AdaptiveSegmentedSelector<AuthMode>(
      key: const ValueKey<String>('authentication-mode-selector'),
      value: _authMode,
      showIcons: false,
      onChanged: (mode) {
        setState(() {
          _authMode = mode;
          _loginError = null;
          _obscurePassword = true;
        });
      },
      options: [
        for (final mode in modes)
          (
            value: mode,
            label: _authModeLabel(mode),
            cupertinoIcon: CupertinoIcons.circle,
            materialIcon: Icons.circle_outlined,
            enabled: true,
          ),
      ],
    );
  }

  Widget _buildServerDomain() {
    final activeServerAsync = ref.watch(activeServerProvider);
    final cfg =
        widget.serverConfig ??
        activeServerAsync.maybeWhen(data: (s) => s, orElse: () => null);
    final displayUrl = _serverAddressForDisplay(cfg?.url);
    return Text(
      displayUrl,
      overflow: TextOverflow.ellipsis,
      style: context.conduitTheme.bodySmall?.copyWith(
        color: context.conduitTheme.textPrimary,
        fontWeight: FontWeight.w600,
        fontFamily: AppTypography.monospaceFontFamily,
      ),
    );
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
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Show SSO buttons prominently if OAuth providers are configured
        if (_hasSsoEnabled) ...[
          _buildSsoButtons(l10n),
          if (_hasLoginFormEnabled || _hasLdapEnabled) ...[
            const SizedBox(height: Spacing.lg),
            _buildDividerWithText(l10n.or),
            const SizedBox(height: Spacing.lg),
          ],
        ],

        // Show the appropriate form based on auth mode
        // Credentials form is shown directly when login form is enabled
        // Other modes (LDAP, Token) are shown when selected from "More options"
        if (_hasLoginFormEnabled && _authMode == AuthMode.credentials) ...[
          _buildCredentialsForm(),
        ] else if (_authMode == AuthMode.ldap && _hasLdapEnabled) ...[
          _buildLdapForm(),
        ] else if (_authMode == AuthMode.token) ...[
          _buildApiKeyForm(),
        ] else if (_authMode == AuthMode.sso && !_hasSsoEnabled) ...[
          _buildSsoPrompt(),
        ],

        if (_loginError != null) ...[
          const SizedBox(height: Spacing.md),
          _buildErrorMessage(_loginError!),
        ],
      ],
    );
  }

  Widget _buildDividerWithText(String text) {
    return Row(
      children: [
        Expanded(
          child: Divider(
            color: context.conduitTheme.dividerColor.withValues(alpha: 0.5),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: Text(
            text,
            style: context.conduitTheme.bodySmall?.copyWith(
              color: context.conduitTheme.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Divider(
            color: context.conduitTheme.dividerColor.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _buildSsoButtons(AppLocalizations l10n) {
    final providers = _oauthProviders.enabledProviders;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < providers.length; i++) ...[
          if (i > 0) const SizedBox(height: Spacing.sm),
          _buildOAuthButton(providers[i], l10n),
        ],
      ],
    );
  }

  Widget _buildOAuthButton(String provider, AppLocalizations l10n) {
    final displayName = _oauthProviders.getProviderDisplayName(provider);

    IconData icon;

    switch (provider) {
      case 'google':
        icon = Icons.g_mobiledata;
      case 'microsoft':
        icon = Icons.window;
      case 'github':
        icon = Icons.code;
      case 'oidc':
        icon = context.usesCupertinoChrome
            ? CupertinoIcons.lock_shield
            : Icons.security;
      case 'feishu':
        icon = Icons.chat_bubble_outline;
      default:
        icon = Icons.login;
    }

    return ConduitButton(
      text: l10n.continueWithProvider(displayName),
      icon: icon,
      onPressed: _navigateToSso,
      isSecondary: true,
      isFullWidth: true,
    );
  }

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

  Widget _buildSsoPrompt() {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      key: const ValueKey('sso_form'),
      children: [
        Container(
          padding: const EdgeInsets.all(Spacing.lg),
          decoration: BoxDecoration(
            color: context.conduitTheme.surfaceContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(AppBorderRadius.medium),
            border: Border.all(
              color: context.conduitTheme.dividerColor.withValues(alpha: 0.5),
              width: BorderWidth.standard,
            ),
          ),
          child: Column(
            children: [
              Icon(
                context.usesCupertinoChrome
                    ? CupertinoIcons.lock_shield
                    : Icons.security,
                size: IconSize.xxl,
                color: context.conduitTheme.buttonPrimary,
              ),
              const SizedBox(height: Spacing.md),
              Text(l10n.sso, style: context.conduitTheme.headingMedium),
              const SizedBox(height: Spacing.sm),
              Text(
                l10n.ssoDescription,
                style: context.conduitTheme.bodyMedium?.copyWith(
                  color: context.conduitTheme.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.lg),
              ConduitButton(
                text: l10n.signInWithSso,
                icon: context.usesCupertinoChrome
                    ? CupertinoIcons.arrow_right
                    : Icons.arrow_forward,
                onPressed: _navigateToSso,
                isFullWidth: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _navigateToSso() async {
    if (!mounted) return;

    // Save server config first if needed
    if (widget.serverConfig != null && !_serverConfigSaved) {
      await _saveServerConfig(widget.serverConfig!);
      _serverConfigSaved = true;
      if (!mounted) return;
    }

    context.pushNamed(RouteNames.ssoAuth, extra: widget.serverConfig);
  }

  Widget _buildSignInButton() {
    final l10n = AppLocalizations.of(context)!;

    // Don't show sign-in button for SSO mode (it has its own button)
    if (_authMode == AuthMode.sso) {
      return const SizedBox.shrink();
    }

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
      onPressed: _isSigningIn ? null : _signIn,
      isLoading: _isSigningIn,
      isFullWidth: true,
      useNativeLabel: true,
    );
  }

  Widget _buildErrorMessage(String message) {
    return Semantics(
      liveRegion: true,
      label: message,
      child: Container(
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: context.conduitTheme.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
          border: Border.all(
            color: context.conduitTheme.error.withValues(alpha: 0.2),
            width: BorderWidth.standard,
          ),
        ),
        child: Row(
          children: [
            Icon(
              context.usesCupertinoChrome
                  ? CupertinoIcons.exclamationmark_circle
                  : Icons.error_outline,
              color: context.conduitTheme.error,
              size: IconSize.small,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                message,
                style: context.conduitTheme.bodySmall?.copyWith(
                  color: context.conduitTheme.error,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

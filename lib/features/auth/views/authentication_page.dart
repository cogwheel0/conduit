import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/backend_config.dart';
import '../../../core/models/server_config.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/input_validation_service.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/services/brand_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../core/auth/auth_state_manager.dart';
import '../../../core/utils/debug_logger.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../providers/unified_auth_providers.dart';
import '../../../core/auth/webview_cookie_helper.dart' show isWebViewSupported;

/// Authentication mode options
enum AuthMode {
  credentials, // Email/password
  token, // JWT token
  sso, // OAuth/OIDC via WebView
  ldap, // LDAP username/password
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
  bool _showMoreOptions = false;

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
    if (savedCredentials != null) {
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
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveServerConfigs([config]);
    await storage.setActiveServerId(config.id);
    ref.invalidate(serverConfigsProvider);
    ref.invalidate(activeServerProvider);
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
    // Listen for auth state changes to navigate on successful login
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

        DebugLogger.auth('Navigating to chat page');
        // Navigate directly to chat page on successful authentication
        context.go(Routes.chat);
      }
    });

    return ErrorBoundary(
      child: AdaptiveScaffold(
        body: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.pagePadding,
              vertical: Spacing.lg,
            ),
            child: Column(
              children: [
                // Header with progress indicator
                _buildHeader(),

                const SizedBox(height: Spacing.xl),

                // Main content
                Expanded(
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Server connection status
                            _buildServerStatus(),

                            const SizedBox(height: Spacing.xl),

                            // Welcome section
                            _buildWelcomeSection(),

                            const SizedBox(height: Spacing.xl),

                            // Authentication form
                            _buildAuthForm(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Bottom action button
                _buildSignInButton(),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        ConduitIconButton(
          icon: Platform.isIOS ? CupertinoIcons.back : Icons.arrow_back,
          onPressed: () => context.go(Routes.serverConnection),
          tooltip: AppLocalizations.of(context)!.backToServerSetup,
        ),
        const Spacer(),
        // Progress indicator (step 2 of 2)
        Row(
          children: [
            Container(
              width: 24,
              height: 4,
              decoration: BoxDecoration(
                color: context.conduitTheme.buttonPrimary,
                borderRadius: BorderRadius.circular(AppBorderRadius.round),
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Container(
              width: 24,
              height: 4,
              decoration: BoxDecoration(
                color: context.conduitTheme.buttonPrimary,
                borderRadius: BorderRadius.circular(AppBorderRadius.round),
              ),
            ),
          ],
        ),
        const Spacer(),
        const SizedBox(width: TouchTarget.minimum), // Balance the back button
      ],
    );
  }

  Widget _buildServerStatus() {
    // Prefer route-provided config; otherwise fall back to active server
    final activeServerAsync = ref.watch(activeServerProvider);
    final cfg =
        widget.serverConfig ??
        activeServerAsync.maybeWhen(data: (s) => s, orElse: () => null);
    final hostText = () {
      try {
        final url = cfg?.url;
        if (url != null && url.isNotEmpty) return Uri.parse(url).host;
      } catch (_) {}
      return 'Server';
    }();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: context.conduitTheme.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: context.conduitTheme.success.withValues(alpha: 0.2),
          width: BorderWidth.standard,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Platform.isIOS
                ? CupertinoIcons.checkmark_circle
                : Icons.check_circle_outline,
            color: context.conduitTheme.success,
            size: IconSize.small,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context)!.connectedToServer,
                  style: context.conduitTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: context.conduitTheme.success,
                  ),
                ),
                Text(
                  hostText,
                  style: context.conduitTheme.bodySmall?.copyWith(
                    color: context.conduitTheme.textSecondary,
                    fontFamily: AppTypography.monospaceFontFamily,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcomeSection() {
    return Column(
      children: [
        BrandService.createBrandIcon(
          size: 48,
          useGradient: false,
          addShadow: false,
          context: context,
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          AppLocalizations.of(context)!.signIn,
          textAlign: TextAlign.center,
          style: context.conduitTheme.headingLarge?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          AppLocalizations.of(context)!.enterCredentials,
          textAlign: TextAlign.center,
          style: context.conduitTheme.bodyMedium?.copyWith(
            color: context.conduitTheme.textSecondary,
            height: 1.4,
          ),
        ),
      ],
    );
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

        // More options section - always show for additional auth methods
        const SizedBox(height: Spacing.lg),
        _buildMoreOptionsSection(l10n),
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
        icon = Platform.isIOS ? CupertinoIcons.lock_shield : Icons.security;
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
    return Column(
      key: const ValueKey('api_key_form'),
      children: [
        AccessibleFormField(
          label: AppLocalizations.of(context)!.token,
          hint: 'eyJ...',
          controller: _apiKeyController,
          validator: _validateJwtToken,
          obscureText: _obscurePassword,
          semanticLabel: AppLocalizations.of(context)!.enterToken,
          prefixIcon: Icon(
            Platform.isIOS
                ? CupertinoIcons.lock_shield
                : Icons.vpn_key_outlined,
            color: context.conduitTheme.iconSecondary,
          ),
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword
                  ? (Platform.isIOS
                        ? CupertinoIcons.eye_slash
                        : Icons.visibility_off)
                  : (Platform.isIOS
                        ? CupertinoIcons.eye
                        : Icons.visibility),
              color: context.conduitTheme.iconSecondary,
            ),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          onSubmitted: (_) => _signIn(),
          isRequired: true,
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
    return Column(
      key: const ValueKey('credentials_form'),
      children: [
        AccessibleFormField(
          label: AppLocalizations.of(context)!.usernameOrEmail,
          hint: AppLocalizations.of(context)!.usernameOrEmailHint,
          controller: _usernameController,
          validator: InputValidationService.combine([
            InputValidationService.validateRequired,
            (value) => InputValidationService.validateEmailOrUsername(value),
          ]),
          keyboardType: TextInputType.emailAddress,
          semanticLabel: AppLocalizations.of(context)!.usernameOrEmailHint,
          prefixIcon: Icon(
            Platform.isIOS ? CupertinoIcons.person : Icons.person_outline,
            color: context.conduitTheme.iconSecondary,
          ),
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          isRequired: true,
        ),
        const SizedBox(height: Spacing.lg),
        AccessibleFormField(
          label: AppLocalizations.of(context)!.password,
          hint: AppLocalizations.of(context)!.passwordHint,
          controller: _passwordController,
          validator: InputValidationService.combine([
            InputValidationService.validateRequired,
            (value) => InputValidationService.validateMinLength(
              value,
              1,
              fieldName: AppLocalizations.of(context)!.password,
            ),
          ]),
          obscureText: _obscurePassword,
          semanticLabel: AppLocalizations.of(context)!.passwordHint,
          prefixIcon: Icon(
            Platform.isIOS ? CupertinoIcons.lock : Icons.lock_outline,
            color: context.conduitTheme.iconSecondary,
          ),
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword
                  ? (Platform.isIOS
                        ? CupertinoIcons.eye_slash
                        : Icons.visibility_off)
                  : (Platform.isIOS
                        ? CupertinoIcons.eye
                        : Icons.visibility),
              color: context.conduitTheme.iconSecondary,
            ),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          onSubmitted: (_) => _signIn(),
          autofillHints: const [AutofillHints.password],
          isRequired: true,
        ),
      ],
    );
  }

  Widget _buildLdapForm() {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      key: const ValueKey('ldap_form'),
      children: [
        AccessibleFormField(
          label: l10n.ldapUsername,
          hint: l10n.ldapUsernameHint,
          controller: _ldapUsernameController,
          validator: InputValidationService.validateRequired,
          keyboardType: TextInputType.text,
          semanticLabel: l10n.ldapUsernameHint,
          prefixIcon: Icon(
            Platform.isIOS ? CupertinoIcons.person : Icons.person_outline,
            color: context.conduitTheme.iconSecondary,
          ),
          autofillHints: const [AutofillHints.username],
          isRequired: true,
        ),
        const SizedBox(height: Spacing.lg),
        AccessibleFormField(
          label: l10n.password,
          hint: l10n.passwordHint,
          controller: _ldapPasswordController,
          validator: InputValidationService.combine([
            InputValidationService.validateRequired,
            (value) => InputValidationService.validateMinLength(
              value,
              1,
              fieldName: l10n.password,
            ),
          ]),
          obscureText: _obscurePassword,
          semanticLabel: l10n.passwordHint,
          prefixIcon: Icon(
            Platform.isIOS ? CupertinoIcons.lock : Icons.lock_outline,
            color: context.conduitTheme.iconSecondary,
          ),
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword
                  ? (Platform.isIOS
                        ? CupertinoIcons.eye_slash
                        : Icons.visibility_off)
                  : (Platform.isIOS
                        ? CupertinoIcons.eye
                        : Icons.visibility),
              color: context.conduitTheme.iconSecondary,
            ),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          onSubmitted: (_) => _signIn(),
          autofillHints: const [AutofillHints.password],
          isRequired: true,
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          l10n.ldapDescription,
          style: context.conduitTheme.bodySmall?.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
      ],
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
                Platform.isIOS ? CupertinoIcons.lock_shield : Icons.security,
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
                icon: Platform.isIOS
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

  Widget _buildMoreOptionsSection(AppLocalizations l10n) {
    // Build list of available options - always show all available options
    // with the current one highlighted for consistency
    final options = <Widget>[];

    // Credentials option (if login form is enabled)
    if (_hasLoginFormEnabled) {
      options.add(
        _buildOptionButton(
          icon: Platform.isIOS
              ? CupertinoIcons.person_circle
              : Icons.account_circle_outlined,
          label: l10n.credentials,
          isSelected: _authMode == AuthMode.credentials,
          onTap: () => setState(() {
            _authMode = AuthMode.credentials;
            _loginError = null;
            _obscurePassword = true;
          }),
        ),
      );
    }

    // SSO option (only if WebView supported and no OAuth buttons shown above)
    if (isWebViewSupported && !_hasSsoEnabled) {
      options.add(
        _buildOptionButton(
          icon: Platform.isIOS ? CupertinoIcons.lock_shield : Icons.security,
          label: l10n.sso,
          isSelected: _authMode == AuthMode.sso,
          onTap: () => setState(() {
            _authMode = AuthMode.sso;
            _loginError = null;
            _obscurePassword = true;
          }),
        ),
      );
    }

    // LDAP option (if enabled on server)
    if (_hasLdapEnabled) {
      options.add(
        _buildOptionButton(
          icon: Platform.isIOS ? CupertinoIcons.building_2_fill : Icons.domain,
          label: l10n.ldap,
          isSelected: _authMode == AuthMode.ldap,
          onTap: () => setState(() {
            _authMode = AuthMode.ldap;
            _loginError = null;
            _obscurePassword = true;
          }),
        ),
      );
    }

    // Token option (always available as fallback)
    options.add(
      _buildOptionButton(
        icon: Platform.isIOS ? CupertinoIcons.lock_shield : Icons.vpn_key,
        label: l10n.token,
        isSelected: _authMode == AuthMode.token,
        onTap: () => setState(() {
          _authMode = AuthMode.token;
          _loginError = null;
          _obscurePassword = true;
        }),
      ),
    );

    if (options.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        // Expandable header
        InkWell(
          onTap: () => setState(() => _showMoreOptions = !_showMoreOptions),
          borderRadius: BorderRadius.circular(AppBorderRadius.button),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  l10n.moreSignInOptions,
                  style: context.conduitTheme.bodySmall?.copyWith(
                    color: context.conduitTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                AnimatedRotation(
                  duration: AnimationDuration.microInteraction,
                  turns: _showMoreOptions ? 0.5 : 0,
                  child: Icon(
                    Platform.isIOS
                        ? CupertinoIcons.chevron_down
                        : Icons.expand_more,
                    color: context.conduitTheme.iconSecondary,
                    size: IconSize.small,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Options (collapsed by default unless a secondary option is selected)
        AnimatedCrossFade(
          duration: AnimationDuration.microInteraction,
          sizeCurve: Curves.easeInOutCubic,
          crossFadeState:
              _showMoreOptions ||
                  _authMode == AuthMode.ldap ||
                  _authMode == AuthMode.token ||
                  (_authMode == AuthMode.sso && !_hasSsoEnabled)
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: Spacing.md),
            child: Row(
              children: [
                for (int i = 0; i < options.length; i++) ...[
                  if (i > 0) const SizedBox(width: Spacing.sm),
                  Expanded(child: options[i]),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOptionButton({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: isSelected
          ? context.conduitTheme.buttonPrimary.withValues(alpha: 0.1)
          : context.conduitTheme.surfaceContainer.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(AppBorderRadius.small),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        child: Container(
          padding: const EdgeInsets.symmetric(
            vertical: Spacing.md,
            horizontal: Spacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppBorderRadius.small),
            border: Border.all(
              color: isSelected
                  ? context.conduitTheme.buttonPrimary
                  : context.conduitTheme.dividerColor.withValues(alpha: 0.5),
              width: BorderWidth.standard,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: IconSize.small,
                color: isSelected
                    ? context.conduitTheme.buttonPrimary
                    : context.conduitTheme.iconSecondary,
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                label,
                style: context.conduitTheme.bodySmall?.copyWith(
                  color: isSelected
                      ? context.conduitTheme.buttonPrimary
                      : context.conduitTheme.textSecondary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.lg),
      child: ConduitButton(
        text: buttonText,
        icon: _isSigningIn
            ? null
            : (Platform.isIOS
                  ? CupertinoIcons.arrow_right
                  : Icons.arrow_forward),
        onPressed: _isSigningIn ? null : _signIn,
        isLoading: _isSigningIn,
        isFullWidth: true,
      ),
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
              Platform.isIOS
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

import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../../../core/auth/webview_cookie_helper.dart';
import '../../../core/models/server_config.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/worker_manager.dart';
import '../../../core/services/input_validation_service.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/widgets/error_boundary.dart';
import '../providers/unified_auth_providers.dart';
import '../../../shared/services/brand_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'proxy_auth_page.dart';

class ServerConnectionPage extends ConsumerStatefulWidget {
  const ServerConnectionPage({super.key});

  @override
  ConsumerState<ServerConnectionPage> createState() =>
      _ServerConnectionPageState();
}

class _ServerConnectionPageState extends ConsumerState<ServerConnectionPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _urlController = TextEditingController();
  final Map<String, String> _customHeaders = {};
  final TextEditingController _headerKeyController = TextEditingController();
  final TextEditingController _headerValueController = TextEditingController();

  String? _connectionError;
  bool _isConnecting = false;
  bool _showAdvancedSettings = false;
  bool _allowSelfSignedCertificates = false;

  @override
  void initState() {
    super.initState();
    _prefillFromState();
  }

  Future<void> _prefillFromState() async {
    final activeServer = await ref.read(activeServerProvider.future);
    if (!mounted || activeServer == null) return;
    setState(() {
      _urlController.text = activeServer.url;
      _allowSelfSignedCertificates = activeServer.allowSelfSignedCertificates;
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _headerKeyController.dispose();
    _headerValueController.dispose();
    super.dispose();
  }

  Future<void> _connectToServer() async {
    DebugLogger.log('Connect button pressed', scope: 'auth/connection');

    final urlValue = _urlController.text.trim();
    DebugLogger.log('URL value: "$urlValue"', scope: 'auth/connection');

    // Check what validation would return
    final validationResult = InputValidationService.validateUrl(urlValue);
    DebugLogger.log(
      'URL validation result: ${validationResult ?? "valid"}',
      scope: 'auth/connection',
    );

    if (!_formKey.currentState!.validate()) {
      DebugLogger.log('Form validation failed', scope: 'auth/connection');
      return;
    }

    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });

    try {
      String url = _validateAndFormatUrl(_urlController.text.trim());

      final tempConfig = ServerConfig(
        id: const Uuid().v4(),
        name: _deriveServerNameFromUrl(url),
        url: url,
        customHeaders: Map<String, String>.from(_customHeaders),
        isActive: true,
        allowSelfSignedCertificates: _allowSelfSignedCertificates,
      );

      final workerManager = ref.read(workerManagerProvider);
      final api = ApiService(
        serverConfig: tempConfig,
        workerManager: workerManager,
      );

      // First check connectivity with proxy detection
      DebugLogger.log('Checking server health...', scope: 'auth/connection');
      final healthResult = await api.checkHealthWithProxyDetection();
      DebugLogger.log(
        'Health check result: $healthResult',
        scope: 'auth/connection',
      );

      // Handle proxy authentication requirement
      if (healthResult == HealthCheckResult.proxyAuthRequired) {
        DebugLogger.log(
          'Server behind proxy detected, prompting for proxy auth',
          scope: 'auth/connection',
        );
        await _handleProxyAuth(tempConfig, api, workerManager);
        return;
      }

      if (healthResult == HealthCheckResult.unreachable) {
        throw Exception(
          'Could not reach the server. Please check the address.',
        );
      }

      if (healthResult == HealthCheckResult.unhealthy) {
        throw Exception(
          'Server responded but may not be healthy. Please try again.',
        );
      }

      // Then verify it's actually an OpenWebUI server and get its config
      DebugLogger.log(
        'Verifying OpenWebUI server...',
        scope: 'auth/connection',
      );
      final backendConfig = await api.verifyAndGetConfig();
      DebugLogger.log(
        'OpenWebUI verification result: ${backendConfig != null}',
        scope: 'auth/connection',
      );
      if (backendConfig == null) {
        throw Exception('This does not appear to be an Open-WebUI server.');
      }

      DebugLogger.log(
        'Server validation passed, navigating to auth page',
        scope: 'auth/connection',
      );

      // Don't save server config yet - wait until authentication succeeds
      // The config is passed to the authentication page along with backend config
      if (mounted) {
        final authFlowConfig = AuthFlowConfig(
          serverConfig: tempConfig,
          backendConfig: backendConfig,
        );
        context.pushNamed(RouteNames.authentication, extra: authFlowConfig);
      }
    } catch (e, stack) {
      DebugLogger.error(
        'server-connection-error',
        scope: 'auth/connection',
        error: e,
        stackTrace: stack,
      );
      if (mounted) {
        setState(() {
          _connectionError = _formatConnectionError(e.toString());
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  /// Handles proxy authentication flow.
  ///
  /// Opens the proxy auth page in a WebView where the user authenticates
  /// through the proxy (oauth2-proxy, Pangolin, etc.).
  ///
  /// After proxy auth completes, the cookies are captured and added to
  /// the server config. Then the normal authentication flow proceeds.
  Future<void> _handleProxyAuth(
    ServerConfig tempConfig,
    ApiService api,
    WorkerManager workerManager,
  ) async {
    // Check if WebView is supported
    if (!isWebViewSupported) {
      throw Exception(
        AppLocalizations.of(context)?.proxyAuthPlatformNotSupported ??
            'Proxy authentication requires a mobile device.',
      );
    }

    // Show proxy auth page
    final proxyConfig = ProxyAuthConfig(serverConfig: tempConfig);

    if (!mounted) return;

    final result = await context.pushNamed<ProxyAuthResult>(
      RouteNames.proxyAuth,
      extra: proxyConfig,
    );

    if (!mounted) return;

    // If user cancelled or proxy auth failed, show error
    if (result == null || !result.success) {
      setState(() {
        _connectionError =
            AppLocalizations.of(context)?.proxyAuthFailed ??
            'Proxy authentication was cancelled or failed.';
        _isConnecting = false;
      });
      return;
    }

    DebugLogger.log(
      'Proxy auth completed, captured ${result.cookies?.length ?? 0} cookies, '
      'JWT: ${result.isFullyAuthenticated}',
      scope: 'auth/connection',
    );

    // Build updated headers with proxy cookies
    final updatedHeaders = Map<String, String>.from(tempConfig.customHeaders);
    if (result.cookies != null && result.cookies!.isNotEmpty) {
      // Format cookies as Cookie header
      final proxyCookieHeader = result.cookies!.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');

      // Merge with existing Cookie header if present (from advanced settings)
      final existingCookies = updatedHeaders['Cookie'];
      if (existingCookies != null && existingCookies.isNotEmpty) {
        updatedHeaders['Cookie'] = '$existingCookies; $proxyCookieHeader';
        DebugLogger.log(
          'Merged ${result.cookies!.length} proxy cookies with existing Cookie header',
          scope: 'auth/connection',
        );
      } else {
        updatedHeaders['Cookie'] = proxyCookieHeader;
        DebugLogger.log(
          'Added Cookie header with ${result.cookies!.length} cookies',
          scope: 'auth/connection',
        );
      }
    }

    // Create updated config with proxy cookies (and possibly JWT token)
    final configWithCookies = ServerConfig(
      id: tempConfig.id,
      name: tempConfig.name,
      url: tempConfig.url,
      customHeaders: updatedHeaders,
      isActive: tempConfig.isActive,
      allowSelfSignedCertificates: tempConfig.allowSelfSignedCertificates,
      // If we got a JWT token, store it as apiKey for API auth
      apiKey: result.jwtToken,
    );

    // Create new API service with updated config
    final apiWithCookies = ApiService(
      serverConfig: configWithCookies,
      workerManager: workerManager,
      // If we have a JWT token, use it as auth token
      authToken: result.jwtToken,
    );

    // Now verify it's an OpenWebUI server
    DebugLogger.log(
      'Verifying OpenWebUI server with proxy cookies...',
      scope: 'auth/connection',
    );

    final backendConfig = await apiWithCookies.verifyAndGetConfig();
    if (backendConfig == null) {
      if (mounted) {
        setState(() {
          _connectionError =
              'Could not verify OpenWebUI server. The proxy cookies may '
              'have expired or be invalid. Please try again.';
          _isConnecting = false;
        });
      }
      return;
    }

    // Check if user is already fully authenticated via trusted headers
    // (e.g., oauth2-proxy with X-Forwarded-Email)
    if (result.isFullyAuthenticated) {
      DebugLogger.log(
        'User already authenticated via trusted headers, '
        'skipping sign-in page',
        scope: 'auth/connection',
      );

      // Save the server config and go directly to chat
      await _completeAuthWithToken(
        configWithCookies,
        result.jwtToken!,
      );
      return;
    }

    DebugLogger.log(
      'Server validated with proxy cookies, navigating to auth page',
      scope: 'auth/connection',
    );

    if (mounted) {
      final authFlowConfig = AuthFlowConfig(
        serverConfig: configWithCookies,
        backendConfig: backendConfig,
      );
      context.pushNamed(RouteNames.authentication, extra: authFlowConfig);
    }
  }

  /// Completes authentication when user is already authenticated via
  /// trusted headers (oauth2-proxy with X-Forwarded-Email).
  Future<void> _completeAuthWithToken(
    ServerConfig serverConfig,
    String token,
  ) async {
    try {
      // Save the server config first (needed for auth actions)
      await _saveServerConfig(serverConfig);

      // Use the same auth flow as SSO - loginWithApiKey handles
      // saving credentials and updating auth state
      final authActions = ref.read(authActionsProvider);
      final success = await authActions.loginWithApiKey(
        token,
        rememberCredentials: true,
        authType: 'proxy-sso', // Mark as proxy-obtained token
      );

      if (!mounted) return;

      if (success) {
        DebugLogger.auth('Proxy SSO login successful');
        // Navigation is handled automatically by the router when auth state
        // changes to authenticated. The router redirect will navigate to chat.
      } else {
        throw Exception('Login failed');
      }
    } catch (e, stack) {
      DebugLogger.error(
        'Failed to complete auth with token',
        scope: 'auth/connection',
        error: e,
        stackTrace: stack,
      );
      if (mounted) {
        setState(() {
          _connectionError =
              'Authentication failed. Please try signing in manually.';
          _isConnecting = false;
        });
      }
    }
  }

  /// Saves server config (extracted from authentication_page.dart)
  Future<void> _saveServerConfig(ServerConfig config) async {
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveServerConfigs([config]);
    await storage.setActiveServerId(config.id);
    ref.invalidate(serverConfigsProvider);
    ref.invalidate(activeServerProvider);
  }

  String _validateAndFormatUrl(String input) {
    if (input.isEmpty) {
      throw Exception(AppLocalizations.of(context)!.serverUrlEmpty);
    }

    // Clean up the input
    String url = input.trim();

    // Add protocol if missing
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }

    // Remove trailing slash
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    // Parse and validate the URI
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw Exception(AppLocalizations.of(context)!.invalidUrlFormat);
    }

    // Validate scheme
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw Exception(AppLocalizations.of(context)!.onlyHttpHttps);
    }

    // Validate host
    if (uri.host.isEmpty) {
      throw Exception(AppLocalizations.of(context)!.serverAddressRequired);
    }

    // Validate port if specified
    if (uri.hasPort) {
      if (uri.port < 1 || uri.port > 65535) {
        throw Exception(AppLocalizations.of(context)!.portRange);
      }
    }

    // Validate IP address format if it looks like an IP
    if (_isIPAddress(uri.host) && !_isValidIPAddress(uri.host)) {
      throw Exception(AppLocalizations.of(context)!.invalidIpFormat);
    }

    return url;
  }

  bool _isIPAddress(String host) {
    return RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host);
  }

  bool _isValidIPAddress(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;

    for (final part in parts) {
      final num = int.tryParse(part);
      if (num == null || num < 0 || num > 255) return false;
    }
    return true;
  }

  String _deriveServerNameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host.isNotEmpty) return uri.host;
    } catch (_) {}
    return 'Server';
  }

  String _formatConnectionError(String error) {
    // Clean up the error message
    String cleanError = error.replaceFirst('Exception: ', '');

    // Handle specific error types
    if (error.contains('SocketException')) {
      return AppLocalizations.of(context)!.weCouldntReachServer;
    } else if (error.contains('timeout')) {
      return AppLocalizations.of(context)!.connectionTimedOut;
    } else if (error.contains('Server URL cannot be empty')) {
      return AppLocalizations.of(context)!.serverUrlEmpty;
    } else if (error.contains('Invalid URL format')) {
      return AppLocalizations.of(context)!.invalidUrlFormat;
    } else if (error.contains('Only HTTP and HTTPS')) {
      return AppLocalizations.of(context)!.useHttpOrHttpsOnly;
    } else if (error.contains('Server address is required')) {
      return cleanError;
    } else if (error.contains('Port must be between')) {
      return cleanError;
    } else if (error.contains('Invalid IP address format')) {
      return cleanError;
    } else if (error.contains(
      'This does not appear to be an Open-WebUI server',
    )) {
      return AppLocalizations.of(context)!.serverNotOpenWebUI;
    }

    return AppLocalizations.of(context)!.couldNotConnectGeneric;
  }

  @override
  Widget build(BuildContext context) {
    final reviewerMode = ref.watch(reviewerModeProvider);
    final safePadding = MediaQuery.of(context).padding;

    return ErrorBoundary(
      child: Scaffold(
        backgroundColor: context.conduitTheme.surfaceBackground,
        body: Column(
          children: [
            // Main content
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: Spacing.pagePadding,
                        right: Spacing.pagePadding,
                        top: safePadding.top + Spacing.xxl,
                      ),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Brand header with welcome text
                            _buildHeader(reviewerMode),

                            const SizedBox(height: Spacing.xxl),

                            // Reviewer mode demo (if enabled)
                            if (reviewerMode) ...[
                              _buildReviewerModeSection(),
                              const SizedBox(height: Spacing.xl),
                            ],

                            // Server connection form
                            _buildServerForm(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Bottom action button
            Padding(
              padding: EdgeInsets.fromLTRB(
                Spacing.pagePadding,
                Spacing.md,
                Spacing.pagePadding,
                safePadding.bottom + Spacing.md,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: _buildConnectButton(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool reviewerMode) {
    final theme = context.conduitTheme;

    return Column(
      children: [
        // Brand icon with gradient container
        GestureDetector(
          onLongPress: () async {
            HapticFeedback.mediumImpact();
            await ref.read(reviewerModeProvider.notifier).toggle();
            if (!mounted) return;
            final enabled = ref.read(reviewerModeProvider);
            AdaptiveSnackBar.show(
              context,
              message: enabled
                  ? 'Reviewer Mode enabled: Demo without server'
                  : 'Reviewer Mode disabled',
              type: AdaptiveSnackBarType.info,
            );
          },
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      theme.buttonPrimary.withValues(alpha: 0.12),
                      theme.buttonPrimary.withValues(alpha: 0.04),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: theme.buttonPrimary.withValues(alpha: 0.15),
                    width: BorderWidth.standard,
                  ),
                ),
                child: Center(
                  child: BrandService.createBrandIcon(
                    size: 36,
                    useGradient: true,
                    context: context,
                  ),
                ),
              ),
              // Reviewer mode badge
              if (reviewerMode)
                Positioned(
                  bottom: -8,
                  child: ConduitBadge(
                    text: AppLocalizations.of(context)!.demoBadge,
                    backgroundColor: theme.warning.withValues(alpha: 0.15),
                    textColor: theme.warning,
                    isCompact: true,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),

        // Title
        Text(
          AppLocalizations.of(context)!.connectToServer,
          textAlign: TextAlign.center,
          style: theme.headingLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: AppTypography.letterSpacingTight,
          ),
        ),
        const SizedBox(height: Spacing.sm),

        // Subtitle
        Text(
          AppLocalizations.of(context)!.enterServerAddress,
          textAlign: TextAlign.center,
          style: theme.bodyMedium?.copyWith(
            color: theme.textSecondary,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildReviewerModeSection() {
    return ConduitCard(
      isElevated: false,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Platform.isIOS ? CupertinoIcons.wand_stars : Icons.auto_awesome,
                color: context.conduitTheme.warning,
                size: IconSize.medium,
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizations.of(context)!.demoModeActive,
                      style: context.conduitTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: context.conduitTheme.warning,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      AppLocalizations.of(context)!.skipServerSetupTryDemo,
                      style: context.conduitTheme.bodySmall?.copyWith(
                        color: context.conduitTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          ConduitButton(
            text: AppLocalizations.of(context)!.enterDemo,
            icon: Platform.isIOS ? CupertinoIcons.play_fill : Icons.play_arrow,
            onPressed: () {
              context.go(Routes.chat);
            },
            isSecondary: true,
            isFullWidth: true,
          ),
        ],
      ),
    );
  }

  Widget _buildServerForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveTextFormField(
          controller: _urlController,
          placeholder: AppLocalizations.of(context)!.serverUrlHint,
          validator: (value) {
            final v = value ?? _urlController.text;
            return InputValidationService.combine([
              InputValidationService.validateRequired,
              (val) =>
                  InputValidationService.validateUrl(val, required: true),
            ])(v);
          },
          keyboardType: TextInputType.url,
          onSubmitted: (_) => _connectToServer(),
          prefixIcon: Icon(
            Platform.isIOS ? CupertinoIcons.globe : Icons.public,
            color: context.conduitTheme.iconSecondary,
          ),
          autofillHints: const [AutofillHints.url],
        ),

        if (_connectionError != null) ...[
          const SizedBox(height: Spacing.md),
          _buildErrorMessage(_connectionError!),
        ],

        const SizedBox(height: Spacing.lg),

        // Advanced settings
        _buildAdvancedSettings(),
      ],
    );
  }

  Widget _buildAdvancedSettings() {
    final theme = context.conduitTheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppBorderRadius.card),
        border: Border.all(
          color: theme.cardBorder,
          width: BorderWidth.thin,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Toggle header
          InkWell(
            onTap: () => setState(
              () => _showAdvancedSettings = !_showAdvancedSettings,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.md,
              ),
              child: Row(
                children: [
                  Icon(
                    Platform.isIOS
                        ? CupertinoIcons.gear_alt
                        : Icons.tune_rounded,
                    color: theme.iconSecondary,
                    size: IconSize.medium,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context)!.advancedSettings,
                      style: theme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: theme.textPrimary,
                      ),
                    ),
                  ),
                  if (_customHeaders.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.sm),
                      child: ConduitBadge(
                        text: '${_customHeaders.length}',
                        backgroundColor: theme.buttonPrimary
                            .withValues(alpha: 0.1),
                        textColor: theme.buttonPrimary,
                        isCompact: true,
                      ),
                    ),
                  AnimatedRotation(
                    duration: AnimationDuration.microInteraction,
                    turns: _showAdvancedSettings ? 0.5 : 0,
                    child: Icon(
                      Platform.isIOS
                          ? CupertinoIcons.chevron_down
                          : Icons.expand_more,
                      color: theme.iconSecondary,
                      size: IconSize.medium,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Expandable content
          AnimatedCrossFade(
            duration: AnimationDuration.microInteraction,
            sizeCurve: Curves.easeInOutCubic,
            crossFadeState: _showAdvancedSettings
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: _buildAdvancedSettingsContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedSettingsContent() {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(
          height: BorderWidth.thin,
          thickness: BorderWidth.thin,
          color: theme.cardBorder,
        ),

        // Self-signed certificates toggle
        Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.allowSelfSignedCertificates,
                      style: theme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      l10n.allowSelfSignedCertificatesDescription,
                      style: TextStyle(
                        fontSize: AppTypography.labelSmall,
                        color: theme.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.md),
              AdaptiveSwitch(
                value: _allowSelfSignedCertificates,
                onChanged: (value) {
                  setState(() {
                    _allowSelfSignedCertificates = value;
                  });
                },
                activeColor: theme.buttonPrimary,
              ),
            ],
          ),
        ),

        Divider(
          height: BorderWidth.thin,
          thickness: BorderWidth.thin,
          color: theme.cardBorder,
        ),

        // Custom headers section
        Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.customHeaders,
                          style: theme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: Spacing.xxs),
                        Text(
                          l10n.customHeadersDescription,
                          style: TextStyle(
                            fontSize: AppTypography.labelSmall,
                            color: theme.textSecondary,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  if (_customHeaders.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.xs),
                      child: Text(
                        '${_customHeaders.length}/10',
                        style: TextStyle(
                          fontSize: AppTypography.labelSmall,
                          color: _customHeaders.length >= 10
                              ? theme.error
                              : theme.textTertiary,
                        ),
                      ),
                    ),
                  ConduitIconButton(
                    icon: Platform.isIOS
                        ? CupertinoIcons.plus
                        : Icons.add_rounded,
                    onPressed: _customHeaders.length >= 10
                        ? null
                        : _addCustomHeader,
                    tooltip: _customHeaders.length >= 10
                        ? l10n.maximumHeadersReached
                        : l10n.addHeader,
                    backgroundColor: _customHeaders.length >= 10
                        ? theme.surfaceContainer
                        : theme.buttonPrimary,
                    iconColor: _customHeaders.length >= 10
                        ? theme.textDisabled
                        : theme.buttonPrimaryText,
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),

              // Header input row
              Row(
                children: [
                  Expanded(
                    child: AdaptiveTextFormField(
                      placeholder: 'X-Custom-Header',
                      controller: _headerKeyController,
                      validator: (value) => _validateHeaderKey(
                        value ?? _headerKeyController.text,
                      ),
                      keyboardType: TextInputType.text,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: AdaptiveTextFormField(
                      placeholder: l10n.headerValueHint,
                      controller: _headerValueController,
                      validator: (value) => _validateHeaderValue(
                        value ?? _headerValueController.text,
                      ),
                      keyboardType: TextInputType.text,
                    ),
                  ),
                ],
              ),

              // Header list
              if (_customHeaders.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                _buildCustomHeadersList(),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCustomHeadersList() {
    final theme = context.conduitTheme;

    return Column(
      children: _customHeaders.entries.map((entry) {
        return Padding(
          padding: const EdgeInsets.only(bottom: Spacing.xs),
          child: Container(
            padding: const EdgeInsets.only(
              left: Spacing.md,
              top: Spacing.sm,
              bottom: Spacing.sm,
              right: Spacing.xs,
            ),
            decoration: BoxDecoration(
              color: theme.surfaceBackground,
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
              border: Border.all(
                color: theme.cardBorder,
                width: BorderWidth.thin,
              ),
            ),
            child: Row(
              children: [
                Text(
                  entry.key,
                  style: theme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.buttonPrimary,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    entry.value,
                    style: theme.bodySmall?.copyWith(
                      color: theme.textSecondary,
                      fontFamily: AppTypography.monospaceFontFamily,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ConduitIconButton(
                  icon: Platform.isIOS
                      ? CupertinoIcons.xmark
                      : Icons.close_rounded,
                  onPressed: () => _removeCustomHeader(entry.key),
                  tooltip: AppLocalizations.of(context)!.removeHeader,
                  backgroundColor: Colors.transparent,
                  iconColor: theme.textTertiary,
                  isCompact: true,
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildConnectButton() {
    return ConduitButton(
      text: _isConnecting
          ? AppLocalizations.of(context)!.connecting
          : AppLocalizations.of(context)!.connectToServerButton,
      icon: _isConnecting
          ? null
          : (Platform.isIOS
                ? CupertinoIcons.arrow_right
                : Icons.arrow_forward),
      onPressed: _isConnecting ? null : _connectToServer,
      isLoading: _isConnecting,
      isFullWidth: true,
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

  void _addCustomHeader() {
    final key = _headerKeyController.text.trim();
    final value = _headerValueController.text.trim();

    if (key.isEmpty || value.isEmpty) return;

    // Validate header name
    final keyValidation = _validateHeaderKey(key);
    if (keyValidation != null) {
      _showHeaderError(keyValidation);
      return;
    }

    // Validate header value
    final valueValidation = _validateHeaderValue(value);
    if (valueValidation != null) {
      _showHeaderError(valueValidation);
      return;
    }

    // Check for duplicates
    if (_customHeaders.containsKey(key)) {
      _showHeaderError(AppLocalizations.of(context)!.headerAlreadyExists(key));
      return;
    }

    // Check header count limit
    if (_customHeaders.length >= 10) {
      _showHeaderError(AppLocalizations.of(context)!.maxHeadersReachedDetail);
      return;
    }

    setState(() {
      _customHeaders[key] = value;
      _headerKeyController.clear();
      _headerValueController.clear();
    });
    HapticFeedback.lightImpact();
  }

  String? _validateHeaderKey(String key) {
    // Allow empty - header fields are optional
    if (key.isEmpty) return null;
    if (key.length > 64) return AppLocalizations.of(context)!.headerNameTooLong;

    // Check for valid characters (RFC 7230: token characters)
    if (!RegExp(r'^[a-zA-Z0-9!#$&\-^_`|~]+$').hasMatch(key)) {
      return AppLocalizations.of(context)!.headerNameInvalidChars;
    }

    // Check for reserved headers that should not be overridden
    final lowerKey = key.toLowerCase();
    final reservedHeaders = {
      'authorization',
      'content-type',
      'content-length',
      'host',
      'user-agent',
      'accept',
      'accept-encoding',
      'connection',
      'transfer-encoding',
      'upgrade',
      'via',
      'warning',
    };

    if (reservedHeaders.contains(lowerKey)) {
      return AppLocalizations.of(context)!.headerNameReserved(key);
    }

    return null;
  }

  String? _validateHeaderValue(String value) {
    // Allow empty - header fields are optional
    if (value.isEmpty) return null;
    if (value.length > 1024) {
      return AppLocalizations.of(context)!.headerValueTooLong;
    }

    // Check for valid characters (no control characters except tab)
    for (int i = 0; i < value.length; i++) {
      final char = value.codeUnitAt(i);
      // Allow printable ASCII (32-126) and tab (9)
      if (char != 9 && (char < 32 || char > 126)) {
        return AppLocalizations.of(context)!.headerValueInvalidChars;
      }
    }

    // Check for security-sensitive patterns
    if (value.toLowerCase().contains('script') ||
        value.contains('<') ||
        value.contains('>')) {
      return AppLocalizations.of(context)!.headerValueUnsafe;
    }

    return null;
  }

  void _showHeaderError(String message) {
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: AdaptiveSnackBarType.error,
      duration: const Duration(seconds: 3),
    );
  }

  void _removeCustomHeader(String key) {
    setState(() {
      _customHeaders.remove(key);
    });
    HapticFeedback.lightImpact();
  }
}

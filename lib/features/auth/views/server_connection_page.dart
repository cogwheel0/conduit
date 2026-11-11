import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:uuid/uuid.dart';
import 'package:conduit/l10n/app_localizations.dart';

export '../services/server_address_service.dart';

import '../../../platform/webview_cookie_helper.dart';

import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/auth/proxy_session.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/auth/openwebui_address_check.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart'
    show proxySignInForRouteEditingProvider;
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show accountAdditionOriginProvider, pendingSignInAbandonableProvider;
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/services/api_service.dart';

import 'package:conduit_core/services/worker_manager.dart';

import '../../../shared/services/input_validation_service.dart';
import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'proxy_auth_page.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../widgets/auth_grouped_form.dart';
import '../services/server_address_service.dart';
import '../../profile/widgets/account_actions.dart'
    show
        abandonAddedAccount,
        confirmChangingAddressInUse,
        confirmLeavingActiveAccount;

/// What the account sheet hands the connection page to carry on from.
///
/// With [authFlow], the sheet checked [config]'s server and the page goes
/// straight on to sign-in. Without, the page connects as it opens: to
/// [config], whose proxy wants its own sign-in, or else to the saved server
/// [serverId].
@immutable
class ServerConnectionHandoff {
  const ServerConnectionHandoff({this.config, this.authFlow, this.serverId})
    : assert(authFlow == null || config != null),
      assert(config != null || serverId != null);

  final ServerConfig? config;
  final AuthFlowConfig? authFlow;
  final String? serverId;
}

class ServerConnectionPage extends ConsumerStatefulWidget {
  const ServerConnectionPage({
    super.key,
    this.addingAccount = false,
    this.serverId,
    this.routesOfServerId,
    this.endpointId,
    this.handoff,
    this.onChecked,
    this.header,
  });

  /// The address group's header on iOS, when the form shares the account
  /// sheet with other choices, such as the saved servers.
  final String? header;

  /// What the account sheet checked, to carry on from.
  final ServerConnectionHandoff? handoff;

  /// Set when the form is part of the account sheet: it brings no page of
  /// its own, starts empty, and hands each server it checks -- or finds
  /// behind a proxy -- here rather than going on to sign in itself.
  final void Function(ServerConnectionHandoff checked)? onChecked;

  /// Adding or editing one address of the saved server with this id, rather
  /// than connecting to sign in. The address is checked the same way, then
  /// saved as a route to that server.
  final String? routesOfServerId;

  /// The address being edited; null adds a new one.
  final String? endpointId;

  /// Connecting to sign in to another account while one is signed in. The
  /// form starts empty -- or from [serverId]'s saved route -- rather than
  /// from the active account, and proxy sign-in starts from a clean browser
  /// session so it cannot sign straight back in as the current user.
  final bool addingAccount;

  /// The saved server another account is being added on, when there is one.
  final String? serverId;

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
  final TextEditingController _mtlsPrivateKeyPasswordController =
      TextEditingController();
  final FocusNode _headerValueFocusNode = FocusNode();
  final FocusNode _urlFocusNode = FocusNode();

  String? _connectionError;
  String? _mtlsCertificateChainPem;
  String? _mtlsCertificateLabel;
  String? _mtlsPrivateKeyPem;
  String? _mtlsPrivateKeyLabel;
  bool _isConnecting = false;
  bool _showAdvancedSettings = false;
  bool _allowSelfSignedCertificates = false;

  ConnectionAttemptState get _attemptState {
    final l10n = AppLocalizations.of(context)!;
    if (_isConnecting) {
      return ConnectionAttemptState.connecting(l10n.connecting);
    }
    final error = _connectionError;
    if (error != null) return ConnectionAttemptState.failed(error);
    return const ConnectionAttemptState.idle();
  }

  bool get _canAddCustomHeader =>
      _customHeaders.length < 10 &&
      _headerKeyController.text.trim().isNotEmpty &&
      _headerValueController.text.trim().isNotEmpty;

  /// Ends the account addition this page was opened for, as it goes.
  void Function()? _endAccountAddition;
  final TextEditingController _routeLabelController = TextEditingController();

  /// The id an address added here is saved under. One per editor, so saving
  /// again after a save that stored the address and then failed edits it
  /// rather than adding it twice.
  final String _addedEndpointId = const Uuid().v4();

  bool get _editingRoutes => widget.routesOfServerId != null;

  bool get _embedded => widget.onChecked != null;

  /// The saved server the form was filled in from, when it was.
  OpenWebUiServer? _savedServer;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_resetTransientAttempt);
    if (_editingRoutes) {
      _prefillFromRoute();
    } else if (_embedded) {
      // A new server: the sheet offers the saved ones itself.
    } else if (widget.addingAccount) {
      // openAddAccount began the addition before opening this page, which the
      // router needs; the page only ends it when it goes.
      _endAccountAddition = ref
          .read(accountAdditionOriginProvider.notifier)
          .endLater();
      if (widget.handoff case final handoff?) {
        unawaited(_carryOn(handoff));
      } else {
        _prefillFromSavedServer();
      }
    } else if (widget.handoff case final handoff?) {
      unawaited(_carryOn(handoff));
    } else {
      _prefillFromState();
    }
  }

  /// Carries on from what the account sheet checked: on to sign-in when the
  /// server passed, else connecting from here -- through its proxy's
  /// sign-in, or to the saved server the sheet named.
  Future<void> _carryOn(ServerConnectionHandoff handoff) async {
    final config = handoff.config;
    if (config != null) {
      _applyConfig(config);
    } else {
      await _prefillFromSavedServer();
      // Unread, the form stays empty and says why: connecting would only
      // ask for an address over that.
      if (!mounted || _urlController.text.trim().isEmpty) return;
    }
    // Pushed from the page, which must be in the tree first.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final authFlow = handoff.authFlow;
    if (authFlow != null) {
      unawaited(context.pushNamed(RouteNames.authentication, extra: authFlow));
    } else {
      await _connectToServer();
    }
  }

  Future<void> _prefillFromRoute() async {
    final endpointId = widget.endpointId;
    if (endpointId == null) return;
    // As for a saved server's: what the user typed while it is read stays.
    final untouched = (_formContents(), _routeLabelController.text);
    final OpenWebUiRegistry registry;
    try {
      registry = await ref
          .read(optimizedStorageServiceProvider)
          .getOpenWebUiRegistryStrict();
    } catch (error, stackTrace) {
      // Nothing awaits this; say why the form starts empty.
      DebugLogger.error(
        'route-edit-prefill-failed',
        scope: 'auth/accounts',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _connectionError = AppLocalizations.of(context)!.errorMessage;
      });
      return;
    }
    final endpoint = registry
        .server(widget.routesOfServerId!)
        ?.endpoint(endpointId);
    if (!mounted || endpoint == null) return;
    if ((_formContents(), _routeLabelController.text) != untouched) return;
    _routeLabelController.text = endpoint.label ?? '';
    _applyEndpoint(endpoint);
  }

  void _applyEndpoint(OpenWebUiEndpoint endpoint) {
    setState(() {
      _urlController.text = endpoint.url;
      _customHeaders
        ..clear()
        ..addAll(endpoint.customHeaders);
      _showAdvancedSettings =
          endpoint.allowSelfSignedCertificates ||
          endpoint.customHeaders.isNotEmpty ||
          (!kIsWeb && endpoint.mtlsPrivateKeyPem != null);
      _allowSelfSignedCertificates = endpoint.allowSelfSignedCertificates;
      _mtlsCertificateChainPem = kIsWeb
          ? null
          : endpoint.mtlsCertificateChainPem;
      _mtlsCertificateLabel = kIsWeb ? null : endpoint.mtlsCertificateLabel;
      _mtlsPrivateKeyPem = kIsWeb ? null : endpoint.mtlsPrivateKeyPem;
      _mtlsPrivateKeyLabel = kIsWeb ? null : endpoint.mtlsPrivateKeyLabel;
      _mtlsPrivateKeyPasswordController.text = kIsWeb
          ? ''
          : (endpoint.mtlsPrivateKeyPassword ?? '');
    });
  }

  /// Saves [verified] -- an address that answered as an Open WebUI server --
  /// as a route to the server being edited.
  ///
  /// The address must also know the server's accounts: a token one of them
  /// holds has to name the same user through it. Otherwise it is another
  /// server (or another account behind the same proxy), and every account on
  /// this one would start sending its session there. Returns whether it
  /// saved.
  ///
  /// [sessionRevision] is [OptimizedStorageService.sessionRevocationRevision]
  /// as it was before the address was first contacted: a proxy cookie
  /// captured for it is not kept once a sign-out has revoked cookies since.
  Future<bool> _saveRoute(ServerConfig verified, int sessionRevision) async {
    final l10n = AppLocalizations.of(context)!;
    // The editor can be left while a save runs, and the widget's ref is gone
    // with it; what follows the save must still run.
    final container = ProviderScope.containerOf(context, listen: false);
    final outcome = await saveVerifiedServerAddress(
      container,
      serverId: widget.routesOfServerId!,
      endpointId: widget.endpointId,
      addedEndpointId: _addedEndpointId,
      label: _routeLabelController.text,
      verified: verified,
      sessionRevision: sessionRevision,
      l10n: l10n,
      confirmSendingSession: (address) async {
        if (!mounted) return false;
        return ThemedDialogs.confirm(
          context,
          title: l10n.accountsAddressConfirmTitle,
          message: l10n.accountsAddressConfirmMessage(address.authority),
          confirmText: l10n.accountsAddressConfirmAction,
        );
      },
      confirmChangingInUse: () async =>
          mounted && await confirmChangingAddressInUse(context, container),
      // Left while the address was checked: Back abandons the edit, and the
      // address the server's accounts use stays as it was.
      stillWanted: () => mounted,
    );
    switch (outcome) {
      case ServerAddressSaved():
        if (mounted) {
          ConduitHaptics.success();
          context.pop();
        }
        return true;
      case ServerAddressNotSaved(:final message):
        if (message != null && mounted) {
          setState(() => _connectionError = message);
        }
        return false;
    }
  }

  /// [draft] with the proxy cookie kept on the address being edited, the
  /// active account's when it is on the server, else another account's.
  /// Unchanged while adding an address, or once [draft] reaches somewhere
  /// else ([keptAddressSessionHeaders]).
  Future<ServerConfig> _withKeptAddressCookie(ServerConfig draft) async {
    final serverId = widget.routesOfServerId;
    if (serverId == null || widget.endpointId == null) return draft;
    final storage = ref.read(optimizedStorageServiceProvider);
    final registry = await storage.getOpenWebUiRegistryStrict();
    // As storage counts it, as the check of the address does.
    final activeId = await storage.getEffectiveActiveServerId();
    return withKeptAddressCookie(
      draft,
      registry: registry,
      serverId: serverId,
      endpointId: widget.endpointId,
      accountIds: [
        ?activeId,
        for (final account in registry.accountsOn(serverId)) account.id,
      ],
    );
  }

  Future<void> _prefillFromSavedServer() async {
    final serverId = widget.serverId;
    if (serverId == null) return;
    // The form can be edited while the saved server is read; what the user
    // typed then stays.
    final untouched = _formContents();
    final OpenWebUiRegistry registry;
    try {
      registry = await ref
          .read(optimizedStorageServiceProvider)
          .getOpenWebUiRegistryStrict();
    } catch (error, stackTrace) {
      // Nothing awaits this; say why the form starts empty.
      DebugLogger.error(
        'add-account-prefill-failed',
        scope: 'auth/accounts',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _connectionError = AppLocalizations.of(context)!.errorMessage;
      });
      return;
    }
    final server = registry.server(serverId);
    final endpoint = server?.endpoints.first;
    if (!mounted || endpoint == null) return;
    _savedServer = server;
    if (_formContents() != untouched) return;
    _applyEndpoint(endpoint);
  }

  /// What the connection form holds, to tell whether it has been edited.
  Object _formContents() => (
    _urlController.text,
    [
      for (final header in _customHeaders.entries)
        '${header.key}\u0000${header.value}',
    ].join('\u0001'),
    _allowSelfSignedCertificates,
    _mtlsCertificateChainPem,
    _mtlsPrivateKeyPem,
    _mtlsPrivateKeyPasswordController.text,
  );

  void _resetTransientAttempt() {
    if (!mounted || _isConnecting) return;
    setState(() => _connectionError = null);
  }

  Future<void> _prefillFromState() async {
    final activeServer = await ref.read(activeServerProvider.future);
    if (!mounted || activeServer == null) return;
    _applyConfig(activeServer);
  }

  void _applyConfig(ServerConfig config) {
    setState(() {
      _urlController.text = config.url;
      _customHeaders
        ..clear()
        ..addAll(config.customHeaders);
      _showAdvancedSettings =
          config.allowSelfSignedCertificates ||
          config.customHeaders.isNotEmpty ||
          (!kIsWeb && config.hasMutualTlsCredentials);
      _allowSelfSignedCertificates = config.allowSelfSignedCertificates;
      _mtlsCertificateChainPem = kIsWeb ? null : config.mtlsCertificateChainPem;
      _mtlsCertificateLabel = kIsWeb ? null : config.mtlsCertificateLabel;
      _mtlsPrivateKeyPem = kIsWeb ? null : config.mtlsPrivateKeyPem;
      _mtlsPrivateKeyLabel = kIsWeb ? null : config.mtlsPrivateKeyLabel;
      _mtlsPrivateKeyPasswordController.text = kIsWeb
          ? ''
          : (config.mtlsPrivateKeyPassword ?? '');
    });
  }

  @override
  void dispose() {
    final endAccountAddition = _endAccountAddition;
    if (endAccountAddition != null) {
      // Not while the tree is unmounting: Riverpod forbids changing provider
      // state from a widget lifecycle callback.
      Future.microtask(endAccountAddition);
    }
    _urlController.removeListener(_resetTransientAttempt);
    _urlController.dispose();
    _urlFocusNode.dispose();
    _routeLabelController.dispose();
    _headerKeyController.dispose();
    _headerValueController.dispose();
    _mtlsPrivateKeyPasswordController.dispose();
    _headerValueFocusNode.dispose();
    super.dispose();
  }

  Future<void> _connectToServer() async {
    if (_isConnecting) return;
    final l10n = AppLocalizations.of(context)!;
    // Before anything is awaited: a sign-out from here on, during the checks
    // or the proxy sign-in, revokes whatever cookie they capture. Only an
    // address being edited keeps one.
    final sessionRevision = _editingRoutes
        ? ref.read(optimizedStorageServiceProvider).sessionRevocationRevision
        : 0;

    DebugLogger.log('Connect button pressed', scope: 'auth/connection');

    final urlValue = _urlController.text.trim();
    DebugLogger.log(
      'Server address provided: ${urlValue.isNotEmpty}',
      scope: 'auth/connection',
    );

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

    final mutualTlsValidationError = _validateMutualTlsSelection();
    if (mutualTlsValidationError != null) {
      setState(() {
        _connectionError = mutualTlsValidationError;
      });
      return;
    }

    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });

    ApiService? connectionApi;
    var checkHeaders = const <String, String>{};
    try {
      final rawUrl = _urlController.text.trim();
      String url = _validateAndFormatUrl(rawUrl);
      if (!_hasExplicitHttpScheme(rawUrl)) {
        url = await _canonicalizeSchemeLessServerUrl(url);
        if (!mounted) return;
      }

      final tempConfig = ServerConfig(
        id: const Uuid().v4(),
        name: _serverNameFor(url),
        url: url,
        customHeaders: Map<String, String>.from(_customHeaders),
        isActive: true,
        allowSelfSignedCertificates: _allowSelfSignedCertificates,
        mtlsCertificateChainPem: _mtlsCertificateChainPem,
        mtlsCertificateLabel: _mtlsCertificateLabel,
        mtlsPrivateKeyPem: _mtlsPrivateKeyPem,
        mtlsPrivateKeyLabel: _mtlsPrivateKeyLabel,
        mtlsPrivateKeyPassword: _normalizedMtlsPrivateKeyPassword,
      );

      // An edit that still reaches the address as stored passes its proxy
      // with the cookie the server's accounts keep there. A fresh proxy
      // sign-in below starts from tempConfig, without it.
      final checkConfig = await _withKeptAddressCookie(tempConfig);
      if (!mounted) return;
      checkHeaders = checkConfig.customHeaders;

      final workerManager = ref.read(workerManagerProvider);
      final api = buildAddressCheckApi(
        ProviderScope.containerOf(context, listen: false),
        checkConfig,
      );
      connectionApi = api;

      // First check connectivity with proxy detection
      DebugLogger.log('Checking server health...', scope: 'auth/connection');
      final healthResult = await api.checkHealthWithProxyDetection(
        throwOnConnectionError: true,
      );
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
        api.dispose();
        connectionApi = null;
        if (_embedded) {
          // Left while the address was checked: the sheet is gone.
          if (!mounted) return;
          // Its sign-in is a page of its own: the connection page goes on
          // from here.
          widget.onChecked!(ServerConnectionHandoff(config: tempConfig));
          return;
        }
        await _handleProxyAuth(tempConfig, workerManager, sessionRevision);
        return;
      }

      if (healthResult == HealthCheckResult.unreachable) {
        throw Exception(l10n.couldNotConnectGeneric);
      }

      if (healthResult == HealthCheckResult.notOpenWebUI) {
        throw Exception(l10n.serverNotOpenWebUI);
      }

      if (healthResult == HealthCheckResult.unhealthy) {
        throw Exception(l10n.serverErrorUnavailable);
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
        throw Exception(l10n.serverNotOpenWebUI);
      }

      // Left while the address was checked: the save works through this
      // page, and it is gone.
      if (!mounted) return;
      if (_editingRoutes) {
        await _saveRoute(tempConfig, sessionRevision);
        return;
      }

      DebugLogger.log(
        'Server validation passed, navigating to auth page',
        scope: 'auth/connection',
      );

      // Don't save server config yet - wait until authentication succeeds
      // The config is passed to the authentication page along with backend config
      if (mounted) {
        ConduitHaptics.success();
        final authFlowConfig = AuthFlowConfig(
          serverConfig: tempConfig,
          backendConfig: backendConfig,
        );
        if (_embedded) {
          widget.onChecked!(
            ServerConnectionHandoff(
              config: tempConfig,
              authFlow: authFlowConfig,
            ),
          );
        } else {
          context.pushNamed(RouteNames.authentication, extra: authFlowConfig);
        }
      }
    } catch (e) {
      DebugLogger.error(
        'server-connection-error',
        scope: 'auth/connection',
        data: {'errorType': e.runtimeType.toString()},
      );
      if (mounted) {
        setState(() {
          _connectionError = _formatConnectionError(
            e,
            sensitiveValues: [..._customHeaders.values, ...checkHeaders.values],
          );
        });
        ConduitHaptics.error();
      }
    } finally {
      connectionApi?.dispose();
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
    WorkerManager workerManager,
    int sessionRevision,
  ) async {
    // Check if WebView is supported
    if (!isWebViewSupported) {
      throw Exception(
        AppLocalizations.of(context)?.proxyAuthPlatformNotSupported ??
            'Proxy authentication requires a mobile device.',
      );
    }

    // Show proxy auth page
    final proxyConfig = ProxyAuthConfig(
      serverConfig: tempConfig,
      freshSession: widget.addingAccount,
    );

    if (!mounted) return;

    // Addresses are edited signed in, and the router keeps a signed-in user
    // off sign-in screens; the editor lets the proxy sign-in through while it
    // waits on it.
    final routeEditing = _editingRoutes
        ? ref.read(proxySignInForRouteEditingProvider.notifier)
        : null;
    routeEditing?.begin();
    final ProxyAuthResult? result;
    try {
      result = await context.pushNamed<ProxyAuthResult>(
        RouteNames.proxyAuth,
        extra: proxyConfig,
      );
    } finally {
      routeEditing?.end();
    }

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
    var updatedHeaders = Map<String, String>.from(tempConfig.customHeaders);
    if (result.cookies != null && result.cookies!.isNotEmpty) {
      updatedHeaders = mergeCapturedProxyCookiesIntoHeaders(
        headers: updatedHeaders,
        capturedCookies: result.cookies!,
      );
      DebugLogger.log(
        'Merged ${result.cookies!.length} freshly captured proxy cookies',
        scope: 'auth/connection',
      );
    }

    // Create an updated cookie-scoped config. A discovered JWT is supplied
    // only to the operation-scoped API client below; it is never embedded in a
    // ServerConfig where it could survive logout or a server switch.
    final configWithCookies = ServerConfig(
      id: tempConfig.id,
      name: tempConfig.name,
      url: tempConfig.url,
      customHeaders: updatedHeaders,
      isActive: tempConfig.isActive,
      allowSelfSignedCertificates: tempConfig.allowSelfSignedCertificates,
      mtlsCertificateChainPem: tempConfig.mtlsCertificateChainPem,
      mtlsCertificateLabel: tempConfig.mtlsCertificateLabel,
      mtlsPrivateKeyPem: tempConfig.mtlsPrivateKeyPem,
      mtlsPrivateKeyLabel: tempConfig.mtlsPrivateKeyLabel,
      mtlsPrivateKeyPassword: tempConfig.mtlsPrivateKeyPassword,
    );

    // Create new API service with updated config
    final apiWithCookies = ApiService(
      serverConfig: configWithCookies,
      workerManager: workerManager,
      // If we have a JWT token, use it as auth token
      authToken: result.jwtToken,
    );

    try {
      // Now verify it's an OpenWebUI server
      DebugLogger.log(
        'Verifying OpenWebUI server with proxy cookies...',
        scope: 'auth/connection',
      );

      // What the proxy sign-in captured, kept out of any error shown.
      final proxySensitiveValues = <String>[
        ...updatedHeaders.values,
        ...?result.cookies?.values,
        if ((result.jwtToken ?? '').isNotEmpty) result.jwtToken!,
      ];
      final BackendConfig? backendConfig;
      try {
        backendConfig = await apiWithCookies.verifyAndGetConfig();
      } catch (error) {
        DebugLogger.error(
          'proxy-server-verification-error',
          scope: 'auth/connection',
          data: {'errorType': error.runtimeType.toString()},
        );
        if (mounted) {
          setState(() {
            _connectionError = _formatConnectionError(
              error,
              sensitiveValues: proxySensitiveValues,
            );
            _isConnecting = false;
          });
        }
        return;
      }
      if (backendConfig == null) {
        if (mounted) {
          final message = AppLocalizations.of(context)!
              .proxyServerVerificationFailed;
          setState(() {
            _connectionError = message;
            _isConnecting = false;
          });
        }
        return;
      }

      if (!mounted) return;
      if (_editingRoutes) {
        final bool saved;
        try {
          saved = await _saveRoute(configWithCookies, sessionRevision);
        } catch (error) {
          // Here, not in the caller's handler: that one knows only the
          // headers from before the proxy sign-in.
          DebugLogger.error(
            'proxy-route-save-error',
            scope: 'auth/connection',
            data: {'errorType': error.runtimeType.toString()},
          );
          if (mounted) {
            setState(() {
              _connectionError = _formatConnectionError(
                error,
                sensitiveValues: proxySensitiveValues,
              );
              _isConnecting = false;
            });
          }
          return;
        }
        if (!saved && mounted) setState(() => _isConnecting = false);
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

        final token = result.jwtToken?.trim();
        if (token == null || token.isEmpty) {
          if (mounted) {
            final message = AppLocalizations.of(context)!
                .proxyManualSignInRequired;
            setState(() {
              _connectionError = message;
              _isConnecting = false;
            });
          }
          return;
        }

        // Validate with the same cookie-scoped client before any server config,
        // active-server id, or token is persisted. Trusted-header discovery can
        // report success while returning an already-expired/rejected JWT.
        final User validatedUser;
        try {
          validatedUser = await apiWithCookies.getCurrentUser(
            suppressAuthFailureNotification: true,
          );
        } catch (error) {
          DebugLogger.error(
            'proxy-issued-token-validation-failed',
            scope: 'auth/connection',
            data: {'errorType': error.runtimeType.toString()},
          );
          if (mounted) {
            final message = AppLocalizations.of(context)!
                .proxyManualSignInRequired;
            setState(() {
              _connectionError = message;
              _isConnecting = false;
            });
          }
          return;
        }

        await _completeAuthWithToken(
          configWithCookies,
          token,
          validatedUser,
          backendConfig,
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
    } finally {
      apiWithCookies.dispose();
    }
  }

  /// Completes authentication when user is already authenticated via
  /// trusted headers (oauth2-proxy with X-Forwarded-Email).
  Future<void> _completeAuthWithToken(
    ServerConfig serverConfig,
    String token,
    User validatedUser,
    BackendConfig backendConfig,
  ) async {
    // Committing makes the new account the active one. While another account
    // is added, that leaves the one it was added from and stops a reply still
    // being written there, so ask first. Left while the commit is slow, the
    // addition ends, and so must the commit: the account it was added from
    // stays active.
    final addition = ref.read(accountAdditionOriginProvider) == null
        ? null
        : ref.read(accountAdditionOriginProvider.notifier).stillInProgress();
    if (addition != null && !await confirmLeavingActiveAccount(context, ref)) {
      return;
    }
    if (!mounted) return;
    try {
      final authActions = ref.read(authActionsProvider);
      final success = await authActions.commitPrevalidatedProxySession(
        serverConfig: serverConfig,
        token: token,
        user: validatedUser,
        canCommit: addition,
      );

      if (!mounted) return;

      if (success) {
        DebugLogger.auth(
          'Proxy SSO login successful',
          scope: 'auth/connection',
        );
        try {
          await ref.read(activeServerProvider.future);
          await ref.read(backendConfigProvider.future);
          await ref
              .read(backendConfigProvider.notifier)
              .cacheForServer(backendConfig, serverConfig.id);
        } catch (error) {
          // The authenticated session is authoritative; a cache warmup failure
          // must not roll it back or make the UI report auth failure.
          DebugLogger.warning(
            'proxy-backend-config-cache-failed',
            scope: 'auth/connection',
            data: {'errorType': error.runtimeType.toString()},
          );
        }
        // Navigation is handled automatically by the router when auth state
        // changes to authenticated. The router redirect will navigate to chat.
      } else {
        throw Exception(AppLocalizations.of(context)!.genericSignInFailed);
      }
    } catch (e) {
      DebugLogger.error(
        'Failed to complete auth with token',
        scope: 'auth/connection',
        data: {'errorType': e.runtimeType.toString()},
      );
      if (mounted) {
        setState(() {
          _connectionError = AppLocalizations.of(context)!.genericSignInFailed;
          _isConnecting = false;
        });
      }
    }
  }

  String _validateAndFormatUrl(String input) =>
      formatServerAddressInput(input, AppLocalizations.of(context)!);

  bool _hasExplicitHttpScheme(String input) => hasExplicitHttpScheme(input);

  Future<String> _canonicalizeSchemeLessServerUrl(String url) =>
      upgradeSchemeLessServerUrl(url);

  /// The saved server's own name while the form still reaches it: saving an
  /// added account's connection renames the server it joins after it, for
  /// every account on that server. Otherwise the address's host.
  String _serverNameFor(String url) {
    final saved = _savedServer;
    final identity = openWebUiServerIdentityUrl(url);
    if (saved != null &&
        saved.name.trim().isNotEmpty &&
        saved.endpoints.any(
          (endpoint) => openWebUiServerIdentityUrl(endpoint.url) == identity,
        )) {
      return saved.name;
    }
    return serverNameFromUrl(url);
  }

  String? get _normalizedMtlsPrivateKeyPassword {
    final trimmed = _mtlsPrivateKeyPasswordController.text.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  bool get _hasMutualTlsCertificate =>
      _mtlsCertificateChainPem != null && _mtlsCertificateChainPem!.isNotEmpty;

  bool get _hasMutualTlsPrivateKey =>
      _mtlsPrivateKeyPem != null && _mtlsPrivateKeyPem!.isNotEmpty;

  bool get _hasAnyMutualTlsInput =>
      _hasMutualTlsCertificate ||
      _hasMutualTlsPrivateKey ||
      _normalizedMtlsPrivateKeyPassword != null;

  String? _validateMutualTlsSelection() {
    final hasPassword = _normalizedMtlsPrivateKeyPassword != null;
    if (!_hasMutualTlsCertificate && !_hasMutualTlsPrivateKey) {
      if (!hasPassword) {
        return null;
      }
      return AppLocalizations.of(context)!.mutualTlsMissingCredentialPair;
    }

    if (_hasMutualTlsCertificate && _hasMutualTlsPrivateKey) {
      return null;
    }

    return AppLocalizations.of(context)!.mutualTlsMissingCredentialPair;
  }

  Future<void> _pickMtlsCertificateChain() async {
    await _pickMutualTlsFile(isPrivateKey: false);
  }

  Future<void> _pickMtlsPrivateKey() async {
    await _pickMutualTlsFile(isPrivateKey: true);
  }

  Future<void> _pickMutualTlsFile({required bool isPrivateKey}) async {
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: isPrivateKey
            ? const ['pem', 'key']
            : const ['pem', 'crt', 'cer'],
      );

      if (file == null) {
        return;
      }

      final pemContent = await _readPickedPemFile(file);
      final validationError = _validatePickedPemContent(
        pemContent,
        isPrivateKey: isPrivateKey,
      );

      if (validationError != null) {
        _showHeaderError(validationError);
        return;
      }

      final fileLabel = _resolvePickedFileLabel(
        file,
        fallback: isPrivateKey ? 'client-key.pem' : 'client-cert.pem',
      );

      setState(() {
        if (isPrivateKey) {
          _mtlsPrivateKeyPem = pemContent;
          _mtlsPrivateKeyLabel = fileLabel;
        } else {
          _mtlsCertificateChainPem = pemContent;
          _mtlsCertificateLabel = fileLabel;
        }
        _connectionError = null;
      });
      ConduitHaptics.lightImpact();
    } catch (error) {
      _showHeaderError(error.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<String> _readPickedPemFile(PlatformFile file) =>
      readPickedPemFile(file, AppLocalizations.of(context)!);

  String _resolvePickedFileLabel(
    PlatformFile file, {
    required String fallback,
  }) => pickedFileLabel(file, fallback: fallback);

  String? _validatePickedPemContent(
    String content, {
    required bool isPrivateKey,
  }) => validatePickedPem(
    content,
    isPrivateKey: isPrivateKey,
    l10n: AppLocalizations.of(context)!,
  );

  void _clearMutualTlsCredentials() {
    setState(() {
      _mtlsCertificateChainPem = null;
      _mtlsCertificateLabel = null;
      _mtlsPrivateKeyPem = null;
      _mtlsPrivateKeyLabel = null;
      _mtlsPrivateKeyPasswordController.clear();
      _connectionError = null;
    });
    ConduitHaptics.lightImpact();
  }

  String _formatConnectionError(
    Object error, {
    Iterable<String>? sensitiveValues,
  }) => formatServerConnectionError(
    error,
    sensitiveValues: sensitiveValues ?? _customHeaders.values,
    hasMutualTlsInput: _hasAnyMutualTlsInput,
    l10n: AppLocalizations.of(context)!,
  );

  @override
  Widget build(BuildContext context) {
    final reviewerMode = ref.watch(reviewerModeProvider);
    final l10n = AppLocalizations.of(context)!;
    if (_embedded) {
      // In the account sheet the iOS form is the first-run one: the grouped
      // address and Advanced Settings, then Connect under them, where the
      // sheet's form ends rather than pinned over the keyboard.
      final cupertino = context.usesCupertinoChrome;
      return Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cupertino) ...[
              _buildCupertinoServerForm(),
              const SizedBox(height: Spacing.lg + Spacing.xs),
              _buildCupertinoConnectButton(),
            ] else ...[
              _buildServerForm(),
              const SizedBox(height: Spacing.lg),
              _buildConnectButton(),
            ],
          ],
        ),
      );
    }
    // Kept current for Back, which waits for it.
    if (widget.addingAccount) ref.watch(pendingSignInAbandonableProvider);
    final cupertino = context.usesCupertinoChrome;

    // Adding an account is the router's location, with nothing beneath it to
    // pop to, so the system back does what Back does rather than leave the app.
    return PopScope(
      canPop: !widget.addingAccount,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: UtilityPageScaffold.auth(
        title: !_editingRoutes
            ? l10n.backendChooserOpenWebUITitle
            : widget.endpointId == null
            ? l10n.accountsAddAddress
            : l10n.accountsEditAddress,
        largeTitle: true,
        onTitleLongPress: _editingRoutes ? null : _toggleReviewerMode,
        backNavigation: UtilityBackNavigation(
          label: l10n.back,
          buttonKey: const ValueKey<String>('server-connection-back-button'),
          onPressed: _goBack,
        ),
        bottomAction: cupertino
            ? _buildCupertinoConnectButton()
            : _buildConnectButton(),
        body: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (reviewerMode) ...[
                _buildReviewerModeSection(),
                const SizedBox(height: Spacing.xl),
              ],
              // An address is saved as it was checked, and the editor then
              // closes: an edit made during the check would be lost.
              IgnorePointer(
                ignoring: _editingRoutes && _isConnecting,
                child: ExcludeFocus(
                  excluding: _editingRoutes && _isConnecting,
                  child: cupertino
                      ? _buildCupertinoServerForm()
                      : _buildServerForm(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Back waits to know whether the added account can be dropped; a press
  /// meanwhile, of the button or the system's back, is the same Back.
  bool _goingBack = false;

  /// Users adding Open WebUI next to a working Apple, Direct, or Hermes
  /// backend came from chat; only first-time setup returns to the backend
  /// chooser. Adding another account goes back to chat too, first dropping
  /// the added account if its sign-in began and never finished. Editing an
  /// address goes back to the addresses it was opened from.
  Future<void> _goBack() async {
    if (_goingBack) return;
    _goingBack = true;
    try {
      await _leave();
    } finally {
      _goingBack = false;
    }
  }

  Future<void> _leave() async {
    if (widget.addingAccount) {
      // Asked as it settles, not as last shown: back from the sign-in page,
      // the added account has just become active, and the answer for it may
      // still be on its way. Plain Back would leave that account active.
      final bool abandonable;
      try {
        abandonable = await ref.read(pendingSignInAbandonableProvider.future);
      } catch (_) {
        // Not known whether the added account is still there, signed out:
        // leaving could leave it active. Back stays, says so, and can be
        // pressed again.
        if (mounted) {
          setState(() {
            _connectionError = AppLocalizations.of(context)!.errorMessage;
          });
        }
        return;
      }
      if (!mounted) return;
      if (abandonable) {
        if (!await abandonAddedAccount(context, ref) && mounted) {
          setState(() {
            _connectionError = AppLocalizations.of(context)!.errorMessage;
          });
        }
        return;
      }
    }
    if (!mounted) return;
    if ((widget.addingAccount || _editingRoutes) && context.canPop()) {
      context.pop();
      return;
    }
    context.go(
      widget.addingAccount || ref.read(accountlessPrimaryBackendUsableProvider)
          ? Routes.chat
          : Routes.backendChooser,
    );
  }

  Future<void> _toggleReviewerMode() async {
    final l10n = AppLocalizations.of(context)!;

    ConduitHaptics.mediumImpact();
    await ref.read(reviewerModeProvider.notifier).toggle();
    if (!mounted) return;
    final enabled = ref.read(reviewerModeProvider);
    AdaptiveSnackBar.show(
      context,
      message: enabled ? l10n.reviewerModeEnabled : l10n.reviewerModeDisabled,
      type: AdaptiveSnackBarType.info,
    );
  }

  Widget _buildReviewerModeSection() {
    return Padding(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                context.usesCupertinoChrome
                    ? CupertinoIcons.wand_stars
                    : Icons.auto_awesome,
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
            icon: context.usesCupertinoChrome
                ? CupertinoIcons.play_fill
                : Icons.play_arrow,
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
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_editingRoutes) ...[
          InsetGroupedSection(
            flat: true,
            child: AccessibleFormField(
              key: const ValueKey<String>('server-route-label-field'),
              label: l10n.accountsAddressName,
              hint: l10n.accountsAddressNameHint,
              controller: _routeLabelController,
              textInputAction: TextInputAction.next,
            ),
          ),
          const SizedBox(height: Spacing.md),
        ],
        InsetGroupedSection(
          flat: true,
          child: AccessibleFormField(
            key: const ValueKey<String>('server-url-field'),
            label: l10n.serverUrl,
            hint: l10n.serverUrlHint,
            controller: _urlController,
            validator: (value) {
              final v = value ?? _urlController.text;
              return InputValidationService.combine([
                InputValidationService.validateRequired,
                (val) =>
                    InputValidationService.validateUrl(val, required: true),
              ])(v);
            },
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            onSubmitted: (_) => _connectToServer(),
            semanticLabel: l10n.enterServerUrlSemantic,
            isRequired: true,
            autofillHints: const [AutofillHints.url],
          ),
        ),

        if (_attemptState.isVisible) ...[
          const SizedBox(height: Spacing.md),
          ConnectionAttemptBanner(state: _attemptState),
        ],

        const SizedBox(height: Spacing.lg),

        // Advanced settings
        _buildAdvancedSettings(),
      ],
    );
  }

  /// The iOS form: one inset-grouped section holding the address and, under
  /// it, Advanced Settings as a disclosure row that opens grouped sections
  /// below the footer, which says which address to use (or why connecting
  /// failed). Fields name themselves with leading labels, as the sign-in
  /// step's do.
  Widget _buildCupertinoServerForm() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthGroupedSection(
          key: const ValueKey<String>('server-address-section'),
          header: widget.header,
          footer: _editingRoutes ? null : l10n.serverAddressFooter,
          error: _isConnecting ? null : _connectionError,
          children: [
            if (_editingRoutes)
              AuthGroupedTextField(
                key: const ValueKey<String>('server-route-label-field'),
                controller: _routeLabelController,
                label: l10n.authFieldName,
                placeholder: l10n.authFieldOptional,
                semanticLabel: l10n.accountsAddressName,
                textInputAction: TextInputAction.next,
                autocorrect: true,
                autofocus: widget.endpointId == null,
                onSubmitted: (_) => _urlFocusNode.requestFocus(),
              ),
            AuthGroupedTextField(
              key: const ValueKey<String>('server-url-field'),
              controller: _urlController,
              focusNode: _urlFocusNode,
              label: l10n.authFieldServer,
              placeholder: l10n.serverUrlHint,
              semanticLabel: l10n.enterServerUrlSemantic,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              // Not in the account sheet: the keyboard would cover the
              // saved servers, and a hidden tab's field would take it.
              autofocus: !_editingRoutes && !_embedded,
              autofillHints: const [AutofillHints.url],
              validator: (value) {
                final v = value ?? _urlController.text;
                return InputValidationService.combine([
                  InputValidationService.validateRequired,
                  (val) =>
                      InputValidationService.validateUrl(val, required: true),
                ])(v);
              },
              onSubmitted: (_) => _connectToServer(),
            ),
            AuthGroupedRow(
              key: const ValueKey<String>('advanced-settings-toggle'),
              title: l10n.advancedSettings,
              expanded: _showAdvancedSettings,
              onTap: () => setState(
                () => _showAdvancedSettings = !_showAdvancedSettings,
              ),
            ),
          ],
        ),
        _buildCupertinoAdvancedReveal(),
      ],
    );
  }

  /// Opens the advanced sections under their row the way a native
  /// disclosure does: the space grows from the top, eased out, and appears
  /// at once with Reduce Motion.
  Widget _buildCupertinoAdvancedReveal() {
    final content = _showAdvancedSettings
        ? _buildCupertinoAdvancedContent()
        : const SizedBox(width: double.infinity);
    if (context.reduceMotion) return content;
    return ClipRect(
      child: AnimatedSize(
        duration: AnimationDuration.medium,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: content,
      ),
    );
  }

  Widget _buildCupertinoAdvancedContent() {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    const gap = SizedBox(height: Spacing.lg + Spacing.xs);
    return Column(
      key: const ValueKey<String>('server-advanced-content'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        gap,
        AuthGroupedSection(
          footer: l10n.allowSelfSignedCertificatesDescription,
          children: [
            AuthGroupedSwitchRow(
              title: l10n.allowSelfSignedCertificates,
              value: _allowSelfSignedCertificates,
              onChanged: (value) => setState(() {
                _allowSelfSignedCertificates = value;
                _connectionError = null;
              }),
            ),
          ],
        ),
        if (!kIsWeb) ...[
          gap,
          AuthGroupedSection(
            header: l10n.mutualTlsSectionTitle,
            footer: l10n.mutualTlsSectionDescription,
            children: [
              AuthGroupedRow(
                key: const ValueKey<String>('mtls-certificate-row'),
                title: l10n.mutualTlsSelectCertificate,
                value: _mtlsCertificateLabel ?? l10n.mutualTlsChooseFile,
                showChevron: true,
                onTap: _pickMtlsCertificateChain,
              ),
              AuthGroupedRow(
                key: const ValueKey<String>('mtls-private-key-row'),
                title: l10n.mutualTlsSelectPrivateKey,
                value: _mtlsPrivateKeyLabel ?? l10n.mutualTlsChooseFile,
                showChevron: true,
                onTap: _pickMtlsPrivateKey,
              ),
              if (_hasAnyMutualTlsInput) ...[
                AuthGroupedTextField(
                  controller: _mtlsPrivateKeyPasswordController,
                  label: l10n.password,
                  placeholder: l10n.authFieldOptional,
                  semanticLabel: l10n.mutualTlsPrivateKeyPasswordHint,
                  obscureText: true,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                ),
                AuthGroupedRow(
                  title: l10n.mutualTlsClearCredentials,
                  titleColor: theme.error,
                  onTap: _clearMutualTlsCredentials,
                ),
              ],
            ],
          ),
        ],
        gap,
        AuthGroupedSection(
          header: l10n.customHeaders,
          // At the limit, Add Header is dimmed: the footer says why.
          footer: _customHeaders.length >= 10
              ? l10n.maxHeadersReachedDetail
              : l10n.customHeadersDescription,
          children: [
            for (final entry in _customHeaders.entries)
              AuthGroupedRow(
                title: entry.key,
                value: entry.value,
                trailing: _buildRemoveHeaderButton(entry.key),
              ),
            AuthGroupedTextField(
              key: const ValueKey<String>('custom-header-name-field'),
              controller: _headerKeyController,
              label: l10n.headerName,
              // Both fields are needed for Add Header, this group's action.
              placeholder: l10n.authFieldRequired,
              semanticLabel: l10n.headerName,
              validator: (value) =>
                  _validateHeaderKey(value ?? _headerKeyController.text),
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() => _connectionError = null),
              onSubmitted: (_) => _headerValueFocusNode.requestFocus(),
            ),
            AuthGroupedTextField(
              key: const ValueKey<String>('custom-header-value-field'),
              controller: _headerValueController,
              focusNode: _headerValueFocusNode,
              label: l10n.headerValue,
              placeholder: l10n.authFieldRequired,
              semanticLabel: l10n.headerValue,
              validator: (value) =>
                  _validateHeaderValue(value ?? _headerValueController.text),
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() => _connectionError = null),
              onSubmitted: (_) {
                if (_canAddCustomHeader) _addCustomHeader();
              },
            ),
            AuthGroupedRow(
              key: const ValueKey<String>('add-custom-header-button'),
              title: l10n.addHeader,
              titleColor: _canAddCustomHeader
                  ? theme.buttonPrimary
                  : theme.textTertiary,
              onTap: _canAddCustomHeader ? _addCustomHeader : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRemoveHeaderButton(String key) {
    final l10n = AppLocalizations.of(context)!;
    return AdaptiveTooltip(
      message: l10n.removeHeader,
      child: Semantics(
        button: true,
        label: '${l10n.removeHeader}: $key',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _removeCustomHeader(key),
          child: SizedBox.square(
            dimension: TouchTarget.minimum,
            child: Icon(
              CupertinoIcons.xmark_circle_fill,
              size: IconSize.md,
              color: context.conduitTheme.textTertiary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCupertinoConnectButton() {
    final l10n = AppLocalizations.of(context)!;
    return AuthPrimaryButton(
      key: _embedded
          ? const ValueKey<String>('server-connection-continue')
          : null,
      label: _editingRoutes
          ? l10n.accountsSaveAddress
          : l10n.connectToServerButton,
      busyLabel: l10n.connecting,
      busy: _isConnecting,
      onPressed: _urlController.text.trim().isEmpty ? null : _connectToServer,
    );
  }

  Widget _buildAdvancedSettings() {
    return UtilityDisclosureSection(
      key: const ValueKey<String>('advanced-settings-toggle'),
      title: AppLocalizations.of(context)!.advancedSettings,
      leading: Icon(
        context.usesCupertinoChrome
            ? CupertinoIcons.gear_alt
            : Icons.tune_rounded,
        color: context.conduitTheme.iconSecondary,
        size: IconSize.medium,
      ),
      expanded: _showAdvancedSettings,
      onChanged: (value) => setState(() => _showAdvancedSettings = value),
      contentPadding: EdgeInsets.zero,
      flat: true,
      child: _buildAdvancedSettingsContent(),
    );
  }

  Widget _buildAdvancedSettingsContent() {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Self-signed certificates toggle
        Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: Text(
                        l10n.allowSelfSignedCertificates,
                        style: theme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      l10n.allowSelfSignedCertificatesDescription,
                      style: AppTypography.bodySmallStyle.copyWith(
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
                semanticLabel: l10n.allowSelfSignedCertificates,
                onChanged: (value) {
                  setState(() {
                    _allowSelfSignedCertificates = value;
                    _connectionError = null;
                  });
                },
                activeColor: theme.buttonPrimary,
              ),
            ],
          ),
        ),

        if (!kIsWeb) ...[
          Divider(
            height: BorderWidth.thin,
            thickness: BorderWidth.thin,
            color: theme.cardBorder,
          ),

          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.mutualTlsSectionTitle,
                  style: AppTypography.bodyMediumStyle.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.textPrimary,
                  ),
                ),
                const SizedBox(height: Spacing.xxs),
                Text(
                  l10n.mutualTlsSectionDescription,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: ConduitButton(
                        text: l10n.mutualTlsSelectCertificate,
                        onPressed: _pickMtlsCertificateChain,
                        isSecondary: true,
                        isCompact: true,
                        isFullWidth: true,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: ConduitButton(
                        text: l10n.mutualTlsSelectPrivateKey,
                        onPressed: _pickMtlsPrivateKey,
                        isSecondary: true,
                        isCompact: true,
                        isFullWidth: true,
                      ),
                    ),
                  ],
                ),
                if (_mtlsCertificateLabel != null ||
                    _mtlsPrivateKeyLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.md),
                    child: Wrap(
                      spacing: Spacing.xs,
                      runSpacing: Spacing.xs,
                      children: [
                        if (_mtlsCertificateLabel != null)
                          _buildMutualTlsBadge(
                            label:
                                '${l10n.mutualTlsCertificateReady}: '
                                '$_mtlsCertificateLabel',
                          ),
                        if (_mtlsPrivateKeyLabel != null)
                          _buildMutualTlsBadge(
                            label:
                                '${l10n.mutualTlsPrivateKeyReady}: '
                                '$_mtlsPrivateKeyLabel',
                          ),
                      ],
                    ),
                  ),
                if (_hasAnyMutualTlsInput) ...[
                  const SizedBox(height: Spacing.md),
                  AccessibleFormField(
                    controller: _mtlsPrivateKeyPasswordController,
                    hint: l10n.mutualTlsPrivateKeyPasswordHint,
                    obscureText: true,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                  ),
                  const SizedBox(height: Spacing.sm),
                  ConduitButton(
                    text: l10n.mutualTlsClearCredentials,
                    onPressed: _clearMutualTlsCredentials,
                    isSecondary: true,
                    isCompact: true,
                  ),
                ],
              ],
            ),
          ),

          Divider(
            height: BorderWidth.thin,
            thickness: BorderWidth.thin,
            color: theme.cardBorder,
          ),
        ],

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
                          style: AppTypography.bodyMediumStyle.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: Spacing.xxs),
                        Text(
                          l10n.customHeadersDescription,
                          style: AppTypography.bodySmallStyle.copyWith(
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
                        style: AppTypography.labelSmallStyle.copyWith(
                          color: _customHeaders.length >= 10
                              ? theme.error
                              : theme.textTertiary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Spacing.md),

              AccessibleFormField(
                key: const ValueKey<String>('custom-header-name-field'),
                label: l10n.headerName,
                hint: 'X-Custom-Header',
                controller: _headerKeyController,
                validator: (value) =>
                    _validateHeaderKey(value ?? _headerKeyController.text),
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                onChanged: (_) => setState(() => _connectionError = null),
                onSubmitted: (_) => _headerValueFocusNode.requestFocus(),
              ),
              const SizedBox(height: Spacing.md),
              AccessibleFormField(
                key: const ValueKey<String>('custom-header-value-field'),
                label: l10n.headerValue,
                hint: l10n.headerValueHint,
                controller: _headerValueController,
                focusNode: _headerValueFocusNode,
                validator: (value) =>
                    _validateHeaderValue(value ?? _headerValueController.text),
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                onChanged: (_) => setState(() => _connectionError = null),
                onSubmitted: (_) {
                  if (_canAddCustomHeader) _addCustomHeader();
                },
              ),
              const SizedBox(height: Spacing.md),
              ConduitButton(
                key: const ValueKey<String>('add-custom-header-button'),
                text: l10n.addHeader,
                onPressed: _canAddCustomHeader ? _addCustomHeader : null,
                isSecondary: true,
                isFullWidth: true,
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

  Widget _buildMutualTlsBadge({required String label}) {
    final theme = context.conduitTheme;

    return ConduitBadge(
      text: label,
      isCompact: true,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      backgroundColor: theme.buttonPrimary.withValues(alpha: 0.08),
      textColor: theme.buttonPrimary,
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
                  icon: context.usesCupertinoChrome
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
      key: _embedded
          ? const ValueKey<String>('server-connection-continue')
          : null,
      text: _isConnecting
          ? AppLocalizations.of(context)!.connecting
          : _editingRoutes
          ? AppLocalizations.of(context)!.accountsSaveAddress
          : _embedded
          ? AppLocalizations.of(context)!.continueAction
          : AppLocalizations.of(context)!.connectToServerButton,
      onPressed: _isConnecting || _urlController.text.trim().isEmpty
          ? null
          : _connectToServer,
      isLoading: _isConnecting,
      isFullWidth: true,
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
      _connectionError = null;
    });
    ConduitHaptics.lightImpact();
  }

  String? _validateHeaderKey(String key) =>
      validateServerAddressHeaderName(key, AppLocalizations.of(context)!);

  String? _validateHeaderValue(String value) =>
      validateServerAddressHeaderValue(value, AppLocalizations.of(context)!);

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
      _connectionError = null;
    });
    ConduitHaptics.lightImpact();
  }
}

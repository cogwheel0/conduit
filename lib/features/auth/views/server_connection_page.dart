import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HandshakeException, HttpException, SocketException;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:uuid/uuid.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../../../platform/webview_cookie_helper.dart';

import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/auth/proxy_session.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/network/conduit_user_agent.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/auth/openwebui_address_check.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart'
    show
        logoutFenceSuppressesCookies,
        openWebUiRouteResolverProvider,
        proxySignInForRouteEditingProvider;
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show
        accountAdditionOriginProvider,
        pendingSignInAbandonableProvider;
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/services/api_service.dart';

import 'package:conduit_core/services/worker_manager.dart';

import '../../../shared/services/input_validation_service.dart';
import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/sensitive_value_utils.dart';
import 'package:conduit_core/utils/unicode_prefix.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'proxy_auth_page.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/account_actions.dart'
    show abandonAddedAccount, confirmLeavingActiveAccount;

const int _maxConnectionProviderDetailCharacters = 300;
const int _maxConnectionErrorCharacters = 640;
const int _maxConnectionSecretCharacters = 8 * 1024;
const int _maxConnectionSecretPatterns = 32;
const int _maxConnectionSecretTotalCharacters = 32 * 1024;

/// Builds the deliberately credential-free client options used to discover
/// whether a scheme-less address redirects from HTTP to HTTPS.
///
/// This request is the only request sent before the user-selected scheme is
/// known. Custom headers can contain bearer tokens, cookies, or reverse-proxy
/// credentials, so they must not be exposed to the initial plaintext origin.
@visibleForTesting
BaseOptions buildSchemeLessPlaintextHealthProbeOptions(String baseUrl) {
  return BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 2),
    receiveTimeout: const Duration(seconds: 2),
    followRedirects: false,
    validateStatus: (status) => true,
    headers: ConduitUserAgent.mergeHeaders(),
  );
}

/// Whether a failed connection to a server configured with a client
/// certificate failed in the TLS handshake itself, which is a certificate
/// problem and nothing else.
@visibleForTesting
bool isLikelyMutualTlsRejection(
  String errorText, {
  required bool hasMutualTlsInput,
}) {
  if (!hasMutualTlsInput) return false;
  return errorText.contains('HandshakeException') ||
      errorText.contains('TlsException') ||
      errorText.contains('CERTIFICATE_VERIFY_FAILED') ||
      errorText.contains('alert bad certificate');
}

/// Whether a failed HTTPS connection, to a server configured with a client
/// certificate, was closed before the first response header arrived.
///
/// With TLS 1.3 the client finishes its side of the handshake before the
/// server checks the certificate, so a refusal does not surface as a
/// handshake error: the server closes the connection instead. A proxy reset or
/// a server restart closes it the same way, so this cannot say the certificate
/// was refused, only that it is worth checking. A plain HTTP request cannot
/// involve a client certificate.
@visibleForTesting
bool isConnectionClosedWithClientCertificate(
  String errorText, {
  required bool hasMutualTlsInput,
}) =>
    hasMutualTlsInput &&
    errorText.contains('Connection closed before full header was received') &&
    errorText.contains('uri = https://');

/// Redacts configured header values before normalizing and bounding text that
/// came from a server, proxy, or transport error.
///
/// The working prefix includes enough Unicode scalars to recognize a secret
/// that begins inside the visible limit. If the defensive working limit still
/// cuts through a secret, the partial suffix is dropped before whitespace
/// normalization can move it back into view.
@visibleForTesting
String? sanitizeServerConnectionProviderText(
  Object? value, {
  required Iterable<String> sensitiveValues,
  int maxCharacters = _maxConnectionProviderDetailCharacters,
}) {
  if (value == null) return null;
  if (maxCharacters <= 0) {
    throw RangeError.value(maxCharacters, 'maxCharacters');
  }

  final secrets = <String>{};
  var totalSecretCharacters = 0;
  for (final configuredValue in sensitiveValues) {
    final variants = boundedSensitiveValueVariants(
      configuredValue,
      maxCharacters: _maxConnectionSecretCharacters,
      maxVariants: _maxConnectionSecretPatterns,
    );
    if (variants == null) return null;
    for (final candidate in variants) {
      if (candidate.isEmpty || !secrets.add(candidate)) continue;
      totalSecretCharacters += candidate.length;
      if (secrets.length > _maxConnectionSecretPatterns ||
          totalSecretCharacters > _maxConnectionSecretTotalCharacters) {
        // Imported configuration is untrusted too. Fail closed rather than
        // building an unbounded redaction expression or leaking a fragment.
        return null;
      }
    }
  }

  final orderedSecrets = secrets.toList(growable: false)
    ..sort((a, b) {
      final runeLength = b.runes.length.compareTo(a.runes.length);
      return runeLength != 0 ? runeLength : b.length.compareTo(a.length);
    });
  final raw = value.toString();
  final safe = redactSensitiveValuesInUnicodePrefix(
    raw,
    sensitiveValues: orderedSecrets,
    maxVisibleScalars: maxCharacters,
  );
  return _normalizeAndBoundConnectionText(safe, maxCharacters: maxCharacters);
}

String? _normalizeAndBoundConnectionText(
  String value, {
  required int maxCharacters,
}) {
  final safe = value
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (safe.isEmpty) return null;

  final characters = safe.runes.toList(growable: false);
  if (characters.length <= maxCharacters) return safe;
  if (maxCharacters == 1) return '…';
  return '${String.fromCharCodes(characters.take(maxCharacters - 1))}…';
}

/// Formats a Dio failure without allowing server-controlled status, redirect,
/// or response-body text to reflect custom-header credentials into the UI.
@visibleForTesting
String formatServerConnectionDioExceptionForDisplay(
  DioException error, {
  required Iterable<String> sensitiveValues,
}) {
  final response = error.response;
  if (response != null) {
    final statusCode = response.statusCode;
    final statusMessage = sanitizeServerConnectionProviderText(
      response.statusMessage,
      sensitiveValues: sensitiveValues,
      maxCharacters: 120,
    );
    final status = [
      if (statusCode != null) '$statusCode',
      ?statusMessage,
    ].join(' ');
    final wasRedirected =
        response.headers.value('location')?.trim().isNotEmpty == true;
    final detail = sanitizeServerConnectionProviderText(
      _serverConnectionResponseErrorDetail(response.data),
      sensitiveValues: sensitiveValues,
    );
    final parts = [
      if (status.isNotEmpty) 'HTTP $status',
      'from the server',
      if (wasRedirected) 'redirected by server',
      ?detail,
    ];
    return _normalizeAndBoundConnectionText(
          parts.join(' - '),
          maxCharacters: _maxConnectionErrorCharacters,
        ) ??
        'Could not connect to the server.';
  }

  final formatted = '${error.type.name} while contacting the server';
  return _normalizeAndBoundConnectionText(
        formatted,
        maxCharacters: _maxConnectionErrorCharacters,
      ) ??
      'Could not connect to the server.';
}

Object? _serverConnectionResponseErrorDetail(Object? data) => switch (data) {
  {'detail': final Object value} => value,
  {'message': final Object value} => value,
  {'error': final Object value} => value,
  final String value => value,
  _ => null,
};

/// A client for checking an address typed into this page, through
/// [container]'s providers.
///
/// An address being edited is checked with the proxy cookie the server's
/// accounts keep there. An incomplete logout keeps that cookie off every
/// other client, and a check can outlast the page into one.
@visibleForTesting
ApiService buildAddressCheckApi(
  ProviderContainer container,
  ServerConfig config, {
  String? authToken,
}) => ApiService(
  serverConfig: config,
  workerManager: container.read(workerManagerProvider),
  authToken: authToken,
  shouldSuppressCookieCustomHeader: logoutFenceSuppressesCookies(
    container.read,
  ),
);

/// Saves [route], an address of the server [serverId] that has just been
/// checked -- in place of the address of its id, or as a new one when
/// [adding] -- and keeps the proxy cookie in [headers] for [cookieOwner], the
/// account whose session proved it (see
/// [OptimizedStorageService.saveEndpointSessionHeaders]).
///
/// The address is saved first. Whatever then becomes of the cookie, the
/// clients, the addresses shown and the route in use follow what was saved;
/// a failure to keep the cookie is rethrown for the editor to report.
@visibleForTesting
Future<void> saveCheckedAddress(
  ProviderContainer container, {
  required String serverId,
  required OpenWebUiEndpoint route,
  required bool adding,
  required String? cookieOwner,
  required Map<String, String> headers,
  required int sessionRevision,
}) async {
  final storage = container.read(optimizedStorageServiceProvider);
  // Onto the routes as stored now, not as read before the check, which can
  // take a while; an address removed meanwhile stays removed.
  await storage.editServerEndpoints(
    serverId,
    (endpoints) => withEditedRoute(endpoints, route, adding: adding),
  );
  try {
    if (cookieOwner != null && headers.keys.any(isCapturedSessionHeader)) {
      await storage.saveEndpointSessionHeaders(
        accountId: cookieOwner,
        route: route,
        headers: headers,
        sessionRevision: sessionRevision,
      );
    }
  } finally {
    container.invalidate(serverConfigsProvider);
    container.invalidate(openWebUiAccountsProvider);
    unawaited(
      container
          .read(openWebUiRouteResolverProvider.notifier)
          .resolve(reason: 'routes-edited'),
    );
  }
}

class ServerConnectionPage extends ConsumerStatefulWidget {
  const ServerConnectionPage({
    super.key,
    this.addingAccount = false,
    this.serverId,
    this.routesOfServerId,
    this.endpointId,
  });

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

  /// The saved server the form was filled in from, when it was.
  OpenWebUiServer? _savedServer;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_resetTransientAttempt);
    if (_editingRoutes) {
      _prefillFromRoute();
    } else if (widget.addingAccount) {
      // openAddAccount began the addition before opening this page, which the
      // router needs; the page only ends it when it goes.
      _endAccountAddition = ref
          .read(accountAdditionOriginProvider.notifier)
          .endLater();
      _prefillFromSavedServer();
    } else {
      _prefillFromState();
    }
  }

  Future<void> _prefillFromRoute() async {
    final endpointId = widget.endpointId;
    if (endpointId == null) return;
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
    // The editor can be left while this runs, and the widget's ref is gone
    // with it; what follows a save must still run.
    final container = ProviderScope.containerOf(context, listen: false);
    final storage = container.read(optimizedStorageServiceProvider);
    final registry = await storage.getOpenWebUiRegistryStrict();
    final server = registry.server(widget.routesOfServerId!);
    if (server == null) throw StateError('That server is no longer saved.');

    final activeId = await storage.getActiveServerId();
    final activeAccount = activeId == null ? null : registry.account(activeId);
    final checksActiveAccount =
        activeAccount != null &&
        activeAccount.serverId == server.id &&
        activeAccount.userId != null;
    final (result: check, :provedBy) = await checkOpenWebUiAddress(
      registry: registry,
      serverId: server.id,
      address: verified.url,
      activeAccountId: activeId,
      liveToken: container.read(authTokenProvider3),
      keptTokenFor: storage.vaultedTokenFor,
      accountsWithSession: await storage.accountIdsWithSession(),
      confirmSendingSession: (address) async {
        if (!mounted) return false;
        return ThemedDialogs.confirm(
          context,
          title: l10n.accountsAddressConfirmTitle,
          message: l10n.accountsAddressConfirmMessage(address.authority),
          confirmText: l10n.accountsAddressConfirmAction,
        );
      },
      userAt: (accountId, token) async {
        // Each account's token travels with its own proxy cookie only.
        final probe = buildAddressCheckApi(
          container,
          _withKeptCookie(verified, registry, [accountId]),
          authToken: token,
        );
        try {
          final user = await probe.getCurrentUser(
            suppressAuthFailureNotification: true,
          );
          return user.id;
        } finally {
          probe.dispose();
        }
      },
    );
    if (check != OpenWebUiAddressCheck.sameServer &&
        check != OpenWebUiAddressCheck.nothingToProtect) {
      final refusal = switch (check) {
        OpenWebUiAddressCheck.differentServer =>
          l10n.accountsAddressDifferentServer,
        OpenWebUiAddressCheck.needsSignIn => l10n.accountsAddressNeedsSignIn,
        // Nothing was sent, as the user chose; the form stays as it is.
        OpenWebUiAddressCheck.declined ||
        OpenWebUiAddressCheck.sameServer ||
        OpenWebUiAddressCheck.nothingToProtect => null,
      };
      if (mounted) setState(() => _connectionError = refusal);
      return false;
    }

    final label = _routeLabelController.text.trim();
    final route = OpenWebUiEndpoint(
      id: widget.endpointId ?? _addedEndpointId,
      url: verified.url,
      label: label.isEmpty ? null : label,
      customHeaders: {
        for (final entry in verified.customHeaders.entries)
          if (!isCapturedSessionHeader(entry.key)) entry.key: entry.value,
      },
      allowSelfSignedCertificates: verified.allowSelfSignedCertificates,
      mtlsCertificateChainPem: verified.mtlsCertificateChainPem,
      mtlsCertificateLabel: verified.mtlsCertificateLabel,
      mtlsPrivateKeyPem: verified.mtlsPrivateKeyPem,
      mtlsPrivateKeyLabel: verified.mtlsPrivateKeyLabel,
      mtlsPrivateKeyPassword: verified.mtlsPrivateKeyPassword,
    );
    // A proxy sign-in on this address belongs to the account whose session
    // proved it, which need not be the active one; with nothing to prove, to
    // the active account when it is on this server.
    await saveCheckedAddress(
      container,
      serverId: server.id,
      route: route,
      adding: widget.endpointId == null,
      cookieOwner: provedBy ?? (checksActiveAccount ? activeAccount.id : null),
      headers: verified.customHeaders,
      sessionRevision: sessionRevision,
    );
    if (mounted) {
      ConduitHaptics.success();
      context.pop();
    }
    return true;
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
    final activeId = await storage.getActiveServerId();
    return _withKeptCookie(draft, registry, [
      ?activeId,
      for (final account in registry.accountsOn(serverId)) account.id,
    ]);
  }

  ServerConfig _withKeptCookie(
    ServerConfig draft,
    OpenWebUiRegistry registry,
    Iterable<String> accountIds,
  ) {
    final kept = keptAddressSessionHeaders(
      registry: registry,
      serverId: widget.routesOfServerId!,
      endpointId: widget.endpointId,
      draft: draft,
      accountIds: accountIds,
    );
    return kept.isEmpty
        ? draft
        : draft.copyWith(customHeaders: {...draft.customHeaders, ...kept});
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
    setState(() {
      _urlController.text = activeServer.url;
      _customHeaders
        ..clear()
        ..addAll(activeServer.customHeaders);
      _showAdvancedSettings =
          activeServer.allowSelfSignedCertificates ||
          activeServer.customHeaders.isNotEmpty ||
          (!kIsWeb && activeServer.hasMutualTlsCredentials);
      _allowSelfSignedCertificates = activeServer.allowSelfSignedCertificates;
      _mtlsCertificateChainPem = kIsWeb
          ? null
          : activeServer.mtlsCertificateChainPem;
      _mtlsCertificateLabel = kIsWeb ? null : activeServer.mtlsCertificateLabel;
      _mtlsPrivateKeyPem = kIsWeb ? null : activeServer.mtlsPrivateKeyPem;
      _mtlsPrivateKeyLabel = kIsWeb ? null : activeServer.mtlsPrivateKeyLabel;
      _mtlsPrivateKeyPasswordController.text = kIsWeb
          ? ''
          : (activeServer.mtlsPrivateKeyPassword ?? '');
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
        context.pushNamed(RouteNames.authentication, extra: authFlowConfig);
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
          final proxySensitiveValues = <String>[
            ...updatedHeaders.values,
            ...?result.cookies?.values,
            if ((result.jwtToken ?? '').isNotEmpty) result.jwtToken!,
          ];
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

      if (_editingRoutes) {
        if (!await _saveRoute(configWithCookies, sessionRevision) && mounted) {
          setState(() => _isConnecting = false);
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

  bool _hasExplicitHttpScheme(String input) {
    final normalized = input.trim().toLowerCase();
    return normalized.startsWith('http://') ||
        normalized.startsWith('https://');
  }

  Future<String> _canonicalizeSchemeLessServerUrl(String url) async {
    final originalUri = Uri.parse(url);
    if (originalUri.scheme != 'http') {
      return url;
    }

    final dio = Dio(buildSchemeLessPlaintextHealthProbeOptions(url));
    try {
      final response = await dio.get('/health');
      final redirectedUrl = _sameHostHttpsRedirectBaseUrl(
        originalUri,
        statusCode: response.statusCode,
        location: response.headers.value('location'),
      );
      if (redirectedUrl == null) {
        return url;
      }

      DebugLogger.log('scheme-less-url-upgraded', scope: 'auth/connection');
      return redirectedUrl;
    } on DioException catch (error) {
      DebugLogger.log(
        'Scheme-less HTTPS canonicalization skipped: ${error.type}',
        scope: 'auth/connection',
      );
      return url;
    } catch (error) {
      DebugLogger.log(
        'Scheme-less HTTPS canonicalization skipped: ${error.runtimeType}',
        scope: 'auth/connection',
      );
      return url;
    } finally {
      dio.close(force: true);
    }
  }

  String? _sameHostHttpsRedirectBaseUrl(
    Uri originalUri, {
    required int? statusCode,
    required String? location,
  }) {
    if (location == null || location.isEmpty) {
      return null;
    }
    if (statusCode != 301 &&
        statusCode != 302 &&
        statusCode != 303 &&
        statusCode != 307 &&
        statusCode != 308) {
      return null;
    }

    final redirectUri = originalUri.resolve(location);
    if (redirectUri.scheme != 'https' ||
        redirectUri.host.toLowerCase() != originalUri.host.toLowerCase()) {
      return null;
    }

    final normalizedPath = originalUri.path == '/'
        ? ''
        : originalUri.path.replaceFirst(RegExp(r'/+$'), '');
    final upgradedPort = redirectUri.hasPort && redirectUri.port != 443
        ? redirectUri.port
        : null;
    final upgradedUri = Uri(
      scheme: 'https',
      host: redirectUri.host,
      port: upgradedPort,
      path: normalizedPath,
    );
    return upgradedUri.toString();
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
    return _deriveServerNameFromUrl(url);
  }

  String _deriveServerNameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host.isNotEmpty) return uri.host;
    } catch (_) {}
    return 'Server';
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

  Future<String> _readPickedPemFile(PlatformFile file) async {
    final l10n = AppLocalizations.of(context)!;
    final bytes = file.path != null
        ? await File(file.path!).readAsBytes()
        : await file.readAsBytes();
    if (bytes.isEmpty) {
      throw Exception(l10n.mutualTlsFileReadFailed);
    }

    try {
      return utf8.decode(bytes).trim();
    } catch (_) {
      throw Exception(l10n.mutualTlsFileReadFailed);
    }
  }

  String _resolvePickedFileLabel(
    PlatformFile file, {
    required String fallback,
  }) {
    final trimmedName = file.name.trim();
    if (trimmedName.isNotEmpty) {
      return trimmedName;
    }

    final path = file.path?.trim();
    if (path != null && path.isNotEmpty) {
      final normalized = path.replaceAll('\\', '/');
      final segments = normalized.split('/');
      if (segments.isNotEmpty && segments.last.isNotEmpty) {
        return segments.last;
      }
    }

    return fallback;
  }

  String? _validatePickedPemContent(
    String content, {
    required bool isPrivateKey,
  }) {
    if (isPrivateKey) {
      if (content.contains('BEGIN ') && content.contains('PRIVATE KEY')) {
        return null;
      }
      return AppLocalizations.of(context)!.mutualTlsPrivateKeyPemRequired;
    }

    if (content.contains('BEGIN CERTIFICATE')) {
      return null;
    }
    return AppLocalizations.of(context)!.mutualTlsCertificatePemRequired;
  }

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
  }) {
    final effectiveSensitiveValues = sensitiveValues ?? _customHeaders.values;
    // Clean up the error message
    final errorText = error.toString();
    final cleanError =
        sanitizeServerConnectionProviderText(
          _cleanExceptionPrefix(errorText),
          sensitiveValues: effectiveSensitiveValues,
          maxCharacters: _maxConnectionErrorCharacters,
        ) ??
        AppLocalizations.of(context)!.couldNotConnectGeneric;

    // Handle specific error types
    if (errorText.contains('mTLS certificate setup failed')) {
      return cleanError;
    } else if (isLikelyMutualTlsRejection(
      errorText,
      hasMutualTlsInput: _hasAnyMutualTlsInput,
    )) {
      return AppLocalizations.of(context)!.mutualTlsHandshakeFailed;
    } else if (isConnectionClosedWithClientCertificate(
      errorText,
      hasMutualTlsInput: _hasAnyMutualTlsInput,
    )) {
      return AppLocalizations.of(context)!.mutualTlsConnectionClosed;
    }

    final exactServerUrlError = _formatExactServerUrlError(
      error,
      sensitiveValues: effectiveSensitiveValues,
    );
    if (exactServerUrlError != null) {
      return exactServerUrlError;
    }

    if (errorText.contains('timeout')) {
      return cleanError;
    } else if (errorText.contains('Server URL cannot be empty')) {
      return AppLocalizations.of(context)!.serverUrlEmpty;
    } else if (errorText.contains('Invalid URL format')) {
      return AppLocalizations.of(context)!.invalidUrlFormat;
    } else if (errorText.contains('Only HTTP and HTTPS')) {
      return AppLocalizations.of(context)!.useHttpOrHttpsOnly;
    } else if (errorText.contains('Server address is required')) {
      return cleanError;
    } else if (errorText.contains('Port must be between')) {
      return cleanError;
    } else if (errorText.contains('Invalid IP address format')) {
      return cleanError;
    } else if (errorText.contains(
      'This does not appear to be an Open-WebUI server',
    )) {
      return AppLocalizations.of(context)!.serverNotOpenWebUI;
    }

    return cleanError.isEmpty
        ? AppLocalizations.of(context)!.couldNotConnectGeneric
        : cleanError;
  }

  String? _formatExactServerUrlError(
    Object error, {
    required Iterable<String> sensitiveValues,
  }) {
    if (error is DioException) {
      if (error.response == null) {
        return error.type == DioExceptionType.badCertificate
            ? AppLocalizations.of(context)!.securityCertificateError
            : AppLocalizations.of(context)!.couldNotConnectGeneric;
      }
      return _formatDioException(error, sensitiveValues: sensitiveValues);
    }

    if (error is SocketException) {
      return AppLocalizations.of(context)!.couldNotConnectGeneric;
    }
    if (error is HttpException) {
      return AppLocalizations.of(context)!.serverErrorGeneric;
    }
    if (error is HandshakeException) {
      return AppLocalizations.of(context)!.securityCertificateError;
    }

    return null;
  }

  String _formatDioException(
    DioException error, {
    required Iterable<String> sensitiveValues,
  }) {
    return formatServerConnectionDioExceptionForDisplay(
      error,
      sensitiveValues: sensitiveValues,
    );
  }

  String _cleanExceptionPrefix(String error) {
    return error
        .replaceFirst('Exception: ', '')
        .replaceFirst('DioException [', '[');
  }

  @override
  Widget build(BuildContext context) {
    final reviewerMode = ref.watch(reviewerModeProvider);
    final l10n = AppLocalizations.of(context)!;
    // Kept current for Back, which waits for it.
    if (widget.addingAccount) ref.watch(pendingSignInAbandonableProvider);

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
        onTitleLongPress: _editingRoutes ? null : _toggleReviewerMode,
        backNavigation: UtilityBackNavigation(
          label: l10n.back,
          buttonKey: const ValueKey<String>('server-connection-back-button'),
          onPressed: _goBack,
        ),
        bottomAction: _buildConnectButton(),
        body: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (reviewerMode) ...[
                _buildReviewerModeSection(),
                const SizedBox(height: Spacing.xl),
              ],
              _buildServerForm(),
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
                    Text(
                      l10n.allowSelfSignedCertificates,
                      style: theme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.textPrimary,
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
      text: _isConnecting
          ? AppLocalizations.of(context)!.connecting
          : _editingRoutes
          ? AppLocalizations.of(context)!.accountsSaveAddress
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
      _connectionError = null;
    });
    ConduitHaptics.lightImpact();
  }
}

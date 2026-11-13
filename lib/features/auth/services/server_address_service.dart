import 'dart:convert';
import 'dart:io' show File, HandshakeException, HttpException, SocketException;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/auth/openwebui_address_check.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/network/conduit_user_agent.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_route_resolver.dart'
    show
        logoutFenceSuppressesCookies,
        openWebUiRouteResolverProvider,
        reloadAfterRoutesEdited;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show authTokenProvider3;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/sensitive_value_utils.dart';
import 'package:conduit_core/utils/unicode_prefix.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart' show PlatformFile;
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

/// Checking and saving an address of an Open WebUI server: what the server
/// address editor does, whichever Settings draws it, and what the connection
/// page does after a proxy's own sign-in.

const int _maxConnectionProviderDetailCharacters = 300;

/// The longest a connection error shown to the user is.
const int maxConnectionErrorCharacters = 640;
const int _maxConnectionSecretCharacters = 8 * 1024;
const int _maxConnectionSecretPatterns = 32;
const int _maxConnectionSecretTotalCharacters = 32 * 1024;

/// Builds the deliberately credential-free client options used to discover
/// whether a scheme-less address redirects from HTTP to HTTPS.
///
/// This request is the only request sent before the user-selected scheme is
/// known. Custom headers can contain bearer tokens, cookies, or reverse-proxy
/// credentials, so they must not be exposed to the initial plaintext origin.
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
          maxCharacters: maxConnectionErrorCharacters,
        ) ??
        'Could not connect to the server.';
  }

  final formatted = '${error.type.name} while contacting the server';
  return _normalizeAndBoundConnectionText(
        formatted,
        maxCharacters: maxConnectionErrorCharacters,
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

/// Checks that [address] reaches the saved server [serverId]
/// ([checkOpenWebUiAddress]) with its accounts' sessions: the live one of
/// the active account and those kept for the others.
///
/// Active as storage counts it, which keeps no id for an account only
/// flagged active or the only one saved; its session is the live one, not
/// one kept for an inactive account. Returns what the check found and that
/// account's id. Throws when storage cannot be read.
Future<({OpenWebUiAddressCheckResult found, String? activeAccountId})>
checkSavedServerAddress(
  ProviderContainer container, {
  required OpenWebUiRegistry registry,
  required String serverId,
  required String address,
  required Future<bool> Function(Uri address) confirmSendingSession,
  required Future<String> Function(String accountId, String token) userAt,
}) async {
  final storage = container.read(optimizedStorageServiceProvider);
  final activeAccountId = await storage.getEffectiveActiveServerId();
  final found = await checkOpenWebUiAddress(
    registry: registry,
    serverId: serverId,
    address: address,
    activeAccountId: activeAccountId,
    liveToken: container.read(authTokenProvider3),
    keptTokenFor: storage.vaultedTokenFor,
    accountsWithSession: await storage.accountIdsWithSession(),
    confirmSendingSession: confirmSendingSession,
    userAt: userAt,
  );
  return (found: found, activeAccountId: activeAccountId);
}

/// Saves [route], an address of the server [serverId] that has just been
/// checked -- in place of the address of its id, or as a new one when
/// [adding] -- and keeps the proxy cookie in [headers] for [cookieOwner], the
/// account whose session proved it (see
/// [OptimizedStorageService.editServerEndpointsWithSession]).
///
/// The address and its cookie are saved together: saved without it, an
/// address behind a proxy would be refused. When the cookie cannot be kept
/// nothing is saved, and the address in use stays where it was; a failure is
/// rethrown for the editor to report. Returns false when there is no
/// [cookieOwner] to keep the cookie for, or storage declined it, a sign-out
/// having revoked cookies since [sessionRevision].
Future<bool> saveCheckedAddress(
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
  List<OpenWebUiEndpoint> edit(List<OpenWebUiEndpoint> endpoints) =>
      withEditedRoute(endpoints, route, adding: adding);
  final bool saved;
  if (headers.keys.any(isCapturedSessionHeader)) {
    saved =
        cookieOwner != null &&
        await storage.editServerEndpointsWithSession(
          serverId,
          edit,
          accountId: cookieOwner,
          routeId: route.id,
          headers: headers,
          sessionRevision: sessionRevision,
        );
  } else {
    await storage.editServerEndpoints(serverId, edit);
    saved = true;
  }
  if (!saved) return false;
  // The addresses shown and the route in use follow it, and the clients
  // when the active connection changed.
  await reloadAfterRoutesEdited(container, serverId, endpointId: route.id);
  return true;
}

/// The account of [serverId] a proxy sign-in on one of its addresses is kept
/// for: the one whose session proved the address, else -- with nothing to
/// prove -- the active account when it is one of the server's, else the
/// server's only account. None when it could be any of several.
///
/// Accounts still being signed in to are not counted: none is a user yet.
String? addressCookieOwner(
  OpenWebUiRegistry registry, {
  required String serverId,
  required String? provedBy,
  required String? activeAccountId,
}) {
  if (provedBy != null) return provedBy;
  final accounts = [
    for (final account in registry.accountsOn(serverId))
      if (account.userId != null) account.id,
  ];
  if (accounts.contains(activeAccountId)) return activeAccountId;
  return accounts.length == 1 ? accounts.single : null;
}

/// The most custom headers an address carries.
const maxServerAddressHeaders = 10;

/// What an address editor holds: where the address is, what to call it,
/// and how to reach it -- its headers, whether a self-signed certificate is
/// trusted, and a client certificate with its key.
final class ServerAddressDraft {
  ServerAddressDraft({
    this.url = '',
    this.label = '',
    Map<String, String>? headers,
    this.allowSelfSigned = false,
    this.certificatePem,
    this.certificateLabel,
    this.privateKeyPem,
    this.privateKeyLabel,
    this.privateKeyPassword = '',
  }) : headers = {...?headers};

  /// The draft of [endpoint] as saved, its session headers left out: they
  /// belong to the accounts, and stay with the address.
  factory ServerAddressDraft.of(OpenWebUiEndpoint endpoint) =>
      ServerAddressDraft(
        url: endpoint.url,
        label: endpoint.label ?? '',
        headers: {
          for (final entry in endpoint.customHeaders.entries)
            if (!isCapturedSessionHeader(entry.key)) entry.key: entry.value,
        },
        allowSelfSigned: endpoint.allowSelfSignedCertificates,
        certificatePem: endpoint.mtlsCertificateChainPem,
        certificateLabel: endpoint.mtlsCertificateLabel,
        privateKeyPem: endpoint.mtlsPrivateKeyPem,
        privateKeyLabel: endpoint.mtlsPrivateKeyLabel,
        privateKeyPassword: endpoint.mtlsPrivateKeyPassword ?? '',
      );

  String url;
  String label;
  final Map<String, String> headers;
  bool allowSelfSigned;
  String? certificatePem;
  String? certificateLabel;
  String? privateKeyPem;
  String? privateKeyLabel;
  String privateKeyPassword;

  bool get hasCertificate => certificatePem?.isNotEmpty ?? false;
  bool get hasPrivateKey => privateKeyPem?.isNotEmpty ?? false;

  /// The key's password as it is sent, or null when none was typed.
  String? get normalizedPrivateKeyPassword {
    final trimmed = privateKeyPassword.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool get hasMutualTlsInput =>
      hasCertificate || hasPrivateKey || normalizedPrivateKeyPassword != null;

  void clearMutualTls() {
    certificatePem = null;
    certificateLabel = null;
    privateKeyPem = null;
    privateKeyLabel = null;
    privateKeyPassword = '';
  }

  /// What the draft holds, to tell whether it was edited.
  Object get contents => (
    url,
    label,
    [for (final header in headers.entries) '${header.key}\u0000${header.value}']
        .join('\u0001'),
    allowSelfSigned,
    certificatePem,
    privateKeyPem,
    privateKeyPassword,
  );
}

/// Why something typed into an address editor cannot be used, as the user
/// is told it.
@immutable
final class ServerAddressInputException implements Exception {
  const ServerAddressInputException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [input] as a server address: with a scheme (http when none was typed)
/// and no trailing slash. Throws a [ServerAddressInputException] saying what
/// is wrong with it.
String formatServerAddressInput(String input, AppLocalizations l10n) {
  var url = input.trim();
  if (url.isEmpty) throw ServerAddressInputException(l10n.serverUrlEmpty);
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    url = 'http://$url';
  }
  if (url.endsWith('/')) url = url.substring(0, url.length - 1);
  final uri = Uri.tryParse(url);
  if (uri == null) throw ServerAddressInputException(l10n.invalidUrlFormat);
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw ServerAddressInputException(l10n.onlyHttpHttps);
  }
  if (uri.host.isEmpty) {
    throw ServerAddressInputException(l10n.serverAddressRequired);
  }
  if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
    throw ServerAddressInputException(l10n.portRange);
  }
  if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(uri.host) &&
      !uri.host.split('.').every((part) {
        final number = int.tryParse(part);
        return number != null && number >= 0 && number <= 255;
      })) {
    throw ServerAddressInputException(l10n.invalidIpFormat);
  }
  return url;
}

/// Whether [input] names its scheme itself.
bool hasExplicitHttpScheme(String input) {
  final normalized = input.trim().toLowerCase();
  return normalized.startsWith('http://') || normalized.startsWith('https://');
}

/// [url], typed without a scheme and so tried over http first, as the https
/// address its server redirects to on the same host; else [url] itself. The
/// probe carries no custom header, which may hold credentials.
Future<String> upgradeSchemeLessServerUrl(String url) async {
  final original = Uri.parse(url);
  if (original.scheme != 'http') return url;
  final dio = Dio(buildSchemeLessPlaintextHealthProbeOptions(url));
  try {
    final response = await dio.get('/health');
    return _sameHostHttpsRedirect(
          original,
          statusCode: response.statusCode,
          location: response.headers.value('location'),
        ) ??
        url;
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

String? _sameHostHttpsRedirect(
  Uri original, {
  required int? statusCode,
  required String? location,
}) {
  if (location == null || location.isEmpty) return null;
  if (!const {301, 302, 303, 307, 308}.contains(statusCode)) return null;
  final redirect = original.resolve(location);
  if (redirect.scheme != 'https' ||
      redirect.host.toLowerCase() != original.host.toLowerCase()) {
    return null;
  }
  final path = original.path == '/'
      ? ''
      : original.path.replaceFirst(RegExp(r'/+$'), '');
  return Uri(
    scheme: 'https',
    host: redirect.host,
    port: redirect.hasPort && redirect.port != 443 ? redirect.port : null,
    path: path,
  ).toString();
}

/// The host of [url], as a server is named until it names itself.
String serverNameFromUrl(String url) {
  final host = Uri.tryParse(url)?.host;
  return host == null || host.isEmpty ? 'Server' : host;
}

const _reservedHeaderNames = {
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

/// What is wrong with [name] as a custom header's name, or null.
String? validateServerAddressHeaderName(String name, AppLocalizations l10n) {
  if (name.isEmpty) return null;
  if (name.length > 64) return l10n.headerNameTooLong;
  // RFC 7230 token characters.
  if (!RegExp(r'^[a-zA-Z0-9!#$&\-^_`|~]+$').hasMatch(name)) {
    return l10n.headerNameInvalidChars;
  }
  if (_reservedHeaderNames.contains(name.toLowerCase())) {
    return l10n.headerNameReserved(name);
  }
  return null;
}

/// What is wrong with [value] as a custom header's value, or null.
String? validateServerAddressHeaderValue(String value, AppLocalizations l10n) {
  if (value.isEmpty) return null;
  if (value.length > 1024) return l10n.headerValueTooLong;
  for (final unit in value.codeUnits) {
    // Printable ASCII and tab.
    if (unit != 9 && (unit < 32 || unit > 126)) {
      return l10n.headerValueInvalidChars;
    }
  }
  if (value.toLowerCase().contains('script') ||
      value.contains('<') ||
      value.contains('>')) {
    return l10n.headerValueUnsafe;
  }
  return null;
}

/// What is wrong with adding header [name] with [value] to [headers], or
/// null when it can be added.
String? validateServerAddressHeader(
  Map<String, String> headers, {
  required String name,
  required String value,
  required AppLocalizations l10n,
}) {
  if (name.isEmpty || value.isEmpty) return l10n.authFieldRequired;
  final problem =
      validateServerAddressHeaderName(name, l10n) ??
      validateServerAddressHeaderValue(value, l10n);
  if (problem != null) return problem;
  if (headers.containsKey(name)) return l10n.headerAlreadyExists(name);
  if (headers.length >= maxServerAddressHeaders) {
    return l10n.maxHeadersReachedDetail;
  }
  return null;
}

/// What is missing from [draft]'s client certificate, or null: a
/// certificate needs its key, and a password needs both.
String? validateServerAddressMutualTls(
  ServerAddressDraft draft,
  AppLocalizations l10n,
) {
  if (!draft.hasCertificate && !draft.hasPrivateKey) {
    return draft.normalizedPrivateKeyPassword == null
        ? null
        : l10n.mutualTlsMissingCredentialPair;
  }
  return draft.hasCertificate && draft.hasPrivateKey
      ? null
      : l10n.mutualTlsMissingCredentialPair;
}

/// What is wrong with [content] as a PEM certificate chain, or with
/// [isPrivateKey] a PEM private key, or null.
String? validatePickedPem(
  String content, {
  required bool isPrivateKey,
  required AppLocalizations l10n,
}) {
  if (isPrivateKey) {
    return content.contains('BEGIN ') && content.contains('PRIVATE KEY')
        ? null
        : l10n.mutualTlsPrivateKeyPemRequired;
  }
  return content.contains('BEGIN CERTIFICATE')
      ? null
      : l10n.mutualTlsCertificatePemRequired;
}

/// The text of a picked PEM file. Throws a [ServerAddressInputException]
/// when it is empty or not text.
Future<String> readPickedPemFile(
  PlatformFile file,
  AppLocalizations l10n,
) async {
  final bytes = file.path != null
      ? await File(file.path!).readAsBytes()
      : await file.readAsBytes();
  if (bytes.isEmpty) {
    throw ServerAddressInputException(l10n.mutualTlsFileReadFailed);
  }
  try {
    return utf8.decode(bytes).trim();
  } catch (_) {
    throw ServerAddressInputException(l10n.mutualTlsFileReadFailed);
  }
}

/// What a picked file is called, from its name or path, else [fallback].
String pickedFileLabel(PlatformFile file, {required String fallback}) {
  final name = file.name.trim();
  if (name.isNotEmpty) return name;
  final path = file.path?.trim();
  if (path != null && path.isNotEmpty) {
    final last = path.replaceAll('\\', '/').split('/').last;
    if (last.isNotEmpty) return last;
  }
  return fallback;
}

/// [error], from connecting to an address, as the user is told it, with
/// [sensitiveValues] -- the headers' values -- kept out of it.
String formatServerConnectionError(
  Object error, {
  required Iterable<String> sensitiveValues,
  required bool hasMutualTlsInput,
  required AppLocalizations l10n,
}) {
  if (error is ServerAddressInputException) return error.message;
  final errorText = error.toString();
  final cleanError =
      sanitizeServerConnectionProviderText(
        errorText
            .replaceFirst('Exception: ', '')
            .replaceFirst('DioException [', '['),
        sensitiveValues: sensitiveValues,
        maxCharacters: maxConnectionErrorCharacters,
      ) ??
      l10n.couldNotConnectGeneric;
  if (errorText.contains('mTLS certificate setup failed')) return cleanError;
  if (isLikelyMutualTlsRejection(
    errorText,
    hasMutualTlsInput: hasMutualTlsInput,
  )) {
    return l10n.mutualTlsHandshakeFailed;
  }
  if (isConnectionClosedWithClientCertificate(
    errorText,
    hasMutualTlsInput: hasMutualTlsInput,
  )) {
    return l10n.mutualTlsConnectionClosed;
  }
  switch (error) {
    case DioException(response: null, type: DioExceptionType.badCertificate):
      return l10n.securityCertificateError;
    case DioException(response: null):
      return l10n.couldNotConnectGeneric;
    case DioException():
      return formatServerConnectionDioExceptionForDisplay(
        error,
        sensitiveValues: sensitiveValues,
      );
    case SocketException():
      return l10n.couldNotConnectGeneric;
    case HttpException():
      return l10n.serverErrorGeneric;
    case HandshakeException():
      return l10n.securityCertificateError;
  }
  if (errorText.contains('This does not appear to be an Open-WebUI server')) {
    return l10n.serverNotOpenWebUI;
  }
  return cleanError.isEmpty ? l10n.couldNotConnectGeneric : cleanError;
}

/// [draft] with the proxy cookie the server's accounts keep on the address
/// being edited, [endpointId]: the cookie of the first of [accountIds] that
/// has one there. Unchanged when adding an address, or once [draft] reaches
/// somewhere else ([keptAddressSessionHeaders]).
ServerConfig withKeptAddressCookie(
  ServerConfig draft, {
  required OpenWebUiRegistry registry,
  required String serverId,
  required String? endpointId,
  required Iterable<String> accountIds,
}) {
  if (endpointId == null) return draft;
  final kept = keptAddressSessionHeaders(
    registry: registry,
    serverId: serverId,
    endpointId: endpointId,
    draft: draft,
    accountIds: accountIds,
  );
  return kept.isEmpty
      ? draft
      : draft.copyWith(customHeaders: {...draft.customHeaders, ...kept});
}

/// What checking an address found.
sealed class ServerAddressCheck {
  const ServerAddressCheck();
}

/// It answered as an Open WebUI server: [config] is the address to save.
/// [sessionRevision] is the storage's session revision before the check, so
/// a cookie captured after a sign-out revoked them is not kept.
final class ServerAddressAnswered extends ServerAddressCheck {
  const ServerAddressAnswered(this.config, this.sessionRevision);

  final ServerConfig config;
  final int sessionRevision;
}

/// A proxy in front of it wants its own sign-in first, a page of its own.
final class ServerAddressBehindProxy extends ServerAddressCheck {
  const ServerAddressBehindProxy(this.config, this.sessionRevision);

  final ServerConfig config;
  final int sessionRevision;
}

/// It could not be used, for [message].
final class ServerAddressUnusable extends ServerAddressCheck {
  const ServerAddressUnusable(this.message);

  final String message;
}

/// Checks [draft], an address of the saved server [serverId] -- the one of
/// [endpointId] being edited, or a new one -- for being an Open WebUI server
/// that answers. An edit that still reaches the address as stored passes its
/// proxy with the cookie the server's accounts keep there.
Future<ServerAddressCheck> checkServerAddressDraft(
  ProviderContainer container, {
  required String serverId,
  required String? endpointId,
  required ServerAddressDraft draft,
  required AppLocalizations l10n,
}) async {
  final storage = container.read(optimizedStorageServiceProvider);
  // Before anything is awaited: a sign-out from here on revokes whatever
  // cookie the check or a proxy sign-in captures.
  final sessionRevision = storage.sessionRevocationRevision;
  final tls = validateServerAddressMutualTls(draft, l10n);
  if (tls != null) return ServerAddressUnusable(tls);
  var sensitive = <String>[...draft.headers.values];
  ApiService? api;
  try {
    var url = formatServerAddressInput(draft.url, l10n);
    if (!hasExplicitHttpScheme(draft.url)) {
      url = await upgradeSchemeLessServerUrl(url);
    }
    final config = ServerConfig(
      id: const Uuid().v4(),
      name: serverNameFromUrl(url),
      url: url,
      customHeaders: Map.of(draft.headers),
      isActive: true,
      allowSelfSignedCertificates: draft.allowSelfSigned,
      mtlsCertificateChainPem: draft.certificatePem,
      mtlsCertificateLabel: draft.certificateLabel,
      mtlsPrivateKeyPem: draft.privateKeyPem,
      mtlsPrivateKeyLabel: draft.privateKeyLabel,
      mtlsPrivateKeyPassword: draft.normalizedPrivateKeyPassword,
    );
    final registry = await storage.getOpenWebUiRegistryStrict();
    final activeId = await storage.getEffectiveActiveServerId();
    final checkConfig = withKeptAddressCookie(
      config,
      registry: registry,
      serverId: serverId,
      endpointId: endpointId,
      accountIds: [
        ?activeId,
        for (final account in registry.accountsOn(serverId)) account.id,
      ],
    );
    sensitive = [...sensitive, ...checkConfig.customHeaders.values];
    final check = api = buildAddressCheckApi(container, checkConfig);
    switch (await check.checkHealthWithProxyDetection(
      throwOnConnectionError: true,
    )) {
      case HealthCheckResult.proxyAuthRequired:
        return ServerAddressBehindProxy(config, sessionRevision);
      case HealthCheckResult.unreachable:
        return ServerAddressUnusable(l10n.couldNotConnectGeneric);
      case HealthCheckResult.notOpenWebUI:
        return ServerAddressUnusable(l10n.serverNotOpenWebUI);
      case HealthCheckResult.unhealthy:
        return ServerAddressUnusable(l10n.serverErrorUnavailable);
      case HealthCheckResult.healthy:
        break;
    }
    if (await check.verifyAndGetConfig() == null) {
      return ServerAddressUnusable(l10n.serverNotOpenWebUI);
    }
    return ServerAddressAnswered(config, sessionRevision);
  } catch (error) {
    DebugLogger.error(
      'server-address-check-failed',
      scope: 'auth/connection',
      data: {'errorType': error.runtimeType.toString()},
    );
    return ServerAddressUnusable(
      formatServerConnectionError(
        error,
        sensitiveValues: sensitive,
        hasMutualTlsInput: draft.hasMutualTlsInput,
        l10n: l10n,
      ),
    );
  } finally {
    api?.dispose();
  }
}

/// What saving a checked address came to.
sealed class ServerAddressSave {
  const ServerAddressSave();
}

/// Saved, and the server's accounts reach it now.
final class ServerAddressSaved extends ServerAddressSave {
  const ServerAddressSaved();
}

/// Not saved, for [message]; with none, the user chose not to go on.
final class ServerAddressNotSaved extends ServerAddressSave {
  const ServerAddressNotSaved([this.message]);

  final String? message;
}

/// Saves [verified] -- an address that answered as an Open WebUI server --
/// as an address of the saved server [serverId]: in place of the one of
/// [endpointId], or as a new one under [addedEndpointId], called [label].
///
/// The address must also know the server's accounts: a token one of them
/// holds has to name the same user through it, else every account here
/// would start sending its session to another server. Sending a session to
/// a host it has not reached before is asked first ([confirmSendingSession]),
/// and so is changing the address in use while a reply arrives through it
/// ([confirmChangingInUse]). An editor left while the address was checked
/// abandons the edit ([stillWanted]): the address stays as it was.
Future<ServerAddressSave> saveVerifiedServerAddress(
  ProviderContainer container, {
  required String serverId,
  required String? endpointId,
  required String addedEndpointId,
  required String label,
  required ServerConfig verified,
  required int sessionRevision,
  required AppLocalizations l10n,
  required Future<bool> Function(Uri address) confirmSendingSession,
  required Future<bool> Function() confirmChangingInUse,
  required bool Function() stillWanted,
}) async {
  final storage = container.read(optimizedStorageServiceProvider);
  final registry = await storage.getOpenWebUiRegistryStrict();
  final server = registry.server(serverId);
  if (server == null) return ServerAddressNotSaved(l10n.errorMessage);

  ServerConfig keptCookie(Iterable<String> accountIds) => withKeptAddressCookie(
    verified,
    registry: registry,
    serverId: serverId,
    endpointId: endpointId,
    accountIds: accountIds,
  );
  final (:found, :activeAccountId) = await checkSavedServerAddress(
    container,
    registry: registry,
    serverId: server.id,
    address: verified.url,
    confirmSendingSession: confirmSendingSession,
    userAt: (accountId, token) async {
      // Each account's token travels with its own proxy cookie only.
      final probe = buildAddressCheckApi(
        container,
        keptCookie([accountId]),
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
  final (result: check, :provedBy) = found;
  switch (check) {
    case OpenWebUiAddressCheck.differentServer:
      return ServerAddressNotSaved(l10n.accountsAddressDifferentServer);
    case OpenWebUiAddressCheck.needsSignIn:
      return ServerAddressNotSaved(l10n.accountsAddressNeedsSignIn);
    case OpenWebUiAddressCheck.declined:
      // Nothing was sent, as the user chose.
      return const ServerAddressNotSaved();
    case OpenWebUiAddressCheck.sameServer ||
        OpenWebUiAddressCheck.nothingToProtect:
      break;
  }
  if (!stillWanted()) return const ServerAddressNotSaved();

  final trimmedLabel = label.trim();
  final route = OpenWebUiEndpoint(
    id: endpointId ?? addedEndpointId,
    url: verified.url,
    label: trimmedLabel.isEmpty ? null : trimmedLabel,
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
  // proved it, which need not be the active one.
  final cookieOwner = addressCookieOwner(
    registry,
    serverId: server.id,
    provedBy: provedBy,
    activeAccountId: activeAccountId,
  );
  if (cookieOwner == null &&
      verified.customHeaders.keys.any(isCapturedSessionHeader)) {
    // Kept for none of them, the address would be saved for the proxy to
    // refuse. Once one of them is signed in to, it is that one's.
    return ServerAddressNotSaved(l10n.accountsAddressNeedsSignIn);
  }
  // Saved, the address in use moves the clients off it, ending a reply
  // arriving through them; that is asked first.
  final inUse = container.read(openWebUiRouteResolverProvider);
  if (endpointId != null &&
      inUse.serverId == server.id &&
      inUse.endpointId == endpointId &&
      !await confirmChangingInUse()) {
    return const ServerAddressNotSaved();
  }
  if (!stillWanted()) return const ServerAddressNotSaved();
  final kept = await saveCheckedAddress(
    container,
    serverId: server.id,
    route: route,
    adding: endpointId == null,
    cookieOwner: cookieOwner,
    headers: verified.customHeaders,
    sessionRevision: sessionRevision,
  );
  // Not saved: the proxy sign-in that lets requests through was revoked;
  // signing in through the proxy again captures a new one.
  return kept
      ? const ServerAddressSaved()
      : ServerAddressNotSaved(l10n.proxyAuthFailed);
}

/// Where the address editor route goes: the address [endpointId] of the
/// saved server [serverId], or a new one when null. With [draft], the edit
/// was handed over from Settings to sign in through a proxy, and the
/// connection page carries on with it.
@immutable
class ServerAddressEditorRequest {
  const ServerAddressEditorRequest({
    required this.serverId,
    this.endpointId,
    this.draft,
  });

  final String serverId;

  /// The address to edit; null adds one.
  final String? endpointId;
  final ServerAddressDraft? draft;
}

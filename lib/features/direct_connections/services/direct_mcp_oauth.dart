import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:url_launcher/url_launcher.dart';

import '../models/direct_mcp_server.dart';
import 'direct_mcp_server_store.dart';

const int _maxOAuthDocumentBytes = 256 * 1024;
const int _maxCallbackBytes = 8 * 1024;
const String _callbackPathPrefix = '/mcp-oauth/callback/';

typedef DirectMcpOAuthBrowserLauncher = Future<bool> Function(Uri uri);
typedef DirectMcpOAuthClock = DateTime Function();

final class DirectMcpOAuthException implements Exception {
  const DirectMcpOAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Owns one public-client OAuth flow per MCP server.
final class DirectMcpOAuthCoordinator {
  DirectMcpOAuthCoordinator({
    required DirectMcpServerStore store,
    http.Client? client,
    DirectMcpOAuthBrowserLauncher? launchBrowser,
    DirectMcpOAuthClock? now,
    this.flowTimeout = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 15),
  }) : _store = store,
       _client = client ?? http.Client(),
       _launchBrowser = launchBrowser ?? _launchExternalBrowser,
       _now = now ?? DateTime.now;

  final DirectMcpServerStore _store;
  final http.Client _client;
  final DirectMcpOAuthBrowserLauncher _launchBrowser;
  final DirectMcpOAuthClock _now;
  final Duration flowTimeout;
  final Duration requestTimeout;
  final Map<String, _PendingOAuthFlow> _pending = {};
  final Map<String, Future<DirectMcpOAuthTokens>> _refreshes = {};
  final Map<String, int> _generations = {};
  bool _closed = false;

  bool isPending(String serverId) => _pending.containsKey(serverId);

  Future<DirectMcpServer> connect(DirectMcpServer server) async {
    _requireOpen();
    if (server.authMode != DirectMcpAuthMode.oauth) {
      throw const DirectMcpOAuthException(
        'Select OAuth before connecting this MCP server.',
      );
    }
    server.validate();
    _requireSecureUri(server.endpointUri, allowLoopbackHttp: true);
    await cancel(server.id);
    final generation = (_generations[server.id] ?? 0) + 1;
    _generations[server.id] = generation;
    final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final state = _randomValue(32);
    final verifier = _randomValue(32);
    final callbackPath = '$_callbackPathPrefix${_randomValue(16)}';
    final redirectUri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: listener.port,
      path: callbackPath,
    );
    final flow = _PendingOAuthFlow(
      server: server,
      generation: generation,
      listener: listener,
      state: state,
      verifier: verifier,
      redirectUri: redirectUri,
      expiresAt: _now().toUtc().add(flowTimeout),
    );
    _pending[server.id] = flow;

    try {
      final metadata = await _discover(server);
      _requireCurrent(flow);
      final clientId = await _registerPublicClient(metadata, redirectUri);
      _requireCurrent(flow);
      flow.metadata = metadata;
      flow.clientId = clientId;
      final authorizationUri = metadata.authorizationEndpoint.replace(
        queryParameters: {
          ...metadata.authorizationEndpoint.queryParameters,
          'response_type': 'code',
          'client_id': clientId,
          'redirect_uri': redirectUri.toString(),
          'code_challenge': _pkceChallenge(verifier),
          'code_challenge_method': 'S256',
          'state': state,
          'resource': metadata.resource.toString(),
          if (metadata.scope != null) 'scope': metadata.scope!,
        },
      );
      final callback = _receiveCallback(flow);
      if (!await _launchBrowser(authorizationUri)) {
        unawaited(callback.catchError((_) => _OAuthCallback('')));
        throw const DirectMcpOAuthException(
          'Could not open the system browser for OAuth.',
        );
      }
      final response = await callback;
      _requireCurrent(flow);
      final tokens = await _exchangeCode(
        metadata: metadata,
        clientId: clientId,
        redirectUri: redirectUri,
        verifier: verifier,
        code: response.code,
      );
      _requireCurrent(flow);
      return await _persistTokens(flow, tokens);
    } on DirectMcpOAuthException {
      rethrow;
    } on DirectMcpServerConflictException {
      throw const DirectMcpOAuthException(
        'The MCP server changed while OAuth was in progress. Try again.',
      );
    } catch (_) {
      throw const DirectMcpOAuthException(
        'The MCP OAuth connection could not be completed.',
      );
    } finally {
      if (identical(_pending[server.id], flow)) {
        _pending.remove(server.id);
      }
      await listener.close(force: true);
    }
  }

  Future<String?> accessTokenFor(
    DirectMcpServer server, {
    bool forceRefresh = false,
  }) async {
    switch (server.authMode) {
      case DirectMcpAuthMode.none:
        return null;
      case DirectMcpAuthMode.bearer:
        return server.bearerToken;
      case DirectMcpAuthMode.oauth:
        final current = await _currentOAuthServer(server);
        final tokens = current.oauthTokens;
        if (tokens == null) {
          throw const DirectMcpOAuthException(
            'Connect this MCP server with OAuth before using its tools.',
          );
        }
        final expiry = tokens.expiresAt;
        final needsRefresh =
            forceRefresh ||
            (expiry != null &&
                !expiry.isAfter(
                  _now().toUtc().add(const Duration(seconds: 60)),
                ));
        if (!needsRefresh) return tokens.accessToken;
        if (tokens.refreshToken == null) {
          throw const DirectMcpOAuthException(
            'The MCP OAuth session expired. Reconnect this server.',
          );
        }
        final refresh = _refreshes.putIfAbsent(
          server.id,
          () => _refresh(current, tokens),
        );
        try {
          return (await refresh).accessToken;
        } finally {
          if (identical(_refreshes[server.id], refresh)) {
            _refreshes.remove(server.id);
          }
        }
    }
  }

  Future<DirectMcpServer> disconnect(DirectMcpServer server) async {
    await cancel(server.id);
    final current = await _currentOAuthServer(server);
    final updated = current.copyWith(oauthTokens: null);
    final servers = await _store.upsert(
      updated,
      expectedPrevious: current,
      oauthFlowCompletedForExactMutation: true,
    );
    return servers.firstWhere((item) => item.id == server.id);
  }

  Future<void> cancel(String serverId) async {
    _generations[serverId] = (_generations[serverId] ?? 0) + 1;
    final flow = _pending.remove(serverId);
    if (flow != null) {
      if (!flow.cancelled.isCompleted) flow.cancelled.complete();
      await flow.listener.close(force: true);
    }
  }

  Future<void> cancelAll() async {
    for (final id in {..._pending.keys, ..._refreshes.keys}) {
      _generations[id] = (_generations[id] ?? 0) + 1;
    }
    final flows = _pending.values.toList();
    _pending.clear();
    for (final flow in flows) {
      if (!flow.cancelled.isCompleted) flow.cancelled.complete();
      await flow.listener.close(force: true);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await cancelAll();
    _client.close();
  }

  Future<_OAuthMetadata> _discover(DirectMcpServer server) async {
    final endpoint = server.endpointUri;
    final challenged = await _challengeMetadataUri(endpoint);
    final candidates = <Uri>[
      ?challenged,
      if (endpoint.path.isNotEmpty && endpoint.path != '/')
        _wellKnown(
          endpoint,
          '/.well-known/oauth-protected-resource${endpoint.path}',
        ),
      _wellKnown(endpoint, '/.well-known/oauth-protected-resource'),
    ];
    Map<String, dynamic>? protectedJson;
    for (final candidate in _uniqueUris(candidates)) {
      _requireTrustedMetadataUri(candidate, endpoint);
      try {
        protectedJson = await _getJson(candidate);
        break;
      } on DirectMcpOAuthException {
        if (candidate == challenged) rethrow;
      }
    }
    if (protectedJson == null) {
      throw const DirectMcpOAuthException(
        'This MCP server did not publish OAuth protected-resource metadata.',
      );
    }

    mcp.OAuthProtectedResourceMetadataDocument protected;
    try {
      protected = mcp.OAuthProtectedResourceMetadataDocument.fromJson(
        protectedJson,
      );
    } catch (_) {
      throw const DirectMcpOAuthException(
        'The MCP protected-resource metadata is invalid.',
      );
    }
    if (!_resourceMatchesEndpoint(protected.resource, endpoint)) {
      throw const DirectMcpOAuthException(
        'The MCP OAuth resource does not match this server.',
      );
    }
    final issuer = protected.authorizationServers.first;
    _requireSecureUri(issuer, allowLoopbackHttp: _isLoopback(endpoint.host));

    Map<String, dynamic>? authorizationJson;
    for (final candidate in _authorizationMetadataCandidates(issuer)) {
      try {
        authorizationJson = await _getJson(candidate);
        break;
      } on DirectMcpOAuthException {
        // Try the next standards-defined discovery location.
      }
    }
    if (authorizationJson == null) {
      throw const DirectMcpOAuthException(
        'The OAuth authorization server metadata could not be discovered.',
      );
    }
    mcp.OAuthAuthorizationServerMetadataDocument authorization;
    try {
      authorization = mcp.OAuthAuthorizationServerMetadataDocument.fromJson(
        authorizationJson,
      );
    } catch (_) {
      throw const DirectMcpOAuthException(
        'The OAuth authorization server metadata is invalid.',
      );
    }
    if (authorizationJson['issuer'] != issuer.toString()) {
      throw const DirectMcpOAuthException(
        'The OAuth authorization server issuer did not match discovery.',
      );
    }
    final authorizationEndpoint = authorization.authorizationEndpoint;
    final tokenEndpoint = authorization.tokenEndpoint;
    if (authorizationEndpoint == null || tokenEndpoint == null) {
      throw const DirectMcpOAuthException(
        'The OAuth authorization server is missing required endpoints.',
      );
    }
    for (final uri in [
      authorizationEndpoint,
      tokenEndpoint,
      ?authorization.registrationEndpoint,
    ]) {
      _requireSameAuthorizationServer(uri, issuer);
    }
    if (authorization.codeChallengeMethodsSupported?.contains('S256') != true) {
      throw const DirectMcpOAuthException(
        'The OAuth authorization server does not support PKCE S256.',
      );
    }
    final authMethods = authorization.tokenEndpointAuthMethodsSupported;
    if (authMethods != null && !authMethods.contains('none')) {
      throw const DirectMcpOAuthException(
        'This OAuth server requires a confidential client, which Conduit does not support.',
      );
    }
    final supportedScopes = protected.scopesSupported;
    final scope = supportedScopes == null || supportedScopes.isEmpty
        ? null
        : supportedScopes.join(' ');
    return _OAuthMetadata(
      issuer: issuer,
      resource: protected.resource,
      authorizationEndpoint: authorizationEndpoint,
      tokenEndpoint: tokenEndpoint,
      registrationEndpoint: authorization.registrationEndpoint,
      authorizationResponseIssParameterSupported:
          authorization.authorizationResponseIssParameterSupported == true,
      scope: scope,
    );
  }

  Future<Uri?> _challengeMetadataUri(Uri endpoint) async {
    final request = http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers.addAll(const {
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
        HttpHeaders.contentTypeHeader: 'application/json',
      })
      ..body = jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': mcp.Method.serverDiscover,
        'params': const <String, dynamic>{},
      });
    final response = await _send(request);
    final challenge = mcp.OAuthBearerChallengeParameters.fromHeader(
      response.headers[HttpHeaders.wwwAuthenticateHeader],
    );
    await _readBytes(response);
    return challenge?.resourceMetadata;
  }

  Future<String> _registerPublicClient(
    _OAuthMetadata metadata,
    Uri redirectUri,
  ) async {
    final endpoint = metadata.registrationEndpoint;
    if (endpoint == null) {
      throw const DirectMcpOAuthException(
        'This OAuth server requires hosted client metadata or pre-registration, which Conduit does not support.',
      );
    }
    final response = await _postJson(endpoint, {
      'client_name': 'Conduit',
      'redirect_uris': [redirectUri.toString()],
      'grant_types': ['authorization_code', 'refresh_token'],
      'response_types': ['code'],
      'application_type': 'native',
      'token_endpoint_auth_method': 'none',
    });
    final clientId = response['client_id'];
    final authMethod = response['token_endpoint_auth_method'];
    if (clientId is! String ||
        clientId.isEmpty ||
        clientId.length > 4096 ||
        _hasForbiddenCharacter(clientId)) {
      throw const DirectMcpOAuthException(
        'Dynamic client registration returned an invalid client ID.',
      );
    }
    if (authMethod != null && authMethod != 'none') {
      throw const DirectMcpOAuthException(
        'This OAuth server registered a confidential client, which Conduit does not support.',
      );
    }
    return clientId;
  }

  Future<_OAuthCallback> _receiveCallback(_PendingOAuthFlow flow) async {
    final deadline = Stopwatch()..start();
    HttpRequest request;
    try {
      request = await Future.any([
        flow.listener.first,
        flow.cancelled.future.then<HttpRequest>(
          (_) => throw const DirectMcpOAuthException(
            'The MCP OAuth connection was cancelled.',
          ),
        ),
      ]).timeout(flowTimeout);
    } on TimeoutException {
      throw const DirectMcpOAuthException(
        'The MCP OAuth connection timed out. Try again.',
      );
    }
    var accepted = false;
    try {
      final callbackSize = utf8.encode(request.uri.toString()).length;
      if (request.method != 'GET' ||
          request.uri.path != flow.redirectUri.path ||
          request.requestedUri.host != '127.0.0.1' ||
          request.requestedUri.port != flow.redirectUri.port ||
          callbackSize > _maxCallbackBytes) {
        throw const DirectMcpOAuthException(
          'The MCP OAuth callback was rejected.',
        );
      }
      final all = request.uri.queryParametersAll;
      if (all.values.any((values) => values.length != 1) ||
          all.keys.any(
            (key) => !const {
              'code',
              'state',
              'iss',
              'error',
              'error_description',
            }.contains(key),
          )) {
        throw const DirectMcpOAuthException(
          'The MCP OAuth callback was rejected.',
        );
      }
      if (all.containsKey('error')) {
        throw const DirectMcpOAuthException(
          'The OAuth server declined authorization.',
        );
      }
      final state = request.uri.queryParameters['state'];
      final code = request.uri.queryParameters['code'];
      final issuer = request.uri.queryParameters['iss'];
      final metadata = flow.metadata!;
      if (state == null ||
          state != flow.state ||
          code == null ||
          code.isEmpty) {
        throw const DirectMcpOAuthException(
          'The MCP OAuth callback did not match the pending connection.',
        );
      }
      if (_now().toUtc().isAfter(flow.expiresAt)) {
        throw const DirectMcpOAuthException(
          'The MCP OAuth connection expired. Try again.',
        );
      }
      if ((metadata.authorizationResponseIssParameterSupported &&
              issuer == null) ||
          (issuer != null && issuer != metadata.issuer.toString())) {
        throw const DirectMcpOAuthException(
          'The MCP OAuth callback issuer did not match.',
        );
      }
      if (code.length > 4096 || _hasForbiddenCharacter(code)) {
        throw const DirectMcpOAuthException(
          'The MCP OAuth callback code was invalid.',
        );
      }
      final remaining = flowTimeout - deadline.elapsed;
      if (remaining <= Duration.zero) {
        throw const DirectMcpOAuthException(
          'The MCP OAuth connection timed out. Try again.',
        );
      }
      final iterator = StreamIterator<List<int>>(request);
      var bodyTimedOut = false;
      final timer = Timer(
        remaining < const Duration(seconds: 2)
            ? remaining
            : const Duration(seconds: 2),
        () {
          bodyTimedOut = true;
          unawaited(iterator.cancel());
        },
      );
      var bodyBytes = 0;
      try {
        while (await iterator.moveNext()) {
          bodyBytes += iterator.current.length;
          if (bodyBytes > _maxCallbackBytes) {
            throw const DirectMcpOAuthException(
              'The MCP OAuth callback was rejected.',
            );
          }
          if (deadline.elapsed >= flowTimeout) {
            throw const DirectMcpOAuthException(
              'The MCP OAuth connection timed out. Try again.',
            );
          }
        }
      } finally {
        timer.cancel();
        await iterator.cancel();
      }
      if (bodyTimedOut) {
        throw const DirectMcpOAuthException(
          'The MCP OAuth connection timed out. Try again.',
        );
      }
      accepted = true;
      return _OAuthCallback(code);
    } finally {
      request.response
        ..statusCode = accepted ? HttpStatus.ok : HttpStatus.badRequest
        ..headers.contentType = ContentType.html
        ..write(
          accepted
              ? 'Authorization received. Return to Conduit.'
              : 'Authorization rejected. Return to Conduit.',
        );
      await request.response.close();
      await flow.listener.close(force: true);
    }
  }

  Future<DirectMcpOAuthTokens> _exchangeCode({
    required _OAuthMetadata metadata,
    required String clientId,
    required Uri redirectUri,
    required String verifier,
    required String code,
  }) async {
    final response = await _postForm(metadata.tokenEndpoint, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri.toString(),
      'client_id': clientId,
      'code_verifier': verifier,
      'resource': metadata.resource.toString(),
    });
    return _parseTokens(response, metadata: metadata, clientId: clientId);
  }

  Future<DirectMcpOAuthTokens> _refresh(
    DirectMcpServer server,
    DirectMcpOAuthTokens previous,
  ) async {
    final generation = _generations[server.id] ?? 0;
    final response = await _postForm(Uri.parse(previous.tokenEndpoint), {
      'grant_type': 'refresh_token',
      'refresh_token': previous.refreshToken!,
      'client_id': previous.clientId,
      'resource': previous.resource,
    }, invalidGrant: () => _clearInvalidGrant(server, generation));
    _requireGeneration(server.id, generation);
    final metadata = _OAuthMetadata(
      issuer: Uri.parse(previous.authorizationServerIssuer),
      resource: Uri.parse(previous.resource),
      authorizationEndpoint: Uri(),
      tokenEndpoint: Uri.parse(previous.tokenEndpoint),
      authorizationResponseIssParameterSupported: false,
      scope: previous.grantedScope,
    );
    final refreshed = _parseTokens(
      response,
      metadata: metadata,
      clientId: previous.clientId,
      previous: previous,
    );
    final current = await _requireUnchangedServer(server);
    _requireGeneration(server.id, generation);
    await _store.upsert(
      current.copyWith(oauthTokens: refreshed),
      expectedPrevious: current,
      oauthFlowCompletedForExactMutation: true,
    );
    _requireGeneration(server.id, generation);
    return refreshed;
  }

  Future<void> _clearInvalidGrant(
    DirectMcpServer server,
    int generation,
  ) async {
    _requireGeneration(server.id, generation);
    final current = await _requireUnchangedServer(server);
    _requireGeneration(server.id, generation);
    await _store.upsert(
      current.copyWith(oauthTokens: null),
      expectedPrevious: current,
      oauthFlowCompletedForExactMutation: true,
    );
  }

  DirectMcpOAuthTokens _parseTokens(
    Map<String, dynamic> json, {
    required _OAuthMetadata metadata,
    required String clientId,
    DirectMcpOAuthTokens? previous,
  }) {
    final accessToken = json['access_token'];
    final refreshToken = json['refresh_token'];
    final tokenType = json['token_type'] ?? 'Bearer';
    final scope = json['scope'];
    final expiresIn = json['expires_in'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        accessToken.length > 16384 ||
        _hasForbiddenCharacter(accessToken) ||
        refreshToken != null && refreshToken is! String ||
        tokenType is! String ||
        tokenType.toLowerCase() != 'bearer' ||
        scope != null && scope is! String ||
        expiresIn != null && (expiresIn is! num || !expiresIn.isFinite)) {
      throw const DirectMcpOAuthException(
        'The OAuth token response was invalid.',
      );
    }
    final expirySeconds = expiresIn == null ? null : (expiresIn as num).toInt();
    if (expirySeconds != null &&
        (expirySeconds <= 0 || expirySeconds > 315360000)) {
      throw const DirectMcpOAuthException(
        'The OAuth token expiry was invalid.',
      );
    }
    final tokens = DirectMcpOAuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken as String? ?? previous?.refreshToken,
      tokenType: tokenType,
      grantedScope:
          scope as String? ?? previous?.grantedScope ?? metadata.scope,
      expiresAt: expirySeconds == null
          ? null
          : _now().toUtc().add(Duration(seconds: expirySeconds)),
      authorizationServerIssuer: metadata.issuer.toString(),
      resource: metadata.resource.toString(),
      clientId: clientId,
      tokenEndpoint: metadata.tokenEndpoint.toString(),
    );
    final error = tokens.validateOrNull(
      serverEndpoint: metadata.resource.toString(),
    );
    if (error != null) throw DirectMcpOAuthException(error);
    return tokens;
  }

  Future<DirectMcpServer> _persistTokens(
    _PendingOAuthFlow flow,
    DirectMcpOAuthTokens tokens,
  ) async {
    final current = await _requireUnchangedServer(flow.server);
    _requireCurrent(flow);
    final updated = current.copyWith(
      authMode: DirectMcpAuthMode.oauth,
      bearerToken: null,
      oauthTokens: tokens,
    );
    final servers = await _store.upsert(
      updated,
      expectedPrevious: current,
      oauthFlowCompletedForExactMutation: true,
    );
    _requireCurrent(flow);
    return servers.firstWhere((server) => server.id == flow.server.id);
  }

  Future<DirectMcpServer> _requireUnchangedServer(
    DirectMcpServer expected,
  ) async {
    final current = (await _store.load())
        .where((server) => server.id == expected.id)
        .firstOrNull;
    if (current == null || !sameDirectMcpServerValues(current, expected)) {
      throw DirectMcpServerConflictException(
        currentServers: current == null ? const [] : [current],
      );
    }
    return current;
  }

  Future<DirectMcpServer> _currentOAuthServer(DirectMcpServer expected) async {
    final current = (await _store.load())
        .where((server) => server.id == expected.id)
        .firstOrNull;
    final sameBinding =
        current != null &&
        sameDirectMcpServerValues(
          current.copyWith(oauthTokens: expected.oauthTokens),
          expected,
        );
    if (!sameBinding) {
      throw const DirectMcpOAuthException(
        'The MCP server changed. Start a new model turn.',
      );
    }
    return current;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers[HttpHeaders.acceptHeader] = 'application/json';
    return _jsonResponse(await _send(request), expectedStatus: HttpStatus.ok);
  }

  Future<Map<String, dynamic>> _postJson(
    Uri uri,
    Map<String, dynamic> body,
  ) async {
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers.addAll(const {
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.contentTypeHeader: 'application/json',
      })
      ..body = jsonEncode(body);
    return _jsonResponse(
      await _send(request),
      expectedStatus: HttpStatus.created,
      alsoAcceptOk: true,
    );
  }

  Future<Map<String, dynamic>> _postForm(
    Uri uri,
    Map<String, String> body, {
    Future<void> Function()? invalidGrant,
  }) async {
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers.addAll(const {
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
      })
      ..bodyFields = body;
    final response = await _send(request);
    if (response.statusCode == HttpStatus.badRequest && invalidGrant != null) {
      final json = await _jsonResponse(
        response,
        expectedStatus: HttpStatus.badRequest,
      );
      if (json['error'] == 'invalid_grant') {
        await invalidGrant();
        throw const DirectMcpOAuthException(
          'The MCP OAuth session is no longer valid. Reconnect this server.',
        );
      }
      throw const DirectMcpOAuthException('The OAuth token refresh failed.');
    }
    return _jsonResponse(response, expectedStatus: HttpStatus.ok);
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    try {
      final response = await _client.send(request).timeout(requestTimeout);
      if (response.isRedirect ||
          (response.statusCode >= 300 && response.statusCode < 400)) {
        await _readBytes(response);
        throw const DirectMcpOAuthException(
          'OAuth endpoint redirects are not accepted.',
        );
      }
      return response;
    } on TimeoutException {
      throw const DirectMcpOAuthException('The OAuth request timed out.');
    }
  }

  Future<Map<String, dynamic>> _jsonResponse(
    http.StreamedResponse response, {
    required int expectedStatus,
    bool alsoAcceptOk = false,
  }) async {
    final bytes = await _readBytes(response);
    if (response.statusCode != expectedStatus &&
        !(alsoAcceptOk && response.statusCode == HttpStatus.ok)) {
      throw DirectMcpOAuthException(
        'The OAuth server returned HTTP ${response.statusCode}.',
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    } catch (_) {
      throw const DirectMcpOAuthException(
        'The OAuth server returned invalid metadata.',
      );
    }
  }

  Future<List<int>> _readBytes(http.StreamedResponse response) async {
    final contentLength = response.contentLength;
    if (contentLength != null && contentLength > _maxOAuthDocumentBytes) {
      throw const DirectMcpOAuthException(
        'The OAuth metadata document is too large.',
      );
    }
    final bytes = <int>[];
    final iterator = StreamIterator<List<int>>(response.stream);
    var timedOut = false;
    final timer = Timer(requestTimeout, () {
      timedOut = true;
      unawaited(iterator.cancel());
    });
    try {
      while (await iterator.moveNext()) {
        if (bytes.length + iterator.current.length > _maxOAuthDocumentBytes) {
          throw const DirectMcpOAuthException(
            'The OAuth metadata document is too large.',
          );
        }
        bytes.addAll(iterator.current);
      }
    } finally {
      timer.cancel();
      await iterator.cancel();
    }
    if (timedOut) {
      throw const DirectMcpOAuthException('The OAuth request timed out.');
    }
    return bytes;
  }

  void _requireCurrent(_PendingOAuthFlow flow) {
    _requireOpen();
    if (!identical(_pending[flow.server.id], flow) ||
        _generations[flow.server.id] != flow.generation) {
      throw const DirectMcpOAuthException(
        'The MCP OAuth connection is no longer pending.',
      );
    }
    if (_now().toUtc().isAfter(flow.expiresAt)) {
      throw const DirectMcpOAuthException(
        'The MCP OAuth connection timed out. Try again.',
      );
    }
  }

  void _requireGeneration(String serverId, int generation) {
    _requireOpen();
    if ((_generations[serverId] ?? 0) != generation) {
      throw const DirectMcpOAuthException(
        'The MCP OAuth operation was cancelled.',
      );
    }
  }

  void _requireOpen() {
    if (_closed) {
      throw const DirectMcpOAuthException(
        'The MCP OAuth coordinator is closed.',
      );
    }
  }
}

final class _PendingOAuthFlow {
  _PendingOAuthFlow({
    required this.server,
    required this.generation,
    required this.listener,
    required this.state,
    required this.verifier,
    required this.redirectUri,
    required this.expiresAt,
  });

  final DirectMcpServer server;
  final int generation;
  final HttpServer listener;
  final String state;
  final String verifier;
  final Uri redirectUri;
  final DateTime expiresAt;
  final Completer<void> cancelled = Completer<void>();
  _OAuthMetadata? metadata;
  String? clientId;
}

final class _OAuthMetadata {
  const _OAuthMetadata({
    required this.issuer,
    required this.resource,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.registrationEndpoint,
    required this.authorizationResponseIssParameterSupported,
    this.scope,
  });

  final Uri issuer;
  final Uri resource;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri? registrationEndpoint;
  final bool authorizationResponseIssParameterSupported;
  final String? scope;
}

final class _OAuthCallback {
  const _OAuthCallback(this.code);

  final String code;
}

Future<bool> _launchExternalBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

String _randomValue(int byteCount) {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(byteCount, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

String _pkceChallenge(String verifier) =>
    base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');

Uri _wellKnown(Uri base, String path) => Uri(
  scheme: base.scheme,
  host: base.host,
  port: base.hasPort ? base.port : null,
  path: path,
);

List<Uri> _uniqueUris(Iterable<Uri> values) {
  final seen = <String>{};
  return [
    for (final uri in values)
      if (seen.add(uri.toString())) uri,
  ];
}

List<Uri> _authorizationMetadataCandidates(Uri issuer) {
  final path = issuer.path == '/'
      ? ''
      : issuer.path.replaceFirst(RegExp(r'/$'), '');
  return _uniqueUris([
    _wellKnown(issuer, '/.well-known/oauth-authorization-server$path'),
    _wellKnown(issuer, '/.well-known/openid-configuration$path'),
    _wellKnown(issuer, '$path/.well-known/openid-configuration'),
    _wellKnown(issuer, '$path/.well-known/oauth-authorization-server'),
  ]);
}

void _requireTrustedMetadataUri(Uri uri, Uri endpoint) {
  _requireSecureUri(uri, allowLoopbackHttp: _isLoopback(endpoint.host));
  if (_origin(uri) != _origin(endpoint)) {
    throw const DirectMcpOAuthException(
      'The OAuth protected-resource metadata is not owned by this MCP server.',
    );
  }
}

void _requireSameAuthorizationServer(Uri uri, Uri issuer) {
  _requireSecureUri(uri, allowLoopbackHttp: _isLoopback(issuer.host));
  if (_origin(uri) != _origin(issuer)) {
    throw const DirectMcpOAuthException(
      'The OAuth endpoint is not owned by the discovered authorization server.',
    );
  }
}

void _requireSecureUri(Uri uri, {required bool allowLoopbackHttp}) {
  final validScheme =
      uri.scheme == 'https' ||
      (uri.scheme == 'http' && allowLoopbackHttp && _isLoopback(uri.host));
  if (!uri.isAbsolute ||
      !validScheme ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const DirectMcpOAuthException('The OAuth endpoint is not trusted.');
  }
}

bool _resourceMatchesEndpoint(Uri resource, Uri endpoint) {
  if (_origin(resource) != _origin(endpoint)) return false;
  final resourcePath = resource.path.isEmpty ? '/' : resource.path;
  final endpointPath = endpoint.path.isEmpty ? '/' : endpoint.path;
  return resourcePath == '/' || resourcePath == endpointPath;
}

String _origin(Uri uri) {
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:$port';
}

bool _isLoopback(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost' || normalized == '::1') return true;
  final octets = normalized.split('.').map(int.tryParse).toList();
  return octets.length == 4 &&
      octets.every((value) => value != null && value >= 0 && value <= 255) &&
      octets.first == 127;
}

bool _hasForbiddenCharacter(String value) =>
    value.contains('\r') || value.contains('\n') || value.contains('\u0000');

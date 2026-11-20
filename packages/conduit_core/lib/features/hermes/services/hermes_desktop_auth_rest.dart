part of 'hermes_desktop_api_service.dart';

/// A dashboard REST request Hermes answered with a non-2xx [status]: always
/// from the signed-in web view, and from direct requests that asked for the
/// error's [detail].
final class HermesDesktopHttpException implements Exception {
  const HermesDesktopHttpException(this.status, {this.detail});

  final int status;

  /// The bounded `detail` (or error message) Hermes gave, when it gave one.
  final String? detail;

  @override
  String toString() => 'Hermes dashboard request failed ($status).';
}

/// Whether [error] says Hermes' gateway is not ready yet: a gateway's own
/// listener answers every request with 503 (`gateway_not_ready`) and closes
/// sockets with 1013 while it starts or drains.
bool hermesDesktopGatewayNotReady(Object error) =>
    _hermesDesktopHttpStatus(error) == 503 ||
    (error is HermesDesktopRpcException && error.notReady);

/// Whether a gated dashboard takes the deployment session token as a bearer
/// credential (Hermes 0.22.6+ registers its `session-token` auth provider).
bool hermesDesktopAcceptsSessionToken(Map<String, dynamic> status) {
  final providers = status['auth_providers'];
  return providers is List && providers.contains('session-token');
}

/// The HTTP status a dashboard REST failure carries, from either transport.
int? _hermesDesktopHttpStatus(Object error) => switch (error) {
  DioException(:final response) => response?.statusCode,
  HermesDesktopHttpException(:final status) => status,
  _ => null,
};

/// The `detail` of a FastAPI error body (or its `error.message`), bounded.
String? _hermesDesktopErrorDetail(Object? body) {
  String? source;
  if (body is List<int>) {
    if (body.length > 4096) return null;
    source = utf8.decode(body, allowMalformed: true);
  } else if (body is String) {
    if (body.length > 4096) return null;
    source = body;
  }
  if (source == null || source.isEmpty) return null;
  try {
    final decoded = jsonDecode(source);
    final detail = decoded is Map
        ? decoded['detail'] ??
              (decoded['error'] is Map ? decoded['error']['message'] : null)
        : null;
    return validateHermesBoundedString(detail, maxCharacters: 512);
  } on FormatException {
    return null;
  }
}

extension _HermesDesktopAuthRest on HermesDesktopApiService {
  Future<bool> _authHealth() async {
    try {
      await statusProbe(refresh: true);
      await _ensureConnected();
      await _rpc.request<Object?>(
        'model.options',
        timeout: const Duration(seconds: 10),
      );
      return _rpc.isReady;
    } catch (error) {
      DebugLogger.warning(
        'desktop-health-probe-failed',
        scope: 'hermes/desktop',
        data: {'errorType': error.runtimeType.toString()},
      );
      return false;
    }
  }

  Future<Map<String, dynamic>> _authStatusProbe({bool refresh = false}) async {
    if (!refresh && _status != null) return _status!;
    final data = await _requestJson('GET', '/api/status', authenticated: false);
    if (data is! Map) throw const FormatException('Invalid Hermes status.');
    return _status = Map<String, dynamic>.from(data);
  }

  /// The server status the status screen lists. A gated Webapp listener
  /// answers a signed-out caller with only its version, health and sign-in
  /// options, so it is read signed in when that works.
  Future<Map<String, dynamic>> _authDetailedStatus() async {
    final public = await statusProbe(refresh: true);
    if (public['auth_required'] != true) return public;
    try {
      final data = await _requestJson('GET', '/api/status');
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (error) {
      DebugLogger.warning(
        'signed-in-status-unavailable',
        scope: 'hermes/desktop',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    return public;
  }

  Future<List<String>> _authListProfiles() async {
    final data = _object(await _requestJson('GET', '/api/profiles'));
    return _objects(data['profiles'])
        .map((profile) => profile['name']?.toString().trim() ?? '')
        .where(HermesConfig.isValidDesktopProfile)
        .toSet()
        .take(100)
        .toList(growable: false);
  }

  bool get nativePkceAdvertised {
    final flows = _status?['auth_flows'];
    if (flows is! List) return false;
    return flows.any((flow) {
      if (flow is String) return flow == 'native_pkce';
      return flow is Map &&
          (flow['id'] == 'native_pkce' || flow['type'] == 'native_pkce');
    });
  }

  Future<HermesDesktopTokenSet?> _authSignInNative({String? provider}) async {
    await statusProbe(refresh: true);
    if (!nativePkceAdvertised) {
      throw StateError('This Hermes gateway does not advertise native PKCE.');
    }
    if (config.accessHeaders.isNotEmpty) {
      throw StateError(
        'Use dashboard sign-in when access headers protect Hermes.',
      );
    }

    final state = oidcRandomToken();
    final verifier = oidcRandomToken(byteCount: 64);
    final challenge = oidcS256Challenge(verifier);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = Uri.parse('http://127.0.0.1:${server.port}/callback');
    final authorize = _uri('/auth/native/authorize').replace(
      queryParameters: {
        if (provider != null && provider.trim().isNotEmpty)
          'provider': provider.trim(),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'redirect_uri': redirectUri.toString(),
        'state': state,
      },
    );

    try {
      final String code;
      if (_browserAuth.isSupported) {
        final received = await _nativeCodeInBrowserSheet(
          server,
          authorize,
          state,
        );
        if (received == null) return null;
        code = received;
      } else {
        code = await _nativeCodeInExternalBrowser(server, authorize, state);
      }
      final data = await _requestJson(
        'POST',
        '/auth/native/token',
        authenticated: false,
        body: {'code': code, 'code_verifier': verifier},
      );
      final tokens = _parseTokenSet(data);
      // A sign-in replaces what is stored, even tokens another client wrote
      // since this one last read them: reading first makes the save expect
      // those, where a renewal's save would be refused.
      await _guardingTokens(() async {
        await _readStoredTokens?.call();
        await _saveTokens(tokens);
      });
      return tokens;
    } finally {
      await server.close(force: true);
    }
  }

  /// The code Hermes' loopback redirect brings, from a sign-in in the system
  /// browser's sheet; null when the user closed it.
  ///
  /// Hermes redirects only to a loopback address, which no browser returns
  /// to the app from. The sheet keeps the app in front, so the listener is
  /// still there when Hermes redirects to it, and it answers with the app's
  /// own redirect, which ends the sheet. That redirect carries only the
  /// state, which the browser bridge tells sign-ins apart by: the code goes
  /// from the listener to the token exchange and nowhere else.
  Future<String?> _nativeCodeInBrowserSheet(
    HttpServer server,
    Uri authorize,
    String state,
  ) async {
    final appRedirect = Uri.parse(browserAuthDefaultRedirect);
    final ending = appRedirect.replace(queryParameters: {'state': state});
    final callback = Completer<String>();
    callback.future.ignore();
    final listening = server.listen((request) async {
      final response = request.response;
      // Anything on the loopback port can call it: only this sign-in's state
      // ends the sheet, and nothing else learns that state.
      if (callback.isCompleted ||
          request.uri.path != '/callback' ||
          request.uri.queryParameters['state'] != state) {
        response.statusCode = HttpStatus.notFound;
      } else {
        final code = request.uri.queryParameters['code'];
        if (code != null && code.isNotEmpty) {
          callback.complete(code);
        } else {
          callback.completeError(
            StateError('Hermes sign-in returned no code.'),
          );
        }
        response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, ending.toString());
      }
      try {
        await response.close();
      } catch (_) {
        // The browser went away; the sign-in ends with its own result.
      }
    });
    try {
      final result = await _browserAuth.authorize(
        authorize,
        redirectUri: appRedirect,
      );
      if (result.outcome == BrowserAuthOutcome.cancelled) return null;
      // A sheet can end on the app's redirect only after the listener sent
      // it there, which settled the callback first.
      if (result.outcome != BrowserAuthOutcome.success ||
          !callback.isCompleted) {
        throw StateError('Hermes sign-in did not finish ($result).');
      }
      return await callback.future;
    } finally {
      await listening.cancel();
    }
  }

  /// The code from a sign-in in the default browser, on a host with no
  /// browser sheet. The browser stays on the listener's page; the user comes
  /// back to the app by hand.
  Future<String> _nativeCodeInExternalBrowser(
    HttpServer server,
    Uri authorize,
    String state,
  ) async {
    final launched = await _openExternalUrl.open(authorize);
    if (!launched) throw StateError('Could not open Hermes sign-in.');
    final request = await (() async {
      await for (final candidate in server) {
        final matches =
            candidate.uri.path == '/callback' &&
            candidate.uri.queryParameters['state'] == state;
        if (matches) return candidate;
        candidate.response.statusCode = 404;
        await candidate.response.close();
      }
      throw StateError('Hermes sign-in callback closed.');
    })().timeout(const Duration(minutes: 5));
    // This sign-in's own callback: it signs in only with a code.
    final code = request.uri.queryParameters['code'] ?? '';
    request.response
      ..statusCode = code.isNotEmpty ? 200 : 400
      ..headers.contentType = ContentType.html
      ..write(
        '<!doctype html><title>Hermes</title>'
        '<p>${code.isNotEmpty ? 'Sign-in complete. You can close this window.' : 'Sign-in could not be verified.'}</p>',
      );
    await request.response.close();
    if (code.isEmpty) throw StateError('Hermes sign-in returned no code.');
    return code;
  }

  /// Renews the gateway tokens as the app comes back to the foreground when
  /// they expire within [margin], so a session idle in the background keeps
  /// renewing instead of waiting for the next request to find it lapsed.
  Future<void> _authRefreshOnResume({
    Duration margin = const Duration(minutes: 5),
  }) async {
    final tokens = _nativeTokens;
    if (_closed ||
        config.desktopAuthKind != HermesDesktopAuthKind.nativePkce ||
        tokens == null ||
        !tokens.expiresWithin(margin)) {
      return;
    }
    try {
      await _validNativeTokens(margin: margin);
    } catch (error) {
      DebugLogger.warning(
        'resume-token-refresh-failed',
        scope: 'hermes/desktop',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  HermesDesktopTokenSet _parseTokenSet(Object? data) {
    if (data is! Map) throw const FormatException('Invalid Hermes token set.');
    final access = data['access_token']?.toString() ?? '';
    final refresh = data['refresh_token']?.toString() ?? '';
    final rawExpiry = data['expires_at'];
    final expirySeconds = rawExpiry is num
        ? rawExpiry.toInt()
        : int.tryParse(rawExpiry?.toString() ?? '');
    if (access.isEmpty ||
        refresh.isEmpty ||
        expirySeconds == null ||
        expirySeconds <= 0) {
      throw const FormatException('Invalid Hermes token set.');
    }
    final expiryMilliseconds = expirySeconds > 100000000000
        ? expirySeconds
        : expirySeconds * 1000;
    try {
      return HermesDesktopTokenSet(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          expiryMilliseconds,
          isUtc: true,
        ),
      );
    } on ArgumentError {
      throw const FormatException('Invalid Hermes token set.');
    }
  }

  Future<void> _saveTokens(HermesDesktopTokenSet? tokens) async {
    _nativeTokens = tokens;
    final credentials = HermesDesktopCredentials(
      legacyToken: config.desktopCredentials?.legacyToken,
      nativeTokens: tokens,
      accessHeaders: config.accessHeaders,
    );
    await onCredentialsChanged?.call(credentials);
  }

  /// Tokens to send: the held ones, renewed first when they expire within
  /// [margin], or when [forceRefresh] because the gateway refused them.
  Future<HermesDesktopTokenSet?> _validNativeTokens({
    bool forceRefresh = false,
    Duration margin = const Duration(seconds: 60),
  }) async {
    final held = _nativeTokens;
    if (held == null) return null;
    bool stale(HermesDesktopTokenSet tokens) =>
        (forceRefresh && identical(tokens, held)) ||
        tokens.expiresWithin(margin);
    if (!stale(held)) return held;
    return _refreshing ??= _renewNative(held, stale).whenComplete(() {
      _refreshing = null;
    });
  }

  Future<HermesDesktopTokenSet?> _renewNative(
    HermesDesktopTokenSet held,
    bool Function(HermesDesktopTokenSet tokens) stale,
  ) async {
    final read = _readStoredTokens;
    if (read == null) return _refreshNative(held);
    return _guardingTokens(() async {
      final stored = await read();
      if (!identical(_nativeTokens, held)) return _nativeTokens;
      final storedToken = stored?.refreshToken;
      // Storage moves on only by a save, and a spent token never comes
      // back: the one storage still holds is the only one worth remembering.
      _spentRefreshTokens.retainWhere((token) => token == storedToken);
      if (storedToken == held.refreshToken ||
          _spentRefreshTokens.contains(storedToken)) {
        return _refreshNative(held);
      }
      // Another client rotated the tokens, or signed out: the held refresh
      // token is spent, and sending it back would end the session.
      _nativeTokens = stored;
      if (stored == null || !stale(stored)) return stored;
      return _refreshNative(stored);
    });
  }

  /// [action], under [_guardTokens] when this client shares its gateway
  /// tokens with others.
  Future<T> _guardingTokens<T>(Future<T> Function() action) {
    final guard = _guardTokens;
    return guard == null ? action() : guard(action);
  }

  Future<HermesDesktopTokenSet?> _refreshNative(
    HermesDesktopTokenSet current,
  ) async {
    try {
      final data = await _requestJson(
        'POST',
        '/auth/native/refresh',
        authenticated: false,
        body: {'refresh_token': current.refreshToken},
      );
      _spend(current.refreshToken);
      final next = _parseTokenSet(data);
      // A sign-in that finished meanwhile is newer than this renewal.
      if (!identical(_nativeTokens, current)) return _nativeTokens;
      await _saveTokens(next);
      return next;
    } on DioException catch (error) {
      // Not ready: the held tokens still serve, a sign-in's if one finished.
      if (error.response?.statusCode == 503) return _nativeTokens;
      if (error.response?.statusCode == 401) {
        _spend(current.refreshToken);
        if (!identical(_nativeTokens, current)) return _nativeTokens;
        await _saveTokens(null);
        return null;
      }
      rethrow;
    }
  }

  void _spend(String refreshToken) {
    if (_readStoredTokens != null) _spentRefreshTokens.add(refreshToken);
  }

  Future<Map<String, String>> _headers({required bool authenticated}) async {
    final headers = <String, String>{...config.accessHeaders};
    if (!authenticated) return headers;
    final status = await statusProbe();
    if (status['auth_required'] != true) {
      final token = config.desktopCredentials?.legacyToken;
      if (token == null || token.isEmpty) {
        throw StateError('Hermes requires a legacy session token.');
      }
      headers['X-Hermes-Session-Token'] = token;
      return headers;
    }
    switch (config.desktopAuthKind) {
      case HermesDesktopAuthKind.nativePkce:
        final tokens = await _validNativeTokens();
        if (tokens == null) throw HermesGatewaySignInRequired();
        headers['Authorization'] = 'Bearer ${tokens.accessToken}';
      case HermesDesktopAuthKind.dashboardCookie:
        throw StateError('Dashboard requests require the WebView bridge.');
      case HermesDesktopAuthKind.legacyToken:
        final token = config.desktopCredentials?.legacyToken;
        if (!hermesDesktopAcceptsSessionToken(status) ||
            token == null ||
            token.isEmpty) {
          throw StateError(
            'Choose native or dashboard sign-in for this gateway.',
          );
        }
        headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<Object?> _requestJson(
    String method,
    String path, {
    bool authenticated = true,
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    Duration? sendTimeout,
    int nativeRetry = 0,
    int dashboardRetry = 0,
    bool readErrorDetail = false,
    bool dashboardUrgent = false,
    bool Function()? dashboardBeforeSend,
  }) async {
    final requestQuery = <String, dynamic>{...?query};
    if (authenticated && _isProfileScopedRestPath(path)) {
      requestQuery.putIfAbsent('profile', () => config.desktopProfile);
    }
    if (authenticated &&
        config.desktopAuthKind == HermesDesktopAuthKind.dashboardCookie) {
      return _requestDashboardJson(
        method,
        path,
        body: body,
        query: requestQuery,
        cancelToken: cancelToken,
        retry: dashboardRetry,
        urgent: dashboardUrgent,
        beforeSend: dashboardBeforeSend,
      );
    }
    try {
      final response = await _dio.request<List<int>>(
        _uri(path, requestQuery.isEmpty ? null : requestQuery).toString(),
        data: body,
        cancelToken: cancelToken,
        options: Options(
          method: method,
          headers: await _headers(authenticated: authenticated),
          responseType: ResponseType.bytes,
          sendTimeout: sendTimeout,
          receiveDataWhenStatusError: readErrorDetail,
        ),
      );
      final bytes = response.data ?? const <int>[];
      if (bytes.length > kMaxHermesDesktopFrameBytes) {
        throw const HermesResponseTooLargeException();
      }
      if (bytes.isEmpty) return null;
      final source = utf8.decode(bytes);
      if (source.length > kMaxHermesDesktopFrameCharacters) {
        throw const HermesResponseTooLargeException();
      }
      validateHermesJsonSource(source);
      return jsonDecode(source);
    } on DioException catch (error, stackTrace) {
      final status = error.response?.statusCode;
      if (authenticated && status == 401) {
        if (config.desktopAuthKind == HermesDesktopAuthKind.nativePkce) {
          final previous = _nativeTokens;
          HermesDesktopTokenSet? refreshed;
          if (nativeRetry == 0) {
            try {
              refreshed = await _validNativeTokens(forceRefresh: true);
            } catch (_) {
              Error.throwWithStackTrace(error, stackTrace);
            }
          }
          if (nativeRetry == 0 &&
              hermesNativeRefreshAllowsRetry(previous, refreshed)) {
            return _requestJson(
              method,
              path,
              authenticated: authenticated,
              body: body,
              query: query,
              cancelToken: cancelToken,
              sendTimeout: sendTimeout,
              nativeRetry: 1,
              readErrorDetail: readErrorDetail,
            );
          }
          // Hermes did not refuse the refresh token: it could not renew
          // for now, and what it left is held or already expired.
          if (nativeRetry == 0 && refreshed != null) rethrow;
          await _saveTokens(null);
          throw HermesGatewaySignInRequired();
        }
      }
      if (readErrorDetail && status != null && status != 401) {
        throw HermesDesktopHttpException(
          status,
          detail: _hermesDesktopErrorDetail(error.response?.data),
        );
      }
      rethrow;
    }
  }

  Future<Object?> _requestDashboardJson(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    int retry = 0,
    bool urgent = false,
    bool Function()? beforeSend,
  }) async {
    if (!hermesDashboardHeadersSupported(
      isIOS: Platform.isIOS,
      accessHeaders: config.accessHeaders,
    )) {
      throw HermesDashboardUnavailable(
        'Dashboard cookie requests with gateway headers are unavailable on iOS.',
      );
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final bridgeFactory = _dashboardBridgeFactory;
    if (bridgeFactory == null) {
      throw StateError(
        'This host has no WebView, so the Hermes dashboard cannot be reached.',
      );
    }
    final bridge = _dashboardBridge ??= bridgeFactory(
      root: _root,
      accessHeaders: config.accessHeaders,
    );
    final response = await bridge.request(
      method,
      _uri(path, query),
      body: body == null ? null : jsonEncode(body),
      urgent: urgent,
      beforeSend: beforeSend,
    );
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    if (response.status == 401 || response.status == 403) {
      if (retry < 2) {
        await bridge.reload();
        return _requestDashboardJson(
          method,
          path,
          body: body,
          query: query,
          cancelToken: cancelToken,
          retry: retry + 1,
          urgent: urgent,
          beforeSend: beforeSend,
        );
      }
      throw StateError('Hermes dashboard sign-in expired.');
    }
    if (response.status < 200 || response.status >= 300) {
      throw HermesDesktopHttpException(
        response.status,
        detail: _hermesDesktopErrorDetail(response.body),
      );
    }
    if (response.body.isEmpty) return null;
    validateHermesJsonSource(response.body);
    return jsonDecode(response.body);
  }
}

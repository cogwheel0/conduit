part of 'hermes_desktop_api_service.dart';

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
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _authStatusProbe({bool refresh = false}) async {
    if (!refresh && _status != null) return _status!;
    final data = await _requestJson('GET', '/api/status', authenticated: false);
    if (data is! Map) throw const FormatException('Invalid Hermes status.');
    return _status = Map<String, dynamic>.from(data);
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

  Future<HermesDesktopTokenSet> _authSignInNative({String? provider}) async {
    await statusProbe(refresh: true);
    if (!nativePkceAdvertised) {
      throw StateError('This Hermes gateway does not advertise native PKCE.');
    }
    if (config.accessHeaders.isNotEmpty) {
      throw StateError(
        'Use dashboard sign-in when access headers protect Hermes.',
      );
    }

    final random = Random.secure();
    String randomValue(int bytes) => base64Url
        .encode(List<int>.generate(bytes, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final state = randomValue(32);
    final verifier = randomValue(64);
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
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
      final launched = await launchUrl(
        authorize,
        mode: LaunchMode.externalApplication,
      );
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
      final code = request.uri.queryParameters['code'];
      final returnedState = request.uri.queryParameters['state'];
      request.response
        ..statusCode = code != null && returnedState == state ? 200 : 400
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><title>Hermes</title>'
          '<p>${code != null && returnedState == state ? 'Sign-in complete. You can close this window.' : 'Sign-in could not be verified.'}</p>',
        );
      await request.response.close();
      if (code == null || code.isEmpty || returnedState != state) {
        throw StateError('Hermes sign-in state did not match.');
      }
      final data = await _requestJson(
        'POST',
        '/auth/native/token',
        authenticated: false,
        body: {'code': code, 'code_verifier': verifier},
      );
      final tokens = _parseTokenSet(data);
      await _saveTokens(tokens);
      return tokens;
    } finally {
      await server.close(force: true);
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

  Future<HermesDesktopTokenSet?> _validNativeTokens({
    bool forceRefresh = false,
  }) async {
    final current = _nativeTokens;
    if (current == null || (!forceRefresh && !current.needsRefresh)) {
      return current;
    }
    return _refreshing ??= _refreshNative(current).whenComplete(() {
      _refreshing = null;
    });
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
      final next = _parseTokenSet(data);
      await _saveTokens(next);
      return next;
    } on DioException catch (error) {
      if (error.response?.statusCode == 503) return current;
      if (error.response?.statusCode == 401) {
        await _saveTokens(null);
        return null;
      }
      rethrow;
    }
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
        if (tokens == null) throw StateError('Hermes sign-in is required.');
        headers['Authorization'] = 'Bearer ${tokens.accessToken}';
      case HermesDesktopAuthKind.dashboardCookie:
        throw StateError('Dashboard requests require the WebView bridge.');
      case HermesDesktopAuthKind.legacyToken:
        throw StateError(
          'Choose native or dashboard sign-in for this gateway.',
        );
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
    int nativeRetry = 0,
    int dashboardRetry = 0,
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
        ),
      );
      final bytes = response.data ?? const <int>[];
      if (bytes.length > kMaxHermesDesktopFrameBytes) {
        throw const FormatException('Hermes response is too large.');
      }
      if (bytes.isEmpty) return null;
      final source = utf8.decode(bytes);
      if (source.length > kMaxHermesDesktopFrameCharacters) {
        throw const FormatException('Hermes response is too large.');
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
              nativeRetry: 1,
            );
          }
          if (nativeRetry == 0 && identical(previous, refreshed)) rethrow;
          await _saveTokens(null);
        }
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
  }) async {
    if (!hermesDashboardHeadersSupported(
      platform: defaultTargetPlatform,
      accessHeaders: config.accessHeaders,
    )) {
      throw StateError(
        'Dashboard cookie requests with gateway headers are unavailable on iOS.',
      );
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final bridge = _dashboardBridge ??= HermesDashboardRestBridge(
      config: config,
      root: _root,
    );
    final response = await bridge.request(
      method,
      _uri(path, query),
      body: body == null ? null : jsonEncode(body),
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
        );
      }
      throw StateError('Hermes dashboard sign-in expired.');
    }
    if (response.status < 200 || response.status >= 300) {
      throw StateError('Hermes dashboard request failed (${response.status}).');
    }
    if (response.body.isEmpty) return null;
    validateHermesJsonSource(response.body);
    return jsonDecode(response.body);
  }
}

part of 'api_service.dart';

mixin _HealthApi on _ApiServiceBase {
  /// Warms the service-wide Dio pool so the first real request (often a chat
  /// completion) does not pay DNS/TCP/TLS handshake latency. [checkHealth]
  /// deliberately uses a request-scoped client it can force-close, so it no
  /// longer touches the pool the completion path uses; this probe does.
  Future<void> warmConnectionPool() async {
    try {
      await _dio.get<dynamic>(
        '/health',
        options: Options(
          extra: const {'suppressAuthFailureNotification': true},
        ),
      );
    } catch (_) {
      // Best-effort: warmup failures are routine offline and must stay silent.
    }
  }

  /// Basic health check - just verifies the server is reachable.
  Future<bool> checkHealth() async {
    final deadline = PublicHealthDeadline(_publicHealthRequestTimeout);
    final cancelToken = CancelToken();
    final initialRequestCancelToken = _linkedPublicHealthCancelToken(
      cancelToken,
    );
    // The service-wide Dio pool must not retain an unread or endless health
    // response. A request-scoped client gives this probe force-close ownership
    // of the upstream socket as soon as status/redirect headers are known.
    final healthDio = Dio(
      BaseOptions(
        baseUrl: serverConfig.url,
        connectTimeout: deadline.remaining(
          cappedAt: const Duration(seconds: 30),
        ),
        receiveTimeout: deadline.remaining(
          cappedAt: const Duration(seconds: 30),
        ),
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (status) => status != null,
        headers: _publicHealthHeaders(includeServerHeaders: true),
      ),
    );
    ServerTlsHttpClientFactory.configureDio(
      healthDio,
      serverConfig,
      userAgent: ConduitUserAgent.value,
    );
    final deadlineTimer = Timer(_publicHealthRequestTimeout, () {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('Public health-check deadline expired');
      }
    });
    Response<dynamic>? response;
    try {
      response = await healthDio
          .get<dynamic>(
            '/health',
            options: Options(
              followRedirects: false,
              responseType: ResponseType.stream,
              validateStatus: (status) => status != null,
            ),
            cancelToken: initialRequestCancelToken,
          )
          .timeout(deadline.remaining());
      if (response.statusCode == HttpStatus.ok) return true;
      if (!publicHealthRedirectStatusCodes.contains(response.statusCode)) {
        return false;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || location.isEmpty) return false;
      final from = response.requestOptions.uri;
      if (!initialRequestCancelToken.isCancelled) {
        initialRequestCancelToken.cancel('Initial health response complete');
      }
      await _cancelPublicHealthResponse(response);
      response = null;
      healthDio.close(force: true);
      return await _followPublicHealthRedirect(
        from: from,
        location: location,
        deadline: deadline,
        cancelToken: cancelToken,
      );
    } on TimeoutException {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('Public health-check deadline expired');
      }
      return false;
    } on DioException catch (error) {
      response ??= error.response;
      return false;
    } catch (_) {
      return false;
    } finally {
      deadlineTimer.cancel();
      if (!initialRequestCancelToken.isCancelled) {
        initialRequestCancelToken.cancel('Initial health response complete');
      }
      await _cancelPublicHealthResponse(response);
      healthDio.close(force: true);
    }
  }

  /// Health check with proxy detection.
  ///
  /// This method detects when the server is behind an authentication proxy
  /// (like oauth2-proxy) by checking for:
  /// - HTTP redirects (301, 302, 303, 307, 308) to login pages
  /// - HTML responses instead of expected JSON/text
  ///
  /// When a proxy is detected, returns [HealthCheckResult.proxyAuthRequired]
  /// so the app can show a WebView for proxy authentication.
  ///
  /// Set [throwOnConnectionError] when the caller needs to show the exact
  /// transport failure instead of a collapsed [HealthCheckResult.unreachable].
  Future<HealthCheckResult> checkHealthWithProxyDetection({
    bool throwOnConnectionError = false,
  }) async {
    // This transport intentionally differs from the service client because
    // redirects must remain visible. It is nevertheless request-scoped and
    // must release its native connection pool on every return path.
    final tempDio = Dio(
      BaseOptions(
        baseUrl: serverConfig.url,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: false,
        validateStatus: (status) => true,
        headers: _publicHealthHeaders(includeServerHeaders: true),
      ),
    );
    Response<dynamic>? response;
    try {
      ServerTlsHttpClientFactory.configureDio(tempDio, serverConfig);

      response = await tempDio.get<dynamic>(
        '/health',
        options: Options(responseType: ResponseType.stream),
      );
      final statusCode = response.statusCode ?? 0;

      DebugLogger.log(
        'Proxy detection health check: status=$statusCode',
        scope: 'api/proxy-detect',
      );

      // Check for redirects (proxy authentication pages)
      if (publicHealthRedirectStatusCodes.contains(statusCode)) {
        DebugLogger.log(
          'proxy-auth-redirect-detected',
          scope: 'api/proxy-detect',
          data: {'statusCode': statusCode},
        );
        return HealthCheckResult.proxyAuthRequired;
      }

      // Check for 401/403 which may indicate proxy auth
      if (statusCode == 401 || statusCode == 403) {
        // Check if the response is HTML (proxy login page)
        final contentType =
            response.headers.value('content-type')?.toLowerCase() ?? '';
        if (contentType.contains('text/html')) {
          DebugLogger.log(
            'Detected HTML response on 401/403 - likely proxy auth required',
            scope: 'api/proxy-detect',
          );
          return HealthCheckResult.proxyAuthRequired;
        }
      }

      // Check for successful response
      if (statusCode == 200) {
        // Verify it's not an HTML login page masquerading as 200
        final contentType =
            response.headers.value('content-type')?.toLowerCase() ?? '';

        // OpenWebUI's /health returns {"status": true} or plain "true"
        // If we get HTML, it's probably a proxy login page
        if (contentType.contains('text/html')) {
          DebugLogger.log(
            'Detected HTML response on /health',
            scope: 'api/proxy-detect',
          );

          // All HTML responses suggest proxy auth is needed
          // (either login page or custom proxy page)
          return HealthCheckResult.proxyAuthRequired;
        }

        return HealthCheckResult.healthy;
      }

      return HealthCheckResult.unhealthy;
    } on DioException catch (e) {
      response ??= e.response;
      DebugLogger.log(
        'Proxy detection failed with DioException: ${e.type}',
        scope: 'api/proxy-detect',
      );

      if (isTlsHandshakeFailureForTest(e)) {
        rethrow;
      }

      // Connection errors mean unreachable
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        if (throwOnConnectionError) {
          rethrow;
        }
        return HealthCheckResult.unreachable;
      }

      // Check if response indicates proxy
      final errorResponse = e.response;
      if (errorResponse != null) {
        final statusCode = errorResponse.statusCode ?? 0;
        if (publicHealthRedirectStatusCodes.contains(statusCode)) {
          return HealthCheckResult.proxyAuthRequired;
        }

        final contentType =
            errorResponse.headers.value('content-type')?.toLowerCase() ?? '';
        if (contentType.contains('text/html') &&
            (statusCode == 401 || statusCode == 403 || statusCode == 200)) {
          return HealthCheckResult.proxyAuthRequired;
        }
      }

      if (throwOnConnectionError) {
        rethrow;
      }
      return HealthCheckResult.unreachable;
    } catch (e) {
      if (e.toString().toLowerCase().contains(
        'mtls certificate setup failed',
      )) {
        rethrow;
      }
      DebugLogger.error(
        'proxy-detection-failed',
        scope: 'api/proxy-detect',
        data: {
          'errorType': e.runtimeType.toString(),
          if (e is DioException) 'statusCode': e.response?.statusCode,
        },
      );
      if (throwOnConnectionError) {
        rethrow;
      }
      return HealthCheckResult.unreachable;
    } finally {
      await _cancelPublicHealthResponse(response);
      tempDio.close(force: true);
    }
  }

  /// Releases the native HTTP client's connection pool. Every [ApiService]
  /// owns its Dio instance; providers and request-scoped auth probes call this
  /// when their server/session ownership ends.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Graceful close: new work is rejected but in-flight requests run to
    // completion. Provider rebuilds can retire a service for the same server
    // mid-generation (config writes, fence flips); force-closing there would
    // abort an active SSE chat stream that survived such rebuilds before this
    // client owned its pool.
    _dio.close();
  }

  /// Verifies this is actually an OpenWebUI server by checking the /api/config
  /// endpoint for OpenWebUI-specific fields (version, status, features).
  ///
  /// Verifies this is an OpenWebUI server and returns the backend config.
  ///
  /// Returns `BackendConfig` if the server is valid, `null` otherwise.
  /// This combines server verification and config fetching in a single call.
  Future<BackendConfig?> verifyAndGetConfig() async {
    try {
      final response = await _dio.get('/api/config');
      if (response.statusCode != 200) {
        return null;
      }

      final data = response.data;
      if (data is! Map<String, dynamic>) {
        return null;
      }

      // Check for OpenWebUI-specific fields
      // The /api/config endpoint always returns these fields on OpenWebUI
      final hasStatus = data['status'] == true;
      final hasVersion =
          data['version'] is String && (data['version'] as String).isNotEmpty;
      final hasFeatures = data['features'] is Map;

      if (!hasStatus || !hasVersion || !hasFeatures) {
        return null;
      }

      _setChatRequestMetadataFormatFromVersion(data['version']);
      return await _enrichBackendConfigWithAudioConfig(
        BackendConfig.fromJson(data),
      );
    } catch (e) {
      return null;
    }
  }

  Future<BackendConfig?> getBackendConfig() async {
    try {
      final response = await _dio.get('/api/config');
      final data = response.data;
      Map<String, dynamic>? jsonMap;
      if (data is Map<String, dynamic>) {
        jsonMap = data;
      } else if (data is String && data.isNotEmpty) {
        final decoded = json.decode(data);
        if (decoded is Map<String, dynamic>) {
          jsonMap = decoded;
        }
      }
      if (jsonMap == null) {
        return null;
      }
      _setChatRequestMetadataFormatFromVersion(jsonMap['version']);
      return await _enrichBackendConfigWithAudioConfig(
        BackendConfig.fromJson(jsonMap),
      );
    } on DioException catch (e, stackTrace) {
      _traceApi('Backend config request failed: $e');
      DebugLogger.error(
        'backend-config-error',
        scope: 'api/config',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    } catch (e, stackTrace) {
      _traceApi('Backend config decode error: $e');
      DebugLogger.error(
        'backend-config-decode',
        scope: 'api/config',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<ServerAboutInfo> getServerAboutInfo() async {
    final results = await Future.wait<dynamic>([
      _dio.get('/api/config').then((response) => response.data),
      (() async {
        try {
          return (await _dio.get('/api/version')).data;
        } catch (_) {
          return null;
        }
      })(),
      (() async {
        try {
          return (await _dio.get('/api/version/updates')).data;
        } catch (_) {
          return null;
        }
      })(),
      (() async {
        try {
          return (await _dio.get('/api/changelog')).data;
        } catch (_) {
          return null;
        }
      })(),
    ]);

    final config = _coerceResponseMap(results[0]);
    if (config == null) {
      throw StateError('Unexpected /api/config response type.');
    }

    return ServerAboutInfo.fromJson(
      config,
      versionData: _coerceResponseMap(results[1]),
      updateData: _coerceResponseMap(results[2]),
      changelog: _coerceResponseMap(results[3]),
    );
  }
}

part of 'hermes_desktop_api_service.dart';

extension _HermesDesktopMedia on HermesDesktopApiService {
  Future<void> _downloadMedia(
    HermesMediaReference media,
    String destination, {
    String? sessionId,
    String? profile,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    if (HermesMediaReference.fromPath(media.path) == null ||
        (sessionId != null &&
            validateHermesOpaqueIdentifier(sessionId) == null) ||
        (profile != null && !HermesConfig.isValidDesktopProfile(profile))) {
      throw ArgumentError('Invalid file owner or path');
    }
    if (_closed) throw StateError('Hermes connection closed.');
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final query = <String, dynamic>{
      'path': media.path,
      'session_id': ?sessionId,
      if (sessionId != null) ..._sessionScope(sessionId),
      'profile':
          profile ??
          (sessionId == null ? null : _sessionScope(sessionId)['profile']) ??
          config.desktopProfile,
    };
    final uri = _uri('/api/fs/download', query);
    final partial = File('$destination.part');
    await partial.parent.create(recursive: true);
    try {
      Response<ResponseBody>? response;
      for (var attempt = 0; attempt < 2; attempt++) {
        Map<String, String> headers;
        if (config.desktopAuthKind == HermesDesktopAuthKind.dashboardCookie) {
          final factory = _dashboardBridgeFactory;
          if (factory == null) {
            throw StateError('Dashboard sign-in is unavailable.');
          }
          final bridge = _dashboardBridge ??= factory(
            root: _root,
            accessHeaders: config.accessHeaders,
          );
          if (bridge is! HermesDashboardTransferBridge) {
            throw UnsupportedError(
              'This dashboard cannot download binary files.',
            );
          }
          headers = await (bridge as HermesDashboardTransferBridge)
              .transferHeaders(uri);
        } else {
          headers = await _headers(authenticated: true);
        }
        if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
        if (_closed) throw StateError('Hermes connection closed.');
        try {
          response = await _dio.get<ResponseBody>(
            uri.toString(),
            cancelToken: cancelToken,
            options: Options(
              headers: {...headers, 'Accept-Encoding': 'identity'},
              responseType: ResponseType.stream,
              followRedirects: false,
            ),
          );
          break;
        } on DioException catch (error) {
          final status = error.response?.statusCode;
          if (status == 401 && attempt == 0) {
            if (config.desktopAuthKind == HermesDesktopAuthKind.nativePkce) {
              final previous = _nativeTokens;
              final refreshed = await _validNativeTokens(forceRefresh: true);
              if (hermesNativeRefreshAllowsRetry(previous, refreshed)) continue;
            } else if (config.desktopAuthKind ==
                HermesDesktopAuthKind.dashboardCookie) {
              await _dashboardBridge!.reload();
              continue;
            }
          }
          if (status == 404 || status == 405 || status == 501) {
            // Older gateways expose only a small JSON preview endpoint. Keep
            // that compatibility path bounded rather than base64-loading media.
            final data = _object(
              await _requestJson(
                'GET',
                sessionId == null ? '/api/files/read' : '/api/fs/read-data-url',
                query: query,
                cancelToken: cancelToken,
                maximumResponseBytes: 2 * 1024 * 1024,
              ),
            );
            final source = data['dataUrl'] ?? data['data_url'];
            if (source is! String ||
                !source.startsWith('data:') ||
                source.length > 2 * 1024 * 1024) {
              throw const FormatException(
                'File download is unavailable on this Hermes gateway.',
              );
            }
            final bytes = UriData.parse(source).contentAsBytes();
            if (cancelToken?.isCancelled == true) {
              throw cancelToken!.cancelError!;
            }
            if (_closed) throw StateError('Hermes connection closed.');
            await partial.writeAsBytes(bytes, flush: true);
            if (cancelToken?.isCancelled == true) {
              throw cancelToken!.cancelError!;
            }
            if (_closed) throw StateError('Hermes connection closed.');
            onProgress?.call(bytes.length, bytes.length);
            await partial.rename(destination);
            return;
          }
          rethrow;
        }
      }
      final body = response?.data;
      if (body == null) throw const FormatException('Empty file response.');
      final total =
          int.tryParse(
            response!.headers.value(Headers.contentLengthHeader) ?? '',
          ) ??
          -1;
      if (total > kMaxHermesMediaDownloadBytes) {
        await body.stream.listen(null).cancel();
        throw const FormatException(
          'Files larger than 256 MB cannot be downloaded yet.',
        );
      }
      if (media.kind != HermesMediaKind.file &&
          response.headers
                  .value(Headers.contentTypeHeader)
                  ?.startsWith('text/html') ==
              true) {
        await body.stream.listen(null).cancel();
        throw const FormatException(
          'Hermes returned a sign-in page instead of the file.',
        );
      }
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in body.stream) {
          if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
          if (_closed) throw StateError('Hermes connection closed.');
          received += chunk.length;
          if (received > kMaxHermesMediaDownloadBytes) {
            throw const FormatException(
              'Files larger than 256 MB cannot be downloaded yet.',
            );
          }
          // Await each write: a fast network must not accumulate the whole file
          // in the IOSink's pending queue while disk is slower.
          sink.add(chunk);
          await sink.flush();
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      if (_closed) throw StateError('Hermes connection closed.');
      if (total >= 0 && received != total) {
        throw const FormatException('Incomplete file download. Try again.');
      }
      await partial.rename(destination);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}

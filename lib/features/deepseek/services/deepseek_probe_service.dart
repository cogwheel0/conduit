import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../models/deepseek_config.dart';
import '../models/deepseek_probe.dart';

/// Probes a `dsh web` server root.
///
/// The `dsh web` binary serves its SPA on every path and, before the shell
/// bundle executes, injects
/// `window.__DSH_BOOT__ = { rev, entries: [{ id, url, rev, ... }] }` into the
/// page. Reaching the root and reading that manifest is all the liveness
/// check needs: DSH has no separate status endpoint, and the GUI bootstraps
/// entirely from the injected manifest.
class DeepSeekProbeService {
  const DeepSeekProbeService({this.timeout = const Duration(seconds: 5)});

  /// Upper bound on the probe request.
  final Duration timeout;

  /// GET `<base>/` and parse the injected boot manifest out of the SPA HTML.
  ///
  /// Never throws: every failure mode is reported as a [DeepSeekProbeResult]
  /// whose [DeepSeekProbeResult.ok] is false.
  Future<DeepSeekProbeResult> probe(DeepSeekConfig config) async {
    final root = config.connectionEndpoint(config.baseUrl);
    if (root == null) {
      return const DeepSeekProbeResult(
        status: DeepSeekProbeStatus.error,
        error: 'Base URL is not a valid http(s) origin',
      );
    }
    try {
      final response = await _get(root, config);
      final html = response.data is String ? response.data as String : '';
      final manifest = _parseManifest(html);
      if (manifest == null) {
        return const DeepSeekProbeResult(
          status: DeepSeekProbeStatus.error,
          error: 'Response is not a DSH boot page',
        );
      }
      return DeepSeekProbeResult(
        status: DeepSeekProbeStatus.connected,
        revision: manifest.revision,
        pluginCount: manifest.pluginCount,
      );
    } on DioException catch (error) {
      return _mapDioFailure(error);
    } catch (_) {
      return const DeepSeekProbeResult(
        status: DeepSeekProbeStatus.unreachable,
        error: 'Could not reach the server',
      );
    }
  }

  Future<Response<dynamic>> _get(String root, DeepSeekConfig config) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
    );
    if (config.allowSelfSignedCertificates &&
        !kIsWeb &&
        root.startsWith('https://')) {
      final adapter = dio.httpClientAdapter;
      if (adapter is IOHttpClientAdapter) {
        // Mirrors [ServerTlsHttpClientFactory]: pin the lenient callback to
        // this server's host:port pair so the process-wide certificate
        // policy stays strict everywhere else.
        final (host, port) = _hostAndPort(DeepSeekConfig.connectionOrigin(
          config.baseUrl,
        ));
        adapter.createHttpClient = () {
          final client = HttpClient();
          client.badCertificateCallback =
              (context, certificate, certHost, certPort) {
            return certHost.toLowerCase() == (host ?? '').toLowerCase() &&
                (port == null || certPort == port);
          };
          return client;
        };
      }
    }
    // `plain` keeps the SPA HTML as a string: the default `json` response
    // type would run the body through the JSON transformer.
    return dio.get<void>(
      root,
      options: const Options(responseType: ResponseType.plain),
    );
  }

  (String?, int?) _hostAndPort(String? origin) {
    if (origin == null) return (null, null);
    final separator = origin.indexOf('://');
    if (separator < 0) return (origin, null);
    final authority = origin.substring(separator + 3);
    final colon = authority.lastIndexOf(':');
    if (colon < 0) return (authority, null);
    return (authority.substring(0, colon), int.tryParse(authority.substring(colon + 1)));
  }

  DeepSeekProbeResult _mapDioFailure(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.connectionError:
        return const DeepSeekProbeResult(
          status: DeepSeekProbeStatus.unreachable,
          error: 'Could not reach the server (network error)',
        );
      case DioExceptionType.badCertificate:
        return const DeepSeekProbeResult(
          status: DeepSeekProbeStatus.error,
          error: 'Certificate verification failed',
        );
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        return DeepSeekProbeResult(
          status: DeepSeekProbeStatus.error,
          error: status != null
              ? 'Server responded with HTTP $status'
              : 'Unexpected server response',
        );
      case DioExceptionType.cancel:
        return const DeepSeekProbeResult(
          status: DeepSeekProbeStatus.idle,
          error: 'Probe cancelled',
        );
      case DioExceptionType.transformTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const DeepSeekProbeResult(
          status: DeepSeekProbeStatus.unreachable,
          error: 'Server did not respond in time',
        );
    }
  }

  static const String _marker = 'window.__DSH_BOOT__';

  /// Extract the `{ rev, entries }` manifest from the SPA HTML.
  ///
  /// The injected text is JSON in practice, but parsing tolerates a loose JS
  /// object literal: it first attempts strict JSON, then falls back to a
  /// lenient scan for the `rev` and entry `id` fields.
  ({String revision, int pluginCount}?) _parseManifest(String html) {
    final start = html.indexOf(_marker);
    if (start < 0) return null;
    final open = html.indexOf('{', start + _marker.length);
    if (open < 0) return null;
    final close = _matchingBrace(html, open);
    if (close < 0) return null;
    final snippet = html.substring(open, close + 1);

    final decoded = _tryDecode(snippet);
    if (decoded is Map) {
      final revision = decoded['rev'];
      final entries = decoded['entries'];
      if (revision is! String || revision.isEmpty) return null;
      if (entries is! List) return null;
      return (revision: revision, pluginCount: entries.length);
    }

    // Lenient fallback: the injected literal may not be strict JSON.
    final revMatch = RegExp(
      r"""["']?rev["']?\s*:\s*["']([^"']+)["']""",
    ).firstMatch(snippet);
    if (revMatch == null) return null;
    final idCount = RegExp(r"""["']?id["']?\s*:""").allMatches(snippet).length;
    return (revision: revMatch.group(1)!, pluginCount: idCount);
  }

  Object? _tryDecode(String snippet) {
    try {
      return jsonDecode(snippet);
    } catch (_) {
      return null;
    }
  }

  /// Index of the `}` matching the `{` at [open], respecting JSON strings.
  static int _matchingBrace(String text, int open) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = open; i < text.length; i++) {
      final char = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
      } else if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }
}
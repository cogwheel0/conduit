import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../models/server_config.dart';

/// Builds server-scoped `dart:io` TLS clients for self-signed certs and mTLS.
class ServerTlsHttpClientFactory {
  const ServerTlsHttpClientFactory._();

  /// Parses a server base URL into a usable [Uri].
  static Uri? parseBaseUri(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    Uri? parsed = Uri.tryParse(trimmed);
    if (parsed == null) {
      return null;
    }

    if (!parsed.hasScheme) {
      parsed =
          Uri.tryParse('https://$trimmed') ?? Uri.tryParse('http://$trimmed');
    }

    return parsed;
  }

  /// Whether the server needs a custom `HttpClient` for TLS.
  static bool requiresCustomHttpClient(ServerConfig serverConfig) =>
      !kIsWeb && serverConfig.needsCustomTlsClient;

  /// Configures Dio to use the server's TLS settings for all requests.
  static void configureDio(Dio dio, ServerConfig serverConfig) {
    if (!requiresCustomHttpClient(serverConfig)) {
      return;
    }

    final adapter = dio.httpClientAdapter;
    if (adapter is! IOHttpClientAdapter) {
      return;
    }

    adapter.createHttpClient = () => createHttpClient(serverConfig);
  }

  /// Creates a server-scoped [HttpClient] with self-signed and mTLS support.
  static HttpClient createHttpClient(
    ServerConfig serverConfig, {
    SecurityContext? fallbackContext,
  }) {
    final context = _createSecurityContext(serverConfig) ?? fallbackContext;
    final client = HttpClient(context: context);

    _configureBadCertificateCallback(client, serverConfig);
    return client;
  }

  static SecurityContext? _createSecurityContext(ServerConfig serverConfig) {
    if (!serverConfig.hasMutualTlsCredentials) {
      return null;
    }

    final context = SecurityContext(withTrustedRoots: true);
    final certificatePem = serverConfig.mtlsCertificateChainPem!.trim();
    final privateKeyPem = serverConfig.mtlsPrivateKeyPem!.trim();
    final password = _normalizePassword(serverConfig.mtlsPrivateKeyPassword);

    try {
      context.useCertificateChainBytes(utf8.encode(certificatePem));
      context.usePrivateKeyBytes(
        utf8.encode(privateKeyPem),
        password: password,
      );
      return context;
    } catch (error) {
      throw StateError(
        'mTLS certificate setup failed. Confirm that the client certificate '
        'and private key are valid PEM files and that the private key '
        'password is correct.',
      );
    }
  }

  static void _configureBadCertificateCallback(
    HttpClient client,
    ServerConfig serverConfig,
  ) {
    if (!serverConfig.allowSelfSignedCertificates) {
      return;
    }

    final baseUri = parseBaseUri(serverConfig.url);
    if (baseUri == null) {
      return;
    }

    final host = baseUri.host.toLowerCase();
    final port = baseUri.hasPort ? baseUri.port : null;
    client.badCertificateCallback =
        (X509Certificate _, String requestHost, int requestPort) {
          if (requestHost.toLowerCase() != host) {
            return false;
          }
          if (port == null) {
            return true;
          }
          return requestPort == port;
        };
  }

  static String? _normalizePassword(String? value) {
    if (value == null) {
      return null;
    }

    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    return trimmed;
  }
}

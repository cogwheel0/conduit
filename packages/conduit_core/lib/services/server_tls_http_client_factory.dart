import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/user_trusted_certificates.dart';

// Was Flutter's kIsWeb. This file configures a dart:io HttpClient, so on
// web the whole path is inapplicable rather than merely different -- which
// is what the original guard was saying too.
const bool _kIsWeb = bool.fromEnvironment('dart.library.js_util');

/// Builds server-scoped `dart:io` TLS clients for self-signed certs and mTLS.
class ServerTlsHttpClientFactory {
  const ServerTlsHttpClientFactory._();

  /// The mobile host supplies the embedded node. An opted-in server always
  /// fails closed when the host or its signed-in node is unavailable.
  static Future<ConnectionTask<Socket>> Function(
    Uri,
    SecurityContext?,
    bool Function(X509Certificate, String, int)?,
  )?
  tailnetConnect;

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
      !_kIsWeb &&
      (serverConfig.needsCustomTlsClient || serverConfig.useTailscale);

  /// Configures Dio to use the server's TLS settings for all requests.
  static void configureDio(
    Dio dio,
    ServerConfig serverConfig, {
    String? userAgent,
  }) {
    if (_kIsWeb ||
        (!requiresCustomHttpClient(serverConfig) && userAgent == null)) {
      return;
    }

    final adapter = dio.httpClientAdapter;
    if (adapter is! IOHttpClientAdapter) {
      return;
    }

    adapter.createHttpClient = () {
      final client = requiresCustomHttpClient(serverConfig)
          ? createHttpClient(serverConfig)
          : HttpClient();
      if (userAgent != null) {
        client.userAgent = userAgent;
      }
      return client;
    };
  }

  /// Creates a server-scoped [HttpClient] with self-signed and mTLS support.
  static HttpClient createHttpClient(
    ServerConfig serverConfig, {
    SecurityContext? fallbackContext,
  }) {
    final context = _createSecurityContext(serverConfig) ?? fallbackContext;
    final client = HttpClient(context: context);

    final trust = _certificateTrust(serverConfig);
    client.badCertificateCallback = trust;
    if (serverConfig.useTailscale) {
      final origin = parseBaseUri(serverConfig.url);
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, proxyHost, proxyPort) {
        final dial = tailnetConnect;
        if (dial == null ||
            origin == null ||
            proxyHost != null ||
            proxyPort != null ||
            uri.host != origin.host ||
            uri.port != origin.port ||
            uri.scheme != origin.scheme) {
          throw const SocketException('No Tailscale route to this server');
        }
        return dial(uri, context, trust);
      };
    }
    return client;
  }

  static SecurityContext? _createSecurityContext(ServerConfig serverConfig) {
    if (!serverConfig.hasMutualTlsCredentials) {
      return null;
    }

    final context = SecurityContext(withTrustedRoots: true);
    UserTrustedCertificates.applyTo(context);
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

  static bool Function(X509Certificate, String, int)? _certificateTrust(
    ServerConfig serverConfig,
  ) {
    if (!serverConfig.allowSelfSignedCertificates) {
      return null;
    }

    final baseUri = parseBaseUri(serverConfig.url);
    if (baseUri == null) {
      return null;
    }

    final host = baseUri.host.toLowerCase();
    final port = baseUri.hasPort ? baseUri.port : null;
    return (X509Certificate _, String requestHost, int requestPort) {
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

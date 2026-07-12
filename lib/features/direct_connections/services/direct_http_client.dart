import 'package:dio/dio.dart';

import '../../../core/models/server_config.dart';
import '../../../core/services/server_tls_http_client_factory.dart';
import '../models/direct_connection_profile.dart';

typedef DirectDioFactory = Dio Function(DirectConnectionProfile profile);

/// Creates a credential-scoped Dio client for exactly one direct profile.
final class DirectHttpClientFactory {
  const DirectHttpClientFactory();

  Dio create(DirectConnectionProfile profile) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 60),
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    configure(dio, profile);

    return dio;
  }

  /// Applies the security boundary to an injected Dio instance as well as the
  /// default one. This keeps test/extension clients from accidentally enabling
  /// credential-bearing redirects or using a stale base URL.
  void configure(Dio dio, DirectConnectionProfile profile) {
    profile.validate();
    dio.options.baseUrl = profile.requestBaseUri().toString();
    dio.options.followRedirects = false;
    dio.options.queryParameters.clear();
    if (profile.adapterKey == kOpenAiCompatibleAdapterKey &&
        (profile.apiVersion ?? '').trim().isNotEmpty) {
      dio.options.queryParameters['api-version'] = profile.apiVersion!.trim();
    }
    dio.options.headers.clear();
    dio.options.headers.addAll({
      'Accept': 'application/json',
      if ((profile.apiKey ?? '').trim().isNotEmpty)
        ...switch (profile.apiKeyAuthMode) {
          DirectApiKeyAuthMode.bearer => {
            'Authorization': 'Bearer ${profile.apiKey!.trim()}',
          },
          DirectApiKeyAuthMode.apiKeyHeader => {
            'api-key': profile.apiKey!.trim(),
          },
        },
      ...profile.customHeaders,
    });

    ServerTlsHttpClientFactory.configureDio(
      dio,
      ServerConfig(
        id: 'direct-${profile.id}',
        name: profile.name,
        url: profile.baseUrl,
        allowSelfSignedCertificates: profile.allowSelfSignedCertificates,
        mtlsCertificateChainPem: profile.mtlsCertificateChainPem,
        mtlsCertificateLabel: profile.mtlsCertificateLabel,
        mtlsPrivateKeyPem: profile.mtlsPrivateKeyPem,
        mtlsPrivateKeyLabel: profile.mtlsPrivateKeyLabel,
        mtlsPrivateKeyPassword: profile.mtlsPrivateKeyPassword,
      ),
    );
  }
}

import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/direct_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DirectConnectionProfile security', () {
    test('versioned document round-trips secrets without redaction loss', () {
      final profile = _profile(
        apiKey: 'secret-key',
        customHeaders: const {'X-Tenant': 'tenant-secret'},
      );

      final encoded = DirectConnectionProfilesDocument([profile]).encode();
      final decoded = DirectConnectionProfilesDocument.decode(encoded);

      expect(decoded.profiles, hasLength(1));
      expect(decoded.profiles.single.apiKey, 'secret-key');
      expect(
        decoded.profiles.single.customHeaders['X-Tenant'],
        'tenant-secret',
      );
    });

    test('rejects URL credentials, query secrets, and reserved headers', () {
      expect(
        () => _profile(baseUrl: 'https://user:pass@example.test/v1').validate(),
        throwsFormatException,
      );
      expect(
        () => _profile(baseUrl: 'https://example.test/v1?key=x').validate(),
        throwsFormatException,
      );
      expect(
        () => _profile(
          customHeaders: const {'authorization': 'Basic forged'},
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => _profile(
          customHeaders: const {'X-Test': 'ok\r\nHost: bad'},
        ).validate(),
        throwsFormatException,
      );
    });

    test('blocks all public plaintext HTTP', () {
      expect(
        () => _profile(baseUrl: 'http://ollama.example.test:11434').validate(),
        throwsFormatException,
      );
      expect(
        () => _profile(
          baseUrl: 'http://api.example.test/v1',
          apiKey: 'secret',
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => _profile(
          baseUrl: 'http://203.0.113.9/v1',
          customHeaders: const {'X-Api-Key': 'secret'},
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => _profile(
          baseUrl: 'http://localhost:11434',
          mtlsCertificateChainPem: 'CERT',
          mtlsPrivateKeyPem: 'KEY',
        ).validate(),
        throwsFormatException,
      );
    });

    test('allows plaintext HTTP only for local and private literal hosts', () {
      expect(
        _profile(
          baseUrl: 'http://localhost:11434',
          apiKey: 'secret',
        ).validateOrNull(),
        isNull,
      );
      expect(
        _profile(
          baseUrl: 'http://192.168.1.20:11434',
          customHeaders: const {'X-Api-Key': 'secret'},
        ).validateOrNull(),
        isNull,
      );
      expect(
        _profile(
          baseUrl: 'http://[fd00::20]:11434',
          apiKey: 'secret',
        ).validateOrNull(),
        isNull,
      );
    });

    test('unconfirmed origin change clears all origin-bound material', () {
      final previous = _profile(
        apiKey: 'old-secret',
        customHeaders: const {'X-Api-Key': 'old-header'},
        allowSelfSignedCertificates: true,
        mtlsCertificateChainPem: 'CERT',
        mtlsPrivateKeyPem: 'KEY',
        mtlsPrivateKeyPassword: 'password',
      );
      final edited = previous.copyWith(baseUrl: 'https://other.test/v1');

      final safe = DirectConnectionProfile.secureUpdate(
        previous: previous,
        next: edited,
      );

      expect(safe.apiKey, isNull);
      expect(safe.customHeaders, isEmpty);
      expect(safe.allowSelfSignedCertificates, isFalse);
      expect(safe.mtlsCertificateChainPem, isNull);
      expect(safe.mtlsPrivateKeyPem, isNull);
      expect(safe.mtlsPrivateKeyPassword, isNull);
    });

    test('same origin retains secrets and exact endpoint prefix', () {
      final previous = _profile(apiKey: 'secret');
      final edited = previous.copyWith(
        baseUrl: 'https://example.test/custom/v1',
      );
      final safe = DirectConnectionProfile.secureUpdate(
        previous: previous,
        next: edited,
      );

      expect(safe.apiKey, 'secret');
      expect(
        safe.requestBaseUri().toString(),
        'https://example.test/custom/v1/',
      );
    });

    test('bearer confirmation never rebinds TLS material', () {
      final previous = _profile(
        apiKey: 'old-secret',
        allowSelfSignedCertificates: true,
        mtlsCertificateChainPem: 'CERT',
        mtlsPrivateKeyPem: 'KEY',
      );
      final edited = previous.copyWith(
        baseUrl: 'https://other.test/v1',
        apiKey: 'new-secret',
      );

      final safe = DirectConnectionProfile.secureUpdate(
        previous: previous,
        next: edited,
        secretsConfirmedForNewOrigin: true,
      );

      expect(safe.apiKey, 'new-secret');
      expect(safe.allowSelfSignedCertificates, isFalse);
      expect(safe.mtlsCertificateChainPem, isNull);
      expect(safe.mtlsPrivateKeyPem, isNull);
    });

    test('HTTP factory scopes auth and disables redirects', () {
      final profile = _profile(
        apiKey: 'secret',
        customHeaders: const {'X-Tenant': 'one'},
      );
      final dio = const DirectHttpClientFactory().create(profile);
      addTearDown(() => dio.close(force: true));

      expect(dio.options.baseUrl, 'https://example.test/v1/');
      expect(dio.options.followRedirects, isFalse);
      expect(dio.options.headers['Authorization'], 'Bearer secret');
      expect(dio.options.headers['X-Tenant'], 'one');
    });
  });
}

DirectConnectionProfile _profile({
  String baseUrl = 'https://example.test/v1',
  String? apiKey,
  Map<String, String> customHeaders = const {},
  bool allowSelfSignedCertificates = false,
  String? mtlsCertificateChainPem,
  String? mtlsPrivateKeyPem,
  String? mtlsPrivateKeyPassword,
}) => DirectConnectionProfile(
  id: 'profile-one',
  name: 'Example',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: baseUrl,
  apiKey: apiKey,
  customHeaders: customHeaders,
  allowSelfSignedCertificates: allowSelfSignedCertificates,
  mtlsCertificateChainPem: mtlsCertificateChainPem,
  mtlsPrivateKeyPem: mtlsPrivateKeyPem,
  mtlsPrivateKeyPassword: mtlsPrivateKeyPassword,
);

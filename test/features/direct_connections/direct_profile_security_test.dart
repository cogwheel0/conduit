import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/direct_http_client.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DirectConnectionProfile security', () {
    test('versioned document round-trips secrets without redaction loss', () {
      final profile = _profile(
        apiKey: 'secret-key',
        customHeaders: const {'X-Tenant': 'tenant-secret'},
        openAiApiMode: DirectOpenAiApiMode.responses,
        apiKeyAuthMode: DirectApiKeyAuthMode.apiKeyHeader,
        apiVersion: '2024-10-21',
        modelIdPrefix: 'studio',
        tags: const ['local', 'private'],
      );

      final encoded = DirectConnectionProfilesDocument([profile]).encode();
      final decoded = DirectConnectionProfilesDocument.decode(encoded);

      expect(decoded.profiles, hasLength(1));
      expect(decoded.profiles.single.apiKey, 'secret-key');
      expect(
        decoded.profiles.single.openAiApiMode,
        DirectOpenAiApiMode.responses,
      );
      expect(
        decoded.profiles.single.apiKeyAuthMode,
        DirectApiKeyAuthMode.apiKeyHeader,
      );
      expect(decoded.profiles.single.apiVersion, '2024-10-21');
      expect(decoded.profiles.single.modelIdPrefix, 'studio');
      expect(decoded.profiles.single.tags, ['local', 'private']);
      expect(
        decoded.profiles.single.customHeaders['X-Tenant'],
        'tenant-secret',
      );
    });

    test('legacy profiles default to Chat Completions mode', () {
      final profile = DirectConnectionProfile.fromJson({
        'schemaVersion': DirectConnectionProfile.currentSchemaVersion,
        'id': 'legacy-profile',
        'name': 'Legacy provider',
        'adapterKey': kOpenAiCompatibleAdapterKey,
        'baseUrl': 'https://example.test/v1',
      });

      expect(profile.openAiApiMode, DirectOpenAiApiMode.chatCompletions);
    });

    test('rejects unknown persisted protocol and auth modes', () {
      final base = {
        'schemaVersion': DirectConnectionProfile.currentSchemaVersion,
        'id': 'future-profile',
        'name': 'Future provider',
        'adapterKey': kOpenAiCompatibleAdapterKey,
        'baseUrl': 'https://example.test/v1',
      };

      expect(
        () => DirectConnectionProfile.fromJson({
          ...base,
          'openAiApiMode': 'future-protocol',
        }),
        throwsFormatException,
      );
      expect(
        () => DirectConnectionProfile.fromJson({
          ...base,
          'apiKeyAuthMode': 'future-auth',
        }),
        throwsFormatException,
      );
    });

    test('canonicalizes optional API version and model prefix values', () {
      final profile = _profile(
        apiVersion: ' 2024-10-21 ',
        modelIdPrefix: ' studio ',
      );
      final empty = _profile(apiVersion: '  ', modelIdPrefix: '\t');

      expect(profile.apiVersion, '2024-10-21');
      expect(profile.modelIdPrefix, 'studio');
      expect(empty.apiVersion, isNull);
      expect(empty.modelIdPrefix, isNull);
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
      expect(
        () => _profile(apiVersion: 'preview?secret=value').validate(),
        throwsFormatException,
      );
      expect(
        () => _profile(modelIdPrefix: 'bad prefix').validate(),
        throwsFormatException,
      );
      expect(
        () => _profile(
          apiKey: 'azure-secret',
          apiKeyAuthMode: DirectApiKeyAuthMode.apiKeyHeader,
          customHeaders: const {'api-key': 'duplicate'},
        ).validate(),
        throwsFormatException,
      );
    });

    test('rejects whitespace around custom header names', () {
      for (final name in [' X-Token', 'X-Token ', '\tX-Token']) {
        expect(
          () => _profile(customHeaders: {name: 'value'}).validate(),
          throwsFormatException,
        );
      }
    });

    test('custom header values match dart:io field-value rules', () {
      for (final value in [
        'before\u0000after',
        'before\u0008after',
        'before\u000bafter',
        'before\u001fafter',
        'before\u007fafter',
        'caf\u00e9',
      ]) {
        expect(
          () => _profile(customHeaders: {'X-Test': value}).validate(),
          throwsFormatException,
        );
      }

      expect(
        _profile(
          customHeaders: const {'X-Test': 'visible ASCII\twith tab'},
        ).validateOrNull(),
        isNull,
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

    test('explicit confirmation covers the complete bearer/header set', () {
      final previous = _profile(
        apiKey: 'old-secret',
        customHeaders: const {
          'X-Api-Key': 'old-header',
          'X-Tenant': 'tenant-a',
        },
        allowSelfSignedCertificates: true,
        mtlsCertificateChainPem: 'CERT',
        mtlsPrivateKeyPem: 'KEY',
        mtlsPrivateKeyPassword: 'password',
      );
      final edited = previous.copyWith(
        baseUrl: 'https://other.test/v1',
        apiKey: 'new-secret',
        customHeaders: const {
          'X-Api-Key': 'new-header',
          'X-Tenant': 'tenant-a',
        },
      );

      final safe = DirectConnectionProfile.secureUpdate(
        previous: previous,
        next: edited,
        secretsConfirmedForNewOrigin: true,
      );

      expect(safe.apiKey, 'new-secret');
      expect(safe.customHeaders, {
        'X-Api-Key': 'new-header',
        'X-Tenant': 'tenant-a',
      });
      expect(safe.allowSelfSignedCertificates, isFalse);
      expect(safe.mtlsCertificateChainPem, isNull);
      expect(safe.mtlsPrivateKeyPem, isNull);
      expect(safe.mtlsPrivateKeyPassword, isNull);
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

    test('HTTP factory supports Azure API-key auth and API versions', () {
      final profile = _profile(
        apiKey: 'azure-secret',
        apiKeyAuthMode: DirectApiKeyAuthMode.apiKeyHeader,
        apiVersion: '2024-10-21',
      );
      final dio = const DirectHttpClientFactory().create(profile);
      addTearDown(() => dio.close(force: true));

      expect(dio.options.headers['api-key'], 'azure-secret');
      expect(dio.options.headers['Authorization'], isNull);
      expect(dio.options.queryParameters['api-version'], '2024-10-21');
    });

    test('HTTP factory rotates cached native TLS clients between profiles', () {
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final original = dio.httpClientAdapter;

      const DirectHttpClientFactory().configure(
        dio,
        _profile(allowSelfSignedCertificates: true),
      );
      final customTls = dio.httpClientAdapter as IOHttpClientAdapter;

      expect(customTls, isNot(same(original)));
      expect(customTls.createHttpClient, isNotNull);

      const DirectHttpClientFactory().configure(dio, _profile());
      final defaultTls = dio.httpClientAdapter as IOHttpClientAdapter;

      expect(defaultTls, isNot(same(customTls)));
      expect(defaultTls.createHttpClient, isNull);
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
  DirectOpenAiApiMode openAiApiMode = DirectOpenAiApiMode.chatCompletions,
  DirectApiKeyAuthMode apiKeyAuthMode = DirectApiKeyAuthMode.bearer,
  String? apiVersion,
  String? modelIdPrefix,
  List<String> tags = const [],
}) => DirectConnectionProfile(
  id: 'profile-one',
  name: 'Example',
  adapterKey: kOpenAiCompatibleAdapterKey,
  baseUrl: baseUrl,
  openAiApiMode: openAiApiMode,
  apiKeyAuthMode: apiKeyAuthMode,
  apiVersion: apiVersion,
  modelIdPrefix: modelIdPrefix,
  tags: tags,
  apiKey: apiKey,
  customHeaders: customHeaders,
  allowSelfSignedCertificates: allowSelfSignedCertificates,
  mtlsCertificateChainPem: mtlsCertificateChainPem,
  mtlsPrivateKeyPem: mtlsPrivateKeyPem,
  mtlsPrivateKeyPassword: mtlsPrivateKeyPassword,
);

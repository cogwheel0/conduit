import 'dart:io';

// ignore: implementation_imports
import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart'
    as cached_network_image_ce;
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/network/self_signed_image_cache_manager_factory_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'self-signed-image-cache-manager-test',
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('namespaces differ by host, port, and TLS mode', () {
    final selfSigned = _server(
      id: 'self-signed',
      url: 'https://alpha.example.test',
      allowSelfSignedCertificates: true,
    );
    final otherHost = _server(
      id: 'other-host',
      url: 'https://beta.example.test',
      allowSelfSignedCertificates: true,
    );
    final otherPort = _server(
      id: 'other-port',
      url: 'https://alpha.example.test:8443',
      allowSelfSignedCertificates: true,
    );
    final mutualTls = _server(
      id: 'mtls',
      url: 'https://alpha.example.test',
      mtlsCertificateChainPem: 'cert',
      mtlsPrivateKeyPem: 'key',
    );

    expect(
      buildSelfSignedImageCacheNamespace(selfSigned),
      'conduit-selfsigned-alpha.example.test:0',
    );
    expect(
      buildSelfSignedImageCacheNamespace(otherHost),
      isNot(buildSelfSignedImageCacheNamespace(selfSigned)),
    );
    expect(
      buildSelfSignedImageCacheNamespace(otherPort),
      isNot(buildSelfSignedImageCacheNamespace(selfSigned)),
    );
    expect(
      buildSelfSignedImageCacheNamespace(mutualTls),
      'conduit-mtls-alpha.example.test:0',
    );
  });

  test('isolates identical URLs across different TLS servers', () async {
    final managerA = buildSelfSignedImageCacheManager(
      _server(
        id: 'server-a',
        url: 'https://alpha.example.test',
        allowSelfSignedCertificates: true,
      ),
      cacheDirectoryProvider: () async => tempDir,
    );
    final managerB = buildSelfSignedImageCacheManager(
      _server(
        id: 'server-b',
        url: 'https://beta.example.test',
        allowSelfSignedCertificates: true,
      ),
      cacheDirectoryProvider: () async => tempDir,
    );

    expect(managerA, isNotNull);
    expect(managerB, isNotNull);

    try {
      const url = 'https://cdn.example.test/protected/avatar.png';

      await managerA!.putFile(url, [1, 2, 3], fileExtension: 'png');
      await managerB!.putFile(url, [4, 5, 6], fileExtension: 'png');

      final cachedA = await managerA.getFileFromCache(url);
      final cachedB = await managerB.getFileFromCache(url);

      expect(cachedA, isNotNull);
      expect(cachedB, isNotNull);
      expect(await cachedA!.file.readAsBytes(), orderedEquals([1, 2, 3]));
      expect(await cachedB!.file.readAsBytes(), orderedEquals([4, 5, 6]));
    } finally {
      await managerA?.dispose();
      await managerB?.dispose();
    }
  });

  test('does not share cache with the package default manager', () async {
    final tlsManager = buildSelfSignedImageCacheManager(
      _server(
        id: 'server-a',
        url: 'https://alpha.example.test',
        allowSelfSignedCertificates: true,
      ),
      cacheDirectoryProvider: () async => tempDir,
    );
    final defaultManager = cached_network_image_ce.DefaultCacheManager(
      cacheDirectoryProvider: () async => tempDir,
    );

    expect(tlsManager, isNotNull);

    try {
      const url = 'https://cdn.example.test/protected/avatar.png';

      await defaultManager.putFile(url, [9, 9, 9], fileExtension: 'png');
      await tlsManager!.putFile(url, [7, 7, 7], fileExtension: 'png');

      final defaultCached = await defaultManager.getFileFromCache(url);
      final tlsCached = await tlsManager.getFileFromCache(url);

      expect(defaultCached, isNotNull);
      expect(tlsCached, isNotNull);
      expect(
        await defaultCached!.file.readAsBytes(),
        orderedEquals([9, 9, 9]),
      );
      expect(await tlsCached!.file.readAsBytes(), orderedEquals([7, 7, 7]));
    } finally {
      await tlsManager?.dispose();
      await defaultManager.dispose();
    }
  });
}

ServerConfig _server({
  required String id,
  required String url,
  bool allowSelfSignedCertificates = false,
  String? mtlsCertificateChainPem,
  String? mtlsPrivateKeyPem,
}) {
  return ServerConfig(
    id: id,
    name: id,
    url: url,
    allowSelfSignedCertificates: allowSelfSignedCertificates,
    mtlsCertificateChainPem: mtlsCertificateChainPem,
    mtlsPrivateKeyPem: mtlsPrivateKeyPem,
  );
}

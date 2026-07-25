import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/sherpa/sherpa_catalog.dart';
import 'package:conduit/core/sherpa/sherpa_model.dart';
import 'package:conduit/core/sherpa/sherpa_model_manager.dart';
import 'package:conduit/core/sherpa/sherpa_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storageChannel = MethodChannel('app.cogwheel.conduit/sherpa_storage');
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'conduit-sherpa-archive-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (call) async {
          if (call.method == 'getNoBackupDirectory') {
            return temporaryDirectory.path;
          }
          if (call.method == 'getDeviceInfo') {
            return <String, Object?>{
              'freeStorageBytes': 1024 * 1024 * 1024,
              'physicalMemoryBytes': 1024 * 1024 * 1024,
              'abis': <String>['arm64'],
              'meteredNetwork': false,
            };
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test('extracts a bounded tar.bz2 archive', () {
    final archiveFile = _writeArchive(
      temporaryDirectory,
      Archive()
        ..add(ArchiveFile.string('model/tokens.txt', 'hello'))
        ..add(ArchiveFile.string('model/model.int8.onnx', 'weights')),
    );
    final destination = Directory('${temporaryDirectory.path}/installed');

    extractSherpaArchiveSafely(
      archivePath: archiveFile.path,
      destinationPath: destination.path,
      maximumBytes: 1024,
    );

    check(
      File('${destination.path}/model/tokens.txt').readAsStringSync(),
    ).equals('hello');
    check(File('${destination.path}/.archive.tar').existsSync()).isFalse();
  });

  test('rejects archive traversal and leaves no escaped file', () {
    final archiveFile = _writeArchive(
      temporaryDirectory,
      Archive()..add(ArchiveFile.string('../escaped.txt', 'unsafe')),
    );
    final destination = Directory('${temporaryDirectory.path}/staging');

    check(
      () => extractSherpaArchiveSafely(
        archivePath: archiveFile.path,
        destinationPath: destination.path,
        maximumBytes: 1024,
      ),
    ).throws<StateError>();
    check(
      File('${temporaryDirectory.path}/escaped.txt').existsSync(),
    ).isFalse();
  });

  test('rejects symbolic links and declared-size overflow', () {
    final linkArchive = _writeArchive(
      temporaryDirectory,
      Archive()..add(ArchiveFile.symlink('model/link', '../../outside')),
      name: 'link.tar.bz2',
    );
    check(
      () => extractSherpaArchiveSafely(
        archivePath: linkArchive.path,
        destinationPath: '${temporaryDirectory.path}/link-output',
        maximumBytes: 1024,
      ),
    ).throws<StateError>();

    final largeArchive = _writeArchive(
      temporaryDirectory,
      Archive()..add(ArchiveFile.string('model/large.bin', '123456789')),
      name: 'large.tar.bz2',
    );
    check(
      () => extractSherpaArchiveSafely(
        archivePath: largeArchive.path,
        destinationPath: '${temporaryDirectory.path}/large-output',
        maximumBytes: 8,
      ),
    ).throws<StateError>();
  });

  test('rejects case-insensitive duplicate paths', () {
    final archiveFile = _writeArchive(
      temporaryDirectory,
      Archive()
        ..add(ArchiveFile.string('model/TOKENS.txt', 'first'))
        ..add(ArchiveFile.string('model/tokens.txt', 'second')),
    );

    check(
      () => extractSherpaArchiveSafely(
        archivePath: archiveFile.path,
        destinationPath: '${temporaryDirectory.path}/duplicate-output',
        maximumBytes: 1024,
      ),
    ).throws<StateError>();
  });

  test('runtime failures mark installed models for repair', () async {
    final storage = SherpaStorage(channel: storageChannel);
    final model = sherpaModelCatalog.first;
    final directory = Directory(
      '${(await storage.modelsDirectory()).path}/${model.id}',
    );
    await directory.create(recursive: true);
    for (final role in model.runtime.files.where((role) => !role.optional)) {
      final file = File('${directory.path}/${role.pathSuffix}');
      await file.parent.create(recursive: true);
      await file.writeAsString(role.name);
    }
    await File('${directory.path}/.conduit-model.json').writeAsString(
      jsonEncode({
        'id': model.id,
        'release': model.release,
        'sha256': model.sha256,
        'installedBytes': 1,
      }),
    );

    check(await storage.installedModel(model.id)).isNotNull();
    await storage.markModelBroken(model.id, StateError('load failed'));

    check(await storage.installedModel(model.id)).isNull();
    check(await storage.brokenModelIds()).contains(model.id);
  });

  test('rejects an oversized chunk before it can fill storage', () async {
    var requests = 0;
    final payload = List<int>.generate(5, (index) => index);
    final adapter = _TestHttpClientAdapter((_) async {
      requests++;
      return ResponseBody(
        Stream<Uint8List>.fromIterable([
          Uint8List.fromList(payload.sublist(0, 2)),
          Uint8List.fromList(payload.sublist(2)),
        ]),
        HttpStatus.ok,
      );
    });
    final model = _downloadTestModel(
      Uri.parse('https://example.com/model.tar.bz2'),
      archiveBytes: 4,
      sha256Value: sha256.convert(payload).toString(),
    );
    final storage = SherpaStorage(channel: storageChannel);
    final dio = Dio()..httpClientAdapter = adapter;
    final manager = SherpaModelManager(
      storage: storage,
      dio: dio,
      platformOverride: PlatformType.ios,
    );
    try {
      final failed = manager.progress.firstWhere(
        (progress) => progress[model.id]?.phase == SherpaInstallPhase.failed,
      );
      manager.enqueue(model);
      final progress = await failed.timeout(const Duration(seconds: 5));

      final partial = File(
        '${(await storage.downloadsDirectory()).path}/'
        '${model.id}.tar.bz2.part',
      );
      check(requests).equals(1);
      check(progress[model.id]?.error).isA<StateError>();
      check(
        progress[model.id]!.error.toString(),
      ).contains('exceeded the expected');
      check(await partial.exists()).isFalse();
    } finally {
      manager.dispose();
    }
  });

  test(
    'reuses an exact-size completed partial without another request',
    () async {
      var requests = 0;
      final adapter = _TestHttpClientAdapter((_) async {
        requests++;
        return ResponseBody(
          const Stream<Uint8List>.empty(),
          HttpStatus.internalServerError,
        );
      });
      final payload = <int>[1, 2, 3, 4];
      final model = _downloadTestModel(
        Uri.parse('https://example.com/model.tar.bz2'),
        archiveBytes: payload.length,
        sha256Value: sha256.convert(payload).toString(),
      );
      final storage = SherpaStorage(channel: storageChannel);
      final partial = File(
        '${(await storage.downloadsDirectory()).path}/'
        '${model.id}.tar.bz2.part',
      );
      await partial.writeAsBytes(payload);
      final dio = Dio()..httpClientAdapter = adapter;
      final manager = SherpaModelManager(
        storage: storage,
        dio: dio,
        validator: (_, _) async => throw StateError('stop after download'),
        platformOverride: PlatformType.ios,
      );
      try {
        final failed = manager.progress.firstWhere(
          (progress) => progress[model.id]?.phase == SherpaInstallPhase.failed,
        );
        manager.enqueue(model);
        await failed.timeout(const Duration(seconds: 5));
        check(requests).equals(0);
      } finally {
        manager.dispose();
      }
    },
  );

  test('rejects an incompatible ABI before downloading', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (call) async {
          if (call.method == 'getNoBackupDirectory') {
            return temporaryDirectory.path;
          }
          if (call.method == 'getDeviceInfo') {
            return <String, Object?>{
              'freeStorageBytes': 1024 * 1024 * 1024,
              'physicalMemoryBytes': 1024 * 1024 * 1024,
              'abis': <String>['x86'],
              'meteredNetwork': false,
            };
          }
          return null;
        });
    var requests = 0;
    final adapter = _TestHttpClientAdapter((_) async {
      requests++;
      return ResponseBody(const Stream<Uint8List>.empty(), HttpStatus.ok);
    });
    final model = _downloadTestModel(
      Uri.parse('https://example.com/model.tar.bz2'),
      archiveBytes: 4,
      sha256Value: List.filled(64, '0').join(),
      supportedAbis: const ['arm64'],
    );
    final manager = SherpaModelManager(
      storage: SherpaStorage(channel: storageChannel),
      dio: Dio()..httpClientAdapter = adapter,
      platformOverride: PlatformType.ios,
    );
    try {
      final failed = manager.progress.firstWhere(
        (progress) => progress[model.id]?.phase == SherpaInstallPhase.failed,
      );
      manager.enqueue(model);
      final progress = await failed.timeout(const Duration(seconds: 5));

      check(requests).equals(0);
      check(
        progress[model.id]!.error.toString(),
      ).contains('device architecture');
    } finally {
      manager.dispose();
    }
  });
}

final class _TestHttpClientAdapter implements HttpClientAdapter {
  _TestHttpClientAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options) _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

SherpaModel _downloadTestModel(
  Uri archiveUrl, {
  required int archiveBytes,
  required String sha256Value,
  List<String> supportedAbis = const ['arm64'],
}) {
  return SherpaModel(
    id: 'download-test-model',
    release: 'test',
    displayName: 'Download test model',
    family: SherpaModelFamily.whisper,
    adapter: SherpaRuntimeAdapter.offlineWhisper,
    kind: SherpaModelKind.stt,
    mode: SherpaRecognitionMode.offline,
    languages: const [SherpaLanguage('en')],
    tier: SherpaModelTier.compact,
    archiveUrl: archiveUrl,
    sha256: sha256Value,
    archiveBytes: archiveBytes,
    installedBytes: archiveBytes,
    workingSet: SherpaWorkingSet.low,
    runtime: const SherpaRuntimeConfig(files: []),
    source: Uri.parse('https://example.com/model'),
    license: SherpaLicense(
      name: 'Test',
      url: Uri.parse('https://example.com/license'),
    ),
    minimumSherpaVersion: '1.13.4',
    supportedAbis: supportedAbis,
  );
}

File _writeArchive(
  Directory directory,
  Archive archive, {
  String name = 'model.tar.bz2',
}) {
  final tar = TarEncoder().encodeBytes(archive);
  final compressed = BZip2Encoder().encodeBytes(tar);
  return File('${directory.path}/$name')..writeAsBytesSync(compressed);
}

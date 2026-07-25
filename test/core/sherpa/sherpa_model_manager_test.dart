import 'dart:async';
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

  test('prepares the bundled VAD once for concurrent callers', () async {
    final firstStorage = SherpaStorage(channel: storageChannel);
    final secondStorage = SherpaStorage(channel: storageChannel);
    final firstPreparation = firstStorage.prepareVadModel();
    final secondPreparation = secondStorage.prepareVadModel();

    check(identical(firstPreparation, secondPreparation)).isTrue();
    final files = await Future.wait([firstPreparation, secondPreparation]);

    check(files[0].path).equals(files[1].path);
    check(await files[0].exists()).isTrue();
    check(
      (await sha256.bind(files[0].openRead()).first).toString(),
    ).equals(SherpaStorage.vadSha256);
  });

  test('device capability probing tolerates platform failures', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (call) async {
          if (call.method == 'getDeviceInfo') {
            throw PlatformException(code: 'CREATE_FAILED');
          }
          return temporaryDirectory.path;
        });

    final info = await SherpaStorage(channel: storageChannel).deviceInfo();

    check(info.freeStorageBytes).isNull();
    check(info.physicalMemoryBytes).isNull();
    check(info.abis).isEmpty();
    check(info.meteredNetwork).isNull();
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

  test('resumes a partial download with a matching content range', () async {
    final source = _writeArchive(
      temporaryDirectory,
      Archive()..add(ArchiveFile.string('model/file.txt', 'resume')),
      name: 'resume-source.tar.bz2',
    );
    final payload = await source.readAsBytes();
    final offset = payload.length ~/ 3;
    late RequestOptions request;
    final adapter = _TestHttpClientAdapter((options) async {
      request = options;
      return ResponseBody(
        Stream.value(Uint8List.sublistView(payload, offset)),
        HttpStatus.partialContent,
        headers: {
          'content-range': [
            'bytes $offset-${payload.length - 1}/${payload.length}',
          ],
          Headers.contentLengthHeader: ['${payload.length - offset}'],
          'etag': ['"resume-v1"'],
        },
      );
    });
    final model = _downloadTestModel(
      Uri.parse('https://example.com/resume.tar.bz2'),
      archiveBytes: payload.length,
      sha256Value: sha256.convert(payload).toString(),
    );
    final storage = SherpaStorage(channel: storageChannel);
    final partial = File(
      '${(await storage.downloadsDirectory()).path}/'
      '${model.id}.tar.bz2.part',
    );
    await partial.writeAsBytes(payload.sublist(0, offset));
    await File(
      '${partial.path}.http.json',
    ).writeAsString(jsonEncode({'etag': '"resume-v1"', 'lastModified': null}));
    final manager = SherpaModelManager(
      storage: storage,
      dio: Dio()..httpClientAdapter = adapter,
      validator: (_, _) async {},
      platformOverride: PlatformType.ios,
    );
    try {
      final installed = manager.progress.firstWhere(
        (progress) => progress[model.id]?.phase == SherpaInstallPhase.installed,
      );
      manager.enqueue(model);
      await installed.timeout(const Duration(seconds: 5));

      check(request.headers['Range']).equals('bytes=$offset-');
      check(
        await File(
          '${(await storage.modelsDirectory()).path}/${model.id}/'
          '.conduit-model.json',
        ).exists(),
      ).isTrue();
    } finally {
      manager.dispose();
    }
  });

  test('validator mismatch restarts a partial download from zero', () async {
    final source = _writeArchive(
      temporaryDirectory,
      Archive()..add(ArchiveFile.string('model/file.txt', 'validator')),
      name: 'validator-source.tar.bz2',
    );
    final payload = await source.readAsBytes();
    final offset = payload.length ~/ 3;
    final starts = <String?>[];
    final adapter = _TestHttpClientAdapter((options) async {
      starts.add(options.headers['Range'] as String?);
      if (starts.length == 1) {
        return ResponseBody(
          Stream.value(Uint8List.sublistView(payload, offset)),
          HttpStatus.partialContent,
          headers: {
            'content-range': [
              'bytes $offset-${payload.length - 1}/${payload.length}',
            ],
            Headers.contentLengthHeader: ['${payload.length - offset}'],
            'etag': ['"new"'],
            'last-modified': ['Tue, 21 Jul 2026 10:00:00 GMT'],
          },
        );
      }
      return ResponseBody(
        Stream.value(payload),
        HttpStatus.ok,
        headers: {
          Headers.contentLengthHeader: ['${payload.length}'],
          'etag': ['"new"'],
          'last-modified': ['Tue, 21 Jul 2026 10:00:00 GMT'],
        },
      );
    });
    final model = _downloadTestModel(
      Uri.parse('https://example.com/validator.tar.bz2'),
      archiveBytes: payload.length,
      sha256Value: sha256.convert(payload).toString(),
    );
    final storage = SherpaStorage(channel: storageChannel);
    final partial = File(
      '${(await storage.downloadsDirectory()).path}/'
      '${model.id}.tar.bz2.part',
    );
    await partial.writeAsBytes(payload.sublist(0, offset));
    await File('${partial.path}.http.json').writeAsString(
      jsonEncode({
        'etag': '"old"',
        'lastModified': 'Mon, 20 Jul 2026 10:00:00 GMT',
      }),
    );
    final manager = SherpaModelManager(
      storage: storage,
      dio: Dio()..httpClientAdapter = adapter,
      validator: (_, _) async {},
      platformOverride: PlatformType.ios,
    );
    try {
      final installed = manager.progress.firstWhere(
        (progress) => progress[model.id]?.phase == SherpaInstallPhase.installed,
      );
      manager.enqueue(model);
      await installed.timeout(const Duration(seconds: 5));

      check(starts).deepEquals(['bytes=$offset-', null]);
      check(
        await File(
          '${(await storage.modelsDirectory()).path}/${model.id}/'
          '.conduit-model.json',
        ).exists(),
      ).isTrue();
    } finally {
      manager.dispose();
    }
  });

  test('malformed resume range is discarded before restarting', () async {
    final source = _writeArchive(
      temporaryDirectory,
      Archive()..add(ArchiveFile.string('model/file.txt', 'range')),
      name: 'range-source.tar.bz2',
    );
    final payload = await source.readAsBytes();
    final offset = payload.length ~/ 3;
    final starts = <String?>[];
    final adapter = _TestHttpClientAdapter((options) async {
      starts.add(options.headers['Range'] as String?);
      if (starts.length == 1) {
        return ResponseBody(
          Stream.value(Uint8List.sublistView(payload, offset)),
          HttpStatus.partialContent,
          headers: {
            'content-range': ['bytes malformed'],
            'etag': ['"range-v1"'],
          },
        );
      }
      return ResponseBody(
        Stream.value(payload),
        HttpStatus.ok,
        headers: {
          Headers.contentLengthHeader: ['${payload.length}'],
          'etag': ['"range-v1"'],
        },
      );
    });
    final model = _downloadTestModel(
      Uri.parse('https://example.com/range.tar.bz2'),
      archiveBytes: payload.length,
      sha256Value: sha256.convert(payload).toString(),
    );
    final storage = SherpaStorage(channel: storageChannel);
    final partial = File(
      '${(await storage.downloadsDirectory()).path}/'
      '${model.id}.tar.bz2.part',
    );
    await partial.writeAsBytes(payload.sublist(0, offset));
    await File(
      '${partial.path}.http.json',
    ).writeAsString(jsonEncode({'etag': '"range-v1"', 'lastModified': null}));
    final manager = SherpaModelManager(
      storage: storage,
      dio: Dio()..httpClientAdapter = adapter,
      validator: (_, _) async {},
      platformOverride: PlatformType.ios,
    );
    try {
      final installed = manager.progress.firstWhere(
        (progress) => progress[model.id]?.phase == SherpaInstallPhase.installed,
      );
      manager.enqueue(model);
      await installed.timeout(const Duration(seconds: 5));

      check(starts).deepEquals(['bytes=$offset-', null]);
      check(
        await File(
          '${(await storage.modelsDirectory()).path}/${model.id}/'
          '.conduit-model.json',
        ).exists(),
      ).isTrue();
    } finally {
      manager.dispose();
    }
  });

  test('does not enqueue a duplicate while validation is active', () async {
    final source = _writeArchive(
      temporaryDirectory,
      Archive()..add(ArchiveFile.string('model/file.txt', 'queue')),
      name: 'queue-source.tar.bz2',
    );
    final payload = await source.readAsBytes();
    final adapter = _TestHttpClientAdapter(
      (_) async => ResponseBody(
        Stream.value(payload),
        HttpStatus.ok,
        headers: {
          Headers.contentLengthHeader: ['${payload.length}'],
        },
      ),
    );
    final model = _downloadTestModel(
      Uri.parse('https://example.com/queue.tar.bz2'),
      archiveBytes: payload.length,
      sha256Value: sha256.convert(payload).toString(),
    );
    final validationGate = Completer<void>();
    final manager = SherpaModelManager(
      storage: SherpaStorage(channel: storageChannel),
      dio: Dio()..httpClientAdapter = adapter,
      validator: (_, _) => validationGate.future,
      platformOverride: PlatformType.ios,
    );
    var installedEvents = 0;
    final subscription = manager.progress.listen((progress) {
      if (progress[model.id]?.phase == SherpaInstallPhase.installed) {
        installedEvents++;
      }
    });
    try {
      final validating = manager.progress.firstWhere(
        (progress) =>
            progress[model.id]?.phase == SherpaInstallPhase.validating,
      );
      manager.enqueue(model);
      await validating.timeout(const Duration(seconds: 5));

      manager.enqueue(model);
      validationGate.complete();
      await manager.progress
          .firstWhere(
            (progress) =>
                progress[model.id]?.phase == SherpaInstallPhase.installed,
          )
          .timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      check(installedEvents).equals(1);
    } finally {
      await subscription.cancel();
      manager.dispose();
    }
  });

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

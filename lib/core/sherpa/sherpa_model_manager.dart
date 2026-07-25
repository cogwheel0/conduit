import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../utils/debug_logger.dart';
import 'sherpa_model.dart';
import 'sherpa_runtime.dart';
import 'sherpa_storage.dart';

enum SherpaInstallPhase {
  queued,
  downloading,
  verifying,
  extracting,
  validating,
  installed,
  failed,
}

final class SherpaInstallProgress {
  const SherpaInstallProgress({
    required this.modelId,
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  final String modelId;
  final SherpaInstallPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final Object? error;

  double? get fraction =>
      totalBytes <= 0 ? null : (receivedBytes / totalBytes).clamp(0, 1);
}

typedef SherpaRuntimeValidator =
    Future<void> Function(SherpaModel model, Directory directory);

final sherpaStorageProvider = Provider<SherpaStorage>((ref) => SherpaStorage());

final sherpaStorageChangesProvider = StreamProvider<void>((ref) {
  return SherpaStorage.changes;
});

final sherpaModelManagerProvider = Provider<SherpaModelManager>((ref) {
  final manager = SherpaModelManager(storage: ref.watch(sherpaStorageProvider));
  ref.onDispose(manager.dispose);
  return manager;
});

final sherpaInstallProgressProvider =
    StreamProvider<Map<String, SherpaInstallProgress>>((ref) {
      return ref.watch(sherpaModelManagerProvider).progress;
    });

final sherpaInstalledModelsProvider =
    FutureProvider<List<InstalledSherpaModel>>((ref) {
      ref.watch(sherpaInstallProgressProvider);
      ref.watch(sherpaStorageChangesProvider);
      return ref.watch(sherpaStorageProvider).installedModels();
    });

final sherpaBrokenModelsProvider = FutureProvider<Set<String>>((ref) {
  ref.watch(sherpaInstallProgressProvider);
  ref.watch(sherpaStorageChangesProvider);
  return ref.watch(sherpaStorageProvider).brokenModelIds();
});

final class SherpaModelManager {
  SherpaModelManager({
    required SherpaStorage storage,
    Dio? dio,
    SherpaRuntimeValidator? validator,
    PlatformType? platformOverride,
  }) : _storage = storage,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(minutes: 10),
               followRedirects: true,
               maxRedirects: 5,
               headers: const {'Accept': 'application/octet-stream'},
             ),
           ),
       _validator = validator ?? validateSherpaRuntime,
       _platformOverride = platformOverride;

  final SherpaStorage _storage;
  final Dio _dio;
  final SherpaRuntimeValidator _validator;
  final PlatformType? _platformOverride;
  final StreamController<Map<String, SherpaInstallProgress>> _controller =
      StreamController.broadcast();
  final List<SherpaModel> _queue = [];
  final Map<String, SherpaInstallProgress> _progress = {};
  bool _processing = false;
  bool _disposed = false;

  Stream<Map<String, SherpaInstallProgress>> get progress async* {
    yield Map.unmodifiable(_progress);
    yield* _controller.stream;
  }

  void enqueue(SherpaModel model) {
    if (_disposed ||
        _queue.any((queued) => queued.id == model.id) ||
        _progress[model.id]?.phase == SherpaInstallPhase.downloading) {
      return;
    }
    _queue.add(model);
    _setProgress(
      SherpaInstallProgress(
        modelId: model.id,
        phase: SherpaInstallPhase.queued,
        totalBytes: model.archiveBytes,
      ),
    );
    unawaited(_processQueue());
  }

  Future<void> retry(SherpaModel model) async {
    _progress.remove(model.id);
    enqueue(model);
  }

  Future<void> delete(SherpaModel model) async {
    final models = await _storage.modelsDirectory();
    final directory = Directory(path.join(models.path, model.id));
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    _progress.remove(model.id);
    _emit();
  }

  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final model = _queue.removeAt(0);
        try {
          await _install(model);
          _setProgress(
            SherpaInstallProgress(
              modelId: model.id,
              phase: SherpaInstallPhase.installed,
              receivedBytes: model.archiveBytes,
              totalBytes: model.archiveBytes,
            ),
          );
        } catch (error, stackTrace) {
          DebugLogger.error(
            'Sherpa model installation failed',
            scope: 'sherpa/models',
            error: error,
            stackTrace: stackTrace,
          );
          _setProgress(
            SherpaInstallProgress(
              modelId: model.id,
              phase: SherpaInstallPhase.failed,
              totalBytes: model.archiveBytes,
              error: error,
            ),
          );
        }
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _install(SherpaModel model) async {
    final existing = await _storage.installedModel(model.id);
    if (existing != null) return;

    final device = await _storage.deviceInfo();
    final currentPlatform =
        _platformOverride ??
        (Platform.isAndroid
            ? PlatformType.android
            : Platform.isIOS
            ? PlatformType.ios
            : null);
    if (currentPlatform == null || !model.platforms.contains(currentPlatform)) {
      throw UnsupportedError(
        '${model.displayName} does not support this platform',
      );
    }
    final deviceAbis = device.abis.map((abi) => abi.toLowerCase()).toSet();
    final supportedAbis = model.supportedAbis
        .map((abi) => abi.toLowerCase())
        .toSet();
    if (deviceAbis.isEmpty || deviceAbis.intersection(supportedAbis).isEmpty) {
      throw UnsupportedError(
        '${model.displayName} does not support this device architecture',
      );
    }
    if (model.tier == SherpaModelTier.large && !device.is64Bit) {
      throw UnsupportedError('Large Sherpa models require a 64-bit device');
    }
    final requiredBytes =
        (model.archiveBytes +
                (model.installedBytes * 2) +
                math.max(64 * 1024 * 1024, model.installedBytes ~/ 10))
            .toInt();
    if (device.freeStorageBytes case final free? when free < requiredBytes) {
      throw FileSystemException(
        'Not enough storage. ${formatModelBytes(requiredBytes)} is required.',
      );
    }

    final downloads = await _storage.downloadsDirectory();
    final archive = File(path.join(downloads.path, '${model.id}.tar.bz2.part'));
    final validators = File('${archive.path}.http.json');
    await _download(model, archive, validators);

    _setProgress(
      SherpaInstallProgress(
        modelId: model.id,
        phase: SherpaInstallPhase.verifying,
        receivedBytes: model.archiveBytes,
        totalBytes: model.archiveBytes,
      ),
    );
    final digest = await sha256.bind(archive.openRead()).first;
    if (digest.toString() != model.sha256) {
      await archive.delete();
      if (await validators.exists()) await validators.delete();
      throw StateError('Downloaded archive failed SHA-256 verification');
    }

    _setProgress(
      SherpaInstallProgress(
        modelId: model.id,
        phase: SherpaInstallPhase.extracting,
        totalBytes: model.archiveBytes,
      ),
    );
    final stagingRoot = await _storage.stagingDirectory();
    final staging = Directory(path.join(stagingRoot.path, '${model.id}.new'));
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    var promoted = false;
    try {
      await Isolate.run(
        () => extractSherpaArchiveSafely(
          archivePath: archive.path,
          destinationPath: staging.path,
          maximumBytes: math.max(model.installedBytes * 2, 128 * 1024 * 1024),
        ),
      );
      await _storage.resolveRuntimeFiles(model, staging);

      _setProgress(
        SherpaInstallProgress(
          modelId: model.id,
          phase: SherpaInstallPhase.validating,
          totalBytes: model.archiveBytes,
        ),
      );
      await _validator(model, staging);

      final installedBytes = await _storage.directorySize(staging);
      await File(path.join(staging.path, '.conduit-model.json')).writeAsString(
        jsonEncode({
          'id': model.id,
          'release': model.release,
          'sha256': model.sha256,
          'installedBytes': installedBytes,
          'installedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      final models = await _storage.modelsDirectory();
      final destination = Directory(path.join(models.path, model.id));
      if (await destination.exists()) {
        await destination.delete(recursive: true);
      }
      await staging.rename(destination.path);
      promoted = true;
      await archive.delete();
      if (await validators.exists()) await validators.delete();
    } finally {
      if (!promoted && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  Future<void> _download(
    SherpaModel model,
    File archive,
    File validators,
  ) async {
    var offset = await archive.exists() ? await archive.length() : 0;
    Map<String, Object?> oldValidators = const {};
    if (await validators.exists()) {
      try {
        oldValidators =
            jsonDecode(await validators.readAsString()) as Map<String, Object?>;
      } on Object {
        oldValidators = const {};
      }
    }
    if (offset > model.archiveBytes) {
      await archive.writeAsBytes(const []);
      offset = 0;
    }
    if (offset == model.archiveBytes) return;

    Future<Response<ResponseBody>> request(int start) {
      return _dio.get<ResponseBody>(
        model.archiveUrl.toString(),
        options: Options(
          responseType: ResponseType.stream,
          headers: start > 0 ? {'Range': 'bytes=$start-'} : const {},
        ),
      );
    }

    var response = await request(offset);
    var etag = response.headers.value('etag');
    var modified = response.headers.value('last-modified');
    final hasStoredValidator =
        oldValidators['etag'] != null || oldValidators['lastModified'] != null;
    final resumeValidatorsMatch =
        hasStoredValidator &&
        (oldValidators['etag'] == null || oldValidators['etag'] == etag) &&
        (oldValidators['lastModified'] == null ||
            oldValidators['lastModified'] == modified);
    final contentRange = response.headers.value('content-range');
    final rangeStartsAtOffset =
        offset == 0 || contentRange?.startsWith('bytes $offset-') == true;
    if (offset > 0 &&
        (response.statusCode != HttpStatus.partialContent ||
            !resumeValidatorsMatch ||
            !rangeStartsAtOffset)) {
      await response.data?.stream.listen(null).cancel();
      await archive.writeAsBytes(const []);
      offset = 0;
      response = await request(0);
      etag = response.headers.value('etag');
      modified = response.headers.value('last-modified');
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw HttpException(
        'Model server returned HTTP ${response.statusCode}',
        uri: model.archiveUrl,
      );
    }
    try {
      _validateDownloadResponseHeaders(
        response,
        offset: offset,
        expectedBytes: model.archiveBytes,
      );
    } catch (_) {
      if (await archive.exists()) await archive.delete();
      if (await validators.exists()) await validators.delete();
      rethrow;
    }
    await validators.writeAsString(
      jsonEncode({'etag': etag, 'lastModified': modified}),
      flush: true,
    );

    final sink = archive.openWrite(mode: FileMode.append);
    var received = offset;
    var exceededExpectedSize = false;
    Object? streamError;
    StackTrace? streamStackTrace;
    try {
      await for (final chunk in response.data!.stream) {
        if (chunk.length > model.archiveBytes - received) {
          exceededExpectedSize = true;
          throw StateError(
            'Download exceeded the expected ${model.archiveBytes} bytes',
          );
        }
        sink.add(chunk);
        received += chunk.length;
        _setProgress(
          SherpaInstallProgress(
            modelId: model.id,
            phase: SherpaInstallPhase.downloading,
            receivedBytes: received,
            totalBytes: model.archiveBytes,
          ),
        );
      }
    } catch (error, stackTrace) {
      streamError = error;
      streamStackTrace = stackTrace;
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (exceededExpectedSize) {
      if (await archive.exists()) await archive.delete();
      if (await validators.exists()) await validators.delete();
    }
    if (streamError != null) {
      Error.throwWithStackTrace(streamError, streamStackTrace!);
    }
    if (received != model.archiveBytes) {
      throw StateError(
        'Download size mismatch: expected ${model.archiveBytes}, got $received',
      );
    }
  }

  void _setProgress(SherpaInstallProgress progress) {
    _progress[progress.modelId] = progress;
    _emit();
  }

  void _emit() {
    if (!_disposed) _controller.add(Map.unmodifiable(_progress));
  }

  void dispose() {
    _disposed = true;
    _dio.close(force: true);
    unawaited(_controller.close());
  }
}

void _validateDownloadResponseHeaders(
  Response<ResponseBody> response, {
  required int offset,
  required int expectedBytes,
}) {
  final expectedRemaining = expectedBytes - offset;
  final contentLengthValue = response.headers.value(
    Headers.contentLengthHeader,
  );
  final contentLength = contentLengthValue == null
      ? null
      : int.tryParse(contentLengthValue);
  if (contentLengthValue != null &&
      (contentLength == null || contentLength < 0)) {
    throw StateError('Model server returned an invalid Content-Length');
  }
  if (contentLength != null && contentLength > expectedRemaining) {
    throw StateError(
      'Model server advertised $contentLength bytes; '
      'only $expectedRemaining were expected',
    );
  }

  if (response.statusCode != HttpStatus.partialContent) return;
  final value = response.headers.value('content-range');
  final match = value == null
      ? null
      : RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value);
  if (match == null) {
    throw StateError('Model server returned an invalid Content-Range');
  }
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  final total = int.parse(match.group(3)!);
  if (start != offset ||
      total != expectedBytes ||
      end < start ||
      end >= total ||
      (contentLength != null && contentLength != end - start + 1)) {
    throw StateError(
      'Model server returned a Content-Range outside the expected archive',
    );
  }
}

/// Extracts a model archive while rejecting entries that can escape staging
/// or expand beyond the trusted manifest's declared bounds.
void extractSherpaArchiveSafely({
  required String archivePath,
  required String destinationPath,
  required int maximumBytes,
}) {
  const maximumFiles = 20000;
  Directory(destinationPath).createSync(recursive: true);
  final temporaryTar = File(path.join(destinationPath, '.archive.tar'));
  final compressedInput = InputFileStream(archivePath);
  final tarOutput = OutputFileStream(temporaryTar.path);
  try {
    BZip2Decoder().decodeStream(compressedInput, tarOutput);
  } finally {
    compressedInput.closeSync();
    tarOutput.closeSync();
  }

  final input = InputFileStream(temporaryTar.path);
  Archive? archive;
  final seen = <String>{};
  var count = 0;
  var unpackedBytes = 0;
  try {
    archive = TarDecoder().decodeStream(input);
    for (final entry in archive) {
      count++;
      if (count > maximumFiles) {
        throw StateError('Archive contains too many files');
      }
      if (entry.isSymbolicLink) {
        throw StateError('Archive links are not allowed');
      }
      final normalized = path.normalize(entry.name);
      final duplicateKey = normalized.toLowerCase();
      if (path.isAbsolute(normalized) ||
          normalized == '..' ||
          normalized.startsWith('../') ||
          !seen.add(duplicateKey)) {
        throw StateError('Unsafe or duplicate archive path: ${entry.name}');
      }
      final outputPath = path.join(destinationPath, normalized);
      if (!path.isWithin(path.canonicalize(destinationPath), outputPath)) {
        throw StateError('Archive path escapes staging: ${entry.name}');
      }
      if (entry.isDirectory) {
        Directory(outputPath).createSync(recursive: true);
        continue;
      }
      if (!entry.isFile) {
        throw StateError('Unsupported archive entry: ${entry.name}');
      }
      unpackedBytes += entry.size;
      if (unpackedBytes > maximumBytes) {
        throw StateError('Archive exceeds the declared unpacked-size limit');
      }
      final output = OutputFileStream(outputPath);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
    }
  } finally {
    input.closeSync();
    archive?.clearSync();
    if (temporaryTar.existsSync()) temporaryTar.deleteSync();
  }
}

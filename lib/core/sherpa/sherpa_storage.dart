import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'sherpa_catalog.dart';
import 'sherpa_model.dart';

final class SherpaDeviceInfo {
  const SherpaDeviceInfo({
    required this.freeStorageBytes,
    required this.physicalMemoryBytes,
    required this.abis,
    required this.meteredNetwork,
  });

  final int? freeStorageBytes;
  final int? physicalMemoryBytes;
  final List<String> abis;
  final bool? meteredNetwork;

  bool get is64Bit =>
      abis.any((abi) => abi.contains('64') || abi.toLowerCase() == 'arm64');
}

final class InstalledSherpaModel {
  const InstalledSherpaModel({
    required this.model,
    required this.directory,
    required this.installedBytes,
  });

  final SherpaModel model;
  final Directory directory;
  final int installedBytes;
}

final class SherpaStorage {
  SherpaStorage({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('app.cogwheel.conduit/sherpa_storage');

  static const vadAsset = 'assets/vad/silero_vad_v5.onnx';
  static const vadSha256 =
      '2623a2953f6ff3d2c1e61740c6cdb7168133479b267dfef114a4a3cc5bdd788f';
  static const vadVersion = 'silero-v5';
  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  static Stream<void> get changes => _changes.stream;

  final MethodChannel _channel;
  Directory? _root;

  Future<Directory> rootDirectory() async {
    final cached = _root;
    if (cached != null) return cached;

    String? nativePath;
    try {
      nativePath = await _channel.invokeMethod<String>('getNoBackupDirectory');
    } on MissingPluginException {
      nativePath = null;
    }
    final root = nativePath == null
        ? Directory(
            path.join(
              (await getApplicationSupportDirectory()).path,
              'sherpa-no-backup',
            ),
          )
        : Directory(nativePath);
    await root.create(recursive: true);
    _root = root;
    return root;
  }

  Future<Directory> modelsDirectory() async {
    final directory = Directory(
      path.join((await rootDirectory()).path, 'models'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> downloadsDirectory() async {
    final directory = Directory(
      path.join((await rootDirectory()).path, 'downloads'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> stagingDirectory() async {
    final directory = Directory(
      path.join((await rootDirectory()).path, 'staging'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<SherpaDeviceInfo> deviceInfo() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'getDeviceInfo',
      );
      return SherpaDeviceInfo(
        freeStorageBytes: (raw?['freeStorageBytes'] as num?)?.toInt(),
        physicalMemoryBytes: (raw?['physicalMemoryBytes'] as num?)?.toInt(),
        abis: (raw?['abis'] as List<Object?>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        meteredNetwork: raw?['meteredNetwork'] as bool?,
      );
    } on MissingPluginException {
      return const SherpaDeviceInfo(
        freeStorageBytes: null,
        physicalMemoryBytes: null,
        abis: [],
        meteredNetwork: null,
      );
    }
  }

  Future<File> prepareVadModel() async {
    final runtime = Directory(
      path.join((await rootDirectory()).path, 'runtime'),
    );
    await runtime.create(recursive: true);
    final model = File(path.join(runtime.path, 'silero_vad_v5.onnx'));
    final marker = File(path.join(runtime.path, 'silero_vad_v5.json'));

    if (await model.exists() && await marker.exists()) {
      try {
        final metadata =
            jsonDecode(await marker.readAsString()) as Map<String, Object?>;
        if (metadata['version'] == vadVersion &&
            metadata['sha256'] == vadSha256) {
          final hash = await sha256.bind(model.openRead()).first;
          if (hash.toString() == vadSha256) return model;
        }
      } on Object {
        // Invalid runtime metadata is repaired from the trusted asset below.
      }
    }

    final bytes = await rootBundle.load(vadAsset);
    final data = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    if (sha256.convert(data).toString() != vadSha256) {
      throw StateError('Bundled Silero VAD failed integrity verification');
    }
    final temporary = File('${model.path}.tmp');
    await temporary.writeAsBytes(data, flush: true);
    await temporary.rename(model.path);
    await marker.writeAsString(
      jsonEncode({'version': vadVersion, 'sha256': vadSha256}),
      flush: true,
    );
    return model;
  }

  Future<InstalledSherpaModel?> installedModel(String id) async {
    final model = sherpaModelById(id);
    if (model == null) return null;
    final directory = Directory(
      path.join((await modelsDirectory()).path, model.id),
    );
    final receipt = File(path.join(directory.path, '.conduit-model.json'));
    final brokenMarker = File(
      path.join(directory.path, '.conduit-broken.json'),
    );
    if (!await directory.exists() ||
        !await receipt.exists() ||
        await brokenMarker.exists()) {
      return null;
    }
    try {
      final value =
          jsonDecode(await receipt.readAsString()) as Map<String, Object?>;
      if (value['id'] != model.id ||
          value['release'] != model.release ||
          value['sha256'] != model.sha256) {
        return null;
      }
      await resolveRuntimeFiles(model, directory);
      return InstalledSherpaModel(
        model: model,
        directory: directory,
        installedBytes: await directorySize(directory),
      );
    } on Object {
      return null;
    }
  }

  Future<void> markModelBroken(String id, Object error) async {
    final directory = Directory(path.join((await modelsDirectory()).path, id));
    if (!await directory.exists()) return;
    final marker = File(path.join(directory.path, '.conduit-broken.json'));
    await marker.writeAsString(
      jsonEncode({
        'failedAt': DateTime.now().toUtc().toIso8601String(),
        'error': error.toString(),
      }),
      flush: true,
    );
    _changes.add(null);
  }

  Future<List<InstalledSherpaModel>> installedModels() async {
    final installed = <InstalledSherpaModel>[];
    for (final model in sherpaModelCatalog) {
      final value = await installedModel(model.id);
      if (value != null) installed.add(value);
    }
    return installed;
  }

  Future<Set<String>> brokenModelIds() async {
    final models = await modelsDirectory();
    final broken = <String>{};
    for (final model in sherpaModelCatalog) {
      final directory = Directory(path.join(models.path, model.id));
      if (await directory.exists() && await installedModel(model.id) == null) {
        broken.add(model.id);
      }
    }
    return broken;
  }

  Future<Map<String, String>> resolveRuntimeFiles(
    SherpaModel model,
    Directory directory,
  ) async {
    final entities = await directory
        .list(recursive: true, followLinks: false)
        .toList();
    final resolved = <String, String>{};
    for (final role in model.runtime.files) {
      final suffix = path.normalize(role.pathSuffix);
      final matches = entities
          .where((entity) {
            final relative = path.relative(entity.path, from: directory.path);
            return relative == suffix ||
                relative.endsWith('${path.separator}$suffix');
          })
          .toList(growable: false);
      if (matches.isEmpty && role.optional) continue;
      if (matches.length != 1) {
        throw StateError(
          '${model.id}: expected one ${role.name}, found ${matches.length}',
        );
      }
      resolved[role.name] = matches.single.path;
    }
    return resolved;
  }

  Future<int> directorySize(Directory directory) async {
    var bytes = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) bytes += await entity.length();
    }
    return bytes;
  }
}

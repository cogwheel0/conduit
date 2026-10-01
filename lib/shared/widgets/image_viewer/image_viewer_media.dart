import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:clock/clock.dart';
import 'package:path_provider/path_provider.dart';

/// A lazy item. Opening a gallery only loads the selected image.
@immutable
class ImageViewerItem {
  const ImageViewerItem({
    required this.load,
    this.invalidate,
    this.heroTag,
    this.label,
  });

  final Future<ImageViewerMedia> Function() load;
  final Future<void> Function()? invalidate;
  final String? heroTag;
  final String? label;
}

/// Original encoded image data, also used for sharing and platform previews.
@immutable
class ImageViewerMedia {
  const ImageViewerMedia.bytes(Uint8List data, {this.isSvg = false})
    : bytes = data,
      file = null;
  const ImageViewerMedia.file(File source, {this.isSvg = false})
    : file = source,
      bytes = null;

  final Uint8List? bytes;
  final File? file;
  final bool isSvg;

  Future<Uint8List> readBytes() async => bytes ?? await file!.readAsBytes();

  /// Stage only an image, with an extension derived from its content. Never
  /// expose server URLs, credentials, or arbitrary source filenames to apps.
  Future<File> stage() async {
    final sourceFile = file;
    final Uint8List prefix;
    if (sourceFile != null) {
      final handle = await sourceFile.open();
      try {
        prefix = await handle.read(32);
      } finally {
        await handle.close();
      }
    } else {
      prefix = bytes!;
    }
    final extension = _extension(prefix);
    final root = Directory(
      '${(await getTemporaryDirectory()).path}/image_previews',
    );
    await root.create(recursive: true);
    // External Android viewers may read after returning to Conduit. Keep their
    // files for a day, then prune only this feature's staging directories.
    await for (final entry in root.list()) {
      if (entry is Directory &&
          clock.now().difference((await entry.stat()).modified).inDays >= 1) {
        await entry.delete(recursive: true);
      }
    }
    final directory = await root.createTemp('preview_');
    final path = '${directory.path}/image.$extension';
    return sourceFile != null
        ? sourceFile.copy(path)
        : File(path).writeAsBytes(bytes!);
  }

  String _extension(Uint8List data) {
    bool starts(List<int> magic) =>
        data.length >= magic.length &&
        listEquals(data.sublist(0, magic.length), magic);
    if (isSvg) return 'svg';
    if (starts([0x89, 0x50, 0x4e, 0x47])) return 'png';
    if (starts([0xff, 0xd8, 0xff])) return 'jpg';
    if (starts([0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (starts([0x42, 0x4d])) return 'bmp';
    if (data.length >= 12 &&
        String.fromCharCodes(data.sublist(8, 12)) == 'WEBP') {
      return 'webp';
    }
    if (data.length >= 12 &&
        String.fromCharCodes(data.sublist(4, 8)) == 'ftyp') {
      final brand = String.fromCharCodes(data.sublist(8, 12));
      if (brand == 'avif' || brand == 'avis') return 'avif';
      if (['heic', 'heix', 'hevc', 'hevx', 'mif1'].contains(brand)) {
        return 'heic';
      }
    }
    throw const FormatException('Unsupported image format');
  }
}

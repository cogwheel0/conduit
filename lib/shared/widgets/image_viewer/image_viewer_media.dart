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
        var header = await handle.read(32);
        final box = _fileTypeBox(header);
        if (box != null && box.size > header.length) {
          await handle.setPosition(0);
          header = await handle.read(box.size);
        }
        prefix = header;
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
    // External readers may outlive the handoff. Files become eligible for
    // pruning after a day; cleanup runs on the next export.
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      try {
        if (clock.now().difference((await entry.stat()).modified).inDays >= 1) {
          await entry.delete(recursive: true);
        }
      } on FileSystemException {
        // Concurrent exports can remove an expired directory first.
      }
    }
    final directory = await root.createTemp('preview_');
    final path = '${directory.path}/image.$extension';
    try {
      return await (sourceFile != null
          ? sourceFile.copy(path)
          : File(path).writeAsBytes(bytes!));
    } catch (_) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Preserve the export failure if cleanup also fails.
      }
      rethrow;
    }
  }

  /// Reads the leading ISO BMFF file-type box, bounding untrusted header sizes.
  ({int size, int brandOffset})? _fileTypeBox(Uint8List data) {
    if (data.length < 8 || String.fromCharCodes(data.sublist(4, 8)) != 'ftyp') {
      return null;
    }
    final header = ByteData.sublistView(data);
    var size = header.getUint32(0);
    var brandOffset = 8;
    if (size == 1) {
      if (data.length < 16) {
        throw const FormatException('Incomplete image header');
      }
      size = header.getUint64(8);
      brandOffset = 16;
    }
    // A file-type box normally has only a few four-byte brands. Never allocate
    // or scan an arbitrary declared size while staging a cached file.
    if (size < brandOffset + 8 ||
        size > 64 * 1024 ||
        (size - brandOffset) % 4 != 0) {
      throw const FormatException('Unsupported image header');
    }
    return (size: size, brandOffset: brandOffset);
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
    final box = _fileTypeBox(data);
    if (box != null && box.size <= data.length) {
      final brands = {
        String.fromCharCodes(
          data.sublist(box.brandOffset, box.brandOffset + 4),
        ),
        for (var offset = box.brandOffset + 8; offset < box.size; offset += 4)
          String.fromCharCodes(data.sublist(offset, offset + 4)),
      };
      // AVIF can use mif1 as its major brand. Compatible brands identify the
      // codec, and must be checked before the generic HEIF fallback.
      if (brands.contains('avif') || brands.contains('avis')) return 'avif';
      if (brands.any(['heic', 'heix', 'hevc', 'hevx', 'mif1'].contains)) {
        return 'heic';
      }
    }
    throw const FormatException('Unsupported image format');
  }
}

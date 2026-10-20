import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/services/image_attachment_cache_service.dart';

/// File extension and MIME type for an image written to disk.
class ImageFileType {
  const ImageFileType(this.extension, this.mimeType);

  final String extension;
  final String mimeType;

  bool get isSvg => extension == 'svg';

  @override
  bool operator ==(Object other) =>
      other is ImageFileType &&
      other.extension == extension &&
      other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(extension, mimeType);

  @override
  String toString() => 'ImageFileType($extension, $mimeType)';
}

const _png = ImageFileType('png', 'image/png');
const _jpeg = ImageFileType('jpg', 'image/jpeg');
const _gif = ImageFileType('gif', 'image/gif');
const _webp = ImageFileType('webp', 'image/webp');
const _bmp = ImageFileType('bmp', 'image/bmp');
const _heic = ImageFileType('heic', 'image/heic');
const _avif = ImageFileType('avif', 'image/avif');
const _svg = ImageFileType('svg', 'image/svg+xml');

const _typesByExtension = <String, ImageFileType>{
  'png': _png,
  'jpg': _jpeg,
  'jpeg': _jpeg,
  'gif': _gif,
  'webp': _webp,
  'bmp': _bmp,
  'heic': _heic,
  'heif': _heic,
  'avif': _avif,
  'svg': _svg,
};

/// Detects the image type of [bytes].
///
/// The content signature wins because Quick Look and MediaStore both trust
/// the file extension, and servers often label generated images loosely.
/// [contentType] (a MIME type, or a `data:` URL) and [sourceUrl] are used only
/// when the bytes are not recognized. Falls back to PNG.
ImageFileType detectImageFileType(
  Uint8List bytes, {
  String? contentType,
  String? sourceUrl,
}) {
  return _sniffImageFileType(bytes) ??
      _typeForMime(contentType) ??
      _typeForUrl(sourceUrl) ??
      _png;
}

ImageFileType? _sniffImageFileType(Uint8List bytes) {
  bool startsWith(List<int> signature, [int offset = 0]) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return _png;
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return _jpeg;
  if (startsWith('GIF8'.codeUnits)) return _gif;
  if (startsWith('RIFF'.codeUnits) && startsWith('WEBP'.codeUnits, 8)) {
    return _webp;
  }
  if (startsWith('BM'.codeUnits)) return _bmp;
  if (startsWith('ftyp'.codeUnits, 4) && bytes.length >= 12) {
    String brandAt(int offset) =>
        String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final data = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length);
    // A size of 1 means a 64-bit size follows the type; 0 means the box runs
    // to the end of the file.
    var boxSize = data.getUint32(0);
    var brandOffset = 8;
    if (boxSize == 1) {
      if (bytes.length < 20) return null;
      final high = data.getUint32(8);
      boxSize = high == 0 ? data.getUint32(12) : bytes.length;
      brandOffset = 16;
    }
    if (boxSize == 0 || boxSize > bytes.length) boxSize = bytes.length;
    // The box lists compatible brands after the major brand and version.
    // AVIF files often use the generic `mif1` major brand.
    final brands = [
      brandAt(brandOffset),
      for (var offset = brandOffset + 8; offset + 4 <= boxSize; offset += 4)
        brandAt(offset),
    ];
    if (brands.contains('avif') || brands.contains('avis')) return _avif;
    if (const {
      'heic',
      'heix',
      'heim',
      'heis',
      'hevc',
      'mif1',
      'msf1',
    }.contains(brands[0])) {
      return _heic;
    }
  }
  if (imageAttachmentBytesAreSvg(bytes)) return _svg;
  return null;
}

ImageFileType? _typeForMime(String? value) {
  if (value == null) return null;
  var mime = value.trim().toLowerCase();
  if (mime.startsWith('data:')) {
    final end = mime.indexOf(RegExp('[;,]'));
    mime = end == -1 ? mime.substring(5) : mime.substring(5, end);
  }
  mime = mime.split(';').first.trim();
  if (!mime.startsWith('image/')) return null;
  final subtype = mime.substring('image/'.length);
  if (subtype.startsWith('svg')) return _svg;
  return _typesByExtension[subtype];
}

ImageFileType? _typeForUrl(String? url) {
  if (url == null) return null;
  final path = Uri.tryParse(url)?.path ?? url;
  final dotIndex = path.lastIndexOf('.');
  if (dotIndex == -1 || dotIndex == path.length - 1) return null;
  return _typesByExtension[path.substring(dotIndex + 1).toLowerCase()];
}

/// Writes [bytes] to `directory/baseName.<ext>` and returns the file.
Future<File> writeImageFile(
  Uint8List bytes, {
  required Directory directory,
  required String baseName,
  required ImageFileType type,
}) async {
  final file = File('${directory.path}/$baseName.${type.extension}');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// Session directories this process is still using.
final Set<String> _liveImageSessions = {};

/// How long a released session directory is kept before it is purged.
const imageSessionRetention = Duration(hours: 1);

/// Creates a private, empty directory for one viewer, share, or save session.
///
/// Callers delete it with [deleteImageSessionDirectory] once the platform no
/// longer needs the files, or release it with [releaseImageSessionDirectory]
/// when another app may still read them. The files hold chat content, so they
/// stay in the app's cache directory, which is excluded from backups.
///
/// Also purges released or abandoned sessions, such as those left by a killed
/// app, once they are older than [imageSessionRetention].
Future<Directory> createImageSessionDirectory(String purpose) async {
  final temp = await getTemporaryDirectory();
  final base = Directory('${temp.path}/conduit_images');
  await purgeStaleImageSessions(base);
  final root = Directory('${base.path}/$purpose');
  await root.create(recursive: true);
  final directory = await root.createTemp();
  _liveImageSessions.add(directory.path);
  return directory;
}

/// Deletes session directories under [base] that this process is not using
/// and that were last modified before [imageSessionRetention] ago.
@visibleForTesting
Future<void> purgeStaleImageSessions(Directory base, {DateTime? now}) async {
  final cutoff = (now ?? DateTime.now()).subtract(imageSessionRetention);
  try {
    if (!await base.exists()) return;
    await for (final purpose in base.list()) {
      if (purpose is! Directory) continue;
      await for (final session in purpose.list()) {
        if (session is! Directory ||
            _liveImageSessions.contains(session.path)) {
          continue;
        }
        if ((await session.stat()).modified.isBefore(cutoff)) {
          await session.delete(recursive: true);
        }
      }
    }
  } on FileSystemException {
    // Purging is best effort; the OS clears the cache directory eventually.
  }
}

/// Stops tracking [directory] without deleting it, so a share target can
/// still read its files. A later session purges it after
/// [imageSessionRetention].
void releaseImageSessionDirectory(Directory directory) {
  _liveImageSessions.remove(directory.path);
}

Future<void> deleteImageSessionDirectory(Directory directory) async {
  _liveImageSessions.remove(directory.path);
  try {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  } on FileSystemException {
    // The OS clears the cache directory eventually.
  }
}

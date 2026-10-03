import 'dart:io';
import 'dart:typed_data';

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
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    if (brand == 'avif' || brand == 'avis') return _avif;
    if (const {'heic', 'heix', 'hevc', 'mif1', 'msf1'}.contains(brand)) {
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

/// Creates a private, empty directory for one viewer, share, or save session.
///
/// Callers delete it with [deleteImageSessionDirectory] once the platform no
/// longer needs the files. The files hold chat content, so they stay in the
/// app's cache directory, which is excluded from backups.
Future<Directory> createImageSessionDirectory(String purpose) async {
  final temp = await getTemporaryDirectory();
  final root = Directory('${temp.path}/conduit_images/$purpose');
  await root.create(recursive: true);
  return root.createTemp();
}

Future<void> deleteImageSessionDirectory(Directory directory) async {
  try {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  } on FileSystemException {
    // The OS clears the cache directory eventually.
  }
}

import 'dart:convert' show utf8;
import 'dart:io' show Directory;

/// The largest note file shared from the editor: one larger is not read
/// into memory to be written out.
const int kNoteFileShareMaxBytes = 64 * 1024 * 1024;

/// The most bytes a download's file name keeps, under the 255 most file
/// systems allow; a longer one is cut, keeping its extension.
const int _maxNameBytes = 200;

/// The folder under [temporaryDirectory] that note files are downloaded
/// into, each in a folder of its own, before they are shared.
String noteFileDownloadsPath(String temporaryDirectory) =>
    '$temporaryDirectory/note-files';

/// A new folder of its own for one download of file [fileId] under
/// [temporaryDirectory], the folders above it made as needed, as on a first
/// download after install.
Future<Directory> createNoteFileDownloadFolder(
  String temporaryDirectory,
  String fileId,
) async {
  final downloads = Directory(noteFileDownloadsPath(temporaryDirectory));
  await downloads.create(recursive: true);
  return downloads.createTemp('${fileId.replaceAll(RegExp(r'[^\w-]'), '_')}-');
}

/// The name a note's file, named [name], is downloaded under, which the
/// share sheet shows: with the characters file systems refuse replaced, and
/// cut by its UTF-8 bytes to a length every file system takes, never inside
/// a character.
String noteFileDownloadName(String name) {
  var safe = name
      .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_')
      .trim();
  if (safe.isEmpty || safe == '.' || safe == '..') safe = 'file';
  if (utf8.encode(safe).length <= _maxNameBytes) return safe;
  final dot = safe.lastIndexOf('.');
  final extension = dot > 0 && safe.length - dot <= 10
      ? safe.substring(dot)
      : '';
  final budget = _maxNameBytes - utf8.encode(extension).length;
  final kept = StringBuffer();
  var bytes = 0;
  for (final rune in safe.substring(0, safe.length - extension.length).runes) {
    final size = utf8.encode(String.fromCharCode(rune)).length;
    if (bytes + size > budget) break;
    kept.writeCharCode(rune);
    bytes += size;
  }
  return '$kept$extension';
}

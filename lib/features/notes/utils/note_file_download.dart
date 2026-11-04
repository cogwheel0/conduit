import 'dart:convert' show utf8;

/// The largest note file shared from the editor: one larger is not read
/// into memory to be written out.
const int kNoteFileShareMaxBytes = 64 * 1024 * 1024;

/// The most bytes a download's file name keeps, under the 255 most file
/// systems allow; a longer one is cut, keeping its extension.
const int _maxNameBytes = 200;

/// Where a note's file [fileId], named [name], is downloaded under
/// [temporaryDirectory] before it is shared: in a folder of the file's own,
/// so two files of one name stay apart, under its name, which the share
/// sheet shows, with the characters file systems refuse replaced and cut to
/// a length every file system takes.
String noteFileDownloadPath(
  String temporaryDirectory, {
  required String fileId,
  required String name,
}) {
  final folder = fileId.replaceAll(RegExp(r'[^\w-]'), '_');
  return '$temporaryDirectory/note-files/$folder/${_safeFileName(name)}';
}

String _safeFileName(String name) {
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
  // Whole characters only, so none is cut in two.
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

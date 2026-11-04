/// The longest file name a download keeps; longer ones are cut, keeping
/// their extension, as some file systems refuse long names.
const int _maxNameLength = 100;

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
  if (safe.length <= _maxNameLength) return safe;
  final dot = safe.lastIndexOf('.');
  final extension = dot > 0 && safe.length - dot <= 10
      ? safe.substring(dot)
      : '';
  return safe.substring(0, _maxNameLength - extension.length) + extension;
}

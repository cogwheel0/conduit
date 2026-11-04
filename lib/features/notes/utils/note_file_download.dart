/// Where a note's file [fileId], named [name], is downloaded under
/// [temporaryDirectory] before it is shared: in a folder of the file's own,
/// so two files of one name stay apart, under its name with no path
/// separators left in it.
String noteFileDownloadPath(
  String temporaryDirectory, {
  required String fileId,
  required String name,
}) {
  final folder = fileId.replaceAll(RegExp(r'[^\w-]'), '_');
  final fileName = name.replaceAll(RegExp(r'[/\\]'), '_');
  return '$temporaryDirectory/note-files/$folder/$fileName';
}

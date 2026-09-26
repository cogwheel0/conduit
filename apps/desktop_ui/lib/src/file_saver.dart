/// Saving a file the daemon produced -- an export.
///
/// A port like [FilePickerPort]'s other direction, so the pages that export
/// stay testable on the VM. The browser hands the file to the shell as a
/// download, and Electron asks where to put it.
abstract interface class FileSaverPort {
  /// Saves [text], or the bytes in [base64], as [filename].
  void save({
    required String filename,
    required String mimeType,
    String? text,
    String? base64,
  });
}

/// Records what it was asked to save. The default outside a browser.
final class RecordingFileSaver implements FileSaverPort {
  final List<({String filename, String mimeType, String? text, String? base64})>
  saved = [];

  @override
  void save({
    required String filename,
    required String mimeType,
    String? text,
    String? base64,
  }) => saved.add((
    filename: filename,
    mimeType: mimeType,
    text: text,
    base64: base64,
  ));
}

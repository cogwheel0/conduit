/// A file the user chose, read as text.
typedef PickedTextFile = ({String name, String content});

/// Picking a small text file (WP-2.2).
///
/// A port, like [ExternalSignInPort] and [ThemeApplierPort], so the pages
/// that use it stay testable on the VM -- `package:web`'s `File` and
/// `FileReader` do not exist there.
///
/// Text only, and deliberately: what this exists for is PEM certificates and
/// private keys, which are text by definition and a few kilobytes at most.
/// A binary or streaming variant would be a different port with different
/// concerns, and pretending one API serves both is how a 2 GB upload ends up
/// in a JSON string.
abstract interface class FilePickerPort {
  /// Opens the OS picker and returns the chosen file, or null if cancelled.
  ///
  /// [accept] is an HTML accept list, e.g. `.pem,.crt`. A filter, never a
  /// guarantee -- the picker will let a determined user choose anything, so
  /// the caller still has to cope with contents that are not what it wanted.
  Future<PickedTextFile?> pickText({required String accept});
}

/// Returns nothing, and says why if asked.
///
/// The VM default. A page that calls this outside a browser gets a clear
/// error rather than a picker that silently never opens.
final class UnavailableFilePicker implements FilePickerPort {
  const UnavailableFilePicker();

  @override
  Future<PickedTextFile?> pickText({required String accept}) async =>
      throw UnsupportedError('file picking needs a browser context');
}

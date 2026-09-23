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

  /// Opens the OS picker for an image and returns it scaled to cover
  /// [size] pixels square, cropped to the middle, as a PNG `data:` URL, or null if cancelled or
  /// not an image. A model's profile image is stored that way (M6), and
  /// Open WebUI's own editor scales it to the same 250 pixels.
  Future<String?> pickImageDataUrl({int size = 250});
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

  @override
  Future<String?> pickImageDataUrl({int size = 250}) async =>
      throw UnsupportedError('file picking needs a browser context');
}

/// Whether [content] holds a PEM block of the given [marker] type.
///
/// Deliberately shallow: it checks for the armour, not the contents. Parsing
/// the base64 or the ASN.1 here would duplicate what the TLS stack does
/// properly a moment later, and get it wrong. What this catches is the
/// genuinely common mistake -- a DER file, a PKCS#12 bundle, or the
/// certificate picked into the key field -- where the armour is absent or
/// says something else.
bool containsPemBlock(String content, String marker) {
  final escaped = RegExp.escape(marker);
  return RegExp('-----BEGIN [A-Z0-9 ]*$escaped-----').hasMatch(content);
}

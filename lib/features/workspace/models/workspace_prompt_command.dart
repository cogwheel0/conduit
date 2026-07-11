/// Helpers for the slash-command identity of a workspace prompt.
///
/// Open WebUI stores a prompt command as a bare token (no leading slash) and
/// validates it against `^[a-zA-Z0-9-_]+$`. In the editor we present the token
/// with a normalized leading slash so it reads the way a user types it in chat
/// (`/summarize`), but every value submitted to the server is stripped back to
/// the bare token. Keep display and submission concerns funnelled through this
/// class so the two never drift.
abstract final class WorkspacePromptCommand {
  static final RegExp _valid = RegExp(r'^[a-zA-Z0-9_-]+$');
  static final RegExp _leadingSlashes = RegExp(r'^/+');
  // Unicode combining marks (accents), stripped during slugify.
  static final RegExp _combiningMarks = RegExp('[̀-ͯ]');
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _illegal = RegExp(r'[^a-zA-Z0-9_-]');

  /// The bare token submitted to the server: trimmed, with any leading slashes
  /// removed. Interior characters are left untouched so validation can reject
  /// an illegal command rather than silently mangling it.
  static String strip(String raw) =>
      raw.trim().replaceFirst(_leadingSlashes, '').trim();

  /// The normalized display form shown in the editor: always exactly one
  /// leading slash in front of the bare token.
  static String display(String raw) => '/${strip(raw)}';

  /// Whether [raw] (after stripping) is a legal command token. An empty token
  /// is invalid — a prompt must have a command.
  static bool isValid(String raw) {
    final token = strip(raw);
    return token.isNotEmpty && _valid.hasMatch(token);
  }

  /// Derives a safe command token from a display [name], mirroring Open WebUI's
  /// `slugify`: fold accents, collapse whitespace to hyphens, drop anything
  /// outside `[a-zA-Z0-9-_]`, and lowercase. Used to auto-fill the command in
  /// create mode until the user edits it manually.
  ///
  /// Dart core has no Unicode NFD normalization, so common precomposed Latin
  /// letters are folded via [_accentFolds] before illegal characters are
  /// stripped (otherwise `é` would be dropped entirely rather than becoming
  /// `e`). Already-decomposed combining marks are removed too.
  static String slugify(String name) {
    final lowered = name.trim().toLowerCase().replaceAll(_combiningMarks, '');
    final folded = StringBuffer();
    for (final ch in lowered.split('')) {
      folded.write(_accentFolds[ch] ?? ch);
    }
    return folded
        .toString()
        .replaceAll(_whitespace, '-')
        .replaceAll(_illegal, '');
  }

  static const Map<String, String> _accentFolds = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'ae',
    'ç': 'c',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
    'ñ': 'n',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y',
    'ß': 'ss',
  };
}

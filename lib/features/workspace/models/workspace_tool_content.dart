import 'workspace_skill_content.dart';

/// Helpers for the Python-source identity of a workspace tool.
///
/// Open WebUI authors tools as pure Python modules whose leading docstring may
/// carry a `"""`-delimited front-matter block (`title`, `description`,
/// `required_open_webui_version`, …). The server parses that block into the
/// tool's `meta.manifest` and generates the function `specs`; the editor mirrors
/// upstream's client behaviour so name/id/description prefill and the
/// compatibility gate stay in lockstep with the server. Keep every parsing,
/// slugging, and version concern funnelled through this class so the editor,
/// importer, and provider never drift from the server's expectations.
abstract final class WorkspaceToolContent {
  // Front-matter key/value line: `key: value`, matching Open WebUI's
  // `extractFrontmatter` (`/^\s*([a-z_]+):\s*(.*)\s*$/i`).
  static final RegExp _frontmatterLine = RegExp(
    r'^\s*([a-zA-Z_]+):\s*(.*)\s*$',
  );
  // A legal tool id is a Python identifier: the server rejects anything that is
  // not `str.isidentifier()` (letters, digits, underscores; no leading digit)
  // and lowercases it. Mirror that rule client-side.
  static final RegExp _validId = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
  static final RegExp _nonWord = RegExp(r'[^A-Za-z0-9_]+');
  static final RegExp _combiningMarks = RegExp('[̀-ͯ]');
  static final RegExp _trimUnderscores = RegExp(r'^_+|_+$');

  // GitHub `tree` (folder) URL → raw `main.py`, mirroring the server's
  // `github_url_to_raw_url`.
  static final RegExp _githubTree = RegExp(
    r'^https://github\.com/([^/]+)/([^/]+)/tree/([^/]+)/(.*)$',
  );
  // GitHub `blob` (file) URL → raw file.
  static final RegExp _githubBlob = RegExp(
    r'^https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.*)$',
  );

  /// Parses the leading Python docstring front-matter into a `key: value` map.
  ///
  /// Mirrors Open WebUI's `extractFrontmatter`: returns an empty map unless the
  /// very first line is exactly `"""`, then collects `key: value` lines until a
  /// line containing `"""` closes the block. Values are trimmed.
  static Map<String, String> parseFrontmatter(String content) {
    final lines = content.split('\n');
    if (lines.isEmpty || lines.first.trim() != '"""') return const {};
    final result = <String, String>{};
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.contains('"""')) break;
      final match = _frontmatterLine.firstMatch(line);
      if (match == null) continue;
      final key = match.group(1)!.trim();
      final value = match.group(2)!.trim();
      if (key.isNotEmpty) result[key] = value;
    }
    return result;
  }

  /// Derives a safe tool id token from a display [name], mirroring Open WebUI's
  /// `nameToId`: fold accents, replace every run of non-word characters with a
  /// single underscore, trim leading/trailing underscores, and lowercase.
  static String nameToId(String name) {
    final lowered = name.trim().toLowerCase().replaceAll(_combiningMarks, '');
    final folded = StringBuffer();
    for (final ch in lowered.split('')) {
      folded.write(_accentFolds[ch] ?? ch);
    }
    return folded
        .toString()
        .replaceAll(_nonWord, '_')
        .replaceAll(_trimUnderscores, '');
  }

  /// Converts a raw id/name (`web_search`) into a title-cased display name
  /// (`Web Search`). Reuses the shared skill formatter (identical upstream).
  static String formatToolName(String name) =>
      WorkspaceSkillContent.formatSkillName(name);

  /// Whether [id] (trimmed) is a legal tool id token — a Python identifier.
  static bool isValidId(String id) {
    final token = id.trim();
    return token.isNotEmpty && _validId.hasMatch(token);
  }

  // GitHub hosts the admin-only URL import is allowed to hand to the server's
  // `/tools/load/url` fetch. Restricting to these hosts keeps the import scoped
  // to the documented GitHub tool sources and prevents the request from being
  // pointed at internal/link-local/metadata endpoints (SSRF defence-in-depth).
  static const Set<String> _allowedImportHosts = {
    'github.com',
    'www.github.com',
    'raw.githubusercontent.com',
    'gist.github.com',
    'gist.githubusercontent.com',
    'codeload.github.com',
    'objects.githubusercontent.com',
  };

  /// Whether [url] is a well-formed `https` GitHub URL the tool importer may
  /// forward to the server. Rejects non-`https` schemes and any host outside
  /// [_allowedImportHosts] (e.g. `http://169.254.169.254/...` or internal
  /// hosts), so the server never fetches a non-GitHub target on the admin's
  /// behalf. Apply this to the already-normalized URL.
  static bool isAllowedImportUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.isAbsolute) return false;
    if (uri.scheme.toLowerCase() != 'https') return false;
    if (uri.userInfo.isNotEmpty) return false;
    return _allowedImportHosts.contains(uri.host.toLowerCase());
  }

  /// Normalizes a GitHub `tree`/`blob` URL into its `raw.githubusercontent.com`
  /// equivalent so the import matches what the admin-only `/tools/load/url`
  /// endpoint fetches. Non-GitHub URLs are returned unchanged.
  static String githubUrlToRawUrl(String url) {
    final trimmed = url.trim();
    final tree = _githubTree.firstMatch(trimmed);
    if (tree != null) {
      final org = tree.group(1);
      final repo = tree.group(2);
      final branch = tree.group(3);
      final path = _stripTrailingSlashes(tree.group(4)!);
      return 'https://raw.githubusercontent.com/$org/$repo/refs/heads/$branch/$path/main.py';
    }
    final blob = _githubBlob.firstMatch(trimmed);
    if (blob != null) {
      final org = blob.group(1);
      final repo = blob.group(2);
      final branch = blob.group(3);
      final path = blob.group(4);
      return 'https://raw.githubusercontent.com/$org/$repo/refs/heads/$branch/$path';
    }
    return trimmed;
  }

  /// The `required_open_webui_version` declared in [content]'s front-matter, or
  /// null when none is declared.
  static String? requiredServerVersion(String content) {
    final value = parseFrontmatter(content)['required_open_webui_version']
        ?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Whether a server reporting [current] satisfies [required].
  ///
  /// Mirrors Open WebUI's `compareVersion` gate: fails open when the required
  /// version is missing or `0.0.0`, or when the current version is unknown or
  /// unparseable, so a save is only blocked when we can confidently determine
  /// the server is older than the tool demands.
  static bool meetsRequiredVersion({
    required String? required,
    required String? current,
  }) {
    final req = _parse(required);
    if (req == null || _isZero(req)) return true;
    final cur = _parse(current);
    if (cur == null) return true; // fail open on unknown/unparseable current
    return _compare(cur, req) >= 0;
  }

  static bool _isZero(List<int> v) => v.every((component) => component == 0);

  static String _stripTrailingSlashes(String value) {
    var end = value.length;
    while (end > 0 && value[end - 1] == '/') {
      end--;
    }
    return value.substring(0, end);
  }

  static List<int>? _parse(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final cut = s.indexOf(RegExp(r'[-+ ]'));
    if (cut != -1) s = s.substring(0, cut);
    final match = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(s);
    if (match == null) return null;
    final major = int.tryParse(match.group(1) ?? '');
    if (major == null) return null;
    final minor = int.tryParse(match.group(2) ?? '0') ?? 0;
    final patch = int.tryParse(match.group(3) ?? '0') ?? 0;
    return [major, minor, patch];
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) return av < bv ? -1 : 1;
    }
    return 0;
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

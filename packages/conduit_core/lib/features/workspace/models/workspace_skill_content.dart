import 'workspace_prompt_command.dart';

/// Helpers for the Markdown/front-matter identity of a workspace skill.
///
/// Open WebUI authors skills as Markdown documents that may carry a leading
/// YAML-ish front-matter block (`---\n…\n---`). The workspace editor mirrors the
/// upstream behaviour: front-matter `name`/`description` can prefill the form
/// fields, and a skill id is slugified from the name until the user edits it.
/// Keep the parsing/slugging concerns funnelled through this class so the editor
/// and importer never drift from the server's expectations.
/// What [WorkspaceSkillContent.fromMarkdown] reads from a Markdown file.
typedef WorkspaceSkillMarkdown = ({
  String name,
  String id,
  String description,
  String content,
});

abstract final class WorkspaceSkillContent {
  // Mirrors Open WebUI's `parseFrontmatter`: an opening `---` line, arbitrary
  // body, and a closing `---` line.
  static final RegExp _frontmatter = RegExp(r'^---\s*\n([\s\S]*?)\n---');
  static final RegExp _quotes = RegExp(r'''^["']|["']$''');
  static final RegExp _wordStart = RegExp(r'\b\w');
  static final RegExp _separators = RegExp(r'[-_]');
  static final RegExp _validId = RegExp(r'^[a-zA-Z0-9_-]+$');

  /// Parses the leading front-matter block into a `key: value` map. Returns an
  /// empty map when [content] has no front-matter. Values are trimmed and have
  /// a single layer of surrounding quotes removed, matching Open WebUI.
  static Map<String, String> parseFrontmatter(String content) {
    final match = _frontmatter.firstMatch(content);
    if (match == null) return const {};
    final body = match.group(1) ?? '';
    final result = <String, String>{};
    for (final line in body.split('\n')) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final key = line.substring(0, separator).trim();
      if (key.isEmpty) continue;
      final value = line
          .substring(separator + 1)
          .trim()
          .replaceAll(_quotes, '');
      result[key] = value;
    }
    return result;
  }

  /// Derives a safe skill id token from a display [name]. Reuses the shared
  /// Open WebUI slugify (fold accents, collapse whitespace to hyphens, drop
  /// illegal characters, lowercase).
  static String slugify(String name) => WorkspacePromptCommand.slugify(name);

  /// Converts a raw id/name (`code-review_guidelines`) into a title-cased
  /// display name (`Code Review Guidelines`), mirroring `formatSkillName`.
  static String formatSkillName(String name) {
    final spaced = name.replaceAll(_separators, ' ');
    return spaced.replaceAllMapped(
      _wordStart,
      (match) => match.group(0)!.toUpperCase(),
    );
  }

  /// A skill read from a Markdown file, as Import Markdown fills the form:
  /// the front-matter's name (title-cased), its id or else one slugged from
  /// the name, its description, and the whole file as the instructions. A
  /// field the front-matter does not give is empty, and the form keeps what
  /// it had there.
  static WorkspaceSkillMarkdown fromMarkdown(String content) {
    final fm = parseFrontmatter(content);
    final name = fm['name']?.trim() ?? '';
    final id = fm['id']?.trim() ?? '';
    final idSource = id.isNotEmpty ? id : name;
    return (
      name: name.isEmpty ? '' : formatSkillName(name),
      id: idSource.isEmpty ? '' : slugify(idSource),
      description: fm['description']?.trim() ?? '',
      content: content,
    );
  }

  /// Whether [id] (trimmed) is a legal skill id token. An empty id is invalid.
  static bool isValidId(String id) {
    final token = id.trim();
    return token.isNotEmpty && _validId.hasMatch(token);
  }
}

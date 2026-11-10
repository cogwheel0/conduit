import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/utils/sensitive_value_utils.dart';
import 'package:conduit_core/utils/unicode_prefix.dart';

/// The title of the tool detail row that carries an edit's diff.
const String kHermesInlineDiffTitle = 'Inline diff';

/// Marks a [ChatStatusItem] whose snippet is an edit's diff.
const String kHermesInlineDiffMetadataKey = 'hermesInlineDiff';

/// The most diff text kept per tool. Hermes caps a rendered diff at 80
/// lines in six files, so this only bounds long lines and odd servers.
const int kMaxHermesInlineDiffCharacters = 32768;

/// The most lines and files one parse reads, however much text arrives.
const int kMaxHermesInlineDiffLines = 2000;
const int kMaxHermesInlineDiffFiles = 50;

// U+FFFD stands in for ESC in rows stored by earlier versions (see
// `_persistedHermesToolDetail`), so those are still read as colour codes. It
// is written as an escape: a literal would look like damage and could be
// changed unseen.
final RegExp _ansiEscape = RegExp(
  r'(?:\x1B|\uFFFD)\[[0-9;?]*[A-Za-z]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)',
);
final RegExp _otherControls = RegExp(
  r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]',
);
/// The longest connection secret a diff is searched for.
const int _kMaxRedactedSecretLength = 8192;

/// The most parts one secret is looked for as
/// ([boundedSensitiveValueVariants]).
const int _kMaxRedactedSecretVariants = 32;

/// The shortest part of a secret redacted wherever it shows. A shorter one
/// (`abc` of `Token abc`, `dark` of `theme=dark`) is a word a diff holds
/// anyway: one that shows on its own refuses the diff instead.
const int _kMinRedactedSecretPartLength = 6;

/// Whether [part] shows in [text] on its own, not inside a longer word or
/// token. A line's diff marker (`+abc`, `-abc`) and an assignment's `=`
/// (`key=abc`) end one too, and so does `+` anywhere: a part next to it
/// counts as alone, even inside a Base64 token.
bool _showsAlone(String text, String part) => RegExp(
  r'(?:(?<=^[-+ ])|(?<![A-Za-z0-9._~/-]))' +
      RegExp.escape(part) +
      r'(?![A-Za-z0-9._~/-])',
  multiLine: true,
).hasMatch(text);

/// Whether [part] is only `=`: what a split at `=` leaves of Base64 padding
/// (the `=` of `Basic aGVsbG8hIQ==`), or a cookie whose value is `=`. The
/// two cannot be told apart (`foobar==` is either), and neither holds
/// anything of a credential to show, while every diff has an `=` on its own
/// (`x = 1`). Any other short part, punctuation too, is still looked for.
bool _isOnlyEquals(String part) => _onlyEquals.hasMatch(part);

final RegExp _onlyEquals = RegExp(r'^=+$');

final RegExp _hunkHeader = RegExp(
  r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
);

/// An edit's diff as Conduit keeps it: terminal colours removed, connection
/// secrets and credential values (`password=`, `api_key:`, `Authorization:`,
/// Bearer tokens) redacted, line breaks kept, bounded. Each secret is looked
/// for with its parts too: an access header's `Token abc123` can be shown as
/// `abc123` alone, a cookie's as one of its pairs. Null when nothing is left,
/// when a connection secret is too long, or has too many parts, to look
/// for, or when a part too short to tell from an ordinary word shows on its
/// own: the diff could hold it, unredacted.
String? sanitizeHermesInlineDiff(
  String raw, {
  Iterable<String> sensitiveValues = const <String>[],
  int maxCharacters = kMaxHermesInlineDiffCharacters,
}) {
  final found = <String>{};
  final short = <String>{};
  for (final secret in sensitiveValues) {
    if (secret.isEmpty) continue;
    final parts = boundedSensitiveValueVariants(
      secret,
      maxCharacters: _kMaxRedactedSecretLength,
      maxVariants: _kMaxRedactedSecretVariants,
    );
    if (parts == null) return null;
    found.add(secret);
    for (final part in parts) {
      if (part.length >= _kMinRedactedSecretPartLength) {
        found.add(part);
      } else if (!_isOnlyEquals(part)) {
        short.add(part);
      }
    }
  }
  final secrets = found.toList(growable: false)
    ..sort((a, b) => b.length.compareTo(a.length));
  final redacted = redactSensitiveValuesInUnicodePrefix(
    raw,
    sensitiveValues: secrets,
    maxVisibleScalars: maxCharacters,
  );
  final normalized = redacted
      .replaceAll(_ansiEscape, '')
      .replaceAll('\r\n', '\n')
      .replaceAll(_otherControls, '');
  // Colour codes and control characters can split a secret or a label, so
  // both are checked again once those are gone.
  final safe = redactSensitiveValuesInUnicodePrefix(
    redactCredentialLabels(normalized, keepLines: true),
    sensitiveValues: secrets,
    maxVisibleScalars: maxCharacters,
  );
  if (short.any((part) => _showsAlone(safe, part))) return null;
  return safe.trim().isEmpty ? null : safe;
}

/// The tool detail row that carries [diff], already sanitized.
ChatStatusItem hermesInlineDiffItem(String diff) => ChatStatusItem(
  title: kHermesInlineDiffTitle,
  snippet: diff,
  presentation: ChatStatusItemPresentation.detail,
  metadata: const {kHermesInlineDiffMetadataKey: true},
);

/// Whether [item] carries an edit's diff (also rows stored before the
/// marker existed, by their title).
bool isHermesInlineDiffItem(ChatStatusItem item) =>
    item.snippet != null &&
    (item.metadata?[kHermesInlineDiffMetadataKey] == true ||
        item.title == kHermesInlineDiffTitle);

enum HermesDiffLineKind { context, added, removed, hunk, note }

/// One line of a file's diff, with its line numbers when Hermes sent the
/// hunk header that gives them.
final class HermesDiffLine {
  const HermesDiffLine(
    this.kind,
    this.text, {
    this.oldNumber,
    this.newNumber,
  });

  final HermesDiffLineKind kind;
  final String text;
  final int? oldNumber;
  final int? newNumber;
}

/// One file of an edit's diff.
final class HermesDiffFile {
  HermesDiffFile(this.path);

  /// The file's path, `b/` and `a/` prefixes removed; empty when unknown.
  final String path;
  final List<HermesDiffLine> lines = [];
  int added = 0;
  int removed = 0;

  /// The last part of [path].
  String get name {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }
}

/// [path] as a diff card shows it: relative to [workingDirectory], the
/// directory the session runs its tools in, when the file is inside it, and
/// as Hermes reported it otherwise. `.` and `..` are resolved first, so a
/// path that only starts with the directory's name is not taken for inside
/// it; Windows drive paths compare without case. For display only: the file
/// is [path].
String hermesDiffDisplayPath(String path, {String? workingDirectory}) {
  final directory = _resolvedPath(workingDirectory?.trim() ?? '');
  final file = _resolvedPath(path);
  // Relative to a root (`/`, `C:/`), a path would only lose its first slash
  // or its drive.
  if (directory == null || file == null || directory.endsWith('/')) {
    return path;
  }
  final root = directory.endsWith('/') ? directory : '$directory/';
  final inside = _windowsDrive.hasMatch(directory)
      ? file.toLowerCase().startsWith(root.toLowerCase())
      : file.startsWith(root);
  return inside ? file.substring(root.length) : path;
}

final RegExp _windowsDrive = RegExp(r'^[A-Za-z]:/');

/// [value] with `\` as `/` and its empty, `.` and `..` segments resolved;
/// null unless it is absolute (`/…` or `C:/…`) and stays under its root.
String? _resolvedPath(String value) {
  final slashed = value.replaceAll('\\', '/');
  final String prefix;
  if (slashed.startsWith('/')) {
    prefix = '/';
  } else if (_windowsDrive.hasMatch(slashed)) {
    prefix = slashed.substring(0, 3);
  } else {
    return null;
  }
  final segments = <String>[];
  for (final segment in slashed.substring(prefix.length).split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment != '..') {
      segments.add(segment);
    } else if (segments.isEmpty) {
      return null;
    } else {
      segments.removeLast();
    }
  }
  return '$prefix${segments.join('/')}';
}

/// An edit's diff, file by file.
final class HermesInlineDiff {
  const HermesInlineDiff({
    required this.files,
    this.notes = const <String>[],
    this.truncated = false,
  });

  final List<HermesDiffFile> files;

  /// Hermes' own remarks, such as how many lines it left out.
  final List<String> notes;

  /// Whether Conduit stopped reading at its own bound.
  final bool truncated;

  int get added => files.fold(0, (sum, file) => sum + file.added);
  int get removed => files.fold(0, (sum, file) => sum + file.removed);
}

/// Reads a Hermes inline diff: optional colour codes, a review header,
/// `a/path → b/path` file headers, unified-diff hunks, and a closing note
/// on what Hermes omitted. Plain unified diffs (`--- a/x`, `+++ b/x`) read
/// too. Null when [text] holds no diff.
HermesInlineDiff? parseHermesInlineDiff(
  String text, {
  int maxLines = kMaxHermesInlineDiffLines,
  int maxFiles = kMaxHermesInlineDiffFiles,
}) {
  final files = <HermesDiffFile>[];
  final notes = <String>[];
  var truncated = false;
  HermesDiffFile? current;
  int? oldLine;
  int? newLine;
  // The lines the current hunk's `@@ -a,b +c,d @@` still owes. Inside a
  // hunk, `--- x` and `+++ x` are a removed `-- x` and an added `++ x`.
  var oldLeft = 0;
  var newLeft = 0;
  String? pendingFrom;
  var read = 0;

  HermesDiffFile open(String path) {
    final file = HermesDiffFile(path);
    files.add(file);
    oldLine = null;
    newLine = null;
    oldLeft = 0;
    newLeft = 0;
    return file;
  }

  for (final raw in text.replaceAll(_ansiEscape, '').split('\n')) {
    if (++read > maxLines) {
      truncated = true;
      break;
    }
    final line = raw.replaceAll('\r', '');
    final inHunk = oldLeft > 0 || newLeft > 0;
    if (!inHunk && line.startsWith('--- ')) {
      pendingFrom = line.substring(4).trim();
      continue;
    }
    final String? path;
    if (!inHunk && line.startsWith('+++ ')) {
      path = _diffPath(pendingFrom, line.substring(4).trim());
      pendingFrom = null;
    } else {
      path = _fileHeader(line);
    }
    if (path != null) {
      if (files.length >= maxFiles) {
        truncated = true;
        break;
      }
      current = open(path);
      continue;
    }
    if (line.startsWith('@@')) {
      // Opened first: opening a file clears the numbers read below.
      final file = current ??= open('');
      final hunk = _hunkHeader.firstMatch(line);
      oldLine = int.tryParse(hunk?.group(1) ?? '');
      newLine = int.tryParse(hunk?.group(3) ?? '');
      oldLeft = hunk == null ? 0 : int.tryParse(hunk.group(2) ?? '1') ?? 0;
      newLeft = hunk == null ? 0 : int.tryParse(hunk.group(4) ?? '1') ?? 0;
      file.lines.add(HermesDiffLine(HermesDiffLineKind.hunk, line));
      continue;
    }
    if (line.startsWith('+')) {
      final file = current ??= open('');
      file.lines.add(
        HermesDiffLine(
          HermesDiffLineKind.added,
          line.substring(1),
          newNumber: newLine,
        ),
      );
      file.added++;
      if (newLine != null) newLine = newLine! + 1;
      if (newLeft > 0) newLeft--;
      continue;
    }
    if (line.startsWith('-')) {
      final file = current ??= open('');
      file.lines.add(
        HermesDiffLine(
          HermesDiffLineKind.removed,
          line.substring(1),
          oldNumber: oldLine,
        ),
      );
      file.removed++;
      if (oldLine != null) oldLine = oldLine! + 1;
      if (oldLeft > 0) oldLeft--;
      continue;
    }
    final trimmed = line.trim();
    // A blank context line is a lone space: it is a line, and counts.
    if (line.isEmpty || (trimmed.isEmpty && !line.startsWith(' '))) continue;
    if (current == null) {
      // The review header (localized by Hermes) and anything else before
      // the first file.
      continue;
    }
    if (trimmed.startsWith('…') || trimmed.startsWith(r'\')) {
      // "… omitted N lines", "\ No newline at end of file".
      if (trimmed.startsWith('…')) notes.add(trimmed);
      current.lines.add(HermesDiffLine(HermesDiffLineKind.note, trimmed));
      continue;
    }
    current.lines.add(
      HermesDiffLine(
        HermesDiffLineKind.context,
        line.startsWith(' ') ? line.substring(1) : line,
        oldNumber: oldLine,
        newNumber: newLine,
      ),
    );
    if (oldLine != null) oldLine = oldLine! + 1;
    if (newLine != null) newLine = newLine! + 1;
    if (oldLeft > 0) oldLeft--;
    if (newLeft > 0) newLeft--;
  }
  final changed = files
      .where((file) => file.lines.isNotEmpty || file.path.isNotEmpty)
      .toList(growable: false);
  if (changed.isEmpty || changed.every((file) => file.lines.isEmpty)) {
    return null;
  }
  return HermesInlineDiff(
    files: changed,
    notes: List.unmodifiable(notes),
    truncated: truncated,
  );
}

/// The file a `from → to` header names, or null when [line] is not one.
/// A hunk header is not, even when the heading after its `@@` holds an
/// arrow (`@@ -1 +1 @@ ## Tide → Moon`).
String? _fileHeader(String line) {
  if (line.startsWith(' ') ||
      line.startsWith('+') ||
      line.startsWith('-') ||
      line.startsWith('@@')) {
    return null;
  }
  final arrow = line.indexOf(' → ');
  if (arrow <= 0) return null;
  return _diffPath(
    line.substring(0, arrow).trim(),
    line.substring(arrow + 3).trim(),
  );
}

/// The path a diff names: the new one, or the old one for a deletion.
String _diffPath(String? from, String to) {
  final target = to == '/dev/null' || to == 'b/?' ? from : to;
  if (target == null || target == '/dev/null' || target == 'a/?') return '';
  if (target.startsWith('a/') || target.startsWith('b/')) {
    return target.substring(2);
  }
  return target;
}

/// Every diff a reply's tools reported, merged by file in the order they
/// were first changed: at most [kMaxHermesInlineDiffFiles] files, each of at
/// most [kMaxHermesInlineDiffLines] lines however often it was edited.
List<HermesDiffFile> hermesChangedFiles(Iterable<ChatStatusUpdate> statuses) {
  final byPath = <String, HermesDiffFile>{};
  final unnamed = <HermesDiffFile>[];
  for (final status in statuses) {
    for (final item in status.items) {
      if (!isHermesInlineDiffItem(item)) continue;
      final diff = parseHermesInlineDiff(item.snippet!);
      if (diff == null) continue;
      for (final file in diff.files) {
        final merged = file.path.isEmpty ? null : byPath[file.path];
        if (merged != null) {
          _appendEdit(merged, file);
        } else if (file.path.isEmpty) {
          unnamed.add(file);
        } else {
          byPath[file.path] = file;
        }
        // Counted file by file: one edit can bring many.
        if (byPath.length + unnamed.length >= kMaxHermesInlineDiffFiles) {
          return [...byPath.values, ...unnamed];
        }
      }
    }
  }
  return [...byPath.values, ...unnamed];
}

/// Adds a later edit of [file] to [merged], after a blank note, keeping
/// [kMaxHermesInlineDiffLines] lines at most. The counts are those of the
/// lines kept.
void _appendEdit(HermesDiffFile merged, HermesDiffFile file) {
  final room = kMaxHermesInlineDiffLines - merged.lines.length - 1;
  if (room <= 0 || file.lines.isEmpty) return;
  merged.lines.add(const HermesDiffLine(HermesDiffLineKind.note, ''));
  for (final line in file.lines.take(room)) {
    merged.lines.add(line);
    if (line.kind == HermesDiffLineKind.added) merged.added++;
    if (line.kind == HermesDiffLineKind.removed) merged.removed++;
  }
}

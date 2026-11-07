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

final RegExp _ansiEscape = RegExp(
  r'(?:\x1B|�)\[[0-9;?]*[A-Za-z]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)',
);
final RegExp _otherControls = RegExp(
  r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]',
);
final RegExp _hunkHeader = RegExp(
  r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
);

/// An edit's diff as Conduit keeps it: terminal colours removed, connection
/// secrets and credential values (`password=`, `api_key:`, `Authorization:`,
/// Bearer tokens) redacted, line breaks kept, bounded. Null when nothing is
/// left.
String? sanitizeHermesInlineDiff(
  String raw, {
  Iterable<String> sensitiveValues = const <String>[],
  int maxCharacters = kMaxHermesInlineDiffCharacters,
}) {
  final secrets =
      sensitiveValues
          .where((secret) => secret.isNotEmpty && secret.length <= 8192)
          .toSet()
          .toList(growable: false)
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
String? _fileHeader(String line) {
  if (line.startsWith(' ') || line.startsWith('+') || line.startsWith('-')) {
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
/// were first changed.
List<HermesDiffFile> hermesChangedFiles(Iterable<ChatStatusUpdate> statuses) {
  final byPath = <String, HermesDiffFile>{};
  final unnamed = <HermesDiffFile>[];
  for (final status in statuses) {
    for (final item in status.items) {
      if (!isHermesInlineDiffItem(item)) continue;
      final diff = parseHermesInlineDiff(item.snippet!);
      if (diff == null) continue;
      for (final file in diff.files) {
        if (file.path.isEmpty) {
          unnamed.add(file);
          continue;
        }
        final merged = byPath[file.path];
        if (merged == null) {
          byPath[file.path] = file;
          continue;
        }
        merged.lines
          ..add(const HermesDiffLine(HermesDiffLineKind.note, ''))
          ..addAll(file.lines);
        merged.added += file.added;
        merged.removed += file.removed;
      }
      if (byPath.length + unnamed.length >= kMaxHermesInlineDiffFiles) {
        return [...byPath.values, ...unnamed];
      }
    }
  }
  return [...byPath.values, ...unnamed];
}

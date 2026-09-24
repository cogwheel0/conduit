/// A unified diff of two texts, line by line, as Python's
/// `difflib.unified_diff(a.splitlines(True), b.splitlines(True),
/// lineterm='')` writes it: the `---`/`+++`
/// header, then `@@` hunks with [context] lines around each change. Lines
/// come without their line breaks. Empty when the texts are the same.
///
/// Open WebUI computes prompt diffs this way on the server; this is the
/// same output for when its route cannot be reached.
List<String> unifiedDiffLines(
  String from,
  String to, {
  String fromFile = '',
  String toFile = '',
  int context = 3,
}) {
  final a = _lines(from);
  final b = _lines(to);
  final groups = _groupedOpcodes(_opcodes(a, b), context);
  if (groups.isEmpty) return const <String>[];
  final out = <String>['--- $fromFile', '+++ $toFile'];
  for (final group in groups) {
    final first = group.first;
    final last = group.last;
    out.add(
      '@@ -${_range(first.i1, last.i2)} +${_range(first.j1, last.j2)} @@',
    );
    for (final op in group) {
      if (op.tag == _Tag.equal) {
        for (var i = op.i1; i < op.i2; i++) {
          out.add(' ${_bare(a[i])}');
        }
        continue;
      }
      for (var i = op.i1; i < op.i2; i++) {
        out.add('-${_bare(a[i])}');
      }
      for (var j = op.j1; j < op.j2; j++) {
        out.add('+${_bare(b[j])}');
      }
    }
  }
  return out;
}

enum _Tag { equal, change }

typedef _Op = ({_Tag tag, int i1, int i2, int j1, int j2});

/// The lines of [text] with their line breaks, which count in comparing:
/// a last line without one differs from the same line with one, as in
/// difflib.
List<String> _lines(String text) =>
    RegExp(r'[^\r\n]*(?:\r\n|\r|\n)|[^\r\n]+$')
        .allMatches(text)
        .map((m) => m[0]!)
        .toList();

/// [line] without its line break, for output.
String _bare(String line) => line.replaceFirst(RegExp(r'(\r\n|\r|\n)$'), '');

/// Runs of equal and changed lines, from a longest common subsequence.
/// Texts too long for the table are treated as wholly changed.
List<_Op> _opcodes(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  if (n * m > 4000000) {
    return <_Op>[(tag: _Tag.change, i1: 0, i2: n, j1: 0, j2: m)];
  }
  // lcs[i][j]: the common subsequence length of a[i..] and b[j..].
  final lcs = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
  );
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final ops = <_Op>[];
  void add(_Tag tag, int i1, int i2, int j1, int j2) {
    if (ops.isNotEmpty && ops.last.tag == tag) {
      final last = ops.removeLast();
      ops.add((tag: tag, i1: last.i1, i2: i2, j1: last.j1, j2: j2));
    } else {
      ops.add((tag: tag, i1: i1, i2: i2, j1: j1, j2: j2));
    }
  }

  var i = 0;
  var j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] == b[j]) {
      add(_Tag.equal, i, i + 1, j, j + 1);
      i++;
      j++;
    } else if (j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j])) {
      add(_Tag.change, i, i, j, j + 1);
      j++;
    } else {
      add(_Tag.change, i, i + 1, j, j);
      i++;
    }
  }
  return ops;
}

/// difflib's `get_grouped_opcodes`: the changes with [n] lines of context,
/// split into hunks where more than twice that lies between them.
List<List<_Op>> _groupedOpcodes(List<_Op> codes, int n) {
  if (!codes.any((op) => op.tag == _Tag.change)) return const [];
  final ops = [...codes];
  if (ops.first.tag == _Tag.equal) {
    final op = ops.first;
    ops[0] = (
      tag: op.tag,
      i1: _max(op.i1, op.i2 - n),
      i2: op.i2,
      j1: _max(op.j1, op.j2 - n),
      j2: op.j2,
    );
  }
  if (ops.last.tag == _Tag.equal) {
    final op = ops.last;
    ops[ops.length - 1] = (
      tag: op.tag,
      i1: op.i1,
      i2: _min(op.i2, op.i1 + n),
      j1: op.j1,
      j2: _min(op.j2, op.j1 + n),
    );
  }
  final groups = <List<_Op>>[];
  var group = <_Op>[];
  for (var op in ops) {
    if (op.tag == _Tag.equal && op.i2 - op.i1 > 2 * n) {
      group.add((
        tag: op.tag,
        i1: op.i1,
        i2: _min(op.i2, op.i1 + n),
        j1: op.j1,
        j2: _min(op.j2, op.j1 + n),
      ));
      groups.add(group);
      group = <_Op>[];
      op = (
        tag: op.tag,
        i1: _max(op.i1, op.i2 - n),
        i2: op.i2,
        j1: _max(op.j1, op.j2 - n),
        j2: op.j2,
      );
    }
    group.add(op);
  }
  if (group.isNotEmpty &&
      !(group.length == 1 && group.first.tag == _Tag.equal)) {
    groups.add(group);
  }
  return groups.where((g) => g.any((op) => op.tag == _Tag.change)).toList();
}

/// difflib's `_format_range_unified`.
String _range(int start, int stop) {
  var beginning = start + 1;
  final length = stop - start;
  if (length == 1) return '$beginning';
  if (length == 0) beginning -= 1;
  return '$beginning,$length';
}

int _max(int a, int b) => a > b ? a : b;
int _min(int a, int b) => a < b ? a : b;

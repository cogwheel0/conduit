import 'package:conduit_core/utils/unified_diff.dart';
import 'package:test/test.dart';

void main() {
  // Expected output from Python's difflib.unified_diff(lineterm=''), which
  // Open WebUI's prompt history diff uses.
  final cases = <(String, String, List<String>)>[
    (
      "a\nb\nc\n",
      "a\nB\nc\n",
      <String>["--- vA", "+++ vB", "@@ -1,3 +1,3 @@", " a", "-b", "+B", " c"],
    ),
    ("", "x\n", <String>["--- vA", "+++ vB", "@@ -0,0 +1 @@", "+x"]),
    ("x", "", <String>["--- vA", "+++ vB", "@@ -1 +0,0 @@", "-x"]),
    (
      "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n",
      "1\n2\nX\n4\n5\n6\n7\n8\n9\n10\nY\n12\n",
      <String>[
        "--- vA",
        "+++ vB",
        "@@ -1,6 +1,6 @@",
        " 1",
        " 2",
        "-3",
        "+X",
        " 4",
        " 5",
        " 6",
        "@@ -8,5 +8,5 @@",
        " 8",
        " 9",
        " 10",
        "-11",
        "+Y",
        " 12",
      ],
    ),
    ("same\n", "same\n", <String>[]),
    (
      "one two\nthree",
      "one two\nthree\nfour",
      <String>[
        "--- vA",
        "+++ vB",
        "@@ -1,2 +1,3 @@",
        " one two",
        "-three",
        "+three",
        "+four",
      ],
    ),
  ];

  for (final (from, to, expected) in cases) {
    test('matches difflib for ${from.length} -> ${to.length} chars', () {
      expect(
        unifiedDiffLines(from, to, fromFile: 'vA', toFile: 'vB'),
        expected,
      );
    });
  }

  test('a swap is shown as a removal and an addition', () {
    final lines = unifiedDiffLines('a\nb\n', 'b\na\n');
    expect(
      lines.where((l) => l.startsWith('-') && !l.startsWith('---')),
      hasLength(1),
    );
    expect(
      lines.where((l) => l.startsWith('+') && !l.startsWith('+++')),
      hasLength(1),
    );
  });
}

import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/markdown/compiled_markdown_document.dart';
import 'package:conduit/shared/widgets/markdown/markdown_compile_service.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

/// Records every position the inline parser offers to it.
final class _PositionProbe extends md.InlineSyntax {
  _PositionProbe() : super(r'(?!)');

  int tries = 0;

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    tries += 1;
    return false;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) => false;
}

String _alphanumericRun(int length) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  return String.fromCharCodes(
    List<int>.generate(
      length,
      (index) => alphabet.codeUnitAt((index * 7 + index ~/ 62) % 62),
    ),
  );
}

String _render(String input, {required bool linear}) {
  final document = md.Document(
    extensionSet: linear
        ? conduitGitHubWebExtensionSet
        : md.ExtensionSet.gitHubWeb,
    blockSyntaxes: const [DetailsBlockSyntax()],
    inlineSyntaxes: [
      if (linear) LongAlphanumericRunSyntax(),
      MentionInlineSyntax(),
    ],
    encodeHtml: false,
  );
  return md.HtmlRenderer().render(document.parse(input));
}

void main() {
  // Issue #677: an escaped tool-call wall is one long unbroken paragraph, and
  // package:markdown retried whole-run patterns at every character of it.
  group('linear inline syntaxes', () {
    test('parse a long alphanumeric run without visiting each character', () {
      final unguarded = _PositionProbe();
      md.Document(
        extensionSet: md.ExtensionSet.gitHubWeb,
        inlineSyntaxes: [unguarded],
        encodeHtml: false,
      ).parse(_alphanumericRun(256));
      // Without the guard every character is a parser position.
      check(unguarded.tries).equals(256);

      final guarded = _PositionProbe();
      md.Document(
        extensionSet: conduitGitHubWebExtensionSet,
        inlineSyntaxes: [LongAlphanumericRunSyntax(), guarded],
        encodeHtml: false,
      ).parse('word ${_alphanumericRun(200000)} word');

      // Only the positions around the run remain: the two words and spaces.
      check(guarded.tries).isLessThan(16);
    });

    test('render exactly what the stock GitHub syntaxes render', () {
      final run = _alphanumericRun(40);
      final cases = <String>[
        '$run@example.com and more',
        '$run.$run@example.com',
        '${run}_x@example.com',
        '$run+tag@x.io',
        '<$run@x.io>',
        'x $run more',
        '**$run** and _${run}_ and __${run}__',
        'a*$run*b and foo_${run}_bar',
        '~~$run~~',
        '[$run](https://example.com) ![$run](https://example.com/a.png)',
        'https://example.com/$run?q=1',
        'www.$run.com/path and WWW.EXAMPLE.COM',
        '(www.example.com) *www.example.com* _https://x.io_',
        'http$run and ${run}www.example.com',
        '`$run` and $run&amp;$run&lt;',
        '$run\\*$run and :smile:$run:smile:',
        '$run<@U:id|name>',
        '$run  \n$run',
        '$run-$run.$run+$run',
        '$run@',
      ];
      for (final input in cases) {
        check(
          because: input,
          _render(input, linear: true),
        ).equals(_render(input, linear: false));
      }
    });

    test('compile long unbroken payloads in linear time', () {
      // Unfixed, each payload takes minutes (the run alone about 15 s per
      // 20 KB and growing quadratically). Fixed, both take milliseconds, so
      // the timeout below leaves a margin of several hundred times.
      final separated = StringBuffer();
      const separators = '-._+';
      var index = 0;
      while (separated.length < 200000) {
        separated
          ..write(_alphanumericRun(17))
          ..write(separators[index++ % separators.length]);
      }
      final run = _alphanumericRun(200000);

      for (final payload in [run, separated.toString()]) {
        final document = compilePreparedMarkdownSync('Before $payload after');
        final paragraph = document.nodes.single as CompiledMarkdownElement;
        check(paragraph.tag).equals('p');
        check(
          paragraph.children
              .whereType<CompiledMarkdownText>()
              .map((node) => node.text)
              .join(),
        ).contains(payload);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

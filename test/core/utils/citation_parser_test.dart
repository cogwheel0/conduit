import 'package:checks/checks.dart';
import 'package:conduit/core/utils/citation_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CitationParser.parse', () {
    test('empty string returns null', () {
      check(CitationParser.parse('')).isNull();
    });

    test('no citations returns null', () {
      check(CitationParser.parse('Hello world')).isNull();
    });

    test('single citation [1] produces segments', () {
      final segments = CitationParser.parse('See this[1] for info');
      check(segments).isNotNull();

      check(segments!.length).equals(3);

      check(segments[0].isText).isTrue();
      check(segments[0].text).equals('See this');

      check(segments[1].isCitation).isTrue();
      check(segments[1].citation!.sourceIds).deepEquals([1]);
      check(segments[1].citation!.raw).equals('[1]');

      check(segments[2].isText).isTrue();
      check(segments[2].text).equals(' for info');
    });

    test('multi-id citation [1,2,3]', () {
      final segments = CitationParser.parse('text[1,2,3]end');
      check(segments).isNotNull();

      final citation = segments!.firstWhere((s) => s.isCitation);
      check(citation.citation!.sourceIds).deepEquals([1, 2, 3]);
      check(citation.citation!.raw).equals('[1,2,3]');
    });

    test('adjacent citations [1][2] are merged', () {
      final segments = CitationParser.parse('text[1][2]end');
      check(segments).isNotNull();

      final citations =
          segments!.where((s) => s.isCitation).toList();
      // Adjacent brackets are merged into a single citation
      check(citations.length).equals(1);
      check(citations[0].citation!.sourceIds).deepEquals([1, 2]);
      check(citations[0].citation!.raw).equals('[1][2]');
    });

    test('spaces in citation [1, 2] are handled', () {
      final segments = CitationParser.parse('text[1, 2]end');
      check(segments).isNotNull();

      final citation = segments!.firstWhere((s) => s.isCitation);
      check(citation.citation!.sourceIds).deepEquals([1, 2]);
    });

    test('footnote [^1] is ignored', () {
      check(CitationParser.parse('text[^1]end')).isNull();
    });

    test('[0,1] filters zero, keeps positive', () {
      final segments = CitationParser.parse('text[0,1]end');
      check(segments).isNotNull();

      final citation = segments!.firstWhere((s) => s.isCitation);
      check(citation.citation!.sourceIds).deepEquals([1]);
    });

    test('[0] only produces no citation segments', () {
      // [0] matches the regex but has no valid IDs, so it
      // becomes text and no citations exist -> returns null
      check(CitationParser.parse('[0]')).isNull();
    });

    test('citation at start of string', () {
      final segments = CitationParser.parse('[1] hello');
      check(segments).isNotNull();

      check(segments![0].isCitation).isTrue();
      check(segments[1].isText).isTrue();
      check(segments[1].text).equals(' hello');
    });

    test('citation at end of string', () {
      final segments = CitationParser.parse('hello[1]');
      check(segments).isNotNull();

      check(segments![0].isText).isTrue();
      check(segments[0].text).equals('hello');
      check(segments[1].isCitation).isTrue();
    });

    test('multiple separate citations', () {
      final segments =
          CitationParser.parse('A[1] and B[2] done');
      check(segments).isNotNull();

      final citations =
          segments!.where((s) => s.isCitation).toList();
      check(citations.length).equals(2);
      check(citations[0].citation!.sourceIds).deepEquals([1]);
      check(citations[1].citation!.sourceIds).deepEquals([2]);
    });
  });

  group('CitationParser.hasCitations', () {
    test('empty string returns false', () {
      check(CitationParser.hasCitations('')).isFalse();
    });

    test('no citations returns false', () {
      check(CitationParser.hasCitations('Hello world')).isFalse();
    });

    test('with citation returns true', () {
      check(CitationParser.hasCitations('See[1]')).isTrue();
    });

    test('with multi-id citation returns true', () {
      check(CitationParser.hasCitations('See[1,2,3]')).isTrue();
    });
  });

  group('CitationParser.extractSourceIds', () {
    test('no citations returns empty list', () {
      check(CitationParser.extractSourceIds('hello'))
          .deepEquals(<int>[]);
    });

    test('returns sorted unique IDs', () {
      final ids =
          CitationParser.extractSourceIds('a[3] b[1] c[2,1]');
      check(ids).deepEquals([1, 2, 3]);
    });

    test('empty string returns empty list', () {
      check(CitationParser.extractSourceIds(''))
          .deepEquals(<int>[]);
    });

    test('single citation returns its ID', () {
      check(CitationParser.extractSourceIds('text[5]'))
          .deepEquals([5]);
    });
  });

  group('Citation', () {
    test('zeroBasedIndices converts 1-based to 0-based', () {
      const citation =
          Citation(sourceIds: [1, 2, 3], raw: '[1,2,3]');
      check(citation.zeroBasedIndices).deepEquals([0, 1, 2]);
    });

    test('zeroBasedIndices with single ID', () {
      const citation = Citation(sourceIds: [5], raw: '[5]');
      check(citation.zeroBasedIndices).deepEquals([4]);
    });
  });

  group('CitationSegment', () {
    test('text segment has correct properties', () {
      final segment = CitationSegment.text('hello');
      check(segment.isText).isTrue();
      check(segment.isCitation).isFalse();
      check(segment.text).equals('hello');
    });

    test('citation segment has correct properties', () {
      const citation = Citation(sourceIds: [1], raw: '[1]');
      final segment = CitationSegment.citation(citation);
      check(segment.isText).isFalse();
      check(segment.isCitation).isTrue();
      check(segment.citation).isNotNull();
    });
  });
}

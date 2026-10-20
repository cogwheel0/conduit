import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/utils/source_presentation.dart';
import 'package:test/test.dart';

void main() {
  test('count label', () {
    check(sourceCountLabel(1)).equals('1 Source');
    check(sourceCountLabel(3)).equals('3 Sources');
  });

  group('sourceSnippet', () {
    test('prefers the snippet, whitespace collapsed', () {
      check(sourceSnippet(const ChatSourceReference(snippet: '  a\n\n b  ')))
          .equals('a b');
    });

    test('falls back to documents, then metadata fields', () {
      check(
        sourceSnippet(
          const ChatSourceReference(
            metadata: {
              'documents': ['', 'from a document'],
            },
          ),
        ),
      ).equals('from a document');
      check(sourceSnippet(const ChatSourceReference(title: 'x'))).isNull();
    });
  });

  test('sourceType is null when blank', () {
    check(sourceType(const ChatSourceReference(type: ' '))).isNull();
    check(sourceType(const ChatSourceReference(type: 'file'))).equals('file');
  });

  test('sourceFaviconUrl uses the resolved domain or the URL host', () {
    check(sourceFaviconUrl('https://www.example.com/a'))
        .equals('https://www.google.com/s2/favicons?sz=32&domain=example.com');
    check(sourceFaviconUrl('https://x.test/a', domain: 'site.test'))
        .equals('https://www.google.com/s2/favicons?sz=32&domain=site.test');
    check(sourceFaviconUrl(null)).isNull();
  });

  group('resolveSourceFaviconDomain', () {
    setUp(debugResetSourceFaviconDomainCache);
    tearDown(debugResetSourceFaviconDomainCache);
    const grounding =
        'https://vertexaisearch.cloud.google.com/grounding-api-redirect/x';

    test(
      'ordinary URLs resolve to their own domain without a request',
      () async {
        var calls = 0;
        final domain = await resolveSourceFaviconDomain(
          'https://www.example.com/page',
          redirectResolver: (_) async {
            calls++;
            return null;
          },
        );
        check(domain).equals('example.com');
        check(calls).equals(0);
      },
    );

    test('accepts only HTTPS destinations and shares lookups', () async {
      var calls = 0;
      final gate = Completer<Uri?>();
      Future<Uri?> resolver(Uri _) {
        calls++;
        return gate.future;
      }

      final first = resolveSourceFaviconDomain(
        grounding,
        redirectResolver: resolver,
      );
      final second = resolveSourceFaviconDomain(
        grounding,
        redirectResolver: resolver,
      );
      gate.complete(Uri.parse('https://www.help.openai.com/en/'));
      check(await Future.wait([first, second]))
          .deepEquals(['help.openai.com', 'help.openai.com']);
      check(calls).equals(1);

      check(
        await resolveSourceFaviconDomain(
          '$grounding/plain',
          redirectResolver: (_) async => Uri.parse('http://help.openai.com/'),
        ),
      ).equals('vertexaisearch.cloud.google.com');
    });
  });
}

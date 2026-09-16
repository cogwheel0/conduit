import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/shared/widgets/markdown/source_reference_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SourceReferenceHelper.getInlineSourceLabel', () {
    test('prefers the canonical source URL domain over the source title', () {
      const source = ChatSourceReference(
        title: 'OpenAI announces something with a very long human title',
        url: 'https://www.openai.com/research/article',
      );

      final label = SourceReferenceHelper.getInlineSourceLabel(source, 0);

      check(label).equals('openai.com');
    });

    test('falls back to the source title when no URL is available', () {
      const source = ChatSourceReference(title: 'Readable title');

      final label = SourceReferenceHelper.getInlineSourceLabel(source, 0);

      check(label).equals('Readable title');
    });

    test('preferTitle uses the page title and keeps the domain fallback', () {
      const titled = ChatSourceReference(
        title: 'How solar panels work',
        url: 'https://www.example.com/solar',
      );
      const untitled = ChatSourceReference(
        title: 'example.com',
        url: 'https://www.example.com/other',
      );

      check(
        SourceReferenceHelper.getInlineSourceLabel(titled, 0, preferTitle: true),
      ).equals('How solar panels work');
      check(
        SourceReferenceHelper.getInlineSourceLabel(
          untitled,
          0,
          preferTitle: true,
        ),
      ).equals('example.com');
      check(SourceReferenceHelper.getInlineSourceLabel(titled, 0))
          .equals('example.com');
    });

    test('uses metadata url when canonical url is absent', () {
      const source = ChatSourceReference(
        title: 'Readable title',
        metadata: {
          'items': [
            {'url': 'https://docs.example.com/path/to/page'},
          ],
        },
      );

      final label = SourceReferenceHelper.getInlineSourceLabel(source, 0);

      check(label).equals('docs.example.com');
    });
  });
}

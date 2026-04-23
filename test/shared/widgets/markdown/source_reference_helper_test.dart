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

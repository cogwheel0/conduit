import 'package:conduit_core/features/workspace/models/workspace_transfer.dart'
    show normalizeImportedTool;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeImportedTool', () {
    test('derives id from the original name, not the front-matter title', () {
      final tool = normalizeImportedTool(const {
        'name': 'main',
        'content': '"""\ntitle: Web Search\n"""\n',
      });
      // The front-matter title becomes the display name, but the id stays tied
      // to the original name so the import does not silently retarget.
      expect(tool['id'], 'main');
      expect(tool['name'], 'Web Search');
    });

    test('falls back to nameToId(title) when the name is empty', () {
      final tool = normalizeImportedTool(const {
        'name': '',
        'content': '"""\ntitle: Web Search\n"""\n',
      });
      expect(tool['id'], 'web_search');
    });

    test('keeps an explicit id untouched', () {
      final tool = normalizeImportedTool(const {
        'id': 'custom_id',
        'name': 'main',
        'content': '"""\ntitle: Web Search\n"""\n',
      });
      expect(tool['id'], 'custom_id');
    });

    test('falls back to the title id when a punctuation-only name slugifies to ""', () {
      final tool = normalizeImportedTool(const {
        'name': '!!!',
        'content': '"""\ntitle: Web Search\n"""\n',
      });
      // '!!!' is non-empty but nameToId('!!!') == '', so the id must fall back
      // to the front-matter title rather than end up empty/invalid.
      expect(tool['id'], 'web_search');
    });

    test('falls back to a safe default when no name or title yields an id', () {
      final tool = normalizeImportedTool(const {
        'name': '!!!',
        'content': '"""\n"""\n',
      });
      expect(tool['id'], 'tool');
    });
  });
}

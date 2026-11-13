import 'package:conduit_core/features/workspace/models/workspace_skill_content.dart';
import 'package:test/test.dart';

void main() {
  group('WorkspaceSkillContent.fromMarkdown', () {
    test('reads the name, id and description from the front-matter', () {
      const md =
          '---\nname: trail_packing\ndescription: "Lists for day hikes"\n---\nPack water first.';
      final read = WorkspaceSkillContent.fromMarkdown(md);
      expect(read.name, 'Trail Packing');
      expect(read.id, 'trail_packing');
      expect(read.description, 'Lists for day hikes');
      expect(read.content, md);
    });

    test('an explicit id wins over the name', () {
      final read = WorkspaceSkillContent.fromMarkdown(
        '---\nname: Trail packing\nid: day-hike-lists\n---\nBody',
      );
      expect(read.id, 'day-hike-lists');
    });

    test('a file without front-matter is only instructions', () {
      final read = WorkspaceSkillContent.fromMarkdown('# Packing\n\nWater.');
      expect(read.name, isEmpty);
      expect(read.id, isEmpty);
      expect(read.description, isEmpty);
      expect(read.content, '# Packing\n\nWater.');
    });
  });
}

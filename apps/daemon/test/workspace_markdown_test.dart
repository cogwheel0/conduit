import 'package:conduitd/src/workspace_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  test('a Markdown skill fills the editor from its front-matter', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final skill = WorkspaceService(container).skillFromMarkdown(
      '---\nname: trail_packing\ndescription: Lists for day hikes\n---\nPack water first.',
    );
    expect(skill.name, 'Trail Packing');
    expect(skill.id, 'trail_packing');
    expect(skill.description, 'Lists for day hikes');
    expect(skill.content, contains('Pack water first.'));
    expect(skill.active, isTrue);
  });
}

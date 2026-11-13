import 'package:conduit_core/features/workspace/models/workspace_clone.dart';
import 'package:test/test.dart';

void main() {
  group('WorkspaceClone', () {
    test('a model copy is <id>-copy, named with the suffix', () {
      expect(WorkspaceClone.modelId('trail-guide'), 'trail-guide-copy');
      expect(
        WorkspaceClone.name('Trail Guide', '(copy)'),
        'Trail Guide (copy)',
      );
    });

    test('a prompt copy slugs the command and the suffix', () {
      expect(
        WorkspaceClone.promptCommand('/summarize', '(copy)'),
        'summarize-copy',
      );
      expect(WorkspaceClone.promptCommand('orbit', '(Kopie)'), 'orbit-kopie');
      // A suffix with nothing legal in it gives way to "copy", so no bare
      // trailing hyphen is left.
      expect(WorkspaceClone.promptCommand('orbit', '（副本）'), 'orbit-copy');
      expect(WorkspaceClone.promptCommand('', '(copy)'), '-copy');
    });

    test('tool and skill copies end in _clone', () {
      expect(WorkspaceClone.toolId('trail_weather'), 'trail_weather_clone');
      expect(WorkspaceClone.toolId(''), 'tool_clone');
      expect(WorkspaceClone.skillId('plain-english'), 'plain-english_clone');
      expect(WorkspaceClone.skillId(''), 'skill_clone');
    });
  });
}

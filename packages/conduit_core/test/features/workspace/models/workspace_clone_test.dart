import 'package:checks/checks.dart';
import 'package:conduit_core/features/workspace/models/workspace_clone.dart';
import 'package:test/test.dart';

void main() {
  group('WorkspaceClone', () {
    test('a model copy is <id>-copy, named with the suffix', () {
      check(WorkspaceClone.modelId('trail-guide')).equals('trail-guide-copy');
      check(WorkspaceClone.name('Trail Guide', '(copy)'))
          .equals('Trail Guide (copy)');
    });

    test('a prompt copy slugs the command and the suffix', () {
      check(WorkspaceClone.promptCommand('/summarize', '(copy)'))
          .equals('summarize-copy');
      check(WorkspaceClone.promptCommand('orbit', '(Kopie)'))
          .equals('orbit-kopie');
      // A suffix with nothing legal in it gives way to "copy", so no bare
      // trailing hyphen is left.
      check(WorkspaceClone.promptCommand('orbit', '（副本）')).equals('orbit-copy');
      check(WorkspaceClone.promptCommand('', '(copy)')).equals('-copy');
    });

    test('tool and skill copies end in _clone', () {
      check(WorkspaceClone.toolId('trail_weather'))
          .equals('trail_weather_clone');
      check(WorkspaceClone.toolId('')).equals('tool_clone');
      check(WorkspaceClone.skillId('plain-english'))
          .equals('plain-english_clone');
      check(WorkspaceClone.skillId('')).equals('skill_clone');
    });
  });
}

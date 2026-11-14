import 'package:checks/checks.dart';
import 'package:conduit_core/features/workspace/models/workspace_clone.dart';
import 'package:test/test.dart';

void main() {
  group('WorkspaceClone', () {
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
  });
}

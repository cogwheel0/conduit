import 'package:checks/checks.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_transfer.dart';

void main() {
  // The shape Open WebUI 0.12's GET /api/v1/skills/export returns per skill.
  Map<String, dynamic> packageExport() => {
    'id': 'review',
    'name': 'Review',
    'description': 'Reviews code',
    'meta': {'tags': <String>[]},
    'files': [
      {'path': 'SKILL.md', 'content': '# Review\nRead carefully.'},
      {'path': 'assets/logo.png', 'content': 'iVBORw0=', 'encoding': 'base64'},
    ],
    'is_active': false,
  };

  test('a 0.12 package export keeps the SKILL.md instructions', () {
    final skill = WorkspaceSkillSummary.fromJson(packageExport());

    check(skill.content).equals('# Review\nRead carefully.');
    check(skill.files).isNotNull().length.equals(2);
  });

  test('a 0.11 export still reads the top-level content', () {
    final skill = WorkspaceSkillSummary.fromJson({
      'id': 'review',
      'name': 'Review',
      'content': '# Review',
    });

    check(skill.content).equals('# Review');
    check(skill.files).isNull();
  });

  test('exported skills import into 0.11 and 0.12 servers', () {
    final exported = workspaceSkillExportMap(
      WorkspaceSkillSummary.fromJson(packageExport()),
    );

    // 0.11 creates the skill from `content`; 0.12 imports `files`.
    check(exported['content']).equals('# Review\nRead carefully.');
    check(exported['files']).isA<List<dynamic>>().length.equals(2);
    check(exported['is_active']).equals(false);
  });

  test('importing a 0.12 package sends its instructions and files', () {
    final body = workspaceSkillFormFromImport(packageExport()).toJson();

    check(body['id']).equals('review');
    check(body['content']).equals('# Review\nRead carefully.');
    check(body['files']).isA<List<dynamic>>().length.equals(2);
  });

  test('importing a 0.11 file sends no files', () {
    final body = workspaceSkillFormFromImport({
      'id': 'review',
      'name': 'Review',
      'content': '# Review',
    }).toJson();

    check(body['content']).equals('# Review');
    check(body.containsKey('files')).isFalse();
  });
}

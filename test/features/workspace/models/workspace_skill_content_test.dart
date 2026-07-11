import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/models/workspace_skill_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseFrontmatter', () {
    test('extracts key/value pairs from a leading block', () {
      const content = '''
---
name: Code Review Guidelines
description: Step-by-step instructions for code reviews
---

# Body
Do the thing.''';
      final fm = WorkspaceSkillContent.parseFrontmatter(content);
      check(fm['name']).equals('Code Review Guidelines');
      check(fm['description']).equals('Step-by-step instructions for code reviews');
    });

    test('strips a single layer of surrounding quotes and keeps colons', () {
      const content = '---\ntitle: "Ratio: 2:1"\n---\nbody';
      final fm = WorkspaceSkillContent.parseFrontmatter(content);
      check(fm['title']).equals('Ratio: 2:1');
    });

    test('returns empty when there is no front-matter', () {
      check(WorkspaceSkillContent.parseFrontmatter('# Just markdown')).isEmpty();
      check(WorkspaceSkillContent.parseFrontmatter('')).isEmpty();
    });
  });

  group('slugify', () {
    test('lowercases, folds accents, and hyphenates whitespace', () {
      check(WorkspaceSkillContent.slugify('Café Réview')).equals('cafe-review');
      check(WorkspaceSkillContent.slugify('Code Review Guidelines'))
          .equals('code-review-guidelines');
    });
  });

  group('formatSkillName', () {
    test('title-cases an id, replacing separators with spaces', () {
      check(WorkspaceSkillContent.formatSkillName('code-review_guidelines'))
          .equals('Code Review Guidelines');
    });
  });

  group('isValidId', () {
    test('accepts slug tokens and rejects empty or illegal ids', () {
      check(WorkspaceSkillContent.isValidId('code-review_1')).isTrue();
      check(WorkspaceSkillContent.isValidId('')).isFalse();
      check(WorkspaceSkillContent.isValidId('has spaces')).isFalse();
      check(WorkspaceSkillContent.isValidId('dots.not.allowed')).isFalse();
    });
  });
}

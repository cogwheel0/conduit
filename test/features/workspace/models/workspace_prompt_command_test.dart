import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/workspace/models/workspace_prompt_command.dart';

void main() {
  group('WorkspacePromptCommand.strip', () {
    test('removes a leading slash and surrounding whitespace', () {
      check(WorkspacePromptCommand.strip('  /summarize ')).equals('summarize');
    });

    test('collapses multiple leading slashes', () {
      check(WorkspacePromptCommand.strip('///run')).equals('run');
    });

    test('leaves a bare token untouched', () {
      check(WorkspacePromptCommand.strip('translate-now')).equals('translate-now');
    });
  });

  group('WorkspacePromptCommand.display', () {
    test('always renders exactly one leading slash', () {
      check(WorkspacePromptCommand.display('summarize')).equals('/summarize');
      check(WorkspacePromptCommand.display('/summarize')).equals('/summarize');
    });
  });

  group('WorkspacePromptCommand.isValid', () {
    test('accepts alphanumerics, hyphens, and underscores', () {
      check(WorkspacePromptCommand.isValid('Summar-ize_2')).isTrue();
      check(WorkspacePromptCommand.isValid('/Summar-ize_2')).isTrue();
    });

    test('rejects an empty token', () {
      check(WorkspacePromptCommand.isValid('')).isFalse();
      check(WorkspacePromptCommand.isValid('/')).isFalse();
    });

    test('rejects spaces and other punctuation', () {
      check(WorkspacePromptCommand.isValid('two words')).isFalse();
      check(WorkspacePromptCommand.isValid('bad!')).isFalse();
      check(WorkspacePromptCommand.isValid('emoji😀')).isFalse();
    });
  });

  group('WorkspacePromptCommand.slugify', () {
    test('lowercases and hyphenates whitespace', () {
      check(WorkspacePromptCommand.slugify('Summarize This')).equals('summarize-this');
    });

    test('strips accents and illegal characters', () {
      check(WorkspacePromptCommand.slugify('Résumé!')).equals('resume');
    });

    test('keeps hyphens and underscores', () {
      check(WorkspacePromptCommand.slugify('multi_word-name')).equals('multi_word-name');
    });
  });
}

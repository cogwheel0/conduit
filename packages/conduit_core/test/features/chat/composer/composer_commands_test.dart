import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/composer/composer_commands.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _Api extends Mock implements ApiService {}

ComposerCommandMatch? _match(
  String text, {
  int? caret,
  bool allowSkills = true,
  bool allowContext = true,
}) => resolveComposerCommand(
  text,
  selectionStart: caret ?? text.length,
  selectionEnd: caret ?? text.length,
  allowSkills: allowSkills,
  allowContext: allowContext,
);

void main() {
  group('resolveComposerCommand', () {
    test('matches each trigger ending at the caret', () {
      check(_match('ask @gp'))
          .equals(const ComposerCommandMatch(command: '@gp', start: 4, end: 7));
      check(_match('#doc')?.trigger).equals(ComposerCommandTrigger.context);
      check(_match(r'$tidy')?.trigger).equals(ComposerCommandTrigger.skill);
      check(_match('/hai')?.trigger).equals(ComposerCommandTrigger.prompt);
    });

    test('needs a collapsed caret after a trigger at a word start', () {
      check(_match('mail@host')).isNull();
      check(_match('@gpt ')).isNull();
      check(_match('')).isNull();
      check(resolveComposerCommand('@gpt', selectionStart: 1, selectionEnd: 3))
          .isNull();
    });

    test('uses the caret, not the end of the text', () {
      check(_match('@gp there', caret: 3))
          .equals(const ComposerCommandMatch(command: '@gp', start: 0, end: 3));
    });

    test('skills and context can be switched off', () {
      check(_match(r'$tidy', allowSkills: false)).isNull();
      check(_match('#doc', allowContext: false)).isNull();
      check(_match('@gpt', allowSkills: false, allowContext: false))
          .isNotNull();
    });

    test('query drops the trigger', () {
      check(_match('#  notes')).isNull();
      check(_match('#notes')!.query).equals('notes');
      check(_match('@')!.query).equals('');
    });
  });

  group('filterModelsForMention', () {
    const gpt = Model(id: 'gpt-4o', name: 'GPT-4o');
    const llama = Model(id: 'llama3', name: 'Llama 3');

    test('a bare @ lists every model', () {
      check(filterModelsForMention([gpt, llama], '@')).deepEquals([gpt, llama]);
    });

    test('matches the name or id, case-insensitively', () {
      check(filterModelsForMention([gpt, llama], '@LLA')).deepEquals([llama]);
      check(filterModelsForMention([gpt, llama], '@4o')).deepEquals([gpt]);
      check(filterModelsForMention([gpt, llama], '@zzz')).isEmpty();
    });
  });

  group('insertComposerMention', () {
    test('replaces the token and leaves the caret after a space', () {
      final match = _match('ask @gp now', caret: 7)!;
      final result = insertComposerMention(
        'ask @gp now',
        match,
        prefix: '@',
        label: 'GPT-4o',
      );
      check(result.text).equals('ask @GPT-4o  now');
      check(result.caret).equals(12);
      check(result.mentionStart).equals(4);
      check(result.mentionEnd).equals(11);
    });
  });

  group('removeComposerCommandToken', () {
    test('removes the whole token and one surrounding space', () {
      check(removeComposerCommandToken('see #doc now', 4, 6))
          .equals((text: 'see now', caret: 4));
      check(removeComposerCommandToken('#doc now', 0, 2))
          .equals((text: 'now', caret: 0));
      check(removeComposerCommandToken('see #doc', 4, 8))
          .equals((text: 'see ', caret: 4));
    });
  });

  group('buildComposerContextSuggestions', () {
    List<ComposerContextSuggestion> build({
      List<Map<String, dynamic>> notes = const [],
      List<Map<String, dynamic>> bases = const [],
      List<Map<String, dynamic>> files = const [],
    }) => buildComposerContextSuggestions(
      notes: notes,
      bases: bases,
      files: files,
      untitledLabel: 'Untitled',
      knowledgeBaseLabel: 'Knowledge',
      fileLabel: 'File',
    );

    test('orders notes, bases then files and drops rows without an id', () {
      final result = build(
        notes: [
          {'id': 'n1', 'title': ' Plan '},
          {'title': 'no id'},
        ],
        bases: [
          {'id': 'b1', 'name': 'Docs', 'description': 'Team docs'},
        ],
        files: [
          {
            'id': 'f1',
            'meta': {'name': 'guide.pdf', 'source': 'guide.pdf'},
            'collection': {'name': 'Docs'},
          },
        ],
      );
      check(result).deepEquals([
        const ComposerContextSuggestion(
          type: ComposerContextSuggestionType.note,
          id: 'n1',
          displayName: 'Plan',
        ),
        const ComposerContextSuggestion(
          type: ComposerContextSuggestionType.knowledgeBase,
          id: 'b1',
          displayName: 'Docs',
          subtitle: 'Team docs',
        ),
        const ComposerContextSuggestion(
          type: ComposerContextSuggestionType.knowledgeFile,
          id: 'f1',
          displayName: 'guide.pdf',
          subtitle: 'Docs',
          collectionName: 'Docs',
          source: 'guide.pdf',
        ),
      ]);
    });

    test('falls back to the labels and caps each type', () {
      final result = build(
        notes: [
          for (var i = 0; i < 6; i++) {'id': 'n$i'},
        ],
        bases: [
          {'id': 'b1'},
        ],
        files: [
          {'id': 'f1', 'collection_name': 'Legacy'},
        ],
      );
      check(result.where((s) => s.type == ComposerContextSuggestionType.note))
          .length
          .equals(kComposerContextSuggestionsPerType);
      check(result.first.displayName).equals('Untitled');
      check(result[4].displayName).equals('Knowledge');
      check(result[5].displayName).equals('File');
      check(result[5].collectionName).equals('Legacy');
    });
  });

  group('searchComposerContext', () {
    late _Api api;

    setUp(() {
      api = _Api();
      when(() => api.searchKnowledgeBases(query: any(named: 'query')))
          .thenAnswer(
            (_) async => [
              {'id': 'b1'},
            ],
          );
      when(() => api.searchKnowledgeFiles(query: any(named: 'query')))
          .thenThrow(StateError('down'));
    });

    test('a failed search contributes nothing; notes are optional', () async {
      final result = await searchComposerContext(
        api,
        query: '',
        includeNotes: false,
      );
      check(result.bases).length.equals(1);
      check(result.files).isEmpty();
      check(result.notesForbidden).isFalse();
      verifyNever(() => api.searchNotes(query: any(named: 'query')));
      verify(() => api.searchKnowledgeBases(query: null)).called(1);
    });

    test('reports notes answering 403', () async {
      when(() => api.searchNotes(query: any(named: 'query'))).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/v1/notes/search'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/v1/notes/search'),
            statusCode: 403,
          ),
        ),
      );
      final result = await searchComposerContext(
        api,
        query: 'plan',
        includeNotes: true,
      );
      check(result.notes).isEmpty();
      check(result.notesForbidden).isTrue();
      verify(() => api.searchKnowledgeBases(query: 'plan')).called(1);
    });
  });

  test('filterComposerSkills keeps active skills with an id and name', () {
    const ok = WorkspaceSkillSummary(id: 's1', name: 'Tidy', userId: 'u');
    const inactive = WorkspaceSkillSummary(
      id: 's2',
      name: 'Old',
      userId: 'u',
      isActive: false,
    );
    const unnamed = WorkspaceSkillSummary(id: 's3', name: '', userId: 'u');
    check(filterComposerSkills([ok, inactive, unnamed])).deepEquals([ok]);
  });
}

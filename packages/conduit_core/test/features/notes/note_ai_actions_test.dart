import 'package:checks/checks.dart';
import 'package:conduit_core/features/notes/services/note_ai_actions.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _AiApi extends ApiService {
  _AiApi({this.title, this.enhanced, this.error})
    : super(
        serverConfig: const ServerConfig(
          id: 'server-1',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final String? title;
  final String? enhanced;
  final Object? error;
  final requests = <({String kind, String content, String modelId})>[];

  @override
  Future<String?> generateNoteTitle(
    String content, {
    required String modelId,
  }) async {
    requests.add((kind: 'title', content: content, modelId: modelId));
    final failure = error;
    if (failure != null) throw failure;
    return title;
  }

  @override
  Future<String?> enhanceNoteContent(
    String content, {
    required String modelId,
  }) async {
    requests.add((kind: 'enhance', content: content, modelId: modelId));
    final failure = error;
    if (failure != null) throw failure;
    return enhanced;
  }
}

class _FixedModel extends SelectedModel {
  _FixedModel(this._model);

  final Model? _model;

  @override
  Model? build() => _model;
}

ProviderContainer _container({ApiService? api, Model? model}) {
  final container = ProviderContainer(
    overrides: [
      apiServiceProvider.overrideWithValue(api),
      selectedModelProvider.overrideWith(() => _FixedModel(model)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  const model = Model(id: 'gpt-test', name: 'GPT Test');

  group('generateNoteTitle', () {
    test('asks the selected model with the trimmed markdown', () async {
      final api = _AiApi(title: 'Weekly sync');
      final result = await generateNoteTitle(
        _container(api: api, model: model),
        '  # Notes\n\nagenda  ',
      );

      check(result.outcome).equals(NoteAiOutcome.done);
      check(result.text).equals('Weekly sync');
      check(api.requests.single.kind).equals('title');
      check(api.requests.single.content).equals('# Notes\n\nagenda');
      check(api.requests.single.modelId).equals('gpt-test');
    });

    test('needs content, a model and a server, in that order', () async {
      final api = _AiApi(title: 'x');
      check(
        (await generateNoteTitle(
          _container(api: api, model: model),
          '  \n',
        )).outcome,
      ).equals(NoteAiOutcome.noContent);
      check((await generateNoteTitle(_container(api: api), 'text')).outcome)
          .equals(NoteAiOutcome.noModel);
      check((await generateNoteTitle(_container(model: model), 'text')).outcome)
          .equals(NoteAiOutcome.unavailable);
      check(api.requests).isEmpty();
    });

    test('an empty answer changes nothing', () async {
      final result = await generateNoteTitle(
        _container(
          api: _AiApi(title: ''),
          model: model,
        ),
        'text',
      );
      check(result.outcome).equals(NoteAiOutcome.empty);
    });

    test('a failed request is reported, not thrown', () async {
      final result = await generateNoteTitle(
        _container(
          api: _AiApi(error: StateError('502')),
          model: model,
        ),
        'text',
      );
      check(result.outcome).equals(NoteAiOutcome.failed);
    });
  });

  group('enhanceNote', () {
    test('returns the enhanced markdown', () async {
      final api = _AiApi(enhanced: '# Better\n\n- [ ] follow up');
      final result = await enhanceNote(
        _container(api: api, model: model),
        'rough notes',
      );

      check(result.outcome).equals(NoteAiOutcome.done);
      check(result.text).equals('# Better\n\n- [ ] follow up');
      check(api.requests.single.kind).equals('enhance');
    });

    test('a null answer changes nothing', () async {
      final result = await enhanceNote(
        _container(api: _AiApi(), model: model),
        'rough notes',
      );
      check(result.outcome).equals(NoteAiOutcome.empty);
    });
  });
}

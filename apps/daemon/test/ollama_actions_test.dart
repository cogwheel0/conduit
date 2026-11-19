@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// `direct.ollama*` against a fake Ollama server: which models are
/// loaded, loading and unloading them, and the per-model settings.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late DirectService direct;
  late _FakeOllama ollama;
  late String id;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('ollama-actions-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    direct = DirectService(runtime.container);
    ollama = await _FakeOllama.start();
    final list = await direct.save(
      DirectConnectionEdit(
        name: 'Home',
        kind: DirectKind.ollama,
        baseUrl: ollama.baseUrl,
      ),
    );
    id = list.connections.single.id;
  });

  tearDownAll(() async {
    await ollama.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('lists the models, and which are loaded', () async {
    final list = await direct.ollamaModels(id);
    expect(list.lifecycle, isTrue);
    expect(list.cloud, isFalse);
    expect(list.models.map((m) => m.id), <String>['tiny:1b', 'big:70b']);
    expect(list.models.map((m) => m.loaded), <bool?>[false, false]);
  });

  test('loads and unloads a model', () async {
    final loaded = await direct.ollamaLoad(
      OllamaModelAction(id: id, model: 'tiny:1b'),
    );
    expect(loaded.models.first.loaded, isTrue);
    final unloaded = await direct.ollamaUnload(
      OllamaModelAction(id: id, model: 'tiny:1b'),
    );
    expect(unloaded.models.first.loaded, isFalse);
    expect(ollama.keepAlives.last, 0);
  });

  test('a keep-alive is saved, and used when loading', () async {
    final list = await direct.ollamaKeepAlive(
      OllamaModelAction(id: id, model: 'big:70b', value: '30m'),
    );
    expect(list.models.last.keepAlive, '30m');
    await direct.ollamaLoad(OllamaModelAction(id: id, model: 'big:70b'));
    expect(ollama.keepAlives.last, '30m');

    final reset = await direct.ollamaKeepAlive(
      OllamaModelAction(id: id, model: 'big:70b'),
    );
    expect(reset.models.last.keepAlive, isNull);
  });

  test('models with no context window are offered a limit', () async {
    final options = await direct.options();
    expect(options.imagesPerRequest, 10);
    expect(options.imagesPerRequestChoices, contains(10));
    expect(options.contextLimitChoices.first, 4096);
    final tiny = options.contextModels.firstWhere((m) => m.name == 'tiny:1b');
    expect(tiny.limit, 4096);
    expect(tiny.connection, 'Home');
    expect(tiny.ollama, isTrue);

    final changed = await direct.setContextLimit(
      DirectContextLimit(modelId: tiny.id, tokens: 32768),
    );
    expect(
      changed.contextModels.firstWhere((m) => m.id == tiny.id).limit,
      32768,
    );
    // Loading the model now carries it as the window Ollama loads.
    await direct.ollamaLoad(OllamaModelAction(id: id, model: 'tiny:1b'));
    expect(ollama.contexts.last, 32768);
  });

  test('images per request takes one of its choices', () async {
    expect((await direct.setImagesPerRequest(4)).imagesPerRequest, 4);
    expect(
      direct.setImagesPerRequest(7),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.invalidParams,
        ),
      ),
    );
    expect((await direct.options()).imagesPerRequest, 4);
  });

  test('a direct model is named after its maker by the logo catalog', () async {
    final dir = Directory('${temporary.path}/logos')..createSync();
    File('${dir.path}/catalog.json').writeAsStringSync(
      jsonEncode(<String, Object>{
        'logos': <String, String>{'ollama-cloud': 'Ollama'},
      }),
    );
    expect(
      installModelLogoCatalog(
        environment: <String, String>{'CONDUIT_MODEL_LOGOS': dir.path},
      ),
      isTrue,
    );
    final models = await ModelsService(runtime.container).list();
    final tiny = models.models.firstWhere((m) => m.name == 'tiny:1b');
    // Neither maker is known: the provider's (any Ollama server's) logo.
    expect(tiny.logo, 'ollama-cloud');
    // The Direct lists name it the same way.
    expect((await direct.ollamaModels(id)).models.first.logo, 'ollama-cloud');
    expect(
      (await direct.options()).contextModels
          .firstWhere((m) => m.name == 'tiny:1b')
          .logo,
      'ollama-cloud',
    );
  });

  test('a nonsense keep-alive is refused', () {
    expect(
      direct.ollamaKeepAlive(
        OllamaModelAction(id: id, model: 'big:70b', value: 'soon'),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.invalidParams,
        ),
      ),
    );
  });
}

/// Just enough of Ollama's API: two models, a running set, and `api/chat`
/// with no messages to load or unload.
final class _FakeOllama {
  _FakeOllama._(this._server);

  final HttpServer _server;
  final Set<String> running = <String>{};
  final List<Object?> keepAlives = <Object?>[];
  final List<int?> contexts = <int?>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeOllama> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeOllama._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decodeStream(request);
    final body = raw.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    Object reply;
    switch (request.uri.path) {
      case '/api/tags':
        reply = <String, dynamic>{
          'models': [
            for (final name in ['tiny:1b', 'big:70b'])
              {'name': name, 'model': name},
          ],
        };
      case '/api/show':
        reply = <String, dynamic>{
          'capabilities': ['completion'],
        };
      case '/api/ps':
        reply = <String, dynamic>{
          'models': [
            for (final name in running) {'name': name, 'model': name},
          ],
        };
      case '/api/version':
        reply = <String, dynamic>{'version': '0.9.0'};
      case '/api/chat':
        final model = body['model'] as String;
        keepAlives.add(body['keep_alive']);
        contexts.add(
          (body['options'] as Map<String, dynamic>?)?['num_ctx'] as int?,
        );
        if (body['keep_alive'] == 0) {
          running.remove(model);
        } else {
          running.add(model);
        }
        reply = <String, dynamic>{'model': model, 'done': true};
      default:
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
    }
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(reply));
    await request.response.close();
  }
}

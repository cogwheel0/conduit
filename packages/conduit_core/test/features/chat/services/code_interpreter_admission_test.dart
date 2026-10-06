import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _serverId = 'interpreter-server';

const _admin = User(
  id: 'admin',
  username: 'admin',
  email: 'admin@example.test',
  role: 'admin',
);
const _member = User(
  id: 'member',
  username: 'member',
  email: 'member@example.test',
  role: 'user',
);

/// `/api/config` as Open WebUI 0.11.4 publishes it. The interpreter's flag and
/// engine are reported only to a signed-in account.
Map<String, dynamic> _serverConfig({
  bool signedIn = true,
  Object? interpreter = true,
  String? engine = 'jupyter',
}) => <String, dynamic>{
  'status': true,
  'name': 'Open WebUI',
  'version': '0.11.4',
  'default_locale': '',
  'oauth': {'providers': <String, dynamic>{}},
  'features': <String, dynamic>{
    'auth': true,
    'enable_login_form': true,
    'enable_websocket': true,
    if (signedIn) ...{
      'enable_code_execution': true,
      'enable_code_interpreter': ?interpreter,
      'enable_web_search': false,
    },
  },
  if (signedIn)
    'code': <String, dynamic>{
      'engine': 'pyodide',
      'interpreter_engine': engine,
    },
};

Map<String, dynamic> _permissions(Object? interpreter) => <String, dynamic>{
  'workspace': {'models': false},
  'chat': {'file_upload': true},
  'features': <String, dynamic>{
    'web_search': true,
    'image_generation': true,
    'code_interpreter': ?interpreter,
  },
};

/// An Open WebUI server answering the two routes the interpreter depends on.
class _Server implements HttpClientAdapter {
  Map<String, dynamic> config = _serverConfig();
  Map<String, dynamic> permissions = _permissions(true);
  bool permissionsFail = false;
  final requests = <String>[];

  ResponseBody _json(Object body, {int status = 200}) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    requests.add(options.path);
    switch (options.path) {
      case '/api/config':
        return _json(config);
      case '/api/v1/users/permissions':
        return permissionsFail
            ? _json(const <String, dynamic>{}, status: 500)
            : _json(permissions);
    }
    return _json(const <String, dynamic>{}, status: 404);
  }

  @override
  void close({bool force = false}) {}
}

ApiService _api(_Server server, {String id = _serverId}) {
  final api = ApiService(
    serverConfig: ServerConfig(id: id, name: id, url: 'https://example.com'),
    workerManager: WorkerManager(),
  );
  api.dio.httpClientAdapter = server;
  // The auth interceptor refuses to send without a signed-in session.
  api.dio.interceptors.clear();
  return api;
}

/// The cached configuration, as the app's own refresh produces it: fetched from
/// the server and tagged with the server it came from.
class _FetchedConfig extends BackendConfigNotifier {
  _FetchedConfig(this.api, {this.taggedFor});

  final ApiService api;
  final String? taggedFor;

  @override
  Future<BackendConfig?> build() async => (await api.getBackendConfig())
      ?.copyWith(serverId: taggedFor ?? api.serverConfig.id);
}

Model _model({Map<String, dynamic>? capabilities}) => Model(
  id: 'model-1',
  name: 'Model 1',
  metadata: capabilities == null
      ? null
      : {
          'info': {
            'meta': {'capabilities': capabilities},
          },
        },
);

/// Who is signed in, switchable mid-test.
class _Account extends Notifier<User?> {
  _Account(this.initial);

  final User? initial;

  @override
  User? build() => initial;

  void signInAs(User? user) => state = user;
}

/// The identity of the current sign-in session. A new one starts whenever
/// anyone signs in, including the same account on the same server.
class _AuthSession extends Notifier<Object> {
  @override
  Object build() => Object();

  void begin() => state = Object();
}

/// The server's API object, switchable mid-test.
class _Connection extends Notifier<ApiService> {
  _Connection(this.initial);

  final ApiService initial;

  @override
  ApiService build() => initial;

  void connectTo(ApiService api) => state = api;
}

/// The Advanced setting, switchable mid-test.
class _Settings extends AppSettingsNotifier {
  _Settings(this.advanced);

  final bool advanced;

  @override
  AppSettings build() => AppSettings(advancedFeaturesEnabled: advanced);

  void setAdvanced(bool value) =>
      state = state.copyWith(advancedFeaturesEnabled: value);
}

class _Session {
  _Session._(this.server, this.api, this.container, this.account, this._wires);

  final _Server server;
  final ApiService api;
  final ProviderContainer container;
  final User? account;
  final ({
    NotifierProvider<_Account, User?> account,
    NotifierProvider<_AuthSession, Object> authSession,
    NotifierProvider<_Connection, ApiService> connection,
  })
  _wires;

  static Future<_Session> start({
    User user = _member,
    Model? model,
    bool advanced = true,
    void Function(_Server server)? serve,
    String? configTaggedFor,
  }) async {
    final server = _Server();
    serve?.call(server);
    final api = _api(server);
    final wires = (
      account: NotifierProvider<_Account, User?>(() => _Account(user)),
      authSession: NotifierProvider<_AuthSession, Object>(_AuthSession.new),
      connection: NotifierProvider<_Connection, ApiService>(
        () => _Connection(api),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => ref.watch(wires.connection)),
        selectedModelProvider.overrideWithValue(model ?? _model()),
        currentUserProvider2.overrideWith((ref) => ref.watch(wires.account)),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(wires.authSession),
        ),
        isAuthenticatedProvider2.overrideWithValue(true),
        appSettingsProvider.overrideWith(() => _Settings(advanced)),
        backendConfigProvider.overrideWith(
          () => _FetchedConfig(api, taggedFor: configTaggedFor),
        ),
        userPermissionsProvider.overrideWith((ref) => api.getUserPermissions()),
      ],
    );
    addTearDown(() {
      container.dispose();
      api.dispose();
    });
    await container.read(backendConfigProvider.future);
    try {
      await container.read(userPermissionsProvider.future);
    } catch (_) {
      // A refused permission read is a state under test, not a failure.
    }
    return _Session._(server, api, container, user, wires);
  }

  CodeInterpreterBlock? get block =>
      container.read(codeInterpreterBlockProvider);

  bool get selected => container.read(codeInterpreterEnabledProvider);

  CodeInterpreterEnabledNotifier get selection =>
      container.read(codeInterpreterEnabledProvider.notifier);

  /// Someone signs in: a new session, as whoever [user] is.
  void signInAs(User user) {
    container.read(_wires.account.notifier).signInAs(user);
    container.read(_wires.authSession.notifier).begin();
  }

  /// The same account signs out and back in, on the same server and API.
  void signInAgain() => container.read(_wires.authSession.notifier).begin();

  /// The app connects to another server.
  void connectToAnotherServer() {
    final other = _api(server, id: 'another-server');
    addTearDown(other.dispose);
    container.read(_wires.connection.notifier).connectTo(other);
  }

  void setAdvanced(bool value) =>
      (container.read(appSettingsProvider.notifier) as _Settings).setAdvanced(
        value,
      );
}

void main() {
  group('the server configuration reaches the app', () {
    Future<BackendConfig> fetch(Map<String, dynamic> body) async {
      final server = _Server()..config = body;
      final api = _api(server);
      addTearDown(api.dispose);
      return (await api.getBackendConfig())!;
    }

    test('a signed-in Jupyter server reports its flag and engine', () async {
      final config = await fetch(_serverConfig());

      check(config.enableCodeInterpreter).equals(true);
      check(config.codeInterpreterEngine).equals('jupyter');
    });

    test('a Pyodide server reports its browser engine', () async {
      final config = await fetch(_serverConfig(engine: 'pyodide'));

      check(config.enableCodeInterpreter).equals(true);
      check(config.codeInterpreterEngine).equals('pyodide');
    });

    test('a server that is switched off says so', () async {
      final config = await fetch(_serverConfig(interpreter: false));

      check(config.enableCodeInterpreter).equals(false);
    });

    test('the public config before sign-in reports neither', () async {
      final config = await fetch(_serverConfig(signedIn: false));

      check(config.enableCodeInterpreter).isNull();
      check(config.codeInterpreterEngine).isNull();
    });

    test('a value of the wrong type is not support', () async {
      final config = await fetch(
        _serverConfig(interpreter: 'true', engine: ' '),
      );

      check(config.enableCodeInterpreter).isNull();
      check(config.codeInterpreterEngine).isNull();
    });

    test(
      'the cached copy keeps both, and an older cache has neither',
      () async {
        final fetched = await fetch(_serverConfig());

        final restored = BackendConfig.fromJson(
          jsonDecode(jsonEncode(fetched.toJson())) as Map<String, dynamic>,
        );
        check(restored.enableCodeInterpreter).equals(true);
        check(restored.codeInterpreterEngine).equals('jupyter');

        final older = BackendConfig.fromJson(<String, dynamic>{
          'version': '0.10.1',
          'enable_websocket': true,
        });
        check(older.enableCodeInterpreter).isNull();
        check(older.codeInterpreterEngine).isNull();
      },
    );
  });

  group('the interpreter runs only where Open WebUI would offer it', () {
    // Each case is one state of the server, the account, the model and the
    // composer, built from the answers the server really gave.
    final cases =
        <
          String,
          ({
            CodeInterpreterBlock? expected,
            User user,
            Model? model,
            void Function(_Server server)? serve,
            String? taggedFor,
            String? terminal,
          })
        >{
          'a member with the permission on a Jupyter server': (
            expected: null,
            user: _member,
            model: null,
            serve: null,
            taggedFor: null,
            terminal: null,
          ),
          'an admin needs no permission document': (
            expected: null,
            user: _admin,
            model: null,
            serve: (s) => s.permissionsFail = true,
            taggedFor: null,
            terminal: null,
          ),
          'a permission that is off': (
            expected: CodeInterpreterBlock.noPermission,
            user: _member,
            model: null,
            serve: (s) => s.permissions = _permissions(false),
            taggedFor: null,
            terminal: null,
          ),
          'a permission the server never listed': (
            expected: CodeInterpreterBlock.noPermission,
            user: _member,
            model: null,
            serve: (s) => s.permissions = _permissions(null),
            taggedFor: null,
            terminal: null,
          ),
          'a permission read the server refused': (
            expected: CodeInterpreterBlock.unverified,
            user: _member,
            model: null,
            serve: (s) => s.permissionsFail = true,
            taggedFor: null,
            terminal: null,
          ),
          'a server on its browser engine': (
            expected: CodeInterpreterBlock.unsupportedEngine,
            user: _member,
            model: null,
            serve: (s) => s.config = _serverConfig(engine: 'pyodide'),
            taggedFor: null,
            terminal: null,
          ),
          'a server with the interpreter switched off': (
            expected: CodeInterpreterBlock.serverDisabled,
            user: _member,
            model: null,
            serve: (s) => s.config = _serverConfig(interpreter: false),
            taggedFor: null,
            terminal: null,
          ),
          'a server that has not reported the interpreter': (
            expected: CodeInterpreterBlock.unverified,
            user: _member,
            model: null,
            serve: (s) => s.config = _serverConfig(interpreter: null),
            taggedFor: null,
            terminal: null,
          ),
          'a config fetched before sign-in': (
            expected: CodeInterpreterBlock.unverified,
            user: _member,
            model: null,
            serve: (s) => s.config = _serverConfig(signedIn: false),
            taggedFor: null,
            terminal: null,
          ),
          'a flag with no engine': (
            expected: CodeInterpreterBlock.unverified,
            user: _member,
            model: null,
            serve: (s) => s.config = _serverConfig(engine: null),
            taggedFor: null,
            terminal: null,
          ),
          'a config cached for another server': (
            expected: CodeInterpreterBlock.unverified,
            user: _member,
            model: null,
            serve: null,
            taggedFor: 'another-server',
            terminal: null,
          ),
          'a model that turns it off': (
            expected: CodeInterpreterBlock.modelUnsupported,
            user: _member,
            model: _model(capabilities: {'code_interpreter': false}),
            serve: null,
            taggedFor: null,
            terminal: null,
          ),
          'a model that turns it on': (
            expected: null,
            user: _member,
            model: _model(capabilities: {'code_interpreter': true}),
            serve: null,
            taggedFor: null,
            terminal: null,
          ),
          'a model with capabilities but no entry for it': (
            expected: null,
            user: _member,
            model: _model(capabilities: {'vision': true}),
            serve: null,
            taggedFor: null,
            terminal: null,
          ),
          'a terminal the model can use': (
            expected: CodeInterpreterBlock.terminalActive,
            user: _member,
            model: null,
            serve: null,
            taggedFor: null,
            terminal: 'terminal-1',
          ),
          'a terminal the model cannot use': (
            expected: null,
            user: _member,
            model: _model(capabilities: {'terminal': false}),
            serve: null,
            taggedFor: null,
            terminal: 'terminal-1',
          ),
          'a Hermes model, which never reaches the server': (
            expected: CodeInterpreterBlock.notOpenWebUi,
            user: _member,
            model: hermesSyntheticModel(),
            serve: null,
            taggedFor: null,
            terminal: null,
          ),
        };

    for (final MapEntry(:key, :value) in cases.entries) {
      test(key, () async {
        final session = await _Session.start(
          user: value.user,
          model: value.model,
          serve: value.serve,
          configTaggedFor: value.taggedFor,
        );
        if (value.terminal != null) {
          session.container
              .read(selectedTerminalIdProvider.notifier)
              .set(value.terminal);
        }

        check(session.block).equals(value.expected);
      });
    }
  });

  group('the selection', () {
    test(
      'starts off, and is chosen only where the interpreter can run',
      () async {
        final usable = await _Session.start();
        check(usable.selected).isFalse();
        usable.selection.set(true);
        check(usable.selected).isTrue();
        usable.selection.set(false);
        check(usable.selected).isFalse();

        final browserEngine = await _Session.start(
          serve: (s) => s.config = _serverConfig(engine: 'pyodide'),
        );
        browserEngine.selection.set(true);
        check(browserEngine.selected).isFalse();
      },
    );

    test('a terminal ends it and refuses it, as in Open WebUI', () async {
      final session = await _Session.start();
      session.selection.set(true);

      session.container.read(selectedTerminalIdProvider.notifier).set('t1');
      check(session.selected).isFalse();

      session.selection.set(true);
      check(session.selected).isFalse();

      session.container.read(selectedTerminalIdProvider.notifier).clear();
      session.selection.set(true);
      check(session.selected).isTrue();
    });

    test('a conversation boundary ends it', () async {
      final session = await _Session.start();
      session.selection.set(true);

      clearSelectedFiltersForConversationBoundary(session.container);

      check(session.selected).isFalse();
    });

    // A choice made as one account is never carried into another's turns:
    // the new account chooses code execution for itself.
    final accountBoundaries = <String, void Function(_Session session)>{
      'another account signs in': (session) => session.signInAs(_admin),
      'the same account signs back in on the same API': (session) =>
          session.signInAgain(),
      'the app connects to another server': (session) =>
          session.connectToAnotherServer(),
    };

    for (final MapEntry(:key, :value) in accountBoundaries.entries) {
      test('ends when $key', () async {
        final session = await _Session.start();
        session.selection.set(true);
        check(session.selected).isTrue();

        value(session);

        check(session.selected).isFalse();
      });
    }

    test('survives the Advanced switch', () async {
      final session = await _Session.start();
      session.selection.set(true);

      session.setAdvanced(false);
      check(session.selected).isTrue();
      session.setAdvanced(true);
      check(session.selected).isTrue();
    });
  });

  group('the composer offers it', () {
    test('only with Advanced on and the interpreter usable', () async {
      final off = await _Session.start(advanced: false);
      check(off.container.read(codeInterpreterOfferProvider)).isNull();

      final on = await _Session.start();
      check(on.container.read(codeInterpreterOfferProvider)).isNotNull()
        ..has((offer) => offer.selected, 'selected').isFalse()
        ..has((offer) => offer.block, 'block').isNull();
    });

    test('and says why a browser-engine server cannot be used', () async {
      final session = await _Session.start(
        serve: (s) => s.config = _serverConfig(engine: 'pyodide'),
      );

      check(session.container.read(codeInterpreterOfferProvider))
          .isNotNull()
          .has((offer) => offer.block, 'block')
          .equals(CodeInterpreterBlock.unsupportedEngine);
    });

    test(
      'and says nothing where an admin, a permission or a model rules it out',
      () async {
        for (final session in [
          await _Session.start(
            serve: (s) => s.permissions = _permissions(false),
          ),
          await _Session.start(
            serve: (s) => s.config = _serverConfig(interpreter: false),
          ),
          await _Session.start(
            model: _model(capabilities: {'code_interpreter': false}),
          ),
          await _Session.start(model: hermesSyntheticModel()),
        ]) {
          check(session.container.read(codeInterpreterOfferProvider)).isNull();
        }
      },
    );

    test(
      'and keeps an active selection in view when Advanced is off',
      () async {
        final session = await _Session.start(advanced: false);
        check(session.container.read(codeInterpreterOfferProvider)).isNull();

        session.selection.set(true);

        check(session.container.read(codeInterpreterOfferProvider))
            .isNotNull()
            .has((offer) => offer.selected, 'selected')
            .isTrue();
      },
    );
  });

  group('a queued turn', () {
    test('is admitted without the interpreter unless it chose one', () {
      final legacy = RequestCompletionPayload.fromJson(<String, dynamic>{
        'assistantMessageId': 'a1',
        'model': 'model-1',
        'toolIds': <String>[],
        'filterIds': <String>[],
        'enableWebSearch': false,
        'enableImageGeneration': false,
        'isVoiceMode': false,
      });
      check(legacy.enableCodeInterpreter).isFalse();

      const chosen = RequestCompletionPayload(
        assistantMessageId: 'a1',
        model: 'model-1',
        enableCodeInterpreter: true,
      );
      check(
        RequestCompletionPayload.fromJson(chosen.toJson())
            .enableCodeInterpreter,
      ).isTrue();

      // A turn that did not choose it keeps the payload it always had.
      const plain = RequestCompletionPayload(
        assistantMessageId: 'a1',
        model: 'model-1',
      );
      check(plain.toJson().containsKey('enableCodeInterpreter')).isFalse();
    });
  });
}

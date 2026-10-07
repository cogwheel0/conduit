import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/chat/widgets/personal_valves_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/models/personal_valves.dart';
import 'package:conduit_core/features/chat/providers/personal_valves_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _server = ServerConfig(
  id: 'test',
  name: 'Test',
  url: 'http://localhost:0',
);

const _tool = PersonalValvesTarget(
  kind: PersonalValvesTargetKind.tool,
  id: 'shared_tool',
  label: 'Shared tool',
);

const _pipe = PersonalValvesTarget(
  kind: PersonalValvesTargetKind.function,
  id: 'echo_pipe',
  label: 'Echo pipe',
);

const _phone = Size(402, 874);
const _keyboardHeight = 302.0;
const _keyboardTop = 874.0 - _keyboardHeight;

void main() {
  testWidgets(
    'the composer Tool settings action edits and saves a use-only tool '
    'above the software keyboard',
    (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final harness = _Harness(advanced: true, targets: const [_tool]);
      await harness.pumpComposer(tester);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tool settings'));
      await tester.pumpAndSettle();

      expect(find.text('Your settings'), findsOneWidget);
      final field = find.byKey(const Key('workspace-tool-valve-input-region'));
      await tester.tap(field);
      tester.view.viewInsets = const FakeViewPadding(bottom: _keyboardHeight);
      await tester.pumpAndSettle();

      expect(tester.getRect(field).bottom, lessThanOrEqualTo(_keyboardTop));
      final save = find.byKey(const Key('personal-valves-save'));
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(_keyboardTop));

      await tester.enterText(field, 'ap-south');
      await tester.tap(save);
      await tester.pumpAndSettle();

      final post = harness.valveRequests.last;
      expect(post.method, 'POST');
      expect(post.path, '/api/v1/tools/id/shared_tool/valves/user/update');
      expect(post.data, {'region': 'ap-south', 'legacy': 7});
      // A use-only user never touches the server-owner valve routes.
      expect(
        harness.valveRequests.map((r) => r.path),
        everyElement(contains('/valves/user')),
      );
      expect(find.text('Your settings'), findsNothing);
    },
  );

  testWidgets(
    'a long schema scrolls above the keyboard and keeps Save visible',
    (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final harness = _Harness(
        advanced: true,
        targets: const [_tool],
        fieldCount: 14,
      );
      await harness.pumpSheet(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: _keyboardHeight);
      await tester.pumpAndSettle();

      final save = find.byKey(const Key('personal-valves-save'));
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(_keyboardTop));

      // The last field starts below the fold of the bounded form. Focusing it
      // scrolls it into the space above the keyboard.
      final last = find.byKey(const Key('workspace-tool-valve-input-field13'));
      await tester.ensureVisible(last);
      await tester.enterText(last, 'typed-last');
      await tester.pumpAndSettle();
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(_keyboardTop));
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(_keyboardTop));

      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(harness.valveRequests.last.method, 'POST');
      expect((harness.valveRequests.last.data as Map)['field13'], 'typed-last');
    },
  );

  testWidgets('Advanced off hides the command and writes nothing', (
    tester,
  ) async {
    final harness = _Harness(advanced: false, targets: const [_tool]);
    await harness.pumpComposer(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('Tool settings'), findsNothing);
    expect(harness.valveRequests, isEmpty);
  });

  testWidgets('several targets are listed and each opens its own function', (
    tester,
  ) async {
    final harness = _Harness(advanced: true, targets: const [_tool, _pipe]);
    await harness.pumpSheet(tester);

    expect(find.byKey(const Key('personal-valves-save')), findsNothing);
    await tester.tap(
      find.byKey(const Key('personal-valves-target-function-echo_pipe')),
    );
    await tester.pumpAndSettle();

    expect(
      harness.requests.map((r) => r.path),
      contains('/api/v1/functions/id/echo_pipe/valves/user/spec'),
    );
    expect(find.text('Your settings'), findsOneWidget);

    await tester.tap(find.byKey(const Key('personal-valves-back')));
    await tester.pumpAndSettle();
    expect(find.text('Your settings'), findsNothing);
    expect(
      find.byKey(const Key('personal-valves-target-tool-shared_tool')),
      findsOneWidget,
    );
  });

  testWidgets('an account switch removes the form and its values', (
    tester,
  ) async {
    final harness = _Harness(advanced: true, targets: const [_tool]);
    await harness.pumpSheet(tester);
    await tester.enterText(
      find.byKey(const Key('workspace-tool-valve-input-region')),
      'typed-by-user-a',
    );
    final sent = harness.requests.length;

    harness.signInAs('user-b', 'token-b');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('personal-valves-owner-changed')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('personal-valves-save')), findsNothing);
    expect(find.text('typed-by-user-a'), findsNothing);
    expect(harness.requests.length, sent);
  });
}

class _Session {
  const _Session(this.userId, this.token);
  final String userId;
  final String token;
}

class _SessionNotifier extends Notifier<_Session> {
  @override
  _Session build() => const _Session('user-a', 'token-a');

  void set(_Session value) => state = value;
}

final _sessionProvider = NotifierProvider<_SessionNotifier, _Session>(
  _SessionNotifier.new,
);

/// A use-only account: personal valve routes answer, every other valve route
/// is forbidden.
class _Harness {
  _Harness({
    required this.advanced,
    required this.targets,
    this.fieldCount = 0,
  });

  final bool advanced;
  final List<PersonalValvesTarget> targets;

  /// Number of generated `fieldN` string properties added to the schema.
  final int fieldCount;
  final List<RequestOptions> requests = [];
  late final ProviderContainer container = _container();

  /// Requests to any tool or function valve route. The composer makes other,
  /// unrelated calls of its own.
  Iterable<RequestOptions> get valveRequests =>
      requests.where((r) => r.path.contains('/valves'));

  ProviderContainer _container() {
    final api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
    );
    api.dio.httpClientAdapter = _Adapter(_serve);
    api.dio.interceptors.clear();
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) => _server),
        authTokenProvider3.overrideWith(
          (ref) => ref.watch(_sessionProvider).token,
        ),
        currentUserProvider2.overrideWith((ref) {
          final id = ref.watch(_sessionProvider).userId;
          return User(
            id: id,
            username: id,
            email: '$id@example.com',
            role: 'user',
          );
        }),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) {
          ref.watch(_sessionProvider);
          return Object();
        }),
        appSettingsProvider.overrideWithValue(
          AppSettings(advancedFeaturesEnabled: advanced),
        ),
        selectedModelProvider.overrideWithValue(
          const Model(id: 'plain', name: 'Plain'),
        ),
        personalValvesTargetsProvider.overrideWithValue(targets),
        userPermissionsProvider.overrideWithValue(const AsyncData({})),
        webSearchAvailableProvider.overrideWithValue(false),
        imageGenerationAvailableProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ResponseBody _serve(RequestOptions request) {
    requests.add(request);
    if (request.path.contains('/valves') &&
        !request.path.contains('/valves/user')) {
      return _json({}, 403);
    }
    // The composer's own, unrelated calls.
    if (!request.path.contains('/valves/user')) return _json({});
    if (request.path.endsWith('/spec')) {
      return _json({
        'properties': {
          'region': {'type': 'string', 'title': 'Region'},
          for (var i = 0; i < fieldCount; i++)
            'field$i': {'type': 'string', 'title': 'Field $i'},
        },
      });
    }
    if (request.method == 'GET') {
      return _json({
        'region': 'eu',
        'legacy': 7,
        for (var i = 0; i < fieldCount; i++) 'field$i': 'value $i',
      });
    }
    return _json(request.data);
  }

  void signInAs(String userId, String token) =>
      container.read(_sessionProvider.notifier).set(_Session(userId, token));

  Future<void> pumpComposer(WidgetTester tester) async {
    await container.read(activeServerProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ModernChatInput(onSendMessage: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpSheet(WidgetTester tester) async {
    await container.read(activeServerProvider.future);
    final owner = PersonalValvesOwner.capture(container.read)!;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PersonalValvesSheet(owner: owner, targets: targets),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);

  final ResponseBody Function(RequestOptions request) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? value, [int statusCode = 200]) => ResponseBody(
  Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
  statusCode,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

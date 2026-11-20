import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart'
    show DirectChatInputException;
import 'package:conduit_core/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/direct_run_registry.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

final class _FixedProfiles extends DirectConnectionProfilesController {
  _FixedProfiles(this.profile);

  final DirectConnectionProfile profile;

  @override
  Future<List<DirectConnectionProfile>> build() async => [profile];
}

/// A provider whose reply streams until the test ends it, as one does while
/// a tool approval holds it open.
final class _WaitingAdapter implements DirectProviderAdapter {
  final events = StreamController<DirectStreamEvent>();
  final done = Completer<void>();
  final requests = <DirectCompletionRequest>[];
  var runs = 0;

  /// Completes when the first reply is asked for.
  final asked = Completer<void>();

  @override
  String get key => kOllamaAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    runs++;
    requests.add(request);
    if (!asked.isCompleted) asked.complete();
    return DirectCompletionRun(
      id: 'run-$runs',
      profileId: profile.id,
      remoteModelId: request.remoteModelId,
      events: events.stream,
      cancelToken: CancelToken(),
      done: done.future,
    );
  }

  Future<void> finish() async {
    await events.close();
    if (!done.isCompleted) done.complete();
  }
}

final class _NoWebSearch extends WebSearchEnabledNotifier {
  @override
  bool build() => false;
}

final class _NoImageGeneration extends ImageGenerationEnabledNotifier {
  @override
  bool build() => false;
}

final class _NoCodeInterpreter extends CodeInterpreterEnabledNotifier {
  @override
  bool build() => false;
}

/// A container whose selected model is a Direct one answered by [adapter].
ProviderContainer _directContainer(
  _WaitingAdapter adapter, {
  List<FileUploadState> tray = const [],
}) {
  final profile = DirectConnectionProfile(
    id: 'profile-one',
    name: 'Local provider',
    adapterKey: kOllamaAdapterKey,
    baseUrl: 'http://localhost:11434',
  );
  final models = DirectModelRegistry();
  final model = models.replaceProfileModels(profile, [
    DirectRemoteModel(id: 'model-one', isMultimodal: true),
  ]).single;
  final container = ProviderContainer(
    overrides: [
      openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
      directLocalDatabaseProvider.overrideWith((ref) {
        final database = AppDatabase(NativeDatabase.memory());
        ref.onDispose(() => unawaited(database.close()));
        return database;
      }),
      apiServiceProvider.overrideWithValue(null),
      socketServiceProvider.overrideWithValue(null),
      selectedModelProvider.overrideWithValue(model),
      reviewerModeProvider.overrideWithValue(false),
      directConnectionProfilesProvider.overrideWith(
        () => _FixedProfiles(profile),
      ),
      directModelRegistryProvider.overrideWithValue(models),
      directRunRegistryProvider.overrideWithValue(DirectRunRegistry()),
      directProviderAdapterRegistryProvider.overrideWithValue(
        DirectProviderAdapterRegistry([adapter]),
      ),
      attachedFilesProvider.overrideWith(() => _Tray(tray)),
      webSearchEnabledProvider.overrideWith(_NoWebSearch.new),
      imageGenerationEnabledProvider.overrideWith(_NoImageGeneration.new),
      codeInterpreterEnabledProvider.overrideWith(_NoCodeInterpreter.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

final class _Tray extends AttachedFilesNotifier {
  _Tray(this.files);

  final List<FileUploadState> files;

  @override
  List<FileUploadState> build() => files;
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  // A Direct send, like a Hermes one, returns only when its reply ends. The
  // composer kept the sent words until then, through any tool approval.
  test('a Direct send says its turn started while the reply runs', () async {
    final adapter = _WaitingAdapter();
    final container = _directContainer(adapter);

    final steps = <String>[];
    var sent = false;
    final send = durableSend(
      container,
      'Summarize the synthetic notes',
      null,
      onAssistantPlaceholderCreated: (_) => steps.add('placeholder'),
      onTurnStarted: () => steps.add('started'),
    ).whenComplete(() => sent = true);
    await adapter.asked.future;

    check(adapter.runs).equals(1);
    check(steps).deepEquals(['placeholder', 'started']);
    check(sent).isFalse();

    adapter.events
      ..add(const DirectContentDelta('Done.'))
      ..add(const DirectStreamDone());
    await adapter.finish();
    await send;
    check(steps).deepEquals(['placeholder', 'started']);
  });

  // A chat begun with only a picture is named for it, not "New Chat".
  test('a Direct send without words is titled by its files', () async {
    final image = 'data:image/png;base64,${base64Encode([1, 2, 3])}';
    final adapter = _WaitingAdapter();
    final container = _directContainer(
      adapter,
      tray: [
        FileUploadState(
          file: File('/synthetic/tray/chart.png'),
          fileName: 'chart.png',
          fileSize: 3,
          progress: 1,
          status: FileUploadStatus.completed,
          fileId: image,
          isImage: true,
          base64DataUrl: image,
        ),
      ],
    );

    final send = durableSend(container, '', [image]);
    await adapter.asked.future;

    check(adapter.runs).equals(1);
    final asked = adapter.requests.single.messages.last;
    check(asked.parts.single).isA<DirectImagePart>();
    check(container.read(chatMessagesProvider).first.content).equals('');
    check(container.read(activeConversationProvider)?.title)
        .equals('chart.png');

    adapter.events
      ..add(const DirectContentDelta('A bar chart.'))
      ..add(const DirectStreamDone());
    await adapter.finish();
    await send;

    // The image the message is saved with keeps its name after the send.
    final userMessage = container
        .read(chatMessagesProvider)
        .firstWhere((message) => message.role == 'user');
    check(userMessage.files).isNotNull().deepEquals([
      {'type': 'image', 'url': image, 'name': 'chart.png'},
    ]);
  });

  // An image kept on the server is fetched only after the turn is saved,
  // and the chat is named as it is saved, from the name the tray shows.
  test('a Direct send of a server image alone is titled by it', () async {
    final adapter = _WaitingAdapter();
    final container = _directContainer(
      adapter,
      tray: [
        FileUploadState(
          file: File('/synthetic/tray/scan.png'),
          fileName: 'scan.png',
          fileSize: 3,
          progress: 1,
          status: FileUploadStatus.completed,
          fileId: 'file-scan',
          isImage: true,
        ),
      ],
    );

    // No server here to fetch it from: the send stops once the turn is
    // saved.
    await check(durableSend(container, '', ['file-scan']))
        .throws<DirectChatInputException>();

    check(container.read(activeConversationProvider)?.title).equals('scan.png');
  });
}

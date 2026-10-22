import 'dart:async';

import 'package:conduit/features/hermes/providers/hermes_mobile_files.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FilesBackend extends Fake implements HermesBackendService {
  final release = Completer<void>();
  final reads = <String>[];
  final tokens = <CancelToken>[];
  @override
  HermesConfig get config =>
      const HermesConfig(enabled: true, baseUrl: 'https://hermes.example');
  @override
  Future<List<Map<String, dynamic>>> listSessions() async => [
    for (var index = 0; index < 8; index++)
      {'id': 'session-$index', 'title': 'Output $index'},
  ];
  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) async {
    reads.add(id);
    if (cancelToken != null) tokens.add(cancelToken);
    if (int.parse(id.split('-').last) >= 4) await release.future;
    return [
      {
        'id': 'output',
        'role': 'tool',
        'tool_name': 'document_export',
        'content': {'output_path': '/workspace/$id.pdf'},
      },
    ];
  }
}

class _Active extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
  void show(Conversation value) => state = value;
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [
    ChatMessage(
      id: 'local-file',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      files: const [
        {'name': 'report.txt'},
      ],
    ),
  ];
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  test('live files require native provenance and the current connection without a transcript read', () {
    final service = _FilesBackend();
    var streaming = false;
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(service),
        activeConversationProvider.overrideWith(_Active.new),
        chatMessagesProvider.overrideWith(_Messages.new),
        isChatStreamingProvider.overrideWith((_) => streaming),
      ],
    );
    addTearDown(container.dispose);
    final identity = HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: HermesConfigController.connectionEndpoint(
        service.config.baseUrl,
      )!,
      principalId: container
          .read(hermesConfigProvider.notifier)
          .documentTrustPrincipalId(),
    );
    Conversation shell(String owner) => Conversation(
      id: 'local:fixture',
      title: 'Report',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      metadata: {
        'hermesSessionId': 'session-file',
        kHermesConnectionIdentityMetadataKey: owner,
      },
    );
    final active =
        container.read(activeConversationProvider.notifier) as _Active;
    active.show(shell(identity));
    expect(
      container.read(hermesLiveFilesProvider),
      isEmpty,
      reason: 'Serialized metadata alone is not native ownership',
    );
    active.show(markNativeHermesConversation(shell('previous-connection')));
    expect(container.read(hermesLiveFilesProvider), isEmpty);
    active.show(markNativeHermesConversation(shell(identity)));
    expect(container.read(hermesLiveFilesProvider).single.name, 'report.txt');
    streaming = true;
    container.invalidate(isChatStreamingProvider);
    expect(container.read(hermesLiveFilesProvider).single.name, 'report.txt');
    active.show(markNativeHermesConversation(shell('previous-connection')));
    expect(container.read(hermesLiveFilesProvider), isEmpty);
    expect(service.reads, isEmpty);
  });

  test('Files publishes tool outputs before the complete history sweep and survives session refresh', () async {
    final service = _FilesBackend();
    final container = ProviderContainer(
      overrides: [hermesApiServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final complete = Completer<HermesFileLibrary>();
    final subscription = container.listen(hermesMobileFilesProvider, (
      _,
      value,
    ) {
      final library = value.asData?.value;
      if (library != null &&
          !library.indexing &&
          library.files.length == 8 &&
          !complete.isCompleted) {
        complete.complete(library);
      }
    });
    addTearDown(subscription.close);
    final first = await container
        .read(hermesMobileFilesProvider.future)
        .timeout(const Duration(seconds: 2));
    expect(first.files, hasLength(4));
    expect(first.indexing, isTrue);
    container.invalidate(hermesSessionsProvider);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(hermesMobileFilesProvider).asData?.value.files,
      hasLength(4),
    );
    expect(service.reads, hasLength(8));
    service.release.complete();
    expect(
      (await complete.future.timeout(const Duration(seconds: 2))).files,
      hasLength(8),
    );
  });

  test(
    'Disposing the file index cancels its pending transcript reads',
    () async {
      final service = _FilesBackend();
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(service)],
      );
      container.listen(hermesMobileFilesProvider, (_, _) {});
      await container.read(hermesMobileFilesProvider.future);
      await Future<void>.delayed(Duration.zero);
      container.dispose();
      expect(service.tokens.every((token) => token.isCancelled), isTrue);
      service.release.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );
}

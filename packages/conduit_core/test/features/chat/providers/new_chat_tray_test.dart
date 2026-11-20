import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _serverModel = Model(id: 'server-model', name: 'Server model');

final class _FixedHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    apiKey: 'key',
    sessionKey: 'memory',
  );
}

final class _Selected extends SelectedModel {
  _Selected(this.initial);

  final Model initial;

  @override
  Model? build() => initial;
}

final class _Tray extends AttachedFilesNotifier {
  @override
  List<FileUploadState> build() => [
    FileUploadState(
      file: File('/synthetic/tray/sketch.png'),
      fileName: 'sketch.png',
      fileSize: 3,
      progress: 1,
      status: FileUploadStatus.completed,
      fileId: 'data:image/png;base64,AQID',
      isImage: true,
    ),
  ];
}

/// The composer's tray outlives a chat. Files picked in a Hermes chat stayed
/// in it, so the next Hermes chat opened with them already attached.
void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  ProviderContainer containerWith(Model selected) {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
        selectedModelProvider.overrideWith(() => _Selected(selected)),
        attachedFilesProvider.overrideWith(_Tray.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(attachedFilesProvider);
    return container;
  }

  test('a new Hermes chat starts without the last chat\'s files', () async {
    final container = containerWith(_serverModel);

    await startNewHermesChat(container);

    check(container.read(attachedFilesProvider)).isEmpty();
  });

  test('a new chat begun from a Hermes chat leaves its files behind', () {
    final container = containerWith(hermesSyntheticModel());

    startNewChat(container, modelForNewConversation: _serverModel);

    check(container.read(attachedFilesProvider)).isEmpty();
  });

  test('a new chat between other backends keeps the tray as it was', () {
    final container = containerWith(_serverModel);

    startNewChat(container, modelForNewConversation: _serverModel);

    check(container.read(attachedFilesProvider)).length.equals(1);
  });
}

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
import 'package:conduit_core/services/settings_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _serverModel = Model(id: 'server-model', name: 'Server model');
const _otherServerModel = Model(id: 'other-model', name: 'Other model');

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

const _sketchPath = '/synthetic/tray/sketch.png';

final class _Tray extends AttachedFilesNotifier {
  @override
  List<FileUploadState> build() => [
    FileUploadState(
      file: File(_sketchPath),
      fileName: 'sketch.png',
      fileSize: 3,
      progress: 0.5,
      status: FileUploadStatus.uploading,
      isImage: true,
    ),
  ];

  /// Attaches [name], from [path] or else a share, as the composer does once
  /// its file is ready.
  void attach(String name, {String? path}) => state = [
    ...state,
    FileUploadState(
      file: File(path ?? '/synthetic/share/$name'),
      fileName: name,
      fileSize: 3,
      progress: 0,
      status: FileUploadStatus.pending,
      isImage: true,
    ),
  ];
}

/// The composer's tray outlives a chat. Files picked in a Hermes chat stayed
/// in it, so the next Hermes chat opened with them already attached.
void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  /// A container whose default model restore picks [defaultModel].
  ProviderContainer containerWith(Model selected, {Model? defaultModel}) {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
        selectedModelProvider.overrideWith(() => _Selected(selected)),
        attachedFilesProvider.overrideWith(_Tray.new),
        // A named default keeps the restore off device storage.
        appSettingsProvider.overrideWithValue(
          const AppSettings(defaultModel: 'default-model'),
        ),
        defaultModelProvider.overrideWith((ref) async {
          await Future<void>.value();
          if (defaultModel != null) {
            ref.read(selectedModelProvider.notifier).set(defaultModel);
          }
          return defaultModel;
        }),
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

  // New Chat names no model: the default restore picks one later, and a file
  // attached meanwhile, such as a share, belongs to the new chat. So does
  // one picked again at the path of a file the chat leaves behind, while that
  // file goes even when its upload moved on meanwhile.
  for (final (attached, attach, kept) in [
    (
      'a share',
      (_Tray tray) {
        tray.updateFileState(
          _sketchPath,
          FileUploadState(
            file: File(_sketchPath),
            fileName: 'sketch.png',
            fileSize: 3,
            progress: 1,
            status: FileUploadStatus.completed,
            fileId: 'data:image/png;base64,AQID',
            isImage: true,
          ),
        );
        tray.attach('receipt.png');
      },
      'receipt.png',
    ),
    (
      'the same file picked again',
      (_Tray tray) {
        tray.removeFile(_sketchPath);
        tray.attach('sketch.png', path: _sketchPath);
      },
      'sketch.png',
    ),
  ]) {
    test(
      'a new chat whose default is Hermes starts without the last chat\'s '
      'files, and keeps $attached attached while the default was chosen',
      () async {
        final container = containerWith(
          _serverModel,
          defaultModel: hermesSyntheticModel(),
        );

        final restored = restoreDefaultModelForNewChat(container);
        attach(container.read(attachedFilesProvider.notifier) as _Tray);
        await restored;

        check(isHermesModel(container.read(selectedModelProvider)!)).isTrue();
        final files = container.read(attachedFilesProvider);
        check(files.map((file) => file.fileName)).deepEquals([kept]);
        check(files.single.status).equals(FileUploadStatus.pending);
      },
    );
  }

  test('a new chat whose default is another backend keeps the tray', () async {
    final container = containerWith(
      _serverModel,
      defaultModel: _otherServerModel,
    );

    await restoreDefaultModelForNewChat(container);

    check(container.read(selectedModelProvider)).equals(_otherServerModel);
    check(container.read(attachedFilesProvider).map((file) => file.fileName))
        .deepEquals(['sketch.png']);
  });
}

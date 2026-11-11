import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/services/media_upload_controller.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/testing.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

const _server = LibreChatServer(baseUrl: 'https://chat.example.com');

final class _MemoryStore implements LibreChatSessionStore {
  LibreChatSession? session;

  @override
  Future<LibreChatSession?> read() async => session;

  @override
  Future<void> write(LibreChatSession value) async => session = value;

  @override
  Future<void> clear() async => session = null;
}

final class _SeededAttachedFiles extends AttachedFilesNotifier {
  _SeededAttachedFiles(this.attachments);

  final List<FileUploadState> attachments;

  @override
  List<FileUploadState> build() => List.of(attachments);
}

void main() {
  test('a LibreChat model uploads the file to its server, sized and '
      'remembered for the turn', () async {
    final fake = FakeLibreChatServer()..addUser();
    final auth = LibreChatAuthService(_server, adapter: fake);
    addTearDown(auth.close);
    final signedIn =
        await auth.signIn(email: 'dev@example.com', password: 'devpassword')
            as LibreChatSignedIn;
    final handle = LibreChatSessionHandle(
      session: signedIn.session,
      store: _MemoryStore(),
      renew: auth.renew,
    );
    addTearDown(handle.dispose);
    final client = LibreChatHttpClient(
      server: _server,
      session: handle,
      adapter: fake,
    );
    addTearDown(client.close);

    final fields = <String, String>{};
    fake.on('POST', '/api/files/images', (request, match) {
      final form = request.data as FormData;
      fields.addEntries(form.fields);
      return FakeLibreChatResponse.json({
        'file_id': 'srv-1',
        'filepath': '/images/user1/srv-1.png',
        'filename': 'photo.png',
        'type': 'image/png',
        'width': 1,
        'height': 1,
      });
    });

    final directory = await Directory.systemTemp.createTemp(
      'conduit_librechat_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final image = File('${directory.path}/photo.png');
    await image.writeAsBytes(_png);

    final model = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Ollama': {'order': 1, 'type': 'custom'},
      },
      models: const {
        'Ollama': ['llama3.2'],
      },
    ).single;
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWithValue(model),
        libreChatApiServiceProvider.overrideWithValue(
          LibreChatApiService(client),
        ),
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFiles([
            FileUploadState(
              file: image,
              fileName: 'photo.png',
              fileSize: _png.length,
              progress: 0,
              status: FileUploadStatus.pending,
              isImage: true,
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(mediaUploadControllerProvider)
        .upload(
          filePath: image.path,
          fileName: 'photo.png',
          fileSize: _png.length,
        );

    final stored = container.read(attachedFilesProvider).single;
    expect(stored.status, FileUploadStatus.completed);
    expect(stored.fileId, 'srv-1');
    expect(fields['endpoint'], 'Ollama');
    expect(fields['endpointType'], 'custom');
    expect(fields['width'], '1');
    expect(fields['height'], '1');
    expect(fields['file_id'], isNotEmpty);
    expect(fields['file_id'], isNot('srv-1'));

    final turnFile = libreChatTurnFile(
      container.read(libreChatUploadedFilesProvider.notifier).recordsFor([
        'srv-1',
      ]).single,
    );
    expect(turnFile['filepath'], '/images/user1/srv-1.png');
    expect(turnFile['width'], 1);
  });

  test('a file larger than the LibreChat server takes is refused before it '
      'goes up', () async {
    final fake = FakeLibreChatServer()..addUser();
    final auth = LibreChatAuthService(_server, adapter: fake);
    addTearDown(auth.close);
    final signedIn =
        await auth.signIn(email: 'dev@example.com', password: 'devpassword')
            as LibreChatSignedIn;
    final handle = LibreChatSessionHandle(
      session: signedIn.session,
      store: _MemoryStore(),
      renew: auth.renew,
    );
    addTearDown(handle.dispose);
    final client = LibreChatHttpClient(
      server: _server,
      session: handle,
      adapter: fake,
    );
    addTearDown(client.close);

    // The server's setting is in megabytes, as librechat.yaml writes it.
    fake.on(
      'GET',
      '/api/files/config',
      (request, match) =>
          FakeLibreChatResponse.json({'serverFileSizeLimit': 1}),
    );
    var uploads = 0;
    fake.on('POST', '/api/files', (request, match) {
      uploads += 1;
      return FakeLibreChatResponse.json({'file_id': 'srv-1'});
    });

    final directory = await Directory.systemTemp.createTemp(
      'conduit_librechat_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final document = File('${directory.path}/notes.txt');
    final size = 1024 * 1024 + 1;
    await document.writeAsBytes(List<int>.filled(size, 0x61));

    final model = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Ollama': {'order': 1, 'type': 'custom'},
      },
      models: const {
        'Ollama': ['llama3.2'],
      },
    ).single;
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWithValue(model),
        libreChatApiServiceProvider.overrideWithValue(
          LibreChatApiService(client),
        ),
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFiles([
            FileUploadState(
              file: document,
              fileName: 'notes.txt',
              fileSize: size,
              progress: 0,
              status: FileUploadStatus.pending,
              isImage: false,
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(mediaUploadControllerProvider)
          .upload(filePath: document.path, fileName: 'notes.txt'),
      throwsA(isA<LibreChatApiException>()),
    );
    expect(uploads, 0);
    expect(
      container.read(attachedFilesProvider).single.status,
      isNot(FileUploadStatus.completed),
    );
  });

  test('a file uploading when the LibreChat account changes is never '
      'handed to the next account', () async {
    final fake = FakeLibreChatServer()..addUser();
    final auth = LibreChatAuthService(_server, adapter: fake);
    addTearDown(auth.close);
    final signedIn =
        await auth.signIn(email: 'dev@example.com', password: 'devpassword')
            as LibreChatSignedIn;
    final handle = LibreChatSessionHandle(
      session: signedIn.session,
      store: _MemoryStore(),
      renew: auth.renew,
    );
    addTearDown(handle.dispose);
    final client = LibreChatHttpClient(
      server: _server,
      session: handle,
      adapter: fake,
    );
    addTearDown(client.close);

    final answer = Completer<void>();
    final reached = Completer<void>();
    fake.on('POST', '/api/files/images', (request, match) async {
      reached.complete();
      await answer.future;
      return FakeLibreChatResponse.json({
        'file_id': 'srv-1',
        'filepath': '/images/user1/srv-1.png',
        'filename': 'photo.png',
        'type': 'image/png',
        'width': 1,
        'height': 1,
      });
    });

    final directory = await Directory.systemTemp.createTemp(
      'conduit_librechat_media_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final image = File('${directory.path}/photo.png');
    await image.writeAsBytes(_png);

    final model = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Ollama': {'order': 1, 'type': 'custom'},
      },
      models: const {
        'Ollama': ['llama3.2'],
      },
    ).single;
    final first = LibreChatAccount.forUser(
      _server,
      const LibreChatUser(id: 'u1'),
    );
    final second = LibreChatAccount.forUser(
      _server,
      const LibreChatUser(id: 'u2'),
    );
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWithValue(model),
        libreChatApiServiceProvider.overrideWithValue(
          LibreChatApiService(client),
        ),
        _accountProvider.overrideWith(() => _Account(first)),
        activeLibreChatAccountProvider.overrideWith(
          (ref) => ref.watch(_accountProvider),
        ),
        attachedFilesProvider.overrideWith(
          () => _SeededAttachedFiles([
            FileUploadState(
              file: image,
              fileName: 'photo.png',
              fileSize: _png.length,
              progress: 0,
              status: FileUploadStatus.pending,
              isImage: true,
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    final uploads = container.read(libreChatUploadedFilesProvider.notifier);
    container.listen(libreChatUploadedFilesProvider, (_, _) {});

    final upload = container
        .read(mediaUploadControllerProvider)
        .upload(
          filePath: image.path,
          fileName: 'photo.png',
          fileSize: _png.length,
        );
    await reached.future;
    container.read(_accountProvider.notifier).set(second);
    answer.complete();
    await upload.catchError((Object _) {});

    expect(
      container.read(libreChatUploadedFilesProvider.notifier).has('srv-1'),
      isFalse,
    );
    expect(uploads.has('srv-1'), isFalse);
    expect(
      container.read(attachedFilesProvider).single.status,
      isNot(FileUploadStatus.completed),
    );
  });
}

final _accountProvider = NotifierProvider<_Account, LibreChatAccount?>(
  () => _Account(null),
);

final class _Account extends Notifier<LibreChatAccount?> {
  _Account(this.initial);

  final LibreChatAccount? initial;

  @override
  LibreChatAccount? build() => initial;

  void set(LibreChatAccount? account) => state = account;
}

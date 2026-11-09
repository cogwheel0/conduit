import 'package:conduit/features/chat/services/file_attachment_service.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final Model _libreChatModel = libreChatCatalog(
  startupConfig: const <String, dynamic>{},
  endpoints: const <String, dynamic>{
    'Sample': <String, dynamic>{'order': 0},
  },
  models: const <String, List<String>>{
    'Sample': <String>['sample-model'],
  },
).single;

/// The pickers open through this service; with only a LibreChat account
/// there is no Open WebUI API, and its files go to LibreChat instead.
void main() {
  ProviderContainer containerFor(
    Model model, {
    required LibreChatApiService? libreChat,
  }) {
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWithValue(model),
        libreChatApiServiceProvider.overrideWithValue(libreChat),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a signed-in LibreChat model opens the pickers without Open WebUI', () {
    final client = LibreChatHttpClient(
      server: const LibreChatServer(baseUrl: 'https://chat.example.com'),
    );
    addTearDown(client.close);
    final container = containerFor(
      _libreChatModel,
      libreChat: LibreChatApiService(client),
    );

    expect(
      container.read(fileAttachmentServiceProvider),
      isA<FileAttachmentService>(),
    );
  });

  test('a LibreChat model with no signed-in server opens none', () {
    final container = containerFor(_libreChatModel, libreChat: null);

    expect(container.read(fileAttachmentServiceProvider), isNull);
  });
}

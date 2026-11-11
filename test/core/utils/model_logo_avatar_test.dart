import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/utils/model_icon_utils.dart';
import 'package:conduit/core/utils/model_logos.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/model_logo_catalog.dart';
import 'package:conduit_core/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

List<Model> _mint(String baseUrl, List<String> remoteIds) =>
    DirectModelRegistry().replaceProfileModels(
      DirectConnectionProfile(
        id: 'provider',
        name: 'Provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: baseUrl,
      ),
      [for (final id in remoteIds) DirectRemoteModel(id: id, name: id)],
    );

void main() {
  setUpAll(() {
    ModelLogos.debugSetCatalog(
      ModelLogoCatalog.fromJson(
        jsonDecode(File('assets/model_logos/catalog.json').readAsStringSync())
            as Map<String, dynamic>,
      ),
    );
  });
  tearDownAll(() => ModelLogos.debugSetCatalog(null));

  test(
    'Direct models show their maker, or their provider, from models.dev',
    () {
      final models = _mint('https://api.groq.com/openai/v1', [
        'gpt-4o',
        'my-finetune',
      ]);

      check(resolveModelIconUrlForModel(null, models.first))
          .equals('${kModelLogoUrlScheme}openai');
      // The connection's host picks the provider's logo.
      check(resolveModelIconUrlForModel(null, models.last))
          .equals('${kModelLogoUrlScheme}groq');
    },
  );

  test('a server model cannot claim a bundled logo through metadata', () {
    // Claiming a Direct identity in metadata buys neither a remote id's
    // maker nor a connection host's logo.
    const spoofed = Model(
      id: 'my-finetune',
      name: 'My finetune',
      metadata: {
        'backend': 'direct',
        'remoteModelId': 'gpt-4o',
        'directBaseHost': 'api.groq.com',
      },
    );
    check(modelLogoIdFromUrl(resolveModelIconUrlForModel(null, spoofed)))
        .isNull();

    // A model an admin customized keeps the server's avatar, whatever its
    // metadata claims.
    const customized = Model(
      id: 'gpt-4o',
      name: 'GPT-4o',
      metadata: {
        'backend': 'direct',
        'remoteModelId': 'gpt-4o',
        'info': {'id': 'gpt-4o'},
      },
    );
    check(modelLogoIdFromUrl(resolveModelIconUrlForModel(null, customized)))
        .isNull();
  });

  test('an uncustomized server model shows its maker by its own id', () {
    const plain = Model(id: 'openai/gpt-5-mini', name: 'openai/gpt-5-mini');
    check(modelLogoIdFromUrl(resolveModelIconUrlForModel(null, plain)))
        .equals('openai');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/direct_connections/services/model_logo_catalog.dart';
import 'package:test/test.dart';

/// The catalog the app ships, so a regenerated bundle is checked too.
final _bundled = ModelLogoCatalog.fromJson(
  jsonDecode(File('../../assets/model_logos/catalog.json').readAsStringSync())
      as Map<String, dynamic>,
);

void main() {
  test('a model resolves to its maker, then to its provider', () {
    final cases = <(String, String?, String?, String?)>[
      // (remote id, API host, adapter, expected logo)
      // Gateway ids name the lab, aliases included.
      ('openai/gpt-5-mini', 'ai-gateway.vercel.sh', null, 'openai'),
      ('meta-llama/llama-3.3-70b-instruct', 'openrouter.ai', null, 'meta'),
      ('x-ai/grok-4', 'openrouter.ai', null, 'xai'),
      // Bare ids use the models.dev index, then family prefixes.
      ('gpt-5.4', 'api.openai.com', null, 'openai'),
      ('claude-sonnet-4-5', null, null, 'anthropic'),
      ('llama3.2:3b', 'localhost', 'ollama', 'meta'),
      ('qwen2.5-coder:7b', 'localhost', 'ollama', 'alibaba'),
      // An unknown maker falls back to the provider serving it.
      ('voyage/voyage-3.5', 'ai-gateway.vercel.sh', null, 'vercel'),
      ('my-finetune', 'api.groq.com', null, 'groq'),
      ('my-finetune', 'localhost', 'ollama', 'ollama-cloud'),
      // Nothing known: the lettered avatar.
      ('my-finetune', 'llm.example.com', 'openai-compatible', null),
    ];
    for (final (id, host, adapter, expected) in cases) {
      expect(
        _bundled.logoFor(
          remoteModelId: id,
          baseHost: host,
          adapterKey: adapter,
        ),
        expected,
        reason: '$id @ $host',
      );
    }
  });

  test('every logo the catalog names ships as an SVG', () {
    expect(_bundled.logos, isNotEmpty);
    final missing = [
      for (final id in _bundled.logos.keys)
        if (!File('../../assets/model_logos/$id.svg').existsSync()) id,
    ];
    expect(missing, isEmpty);
  });
}

// Regenerates the bundled model logos from models.dev.
//
//   dart run tool/generate_model_logos.dart
//   dart run tool/generate_model_logos.dart --names-only
//
// Writes assets/model_logos/<id>.svg for every models.dev provider with a
// real logo, plus assets/model_logos/catalog.json, the index Direct
// connections use to pick a model's avatar and the display names shown for
// raw model ids (see `ModelLogoCatalog` and `modelDisplayName` in
// conduit_core). Everything ships in the app bundle: resolving an avatar or
// a name never touches the network.
//
// `--names-only` refreshes just the catalog's `names` section against the
// logos already bundled, without downloading or rewriting any logo.
import 'dart:convert';
import 'dart:io';

const _catalogUrl = 'https://models.dev/api.json';
const _logoUrl = 'https://models.dev/logos';
const _outDir = 'assets/model_logos';

/// Model-id prefixes that name a lab differently from its models.dev id.
const _labAliases = {
  'x-ai': 'xai',
  'z-ai': 'zhipuai',
  'thudm': 'zhipuai',
  'qwen': 'alibaba',
  'mistralai': 'mistral',
  'meta-llama': 'meta',
  'deepseek-ai': 'deepseek',
  'moonshot': 'moonshotai',
  'google-deepmind': 'google',
  'nvidia-nim': 'nvidia',
  'cohereforai': 'cohere',
  'minimaxai': 'minimax',
  'xiaomimimo': 'xiaomi',
  'stepfun-ai': 'stepfun',
};

/// Model-name prefixes for ids no catalog lists, typically local servers
/// (`llama3.2:3b`, `qwen2.5-coder`). Longest prefixes win.
const _families = {
  'chatgpt': 'openai',
  'gpt-': 'openai',
  'gpt4': 'openai',
  'o1': 'openai',
  'o3': 'openai',
  'o4-': 'openai',
  'dall-e': 'openai',
  'whisper': 'openai',
  'text-embedding': 'openai',
  'claude': 'anthropic',
  'gemini': 'google',
  'gemma': 'google',
  'codellama': 'meta',
  'llama': 'meta',
  'qwen': 'alibaba',
  'qwq': 'alibaba',
  'mistral': 'mistral',
  'mixtral': 'mistral',
  'codestral': 'mistral',
  'ministral': 'mistral',
  'pixtral': 'mistral',
  'magistral': 'mistral',
  'devstral': 'mistral',
  'deepseek': 'deepseek',
  'chatglm': 'zhipuai',
  'glm': 'zhipuai',
  'kimi': 'moonshotai',
  'grok': 'xai',
  'command': 'cohere',
  'c4ai': 'cohere',
  'nemotron': 'nvidia',
  'minimax': 'minimax',
  'sonar': 'perplexity',
  'mimo': 'xiaomi',
  'jamba': 'ai21',
  'mercury': 'inception',
};

/// API hosts of providers whose models.dev entry has no `api` URL because
/// they ship a dedicated SDK.
const _hosts = {
  'api.openai.com': 'openai',
  'api.anthropic.com': 'anthropic',
  'generativelanguage.googleapis.com': 'google',
  'api.groq.com': 'groq',
  'ai-gateway.vercel.sh': 'vercel',
  'api.mistral.ai': 'mistral',
  'api.x.ai': 'xai',
  'api.together.xyz': 'togetherai',
  'api.deepinfra.com': 'deepinfra',
  'api.deepseek.com': 'deepseek',
  'api.cerebras.ai': 'cerebras',
  'api.cohere.ai': 'cohere',
  'api.cohere.com': 'cohere',
  'api.perplexity.ai': 'perplexity',
  'ollama.com': 'ollama-cloud',
};

Future<void> main(List<String> args) async {
  final client = HttpClient();
  try {
    final catalog =
        jsonDecode(await _get(client, _catalogUrl)) as Map<String, dynamic>;
    if (args.contains('--names-only')) {
      final file = File('$_outDir/catalog.json');
      final bundled =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final logos = <String, String>{
        for (final entry in (bundled['logos'] as Map).entries)
          '${entry.key}': '${entry.value}',
      };
      final names = _modelNames(catalog, logos);
      bundled['names'] = _sortedByKey(names);
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(bundled)}\n',
      );
      stdout.writeln('${names.length} names');
      return;
    }
    final defaultLogo = await _get(client, '$_logoUrl/__missing__.svg');

    final dir = Directory(_outDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);

    final logos = <String, String>{};
    for (final entry in catalog.entries) {
      final id = entry.key;
      if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(id)) continue;
      final svg = await _get(client, '$_logoUrl/$id.svg');
      // models.dev answers unknown logos with a generic sparkle.
      if (svg == defaultLogo) continue;
      File('$_outDir/$id.svg').writeAsStringSync(svg);
      logos[id] = (entry.value as Map)['name'] as String? ?? id;
    }

    String? logoFor(String? id) => _logoFor(id, logos);
    final labs = _labs(catalog, logos);

    final models = <String, String>{};
    void index(String? name, String? lab) {
      if (name == null || lab == null) return;
      models.putIfAbsent(name.toLowerCase(), () => lab);
    }

    for (final provider in catalog.values) {
      for (final model in ((provider as Map)['models'] as Map).values) {
        final canonical = (model as Map)['canonical_model_id'] as String?;
        if (canonical == null || !canonical.contains('/')) continue;
        final lab = logoFor(canonical.split('/').first);
        index(canonical.split('/').last, lab);
      }
    }
    // First-party listings cover models without a canonical id.
    _forEachFirstPartyModel(catalog, logos, labs, (lab, name, _) {
      index(name, lab);
    });

    final hosts = <String, String>{};
    for (final entry in catalog.entries) {
      final api = (entry.value as Map)['api'] as String?;
      if (api == null || api.contains(r'${') || !logos.containsKey(entry.key)) {
        continue;
      }
      final host = Uri.tryParse(api)?.host.toLowerCase();
      if (host == null || host.isEmpty || _isLocal(host)) continue;
      hosts.putIfAbsent(host, () => entry.key);
    }
    _hosts.forEach((host, id) {
      if (logos.containsKey(id)) hosts[host] = id;
    });

    final families =
        (_families.entries.toList()
              ..sort((a, b) => b.key.length.compareTo(a.key.length)))
            .where((entry) => logos.containsKey(entry.value))
            .map((entry) => [entry.key, entry.value])
            .toList();

    final aliases = {
      for (final entry in _labAliases.entries)
        if (logos.containsKey(entry.value)) entry.key: entry.value,
    };

    File('$_outDir/catalog.json').writeAsStringSync(
      '${const JsonEncoder.withIndent(' ').convert({'source': 'https://models.dev', 'logos': Map.fromEntries(logos.entries.toList()..sort((a, b) => a.key.compareTo(b.key))), 'labAliases': aliases, 'families': families, 'hosts': Map.fromEntries(hosts.entries.toList()..sort((a, b) => a.key.compareTo(b.key))), 'models': Map.fromEntries(models.entries.toList()..sort((a, b) => a.key.compareTo(b.key))), 'names': _sortedByKey(_modelNames(catalog, logos))})}\n',
    );
    stdout.writeln(
      '${logos.length} logos, ${models.length} models, ${hosts.length} hosts',
    );
  } finally {
    client.close();
  }
}

String? _logoFor(String? id, Map<String, String> logos) {
  if (id == null) return null;
  final lower = id.toLowerCase();
  final resolved = _labAliases[lower] ?? lower;
  return logos.containsKey(resolved) ? resolved : null;
}

/// Labs are the makers named in canonical ids, not resellers.
Set<String> _labs(Map<String, dynamic> catalog, Map<String, String> logos) {
  final labs = <String>{};
  for (final provider in catalog.values) {
    for (final model in ((provider as Map)['models'] as Map).values) {
      final canonical = (model as Map)['canonical_model_id'] as String?;
      final lab = _logoFor(canonical?.split('/').first, logos);
      if (canonical != null && canonical.contains('/') && lab != null) {
        labs.add(lab);
      }
    }
  }
  return labs;
}

String? _familyLab(String name) {
  for (final entry in _families.entries) {
    if (name.startsWith(entry.key)) return entry.value;
  }
  return null;
}

/// Calls [visit] with each model a lab lists as its own. Labs also host each
/// other's models (NVIDIA serves Gemma), so a model whose canonical id or
/// family names another maker is skipped.
void _forEachFirstPartyModel(
  Map<String, dynamic> catalog,
  Map<String, String> logos,
  Set<String> labs,
  void Function(String lab, String name, Map<dynamic, dynamic> model) visit,
) {
  for (final entry in catalog.entries) {
    if (!labs.contains(entry.key)) continue;
    final listed = (entry.value as Map)['models'] as Map;
    for (final MapEntry(key: id, value: model) in listed.entries) {
      final canonical = (model as Map)['canonical_model_id'] as String?;
      final maker = canonical != null && canonical.contains('/')
          ? _logoFor(canonical.split('/').first, logos)
          : null;
      final name = (id as String).split('/').last.toLowerCase();
      final family = _familyLab(name);
      if ((maker != null && maker != entry.key) ||
          (family != null && family != entry.key)) {
        continue;
      }
      visit(entry.key, name, model);
    }
  }
}

/// Display names for bare model ids (`gpt-5-mini` → `GPT-5 Mini`), shown
/// when a server names a model by its raw id.
///
/// A lab's own listing wins. Otherwise a canonical id takes a reseller's
/// name for it, ignoring names that just repeat an id or carry a reseller's
/// parenthetical (`GPT OSS 20B (Groq)`) or "Maker: " prefix.
Map<String, String> _modelNames(
  Map<String, dynamic> catalog,
  Map<String, String> logos,
) {
  String? clean(Object? raw) {
    if (raw is! String) return null;
    final name = raw
        .replaceAll(RegExp(r'\s*\(latest\)\s*$', caseSensitive: false), '')
        .trim();
    return name.isEmpty ? null : name;
  }

  final names = <String, String>{};
  _forEachFirstPartyModel(catalog, logos, _labs(catalog, logos), (
    _,
    name,
    model,
  ) {
    final display = clean(model['name']);
    if (display != null) names.putIfAbsent(name, () => display);
  });

  final resold = <String, Map<String, int>>{};
  for (final provider in catalog.values) {
    for (final model in ((provider as Map)['models'] as Map).values) {
      final canonical = (model as Map)['canonical_model_id'] as String?;
      if (canonical == null || !canonical.contains('/')) continue;
      if (_logoFor(canonical.split('/').first, logos) == null) continue;
      final key = canonical.split('/').last.toLowerCase();
      final display = clean(model['name']);
      if (display == null ||
          display.contains('(') ||
          display.contains('/') ||
          // A reseller's "Maker: Model" label.
          display.contains(':') ||
          display.toLowerCase() == key) {
        continue;
      }
      final counts = resold.putIfAbsent(key, () => <String, int>{});
      counts[display] = (counts[display] ?? 0) + 1;
    }
  }
  // Prefer a name that spells the id's own words as a display name
  // (`kimi-k2` → `Kimi K2`, not a reseller's dated `Kimi K2 0711`), then
  // the most common one.
  List<String> words(String value) => value
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toList();
  for (final MapEntry(key: key, value: counts) in resold.entries) {
    if (names.containsKey(key)) continue;
    final idWords = words(key).join(' ');
    int rank(String name) =>
        (words(name).join(' ') == idWords ? 2 : 0) +
        (name.contains(' ') ? 1 : 0);
    final ranked = counts.entries.toList()
      ..sort((a, b) {
        final byRank = rank(b.key).compareTo(rank(a.key));
        if (byRank != 0) return byRank;
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        final byLength = a.key.length.compareTo(b.key.length);
        return byLength != 0 ? byLength : a.key.compareTo(b.key);
      });
    names[key] = ranked.first.key;
  }

  // `mistral-small-latest` also names the bare `mistral-small`.
  for (final MapEntry(key: key, value: display) in names.entries.toList()) {
    if (key.endsWith('-latest')) {
      names.putIfAbsent(key.substring(0, key.length - 7), () => display);
    }
  }
  return names;
}

Map<String, String> _sortedByKey(Map<String, String> map) => Map.fromEntries(
  map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
);

bool _isLocal(String host) =>
    host == 'localhost' ||
    host.startsWith('127.') ||
    host.startsWith('192.168.') ||
    host.startsWith('10.') ||
    host == '0.0.0.0';

Future<String> _get(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw HttpException('${response.statusCode} for $url');
  }
  return body;
}

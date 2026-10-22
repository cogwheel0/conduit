import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_model_catalog.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:test/test.dart';

HermesDesktopModelOption option(
  String id, {
  String provider = 'openai-codex',
  bool? recommended,
  bool? isDefault,
  bool? popular,
  double? rank,
  bool? deprecated,
  bool? retired,
  DateTime? shutdownAt,
}) => HermesDesktopModelOption(
  id: id,
  name: id,
  provider: provider,
  supportsFast: false,
  supportsReasoning: true,
  recommended: recommended,
  isDefault: isDefault,
  popular: popular,
  recommendationRank: rank,
  deprecated: deprecated,
  retired: retired,
  shutdownAt: shutdownAt,
);

void main() {
  test('preserves model hints and merges inline capability metadata', () {
    final result = parseHermesDesktopConfiguredModels({
      'providers': [
        {
          'slug': 'openai-codex',
          'authenticated': true,
          'models': [
            {
              'id': 'model-a',
              'name': 'Model A',
              'recommended': false,
              'is_default': true,
              'popular': true,
              'recommendation_rank': 2,
              'deprecated': false,
              'retired': false,
              'shutdown_at': '2027-01-01T00:00:00Z',
              'fast': true,
              'capabilities': {
                'reasoning': true,
                'supported_efforts': ['low', 'high'],
              },
            },
          ],
          'capabilities': {
            'model-a': {'reasoning': false, 'can_disable_reasoning': false},
          },
        },
      ],
    });
    final model = HermesDesktopModelOption.fromJson(result.single);
    expect(model.id, 'model-a');
    expect(model.recommended, false);
    expect(model.isDefault, true);
    expect(model.popular, true);
    expect(model.recommendationRank, 2);
    expect(model.shutdownAt, DateTime.utc(2027));
    expect(model.deprecated, false);
    expect(model.retired, false);
    expect(model.supportsFast, true);
    expect(model.reasoningAvailable, true);
    expect(model.canDisableReasoning, false);
    expect(model.supportedEfforts, ['low', 'high']);
  });

  test('plain gateway strings have unknown recommendation and lifecycle', () {
    final parsed = parseHermesDesktopConfiguredModels({
      'model': 'gpt-6.1-sol',
      'provider': 'openai-codex',
      'providers': [
        {
          'slug': 'openai-codex',
          'models': ['gpt-6.1-sol'],
        },
      ],
    });
    final model = HermesDesktopModelOption.fromJson(parsed.single);
    expect(model.recommended, isNull);
    expect(model.isDefault, isNull);
    expect(model.popular, isNull);
    expect(model.shutdownAt, isNull);
    expect(model.retired, isNull);
  });

  test(
    'provider recommendation cloning preserves routing and negative hints',
    () {
      final original = HermesDesktopModelOption(
        id: 'private-model',
        name: 'Private',
        provider: 'custom:local',
        supportsFast: true,
        supportsReasoning: true,
        reasoningAvailable: true,
        canDisableReasoning: false,
        supportedEfforts: const ['low', 'high'],
        baseUrl: 'https://models.example.test/v1',
        recommended: false,
        deprecated: true,
        retired: false,
        shutdownAt: DateTime.utc(2027),
      );
      final tagged = original.withRecommendedDefault();
      expect(tagged.isDefault, true);
      expect(tagged.id, original.id);
      expect(tagged.provider, original.provider);
      expect(tagged.name, original.name);
      expect(tagged.baseUrl, original.baseUrl);
      expect(tagged.supportsFast, original.supportsFast);
      expect(tagged.supportsReasoning, original.supportsReasoning);
      expect(tagged.reasoningAvailable, original.reasoningAvailable);
      expect(tagged.canDisableReasoning, original.canDisableReasoning);
      expect(tagged.supportedEfforts, original.supportedEfforts);
      expect(tagged.recommended, false);
      expect(tagged.deprecated, true);
      expect(tagged.retired, false);
      expect(tagged.shutdownAt, original.shutdownAt);
      expect(hermesRecommendedModels([tagged]), isEmpty);
    },
  );

  test('malformed gateway hints remain unknown', () {
    final model = HermesDesktopModelOption.fromJson({
      'id': 'custom',
      'provider': 'custom:local',
      'recommended': 'yes',
      'is_default': 1,
      'popular': 'true',
      'recommendation_rank': double.nan,
      'shutdown_at': double.infinity,
      'deprecated': 'false',
      'retired': [],
    });
    expect(model.recommended, isNull);
    expect(model.isDefault, isNull);
    expect(model.popular, isNull);
    expect(model.recommendationRank, isNull);
    expect(model.shutdownAt, isNull);
    expect(model.deprecated, isNull);
    expect(model.retired, isNull);
  });

  test('accepts a genuine Unix-second shutdown date', () {
    final date = DateTime.utc(2027);
    expect(hermesModelShutdownAt(date.millisecondsSinceEpoch ~/ 1000), date);
    expect(hermesModelShutdownAt(1e20), isNull);
    expect(hermesModelShutdownAt('not-a-date'), isNull);
  });

  test('preserves official shutdown_date through the gateway parser', () {
    final rows = parseHermesDesktopConfiguredModels({
      'providers': [
        {
          'slug': 'openai',
          'models': [
            {'id': 'retiring-model', 'shutdown_date': '2027-01-01'},
          ],
        },
      ],
    });
    final model = HermesDesktopModelOption.fromJson(rows.single);
    expect(model.shutdownAt, DateTime.utc(2027));
    expect(hermesRecommendedModels([model]), isEmpty);
    expect(
      HermesDesktopModelOption.fromJson({
        'id': 'retiring-model',
        'shutdown_date': '2027-01-01',
      }).shutdownAt,
      DateTime.utc(2027),
    );
  });

  test(
    'preserves validated Codex isDefault alias through parser and model',
    () {
      final rows = parseHermesDesktopConfiguredModels({
        'providers': [
          {
            'slug': 'openai-codex',
            'models': [
              {'id': 'gateway-default', 'isDefault': true},
              {'id': 'malformed-default', 'isDefault': 'true'},
            ],
          },
        ],
      });
      final models = rows.map(HermesDesktopModelOption.fromJson).toList();
      expect(models.first.isDefault, true);
      expect(models.last.isDefault, isNull);
      expect(hermesRecommendedModels(models), [models.first]);
      expect(
        HermesDesktopModelOption.fromJson({
          'id': 'gateway-default',
          'isDefault': true,
        }).isDefault,
        true,
      );
    },
  );

  test(
    'curation selects returned current choices without inventing models',
    () {
      final old = option('gpt-5.4');
      final current = option('gpt-6.1-sol');
      final unknown = option('private-large', provider: 'custom:private');
      final input = [old, current, unknown];
      expect(hermesRecommendedModels(input), [current]);
      expect(input, [old, current, unknown]);
      expect(hermesRecommendedModels([old]), isEmpty);
    },
  );

  test('known provider identity is required for curated endorsements', () {
    final local = option('gpt-6.1-sol', provider: 'custom:local');
    expect(hermesRecommendedModels([local]), isEmpty);
    expect(
      hermesRecommendedModels([
        option('openai/gpt-6.1-sol', provider: 'openrouter'),
        option('models/gemini-3.8-flash', provider: 'google'),
        option('claude-opus-5-5', provider: 'anthropic'),
      ]),
      hasLength(3),
    );
  });

  test('explicit upstream recommendation hints replace curated fallback', () {
    final preferred = option('provider-new', recommended: true);
    final curated = option('gpt-6.1-sol');
    final defaults = option('provider-default', isDefault: true);
    final popular = option('provider-popular', popular: true);
    expect(hermesRecommendedModels([preferred, curated, defaults, popular]), [
      defaults,
      preferred,
      popular,
    ]);
  });

  test('ranked upstream recommendations retain stable ties', () {
    final a = option('a', recommended: true, rank: 3);
    final b = option('b', recommended: true, rank: 1);
    final c = option('c', popular: true, rank: 1);
    expect(hermesRecommendedModels([a, b, c]), [b, c, a]);
  });

  test('explicit false cannot be promoted by default, rank, or curation', () {
    final declined = option(
      'gpt-6.1-sol',
      recommended: false,
      isDefault: true,
      rank: 0,
    );
    expect(hermesRecommendedModels([declined]), isEmpty);
    expect(
      hermesRecommendedModels(
        [declined],
        providerRecommendedDefaults: {'openai-codex': 'gpt-6.1-sol'},
      ),
      isEmpty,
    );
  });

  test(
    'live provider recommendation takes priority and must be in catalog',
    () {
      final live = option('new-provider-default');
      final curated = option('gpt-6.1-sol');
      expect(
        hermesRecommendedModels(
          [curated, live],
          providerRecommendedDefaults: {'openai-codex': live.id},
        ),
        [live],
      );
      expect(
        hermesRecommendedModels(
          [curated],
          providerRecommendedDefaults: {'openai-codex': 'not-advertised'},
        ),
        isEmpty,
      );
    },
  );

  test(
    'retiring and retired models remain catalog entries, not recommended',
    () {
      final now = DateTime.utc(2026, 10, 11);
      final retiring = option(
        'retiring',
        recommended: true,
        shutdownAt: DateTime.utc(2027),
      );
      final retired = option('retired', recommended: true, retired: true);
      final past = option(
        'past',
        recommended: true,
        shutdownAt: DateTime.utc(2026),
      );
      final deprecated = option(
        'deprecated',
        recommended: true,
        deprecated: true,
      );
      final input = [retiring, retired, past, deprecated];
      expect(hermesRecommendedModels(input, now: now), isEmpty);
      expect(input, hasLength(4));
      expect(retiring.isRetiredAt(now), false);
      expect(retired.isRetiredAt(now), true);
      expect(past.isRetiredAt(now), true);
    },
  );

  test('recommendation metadata applies within its provider only', () {
    final marked = option(
      'selected',
      provider: 'custom:one',
      recommended: true,
    );
    final other = option('gpt-6.1-sol');
    expect(hermesRecommendedModels([marked, other]), [marked, other]);
  });
}

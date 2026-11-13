import 'package:conduit_core/features/chat/services/quick_pill_catalog.dart';
import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:test/test.dart';

void main() {
  const tools = [
    Tool(id: 'weather', name: 'Weather'),
    Tool(id: 'calculator', name: 'Calculator'),
  ];
  const filters = [ToggleFilter(id: 'translate', name: 'Translate')];

  test('lists web, image, the tools, then the filters', () {
    final pills = quickPillCandidates(tools: tools, filters: filters);
    expect(pills.map((p) => p.id), [
      'web',
      'image',
      'weather',
      'calculator',
      'filter:translate',
    ]);
    expect(pills.map((p) => p.kind), [
      QuickPillKind.web,
      QuickPillKind.image,
      QuickPillKind.tool,
      QuickPillKind.tool,
      QuickPillKind.filter,
    ]);
    expect(pills.last.name, 'Translate');
    expect(pills.first.name, isEmpty);
  });

  test('keeps only pills on offer, in order and up to the limit', () {
    final pills = quickPillCandidates(tools: tools, filters: filters);
    expect(
      availableQuickPills([
        'filter:translate',
        'gone',
        'web',
        'translate',
      ], pills),
      ['filter:translate', 'web'],
    );
    expect(availableQuickPills(['web', 'image', 'weather'], pills, max: 2), [
      'web',
      'image',
    ]);
  });

  group('the composer', () {
    test('draws the chosen pills it can turn on, in their order', () {
      final pills = composerQuickPills(
        ['filter:translate', 'image', 'weather', 'web'],
        webSearchAvailable: true,
        imageGenerationAvailable: true,
        tools: tools,
        filters: filters,
      );
      expect(pills.map((p) => p.id), [
        'filter:translate',
        'image',
        'weather',
        'web',
      ]);
      expect(pills.map((p) => p.targetId), ['translate', '', 'weather', '']);
      expect(pills.first.name, 'Translate');
    });

    test('leaves out a pill with nothing to turn on', () {
      final pills = composerQuickPills(
        ['web', 'image', 'filter:gone', 'gone', 'filter:', 'calculator'],
        webSearchAvailable: false,
        imageGenerationAvailable: false,
        tools: tools,
        filters: filters,
      );
      expect(pills.map((p) => p.id), ['calculator']);
    });

    test('an unavailable web pill falls back to a tool of that id', () {
      final pills = composerQuickPills(
        ['web'],
        webSearchAvailable: false,
        imageGenerationAvailable: false,
        tools: const [Tool(id: 'web', name: 'Web Reader')],
      );
      expect(pills.single.kind, QuickPillKind.tool);
      expect(pills.single.name, 'Web Reader');
    });

    test('reads a filter id out of a pill id', () {
      expect(quickPillFilterIdFrom('filter:translate'), 'translate');
      expect(quickPillFilterIdFrom('filter:'), isNull);
      expect(quickPillFilterIdFrom('weather'), isNull);
    });
  });
}

import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

Widget selector({
  ValueChanged<CompactModelChoice>? onModel,
  ValueChanged<String>? onEffort,
  String effort = 'high',
  bool busy = false,
  String model = 'GPT-6.1 Sol',
  String provider = 'OpenAI Codex',
  String? selectedModelId,
  String? currentProviderId,
  bool enableRecommendations = false,
  bool recommendationsLoading = false,
  String? status,
  List<CompactModelChoice>? choices,
}) => CompactModelSelector(
  model: model,
  provider: provider,
  selectedModelId: selectedModelId,
  currentProviderId: currentProviderId,
  enableRecommendations: enableRecommendations,
  recommendationsLoading: recommendationsLoading,
  status: status,
  choices:
      choices ??
      const [
        CompactModelChoice('sol', 'GPT-6.1 Sol', 'codex', 'OpenAI Codex'),
        CompactModelChoice('opus', 'Opus', 'anthropic', 'Anthropic'),
      ],
  efforts: const ['low', 'medium', 'high', 'xhigh'],
  effort: effort,
  fast: false,
  fastAvailable: true,
  busy: busy,
  onModel: onModel ?? (_) {},
  onEffort: onEffort ?? (_) {},
  onFast: () {},
  onReset: () {},
  resetLabel: 'Use global model',
);
Future<void> mount(
  WidgetTester tester, {
  bool reduced = false,
  bool inline = false,
  double scale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.dark(TweakcnThemes.conduit),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(360, 800),
        disableAnimations: reduced,
        textScaler: TextScaler.linear(scale),
      ),
      child: Scaffold(
        body: Column(
          children: [
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: inline
                  ? selector()
                  : CompactModelPopover(
                      label: 'Global model',
                      child: selector(),
                    ),
            ),
          ],
        ),
      ),
    ),
  ),
);
void main() {
  const catalog = [
    CompactModelChoice(
      'sol',
      'GPT Sol',
      'codex',
      'OpenAI Codex',
      recommended: true,
    ),
    CompactModelChoice('luna', 'GPT Luna', 'codex', 'OpenAI Codex'),
    CompactModelChoice('old', 'Older GPT', 'codex', 'OpenAI Codex'),
    CompactModelChoice('opus', 'Opus', 'anthropic', 'Anthropic'),
    CompactModelChoice('haiku', 'Haiku', 'anthropic', 'Anthropic'),
  ];

  Future<void> mountCatalog(
    WidgetTester tester, {
    String model = 'GPT Luna',
    String selectedModelId = 'luna',
    String currentProviderId = 'codex',
    List<CompactModelChoice> choices = catalog,
    double scale = 1,
    bool busy = false,
    bool recommendationsLoading = false,
    String? status,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(TweakcnThemes.conduit),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SizedBox(
            width: 260,
            child: selector(
              model: model,
              choices: choices,
              selectedModelId: selectedModelId,
              currentProviderId: currentProviderId,
              enableRecommendations: true,
              busy: busy,
              recommendationsLoading: recommendationsLoading,
              status: status,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('the lightning control identifies ChatGPT Fast mode', (
    tester,
  ) async {
    await mountCatalog(tester);
    expect(
      find.byTooltip('Turn on ChatGPT Fast mode · May cost more'),
      findsOneWidget,
    );
    expect(find.byTooltip('Turn on speed mode · May cost more'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(TweakcnThemes.conduit),
        home: Scaffold(
          body: selector(provider: 'Anthropic', currentProviderId: 'anthropic'),
        ),
      ),
    );
    expect(find.byTooltip('Turn on Fast mode · May cost more'), findsOneWidget);
    expect(
      find.byTooltip('Turn on ChatGPT Fast mode · May cost more'),
      findsNothing,
    );
  });

  testWidgets('busy model controls still allow catalog and provider browsing', (
    tester,
  ) async {
    await mountCatalog(tester, busy: true);
    await tester.tap(find.text('GPT Luna'));
    await tester.pump();
    expect(find.text('All supported models'), findsOneWidget);
    await tester.tap(find.text('All supported models'));
    await tester.pump();
    expect(find.text('Older GPT'), findsOneWidget);
    await tester.tap(find.text('Change provider ›'));
    await tester.pump();
    expect(find.text('Anthropic'), findsOneWidget);
    await tester.tap(find.text('Anthropic'));
    await tester.pump();
    expect(find.text('Opus'), findsOneWidget);
    final option = tester.widget<TextButton>(
      find.ancestor(of: find.text('Opus'), matching: find.byType(TextButton)),
    );
    expect(option.onPressed, isNull);
  });

  testWidgets(
    'late hints and reply status preserve the catalog being browsed',
    (tester) async {
      final unranked = [
        for (final c in catalog)
          CompactModelChoice(c.id, c.name, c.provider, c.providerName),
      ];
      await mountCatalog(
        tester,
        choices: unranked,
        recommendationsLoading: true,
      );
      await tester.tap(find.text('GPT Luna'));
      await tester.pump();
      final header = tester.getRect(find.text('Change provider ›'));
      expect(find.text('Older GPT'), findsOneWidget);
      await mountCatalog(tester, busy: true, status: 'Changes after reply');
      await tester.pump();
      expect(tester.getRect(find.text('Change provider ›')), header);
      expect(find.text('Older GPT'), findsOneWidget);
      expect(find.text('Changes after reply'), findsOneWidget);
    },
  );

  testWidgets(
    'recommendations include the current model and can show the full catalog',
    (tester) async {
      await mountCatalog(tester);
      await tester.tap(find.text('GPT Luna'));
      await tester.pump();
      expect(find.text('Recommended'), findsOneWidget);
      expect(find.text('GPT Sol'), findsOneWidget);
      expect(find.text('GPT Luna'), findsOneWidget);
      expect(find.text('Older GPT'), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.tap(find.text('All supported models'));
      await tester.pump();
      expect(find.text('Older GPT'), findsOneWidget);
      expect(find.text('Recommended models'), findsOneWidget);
      await tester.tap(find.text('Recommended models'));
      await tester.pump();
      expect(find.text('Older GPT'), findsNothing);
      expect(find.text('GPT Luna'), findsOneWidget);
    },
  );

  testWidgets(
    'all configured providers remain available with an honest unranked fallback',
    (tester) async {
      await mountCatalog(tester);
      await tester.tap(find.text('GPT Luna'));
      await tester.pump();
      await tester.tap(find.text('Change provider ›'));
      await tester.pump();
      expect(find.text('Anthropic'), findsOneWidget);
      expect(find.text('OpenAI Codex'), findsOneWidget);
      await tester.tap(find.text('Anthropic'));
      await tester.pump();
      expect(find.text('Opus'), findsOneWidget);
      expect(find.text('Haiku'), findsOneWidget);
      expect(find.text('GPT Sol'), findsNothing);
      expect(find.text('All supported models'), findsOneWidget);
      expect(find.text('No recommendations available'), findsOneWidget);
      expect(find.text('Recommended'), findsNothing);
    },
  );

  testWidgets(
    'catalog identity identifies a renamed current model independently of its display label',
    (tester) async {
      await mountCatalog(tester, model: 'Saved model name');
      await tester.tap(find.text('Saved model name'));
      await tester.pump();
      expect(find.text('GPT Luna'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.text('Older GPT'), findsNothing);
    },
  );

  testWidgets(
    'a missing catalog selection remains a label without inventing a selectable option',
    (tester) async {
      await mountCatalog(
        tester,
        model: 'Unavailable model',
        selectedModelId: 'missing',
      );
      await tester.tap(find.text('Unavailable model'));
      await tester.pump();
      expect(find.text('GPT Sol'), findsOneWidget);
      expect(find.text('Unavailable model'), findsOneWidget);
      expect(find.text('Current model · not in catalog'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('Unavailable model'),
          matching: find.byType(TextButton),
        ),
        findsNothing,
      );
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      await tester.tap(find.text('All supported models'));
      await tester.pump();
      expect(find.text('Unavailable model'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      expect(find.text('Unavailable model'), findsOneWidget);
    },
  );

  testWidgets(
    'matching names and IDs in different providers retain the owning provider',
    (tester) async {
      await mountCatalog(
        tester,
        model: 'Shared model',
        selectedModelId: 'shared',
        currentProviderId: 'second',
        choices: const [
          CompactModelChoice(
            'shared',
            'Shared model',
            'first',
            'Shared provider',
            recommended: true,
          ),
          CompactModelChoice(
            'first-only',
            'First provider model',
            'first',
            'Shared provider',
            recommended: true,
          ),
          CompactModelChoice(
            'shared',
            'Shared model',
            'second',
            'Shared provider',
            recommended: true,
          ),
          CompactModelChoice(
            'second-only',
            'Second provider model',
            'second',
            'Shared provider',
            recommended: true,
          ),
        ],
      );
      await tester.tap(find.text('Shared model'));
      await tester.pump();
      expect(find.text('Second provider model'), findsOneWidget);
      expect(find.text('First provider model'), findsNothing);
      expect(find.text('Shared model'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    },
  );

  testWidgets(
    'an unavailable current provider stays readonly while configured providers remain selectable',
    (tester) async {
      await mountCatalog(
        tester,
        model: 'Unavailable model',
        selectedModelId: 'missing',
        currentProviderId: 'unconfigured',
      );
      await tester.tap(find.text('Unavailable model'));
      await tester.pump();
      expect(find.text('Unavailable model'), findsOneWidget);
      expect(find.text('GPT Sol'), findsNothing);
      await tester.tap(find.text('Change provider ›'));
      await tester.pump();
      expect(find.text('OpenAI Codex'), findsOneWidget);
      expect(find.text('Anthropic'), findsOneWidget);
      expect(find.text('unconfigured'), findsNothing);
      await tester.tap(find.text('OpenAI Codex'));
      await tester.pump();
      expect(find.text('GPT Sol'), findsOneWidget);
      expect(find.text('Unavailable model'), findsNothing);
    },
  );

  testWidgets(
    'full catalog control stays visible beside a long recommended list at larger text sizes',
    (tester) async {
      await mountCatalog(
        tester,
        scale: 1.5,
        choices: [
          ...catalog,
          for (var i = 0; i < 12; i++)
            CompactModelChoice(
              'extra-$i',
              'Recommended model $i',
              'codex',
              'OpenAI Codex',
              recommended: true,
            ),
        ],
      );
      await tester.tap(find.text('GPT Luna'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('All supported models'));
      await tester.pump();
      expect(find.text('Recommended models'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('inline selector fades without changing composer layout', (
    tester,
  ) async {
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Column(
              children: [
                CompactModelReveal(
                  visible: visible,
                  child: const SizedBox(
                    key: ValueKey('trigger'),
                    width: 100,
                    height: 48,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    update(() => visible = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final reveal = find.byType(CompactModelReveal);
    expect(tester.getSize(reveal).height, 48);
    expect(
      tester
          .widget<Opacity>(
            find.descendant(of: reveal, matching: find.byType(Opacity)),
          )
          .opacity,
      inExclusiveRange(0, 1),
    );
    expect(find.byKey(const ValueKey('trigger')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.getSize(reveal).height, 48);
    update(() => visible = true);
    await tester.pumpAndSettle();
    expect(tester.getSize(reveal).height, 48);
  });
  testWidgets('a system Back edge does not dismiss the panel on pointer down', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            systemGestureInsets: EdgeInsets.symmetric(horizontal: 24),
          ),
          child: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                CompactModelPopover(label: 'Model', child: selector()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(1, 100));
    await gesture.moveTo(const Offset(100, 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(CompactModelSelector), findsOneWidget);
    await tester.tapAt(const Offset(500, 100));
    await tester.pumpAndSettle();
    expect(find.byType(CompactModelSelector), findsNothing);
  });

  testWidgets('the owning shell can dismiss an open model panel', (
    tester,
  ) async {
    VoidCallback? dismiss;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              CompactModelPopover(
                label: 'Model',
                onDismissChanged: (callback) => dismiss = callback,
                child: selector(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    expect(dismiss, isNotNull);
    dismiss!();
    expect(dismiss, isNull);
    await tester.pumpAndSettle();
    expect(find.byType(CompactModelSelector), findsNothing);
  });

  testWidgets('hiding a trigger finishes the popup exit at its old position', (
    tester,
  ) async {
    var visible = true;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return Stack(
                children: [
                  Positioned(
                    left: visible ? 16 : 300,
                    bottom: visible ? 16 : 80,
                    child: Visibility(
                      visible: visible,
                      maintainState: true,
                      maintainAnimation: true,
                      child: CompactModelPopover(
                        enabled: visible,
                        label: 'Model',
                        child: selector(),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    final panel = find.byType(CompactModelSelector, skipOffstage: false);
    final left = tester.getTopLeft(panel).dx;
    rebuild(() => visible = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.getTopLeft(panel).dx, closeTo(left, 0.5));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
  });

  testWidgets('Back closes the model panel before navigating the chat', (
    tester,
  ) async {
    var backs = 0;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) backs++;
            },
            child: Scaffold(
              body: Column(
                children: [
                  const Spacer(),
                  CompactModelPopover(label: 'Model', child: selector()),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    expect(backs, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(backs, 1);
  });

  testWidgets('effort stays at the chosen level until the save settles', (
    tester,
  ) async {
    late StateSetter rebuild;
    var busy = false;
    var effort = 'high';
    String? requested;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(TweakcnThemes.conduit),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return selector(
                effort: effort,
                busy: busy,
                onEffort: (value) {
                  requested = value;
                  rebuild(() => busy = true);
                },
              );
            },
          ),
        ),
      ),
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(3);
    slider.onChangeEnd!(3);
    await tester.pump();
    expect(requested, 'xhigh');
    expect(tester.widget<Slider>(find.byType(Slider)).value, 3);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 3);
    rebuild(() {
      effort = 'xhigh';
      busy = false;
    });
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 3);
    // A rejected save restores the server value once, after pending ends.
    final next = tester.widget<Slider>(find.byType(Slider));
    next.onChanged!(0);
    next.onChangeEnd!(0);
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
    rebuild(() => busy = false);
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 3);
  });

  testWidgets('an open model panel lets a chat drag dismiss it and scroll', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ListView(
                controller: scroll,
                children: List.generate(
                  80,
                  (i) => SizedBox(height: 60, child: Text('Message $i')),
                ),
              ),
              Positioned(
                left: 16,
                bottom: 16,
                child: CompactModelPopover(label: 'Model', child: selector()),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    await tester.dragFrom(const Offset(500, 200), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets(
    'chat panel stays narrow, closes without actionable hidden controls, and reverses',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await mount(tester);
      await tester.tap(find.text('Global model'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(tester.getSize(find.byType(CompactModelSelector)).width, 260);
      expect(find.byType(Slider), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.text('Global model')));
      await tester.pump();
      final excluded = tester
          .widgetList<ExcludeSemantics>(find.byType(ExcludeSemantics))
          .any((w) => w.excluding);
      expect(excluded, isTrue);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.text('Global model'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.text('Global model')));
      await tester.pumpAndSettle();
      expect(find.byType(CompactModelSelector), findsNothing);
      semantics.dispose();
    },
  );
  testWidgets(
    'reduced motion completes immediately and global surface uses available width',
    (tester) async {
      await mount(tester, reduced: true);
      await tester.tap(find.text('Global model'));
      await tester.pump();
      expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);
      await tester.tapAt(tester.getCenter(find.text('Global model')));
      await tester.pump();
      expect(find.byType(CompactModelSelector), findsNothing);
      await mount(tester, inline: true, scale: 1.5);
      expect(
        tester.getSize(find.byType(CompactModelSelector)).width,
        greaterThan(260),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('provider change exposes only its configured models', (
    tester,
  ) async {
    CompactModelChoice? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(TweakcnThemes.conduit),
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: selector(onModel: (value) => picked = value),
          ),
        ),
      ),
    );
    await tester.tap(find.text('GPT-6.1 Sol'));
    await tester.pump();
    expect(find.text('Opus'), findsNothing);
    await tester.tap(find.text('Change provider ›'));
    await tester.pump();
    await tester.tap(find.text('Anthropic'));
    await tester.pump();
    await tester.tap(find.text('Opus'));
    expect(picked?.provider, 'anthropic');
    expect(picked?.id, 'opus');
  });
}

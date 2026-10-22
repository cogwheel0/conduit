import 'dart:async';

import 'package:conduit/features/hermes/providers/hermes_agent_settings_provider.dart';
import 'package:conduit/features/hermes/views/hermes_agent_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit_core/features/hermes/models/hermes_agent_settings.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final fixture = HermesAgentSettings(
  config: {
    'model': {'default': 'main-model', 'provider': 'example'},
    'agent': {'reasoning_effort': 'medium'},
    'memory': {
      'memory_enabled': true,
      'memory_char_limit': 2000,
      'provider': '',
    },
    'terminal': {
      'env_passthrough': ['LANG'],
    },
    'fallback_providers': [
      {'model': 'backup-model', 'provider': 'example'},
    ],
  },
  schema: {
    'memory.memory_enabled': {'type': 'boolean'},
    'memory.memory_char_limit': {'type': 'number', 'min': 1, 'max': 10000},
    'memory.provider': {
      'type': 'select',
      'options': ['', 'mnemosyne'],
    },
    'terminal.env_passthrough': {'type': 'list'},
    'fallback_providers': {'type': 'list'},
  },
  auxiliary: [
    {
      'task': 'vision',
      'provider': 'auto',
      'effective': {'model': 'image-model', 'provider': 'example'},
    },
  ],
  supportsGlobalModel: true,
  ensembles: {
    'default_preset': 'default',
    'presets': {
      'default': {
        'enabled': false,
        'reference_models': [
          {'provider': 'example', 'model': 'answer-model'},
        ],
        'aggregator': {'provider': 'example', 'model': 'final-model'},
      },
    },
  },
);

class _Service implements HermesAgentSettingsAccess {
  _Service({this.settings});
  final HermesAgentSettings? settings;
  final writes = <Object>[];
  Completer<List<HermesDesktopModelOption>>? pendingModels;
  @override
  Future<void> setModelEnsembles(
    Map<String, dynamic> settings,
    Map<String, dynamic> expected,
  ) async {
    writes.add(settings);
  }

  @override
  Future<HermesAgentSettings> agentSettings() async => settings ?? fixture;
  @override
  Future<void> setAgentSetting(HermesSettingField field, Object? value) async {
    writes.add((field.path, value));
  }

  @override
  Future<List<HermesDesktopModelOption>> configuredModels() async =>
      pendingModels == null
      ? [
          const HermesDesktopModelOption(
            id: 'main-model',
            name: 'Current model',
            provider: 'example',
            supportsFast: true,
            supportsReasoning: true,
            supportedEfforts: ['low', 'medium', 'high'],
          ),
          const HermesDesktopModelOption(
            id: 'new-model',
            name: 'New model',
            provider: 'example',
            supportsFast: false,
            supportsReasoning: true,
          ),
        ]
      : pendingModels!.future;
  @override
  Future<void> setDefaultModel(
    HermesDesktopModelOption model, {
    String? task,
  }) async {
    writes.add(('model', model.id, task));
  }

  @override
  Future<void> setFallbackModels(
    List<Map<String, dynamic>> models,
    Object? expected,
  ) async {
    writes.add(models);
  }

  @override
  Future<void> setAuxiliaryReasoning({
    required String task,
    required String provider,
    required String model,
    String? effort,
    String? baseUrl,
  }) async {
    writes.add(('reasoning', task, effort, provider, model, baseUrl));
  }

  @override
  Future<void> useGlobalModel(String task) async {
    writes.add(('global', task));
  }

  @override
  Future<void> resetAuxiliaryModel(String task) async {
    writes.add(('reset', task));
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Service service, {
  String? section,
  double scale = 1,
  bool dark = true,
}) async {
  final container = ProviderContainer(
    overrides: [hermesAgentSettingsAccessProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: dark
            ? AppTheme.dark(TweakcnThemes.conduit)
            : AppTheme.light(TweakcnThemes.conduit),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: HermesAgentSettingsPage(section: section),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _openCustomization(WidgetTester tester) async {
  if (find.text('Image analysis').evaluate().isNotEmpty) return;
  await tester.ensureVisible(find.text('Customize Hermes'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Customize Hermes'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('hub groups supported settings and keeps connection separate', (
    tester,
  ) async {
    await _pump(tester, _Service());
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Safety'), findsNothing);
    expect(find.text('Tools and integrations'), findsOneWidget);
    expect(find.text('Persistent memory'), findsNothing);
  });
  testWidgets('switch and numeric editor save deliberate typed values', (
    tester,
  ) async {
    final service = _Service();
    await _pump(tester, service, section: 'Memory');
    await tester.tap(find.byType(AdaptiveSwitch));
    await tester.pumpAndSettle();
    expect(service.writes, [('memory.memory_enabled', false)]);
    await tester.tap(find.text('Memory budget'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('setting-custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('setting-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(AdaptiveTextField), '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid value.'), findsOneWidget);
    expect(service.writes.length, 1);
    await tester.enterText(find.byType(AdaptiveTextField), '3000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.writes.last, ('memory.memory_char_limit', 3000));
  });
  testWidgets('cancel does not save and an empty list can be saved', (
    tester,
  ) async {
    final service = _Service();
    await _pump(tester, service, section: 'Workspace');
    await tester.tap(find.text('Environment passthrough'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(AdaptiveTextField), 'PRIVATE');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.writes, isEmpty);
    await tester.tap(find.text('Environment passthrough'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(AdaptiveTextField), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final write = service.writes.single as (String, Object?);
    expect(write.$1, 'terminal.env_passthrough');
    expect(write.$2, isEmpty);
  });
  testWidgets(
    'global and task-specific model choices target the correct scope',
    (tester) async {
      final service = _Service();
      await _pump(tester, service, section: 'Models');
      await tester.tap(find.text('Current model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New model'));
      await tester.pumpAndSettle();
      expect(service.writes.single, ('model', 'new-model', null));
      await _openCustomization(tester);
      await tester.ensureVisible(find.text('Image analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Image analysis'));
      await tester.pumpAndSettle();
      expect(find.text('Use main model'), findsNothing);
      expect(find.text('Reads images and screenshots.'), findsWidgets);
      expect(
        find.byKey(const ValueKey('auxiliary-model-setting')),
        findsOneWidget,
      );
      expect(find.text('Automatic · image-model · example'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('auxiliary-model-setting')));
      await tester.pumpAndSettle();
      final automatic = tester.widget<UtilityRow>(
        find
            .ancestor(
              of: find.text('Automatic'),
              matching: find.byType(UtilityRow),
            )
            .first,
      );
      expect(automatic.selected, isTrue);
      await tester.tap(find.text('Custom model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('example').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New model'));
      await tester.pumpAndSettle();
      expect(service.writes.last, ('model', 'new-model', 'vision'));
    },
  );
  testWidgets(
    'automatic task routing preserves reasoning and canceled edits do not save',
    (tester) async {
      final service = _Service(
        settings: HermesAgentSettings(
          config: fixture.config,
          schema: fixture.schema,
          auxiliary: [
            {
              'task': 'vision',
              'provider': 'example',
              'model': 'custom-image-model',
              'reasoning_effort': 'high',
              'base_url': 'https://example.test',
            },
          ],
        ),
      );
      await _pump(tester, service, section: 'Models');
      await _openCustomization(tester);
      await tester.ensureVisible(find.text('Image analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Image analysis'));
      await tester.pumpAndSettle();
      expect(find.text('High'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auxiliary-model-setting')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(service.writes, isEmpty);
      await tester.tap(find.text('Image analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auxiliary-model-setting')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Automatic'));
      await tester.pumpAndSettle();
      expect(service.writes.single, (
        'reasoning',
        'vision',
        'high',
        'auto',
        '',
        null,
      ));
    },
  );

  testWidgets(
    'setting labels, values and picker headings have separate roles',
    (tester) async {
      await _pump(tester, _Service(), section: 'Memory');
      final row = tester.widget<UtilityRow>(
        find.byKey(const ValueKey('memory.memory_char_limit')),
      );
      expect(row.title, 'Memory budget');
      expect(row.value, '2,000 characters');
      expect(
        tester.getTopLeft(find.text('2,000 characters')).dx,
        greaterThan(tester.getTopLeft(find.text('Memory budget')).dx),
      );
      await tester.tap(find.text('Memory provider'));
      await tester.pumpAndSettle();
      final heading = tester.widget<Text>(find.text('Memory provider').last);
      final choice = tester.widget<Text>(find.text('mnemosyne'));
      expect(heading.style!.fontSize, greaterThan(choice.style!.fontSize!));
      expect(choice.style!.fontWeight, FontWeight.w400);
      final defaultChoice = tester.widget<UtilityRow>(
        find
            .ancestor(
              of: find.text('Default').last,
              matching: find.byType(UtilityRow),
            )
            .first,
      );
      expect(defaultChoice.selected, isTrue);
    },
  );

  testWidgets('model pickers mark the current provider and model', (
    tester,
  ) async {
    final service = _Service(
      settings: HermesAgentSettings(
        config: {
          'model': {'default': 'new-model', 'provider': 'example'},
        },
        schema: fixture.schema,
      ),
    );
    await _pump(tester, service, section: 'Models');
    await tester.tap(find.text('New model'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(service.writes, isEmpty);
  });

  testWidgets(
    'a pinned automatic endpoint does not offer an ineffective reset',
    (tester) async {
      final service = _Service(
        settings: HermesAgentSettings(
          config: fixture.config,
          schema: fixture.schema,
          auxiliary: [
            {
              'task': 'vision',
              'provider': 'auto',
              'base_url': 'https://example.test',
            },
          ],
        ),
      );
      await _pump(tester, service, section: 'Models');
      await _openCustomization(tester);
      await tester.ensureVisible(find.text('Image analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Image analysis'));
      await tester.pumpAndSettle();
      expect(find.text('Custom endpoint'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('auxiliary-model-setting')));
      await tester.pumpAndSettle();
      final automatic = tester.widget<UtilityRow>(
        find.ancestor(
          of: find.text('Automatic'),
          matching: find.byType(UtilityRow),
        ),
      );
      expect(automatic.enabled, isFalse);
      expect(find.text('Custom model'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(service.writes, isEmpty);
    },
  );

  testWidgets(
    'task sheet and general editors fit 200 percent text in both themes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final dark in [false, true]) {
        await _pump(
          tester,
          _Service(),
          section: 'Models',
          scale: 2,
          dark: dark,
        );
        await _openCustomization(tester);
        await tester.ensureVisible(find.text('Image analysis'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Image analysis'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('auxiliary-reasoning-setting')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await _pump(
          tester,
          _Service(),
          section: 'Memory',
          scale: 2,
          dark: dark,
        );
        await tester.tap(find.text('Memory budget'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Starting points'), findsOneWidget);
        expect(find.byType(AdaptiveTextField), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'global choice saves inheritance and shows current global reasoning',
    (tester) async {
      final service = _Service();
      await _pump(tester, service, section: 'Models');
      expect(find.text('Image analysis'), findsNothing);
      await _openCustomization(tester);
      await tester.ensureVisible(find.text('Image analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Image analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auxiliary-model-setting')));
      await tester.pumpAndSettle();
      expect(find.text('Use global model'), findsOneWidget);
      expect(find.text('Automatic'), findsOneWidget);
      expect(find.text('Custom model'), findsOneWidget);
      await tester.tap(find.text('Use global model'));
      await tester.pumpAndSettle();
      expect(service.writes, [('global', 'vision')]);
      await tester.pumpWidget(const SizedBox.shrink());
      final inherited = _Service(
        settings: HermesAgentSettings(
          config: fixture.config,
          schema: fixture.schema,
          supportsGlobalModel: true,
          auxiliary: [
            {'task': 'vision', 'provider': 'global'},
          ],
        ),
      );
      await _pump(tester, inherited, section: 'Models');
      await _openCustomization(tester);
      await tester.ensureVisible(find.text('Image analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Image analysis'));
      await tester.pumpAndSettle();
      final reasoning = tester.widget<UtilityRow>(
        find.byKey(const ValueKey('auxiliary-reasoning-setting')),
      );
      expect(reasoning.value, 'Medium');
      expect(reasoning.onTap, isNull);
      expect(
        find.text('Use global model · main-model · example'),
        findsWidgets,
      );
      expect(inherited.writes, isEmpty);
    },
  );

  testWidgets('switching connections while a picker loads prevents writes', (
    tester,
  ) async {
    final service = _Service()..pendingModels = Completer();
    final container = await _pump(tester, service, section: 'Models');
    expect(find.text('Loading models…'), findsOneWidget);
    container.updateOverrides([
      hermesAgentSettingsAccessProvider.overrideWithValue(_Service()),
    ]);
    service.pendingModels!.complete([
      const HermesDesktopModelOption(
        id: 'new',
        name: 'New',
        provider: 'example',
        supportsFast: false,
        supportsReasoning: false,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Choose provider'), findsNothing);
    expect(service.writes, isEmpty);
  });
  testWidgets('model rows fit large text on a narrow screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _Service(), section: 'Models', scale: 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'global reasoning slider and auxiliary choice sheet target the correct scope',
    (tester) async {
      final service = _Service();
      await _pump(tester, service, section: 'Models');
      final slider = find.byType(Slider);
      await tester.tapAt(tester.getTopRight(slider) + const Offset(-24, 24));
      await tester.pumpAndSettle();
      expect(service.writes.last, ('agent.reasoning_effort', 'high'));
      await _openCustomization(tester);
      await tester.ensureVisible(find.text('Image analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Image analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reasoning effort'));
      await tester.pumpAndSettle();
      final inheritedReasoning = tester.widget<UtilityRow>(
        find.ancestor(
          of: find.text('Default').last,
          matching: find.byType(UtilityRow),
        ),
      );
      expect(inheritedReasoning.selected, isTrue);
      await tester.tap(find.text('Low'));
      await tester.pumpAndSettle();
      expect(service.writes.last, (
        'reasoning',
        'vision',
        'low',
        'auto',
        '',
        null,
      ));
    },
  );
  testWidgets(
    'ensemble controls save the selected preset and canceled model pickers do not write',
    (tester) async {
      final service = _Service();
      await _pump(tester, service, section: 'ensembles');
      expect(find.text('Answer models'), findsOneWidget);
      expect(find.text('answer-model'), findsOneWidget);
      expect(find.text('final-model · example'), findsOneWidget);
      await tester.tap(find.byType(AdaptiveSwitch));
      await tester.pumpAndSettle();
      final saved = service.writes.single as Map;
      expect(((saved['presets'] as Map)['default'] as Map)['enabled'], true);
      await tester.tap(find.text('Add answer model'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(service.writes.length, 1);
    },
  );
  testWidgets(
    'preset selection is pending until Save and cancellation preserves memory',
    (tester) async {
      final service = _Service();
      await _pump(tester, service, section: 'Memory');
      await tester.tap(find.text('Memory budget'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setting-preset-4400')));
      await tester.pumpAndSettle();
      expect(service.writes, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.writes, isEmpty);
      await tester.tap(find.text('Memory budget'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setting-preset-2200')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(service.writes.single, ('memory.memory_char_limit', 2200));
    },
  );

  testWidgets('percent custom input rejects 200 percent and persists a ratio', (
    tester,
  ) async {
    final data = HermesAgentSettings(
      config: {
        'compression': {'threshold': .5},
      },
      schema: {
        'compression.threshold': {'type': 'number'},
      },
    );
    final service = _Service(settings: data);
    await _pump(tester, service, section: 'Context');
    expect(find.text('50%'), findsOneWidget);
    await tester.tap(find.text('Compression threshold'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('setting-custom')));
    await tester.tap(find.byKey(const ValueKey('setting-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(AdaptiveTextField), '200');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.writes, isEmpty);
    expect(find.text('Enter a valid value.'), findsOneWidget);
    await tester.enterText(find.byType(AdaptiveTextField), '75');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.writes.single, ('compression.threshold', .75));
  });

  testWidgets('voice catalog preserves a custom voice and saves provider ID', (
    tester,
  ) async {
    final data = HermesAgentSettings(
      config: {
        'tts': {
          'provider': 'xai',
          'xai': {'voice_id': 'my-account-voice'},
        },
      },
      schema: {
        'tts.xai.voice_id': {'type': 'string'},
      },
    );
    final service = _Service(settings: data);
    await _pump(tester, service, section: 'Speech output');
    await tester.tap(find.text('Voice'));
    await tester.pumpAndSettle();
    expect(find.text('Current value: my-account-voice'), findsOneWidget);
    expect(find.byType(AdaptiveTextField), findsNothing);
    await tester.tap(find.byKey(const ValueKey('setting-preset-eve')));
    await tester.pumpAndSettle();
    expect(service.writes, isEmpty);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.writes.single, ('tts.xai.voice_id', 'eve'));
  });

  testWidgets(
    'server numeric bounds filter presets and current value remains visible',
    (tester) async {
      final data = HermesAgentSettings(
        config: {
          'memory': {'memory_char_limit': 3000},
        },
        schema: {
          'memory.memory_char_limit': {
            'type': 'number',
            'min': 100,
            'max': 2500,
          },
        },
      );
      final service = _Service(settings: data);
      await _pump(tester, service, section: 'Memory');
      await tester.tap(find.text('Memory budget'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('setting-preset-4400')), findsNothing);
      expect(find.text('Current value: 3,000 characters'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(service.writes, isEmpty);
    },
  );
  testWidgets(
    'custom editor keeps Save reachable with large text and keyboard',
    (tester) async {
      final service = _Service();
      await _pump(tester, service, section: 'Memory', scale: 2);
      await tester.tap(find.text('Memory budget'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('setting-custom')));
      await tester.tap(find.byKey(const ValueKey('setting-custom')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.writes, isEmpty);
    },
  );
}

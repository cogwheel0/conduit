import 'dart:async';

import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_form.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_sections.dart';
import 'package:conduit/features/hermes/controllers/hermes_connection_controller.dart';
import 'package:conduit/features/hermes/views/hermes_jobs_page.dart';
import 'package:conduit/features/hermes/views/hermes_settings_sections.dart';
import 'package:conduit/features/hermes/widgets/hermes_jobs_sheet.dart';
import 'package:conduit/features/workspace/models/workspace_model_draft.dart';
import 'package:conduit/features/workspace/views/models/workspace_model_advanced_section.dart';
import 'package:conduit/features/workspace/views/models/workspace_model_editor_controller.dart';
import 'package:conduit/features/workspace/views/prompts/workspace_prompt_editor_sections.dart';
import 'package:conduit/features/workspace/widgets/workspace_valve_form.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_toolset.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  for (final configuration in [
    (platform: TargetPlatform.android, native: false),
    (platform: TargetPlatform.iOS, native: false),
    (platform: TargetPlatform.iOS, native: true),
  ]) {
    group('${configuration.platform} native=${configuration.native}', () {
      setUp(() {
        stubNativePlatformViews();
        PlatformUiCapabilities.debugPlatformOverride = configuration.platform;
        PlatformUiCapabilities.debugIOSMajorVersionOverride =
            configuration.native ? 27 : 18;
        PlatformUiCapabilities.debugNativeIOS26Override = configuration.native;
      });

      for (final compact in [false, true]) {
        testWidgets('direct availability has one actionable label ($compact)', (
          tester,
        ) async {
          final form = DirectConnectionEditorForm(
            mode: const DirectConnectionEditorMode.create(),
          );
          addTearDown(form.dispose);
          await _pump(
            tester,
            compact
                ? DirectConnectionGeneralSection(form: form)
                : DirectConnectionAvailabilitySection(form: form),
          );
          _expectSwitch(
            tester,
            _l10n(tester).enabledLabel,
            true,
            rowOwnsSemantics: compact,
          );
        }, variant: TargetPlatformVariant.only(configuration.platform));
      }

      for (final sheet in [false, true]) {
        testWidgets('job name labels only its switch ($sheet)', (tester) async {
          await _pump(
            tester,
            sheet ? const HermesJobsSheet() : const HermesJobsPage(),
          );
          _expectSwitch(tester, 'Orbit check', true);
        }, variant: TargetPlatformVariant.only(configuration.platform));

        testWidgets('busy job retains its name ($sheet)', (tester) async {
          final jobs = _Jobs();
          await _pump(
            tester,
            sheet ? const HermesJobsSheet() : const HermesJobsPage(),
            jobs: jobs,
          );
          tester.widget<AdaptiveSwitch>(find.byType(AdaptiveSwitch)).onChanged!(
            false,
          );
          await tester.pump();
          expect(find.byType(AdaptiveSwitch), findsNothing);
          expect('Orbit check'.allMatches(_labels(tester)), hasLength(1));
          jobs.toggle.complete();
          await tester.pumpAndSettle();
          _expectSwitch(tester, 'Orbit check', true);
        }, variant: TargetPlatformVariant.only(configuration.platform));
      }

      testWidgets('toolset switch is reachable and announces its state', (
        tester,
      ) async {
        await _pump(tester, const HermesToolsetsSection());
        _expectSwitch(tester, 'Sketch tools', true);
      }, variant: TargetPlatformVariant.only(configuration.platform));

      testWidgets('TLS row announces its toggle state', (tester) async {
        final controller = HermesConnectionController(
          initialConfig: const HermesConfig(),
          gateway: _UnusedGateway(),
        );
        addTearDown(controller.dispose);
        await _pump(tester, HermesTransportSection(controller: controller));
        await tester.tap(find.text(_l10n(tester).hermesGatewayAccessHeaders));
        await tester.pumpAndSettle();
        _expectSwitch(
          tester,
          _l10n(tester).allowSelfSignedCertificates,
          false,
          rowOwnsSemantics: true,
        );
      }, variant: TargetPlatformVariant.only(configuration.platform));

      testWidgets('model capability labels only its switch', (tester) async {
        final controller = WorkspaceModelEditorController(
          mode: WorkspaceRouteMode.create,
          initialDraft: WorkspaceModelDraft.empty()
            ..capabilities = {'Orbit capability': true},
          writeAccess: true,
        )..setAdvancedExpanded(true);
        addTearDown(controller.dispose);
        await _pump(
          tester,
          WorkspaceModelAdvancedSection(controller: controller),
        );
        _expectSwitch(tester, 'Orbit capability', true);
      }, variant: TargetPlatformVariant.only(configuration.platform));

      testWidgets('prompt production labels only its switch', (tester) async {
        final commit = TextEditingController();
        addTearDown(commit.dispose);
        await _pump(
          tester,
          WorkspacePromptVersionSection(
            readOnly: false,
            expanded: true,
            isProduction: true,
            commitController: commit,
            onExpandedChanged: (_) {},
            onCommitChanged: () {},
            onProductionChanged: (_) {},
          ),
        );
        _expectSwitch(tester, _l10n(tester).workspacePromptSetProduction, true);
      }, variant: TargetPlatformVariant.only(configuration.platform));

      for (final required in [false, true]) {
        testWidgets('custom boolean label retains required state ($required)', (
          tester,
        ) async {
          await _pump(
            tester,
            WorkspaceValveForm(
              spec: WorkspaceValveSpec.fromJson({
                'properties': {
                  'badge': {'type': 'boolean', 'title': 'Keep badge'},
                },
                'required': [if (required) 'badge'],
              }),
              initialValues: const {'badge': true},
              onChanged: (_) {},
            ),
          );
          final label = required
              ? 'Keep badge, ${_l10n(tester).workspaceValveRequired}'
              : 'Keep badge';
          _expectSwitch(tester, label, true);
          expect(
            _labels(tester).split('Keep badge').length - 1,
            _hasNativeView(tester) ? 0 : 1,
          );
        }, variant: TargetPlatformVariant.only(configuration.platform));
      }

      for (final customEnum in [false, true]) {
        testWidgets('boolean title remains without a switch ($customEnum)', (
          tester,
        ) async {
          await _pump(
            tester,
            WorkspaceValveForm(
              spec: WorkspaceValveSpec.fromJson({
                'properties': {
                  'badge': {
                    'type': 'boolean',
                    'title': 'Keep badge',
                    if (customEnum) 'enum': [false, true],
                  },
                },
                'required': ['badge'],
              }),
              initialValues: {if (customEnum) 'badge': true},
              onChanged: (_) {},
            ),
          );
          expect(find.byType(AdaptiveSwitch), findsNothing);
          expect('Keep badge'.allMatches(_labels(tester)), hasLength(1));
          expect(
            _labels(tester),
            contains(_l10n(tester).workspaceValveRequired),
          );
        }, variant: TargetPlatformVariant.only(configuration.platform));
      }
    });
  }
}

Future<void> _pump(WidgetTester tester, Widget child, {_Jobs? jobs}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final service = HermesApiService(
    config: const HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      apiKey: 'fixture',
    ),
  );
  addTearDown(service.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hermesConfigProvider.overrideWith(_DesktopConfig.new),
        hermesJobsProvider.overrideWith(() => jobs ?? _Jobs()),
        hermesCapabilitiesProvider.overrideWith(
          (ref) async => const HermesCapabilities(),
        ),
        hermesApiServiceProvider.overrideWithValue(service),
        hermesToolsetsProvider.overrideWith(
          (ref) async => const [
            HermesToolset(name: 'sketch', label: 'Sketch tools'),
          ],
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        builder: (context, child) => LegacyDesignCompatibility(child: child!),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first))!;

String _labels(WidgetTester tester) => tester.semantics
    .simulatedAccessibilityTraversal()
    .map((node) => node.getSemanticsData().label)
    .join('\n');

bool _hasNativeView(WidgetTester tester) => find
    .descendant(of: find.byType(CNSwitch), matching: find.byType(UiKitView))
    .evaluate()
    .isNotEmpty;

void _expectSwitch(
  WidgetTester tester,
  String label,
  bool value, {
  bool rowOwnsSemantics = false,
}) {
  if (_hasNativeView(tester) && !rowOwnsSemantics) {
    expect(tester.widget<CNSwitch>(find.byType(CNSwitch)).semanticLabel, label);
    expect(_labels(tester).contains(label), isFalse);
  } else {
    final nodes = tester.semantics.simulatedAccessibilityTraversal().where(
      (node) => node.getSemanticsData().label.contains(label),
    );
    expect(nodes, hasLength(1), reason: _labels(tester));
    final node = nodes.single;
    expect(label.allMatches(node.getSemanticsData().label), hasLength(1));
    expect(
      node,
      isSemantics(hasToggledState: true, isToggled: value, hasTapAction: true),
    );
  }
}

class _DesktopConfig extends HermesConfigController {
  @override
  HermesConfig build() =>
      const HermesConfig(mode: HermesBackendMode.desktopGateway);
}

class _Jobs extends HermesJobsController {
  final toggle = Completer<void>();

  @override
  Future<List<HermesJob>> build() async => const [
    HermesJob(
      id: 'orbit',
      name: 'Orbit check',
      prompt: '',
      schedule: '0 8 * * *',
    ),
  ];

  @override
  Future<void> setEnabled(String id, bool enabled) => toggle.future;
}

class _UnusedGateway implements HermesConnectionGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

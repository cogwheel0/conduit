import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/widgets/workspace_valve_form.dart';
import 'package:conduit/l10n/app_localizations.dart';

void main() {
  Widget harness(
    WorkspaceValveSpec spec, {
    Map<String, dynamic> initialValues = const {},
    void Function(Map<String, dynamic>)? onChanged,
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkspaceValveForm(
            spec: spec,
            initialValues: initialValues,
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('renders one field per spec property', (tester) async {
    final spec = WorkspaceValveSpec.fromJson(const {
      'properties': {
        'api_key': {'type': 'string', 'title': 'API Key'},
        'enabled': {'type': 'boolean', 'title': 'Enabled'},
        'mode': {
          'type': 'string',
          'title': 'Mode',
          'enum': ['fast', 'slow'],
        },
      },
      'required': ['api_key'],
    });
    await tester.pumpWidget(harness(spec));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace-tool-valve-api_key')), findsOneWidget);
    expect(find.byKey(const Key('workspace-tool-valve-enabled')), findsOneWidget);
    expect(find.byKey(const Key('workspace-tool-valve-mode')), findsOneWidget);
  });

  testWidgets('empty spec shows the no-valves message', (tester) async {
    await tester.pumpWidget(
      harness(const WorkspaceValveSpec(schema: {})),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workspace-tool-valves-empty')),
      findsOneWidget,
    );
  });

  testWidgets('default/custom toggle reveals the input control', (tester) async {
    final spec = WorkspaceValveSpec.fromJson(const {
      'properties': {
        'api_key': {'type': 'string', 'title': 'API Key', 'default': 'seed'},
      },
    });
    Map<String, dynamic>? emitted;
    await tester.pumpWidget(harness(spec, onChanged: (v) => emitted = v));
    await tester.pumpAndSettle();

    // Starts at the server default: no input control is shown.
    expect(
      find.byKey(const Key('workspace-tool-valve-input-api_key')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const Key('workspace-tool-valve-toggle-api_key')),
    );
    await tester.pumpAndSettle();

    // Toggling to custom reveals the control seeded with the default value.
    expect(
      find.byKey(const Key('workspace-tool-valve-input-api_key')),
      findsOneWidget,
    );
    expect(emitted, isNotNull);
    expect(emitted!['api_key'], 'seed');
  });

  testWidgets(
    'boolean valve without a default emits false when toggled to custom',
    (tester) async {
      final spec = WorkspaceValveSpec.fromJson(const {
        'properties': {
          'enabled': {'type': 'boolean', 'title': 'Enabled'},
        },
      });
      Map<String, dynamic>? emitted;
      await tester.pumpWidget(harness(spec, onChanged: (v) => emitted = v));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('workspace-tool-valve-toggle-enabled')),
      );
      await tester.pumpAndSettle();

      // Without a schema default the custom value must be a real bool, not ''.
      expect(emitted, isNotNull);
      expect(emitted!['enabled'], isFalse);
    },
  );

  testWidgets(
    'numeric valve without a default emits 0 when toggled to custom',
    (tester) async {
      final spec = WorkspaceValveSpec.fromJson(const {
        'properties': {
          'count': {'type': 'integer', 'title': 'Count'},
        },
      });
      Map<String, dynamic>? emitted;
      await tester.pumpWidget(harness(spec, onChanged: (v) => emitted = v));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('workspace-tool-valve-toggle-count')),
      );
      await tester.pumpAndSettle();

      expect(emitted, isNotNull);
      expect(emitted!['count'], 0);
    },
  );

  testWidgets('renders a switch for boolean valves in custom mode', (
    tester,
  ) async {
    final spec = WorkspaceValveSpec.fromJson(const {
      'properties': {
        'enabled': {'type': 'boolean', 'title': 'Enabled'},
      },
    });
    await tester.pumpWidget(
      harness(spec, initialValues: const {'enabled': true}),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsOneWidget);
  });
}

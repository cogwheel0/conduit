import 'dart:ui' as ui;

import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Iterable<SemanticsNode> _nodes(SemanticsNode node) sync* {
  yield node;
  final children = <SemanticsNode>[];
  node.visitChildren((child) {
    children.add(child);
    return true;
  });
  for (final child in children) {
    yield* _nodes(child);
  }
}

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('Material form field keeps one named native editable control', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    final semantics = tester.ensureSemantics();
    try {
      final controller = TextEditingController(text: 'https://initial.invalid');
      addTearDown(controller.dispose);
      final theme = AppTheme.light(TweakcnThemes.conduit);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: AccessibleFormField(
              label: 'Server',
              hint: 'https://server.example',
              controller: controller,
              autofillHints: const [AutofillHints.url],
            ),
          ),
        ),
      );
      await tester.pump();

      final editable = tester.getSemantics(find.byType(EditableText));
      expect(
        editable,
        isSemantics(
          label: 'Server',
          value: 'https://initial.invalid',
          isTextField: true,
          hasTapAction: true,
        ),
      );
      final owner = tester.binding.pipelineOwner.semanticsOwner!;
      expect(
        _nodes(owner.rootSemanticsNode!)
            .where((node) => node.hasFlag(ui.SemanticsFlag.isTextField)),
        hasLength(1),
      );
      owner.performAction(editable.id, ui.SemanticsAction.tap);
      await tester.pump();
      final focusedEditable = tester.getSemantics(find.byType(EditableText));
      expect(
        focusedEditable,
        isSemantics(label: 'Server', isTextField: true, hasSetTextAction: true),
      );
      owner.performAction(
        focusedEditable.id,
        ui.SemanticsAction.setText,
        'https://edited.invalid',
      );
      await tester.pump();
      expect(controller.text, 'https://edited.invalid');
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.labelText, 'Server');
      expect(
        tester.widget<TextField>(find.byType(TextField)).autofillHints,
        contains(AutofillHints.url),
      );
      final decoration = tester
          .widget<InputDecorator>(find.byType(InputDecorator))
          .decoration;
      expect(decoration.fillColor, theme.inputDecorationTheme.fillColor);
      expect(
        decoration.focusedBorder,
        theme.inputDecorationTheme.focusedBorder,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'Material custom field name keeps validation and native actions',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
      final semantics = tester.ensureSemantics();
      try {
        final form = GlobalKey<FormState>();
        final controller = TextEditingController(text: 'invalid');
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(TweakcnThemes.conduit),
            home: Scaffold(
              body: Form(
                key: form,
                child: AccessibleFormField(
                  label: 'Key',
                  semanticLabel: 'Hermes access key',
                  isRequired: true,
                  controller: controller,
                  validator: (value) => value == 'valid' ? null : 'Invalid key',
                ),
              ),
            ),
          ),
        );
        expect(
          tester.getSemantics(find.byType(EditableText)),
          isSemantics(
            label: 'Hermes access key',
            isTextField: true,
            hasTapAction: true,
          ),
        );
        final editable = tester.getSemantics(find.byType(EditableText));
        tester.binding.pipelineOwner.semanticsOwner!.performAction(
          editable.id,
          ui.SemanticsAction.tap,
        );
        await tester.pump();
        expect(
          tester.getSemantics(find.byType(EditableText)),
          isSemantics(
            label: 'Hermes access key',
            isTextField: true,
            hasSetTextAction: true,
          ),
        );
        expect(find.text('Key *'), findsOneWidget);
        expect(form.currentState!.validate(), isFalse);
        await tester.pump();
        expect(find.text('Invalid key'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), 'valid');
        expect(form.currentState!.validate(), isTrue);
        await tester.pump();
        expect(find.text('Invalid key'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}

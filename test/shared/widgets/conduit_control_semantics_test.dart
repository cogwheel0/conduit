import 'dart:ui' as ui;

import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.light(TweakcnThemes.conduit),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  setUp(
    () => PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android,
  );
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets(
    'button semantic activation invokes Save once inside its bounds',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        var saves = 0;
        await tester.pumpWidget(
          _host(
            ConduitButton(
              text: 'Save',
              isCompact: true,
              onPressed: () => saves++,
            ),
          ),
        );
        final node = tester.getSemantics(find.bySemanticsLabel('Save'));
        expect(node.rect.height, 48);
        expect(node.rect.width, greaterThanOrEqualTo(48));
        tester.binding.renderViews.single.owner!.semanticsOwner!.performAction(
          node.id,
          ui.SemanticsAction.tap,
        );
        await tester.pump();
        expect(saves, 1);
        await tester.tap(find.text('Save'));
        await tester.pump();
        expect(saves, 2);
      } finally {
        handle.dispose();
      }
    },
  );

  for (final loading in [false, true]) {
    testWidgets('disabled/loading button exposes no activation ($loading)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _host(
            ConduitButton(
              text: 'Save',
              isLoading: loading,
              onPressed: loading ? () => fail('Loading Save activated') : null,
            ),
          ),
        );
        final node = tester.getSemantics(
          find.bySemanticsLabel(loading ? 'Loading: Save' : 'Save'),
        );
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isFalse,
        );
        expect(node.rect.height, 48);
        expect(
          find.byType(CircularProgressIndicator),
          loading ? findsOneWidget : findsNothing,
        );
      } finally {
        handle.dispose();
      }
    });
  }

  testWidgets('short compact buttons retain a 48 dp Android target', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ConduitButton(text: 'X', width: 32, isCompact: true, onPressed: () {}),
      ),
    );
    expect(tester.getSize(find.byType(ConduitButton)), const Size(48, 48));
  });

  testWidgets('shared input has one editable node with a persistent label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(
          ConduitInput(
            label: 'Name',
            hint: 'Name your schedule',
            controller: controller,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Researcher');
      await tester.pump();
      final nodes = <SemanticsNode>[];
      void visit(SemanticsNode node) {
        if (node.getSemanticsData().flagsCollection.isTextField) {
          nodes.add(node);
        }
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      final owner = tester.binding.renderViews.single.owner!.semanticsOwner!;
      visit(owner.rootSemanticsNode!);
      expect(nodes, hasLength(1));
      expect(nodes.single.getSemanticsData().label, 'Name');
      expect(nodes.single.getSemanticsData().value, 'Researcher');
      owner.performAction(
        nodes.single.id,
        ui.SemanticsAction.setText,
        'Updated',
      );
      await tester.pump();
      expect(controller.text, 'Updated');
    } finally {
      handle.dispose();
    }
  });
}

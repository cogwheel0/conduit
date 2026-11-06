import 'dart:ui' as ui;

import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  setUp(
    () => PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS,
  );
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('iOS response selection covers the space between wrapped lines', (
    tester,
  ) async {
    const response =
        'Place the paper lanterns beside the window. '
        'Arrange the blue lantern above the gold lantern, then measure '
        'the ribbons before hanging the next row.';
    const capture = ValueKey('response-capture');
    const highlight = Color(0xFF2979FF);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.conduit).copyWith(
            platform: TargetPlatform.iOS,
            textSelectionTheme: const TextSelectionThemeData(
              selectionColor: highlight,
            ),
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: capture,
                child: const ColoredBox(
                  color: Colors.white,
                  child: SizedBox(
                    width: 300,
                    height: 260,
                    child: SelectionArea(
                      child: ConduitMarkdownWidget(data: response),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.keyboard);
    await tester.pumpAndSettle();
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == response,
      ),
    );
    final boxes = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: response.length),
    );
    expect(boxes.length, greaterThan(2));
    expect(boxes[1].top - boxes[0].bottom, greaterThan(1));
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    final pixel = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final point = paragraph.localToGlobal(
        Offset(
          (boxes[0].left + boxes[0].right) / 2,
          (boxes[0].bottom + boxes[1].top) / 2,
        ),
      );
      final local = boundary.globalToLocal(point);
      final index = (local.dy.floor() * image.width + local.dx.floor()) * 4;
      final color = bytes!.buffer
          .asUint8List(bytes.offsetInBytes + index, 4)
          .toList();
      image.dispose();
      return color;
    });
    expect(pixel, [41, 121, 255, 255]);
  });
}

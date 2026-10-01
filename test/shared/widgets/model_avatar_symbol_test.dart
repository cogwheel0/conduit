import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_symbol_image_service.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/model_avatar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A 1x1 transparent PNG, enough to stand in for a rasterized glyph.
final Uint8List _pngBytes = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Future<void> _pumpAvatar(WidgetTester tester, {required String? imageUrl}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(TweakcnThemes.conduit),
      home: Scaffold(
        body: Center(child: ModelAvatar(size: 32, imageUrl: imageUrl)),
      ),
    ),
  );
}

void main() {
  // The symbol URL scheme and the glyph cache moved to conduit_core
  // (utils/model_icon_utils_test.dart, services/native_symbol_image_service_test.dart).
  group('ModelAvatar', () {
    testWidgets("a symbol url keeps Conduit's mark until the glyph lands", (
      tester,
    ) async {
      await _pumpAvatar(tester, imageUrl: 'symbol:$kAppleIntelligenceSymbol');
      await tester.pump();

      // The test host has no symbol renderer, so the avatar must not fall back
      // to the lettered plate or the generic brain.
      check(find.byIcon(Icons.auto_awesome).evaluate()).length.equals(1);
      check(find.byIcon(Icons.psychology).evaluate()).isEmpty();
      check(find.byType(Image).evaluate()).isEmpty();
    });

    testWidgets('other urls still use the image pipeline', (tester) async {
      await _pumpAvatar(tester, imageUrl: 'asset:assets/icons/icon.png');
      await tester.pump();

      check(find.byIcon(Icons.auto_awesome).evaluate()).isEmpty();
      check(find.byType(Image).evaluate()).length.equals(1);
    });

    testWidgets('a late glyph for the previous symbol is ignored', (
      tester,
    ) async {
      final slowGlyph = Completer<Uint8List?>();
      final pendingBytes = Uint8List.fromList(_pngBytes);
      final currentBytes = Uint8List.fromList(_pngBytes);
      NativeSymbolImageService.debugInstance = NativeSymbolImageService(
        renderer: (name, pointSize, scale) => name == 'pending.symbol'
            ? slowGlyph.future
            : Future.value(currentBytes),
      );
      addTearDown(() => NativeSymbolImageService.debugInstance = null);

      await _pumpAvatar(tester, imageUrl: 'symbol:pending.symbol');
      await tester.pump();
      await _pumpAvatar(tester, imageUrl: 'symbol:current.symbol');
      await tester.pump();

      // The avatar moved on while the first request was still in flight.
      slowGlyph.complete(pendingBytes);
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      final painted = (image.image as MemoryImage).bytes;
      check(identical(painted, currentBytes)).isTrue();
      check(identical(painted, pendingBytes)).isFalse();
    });
  });
}

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
  group('nativeSymbolNameFromUrl', () {
    test('reads the symbol name', () {
      check(
        nativeSymbolNameFromUrl('symbol:apple.intelligence'),
      ).equals('apple.intelligence');
    });

    test('ignores other schemes and empty names', () {
      check(nativeSymbolNameFromUrl('asset:assets/icons/icon.png')).isNull();
      check(nativeSymbolNameFromUrl('https://example.invalid/a.png')).isNull();
      check(nativeSymbolNameFromUrl('symbol:')).isNull();
      check(nativeSymbolNameFromUrl(null)).isNull();
    });
  });

  group('NativeSymbolImageService', () {
    test('renders once per name, size, and scale', () async {
      final requests = <List<Object>>[];
      final service = NativeSymbolImageService(
        renderer: (name, pointSize, scale) async {
          requests.add([name, pointSize, scale]);
          return _pngBytes;
        },
      );

      final first = await service.load(
        kAppleIntelligenceSymbol,
        pointSize: 20,
        scale: 3,
      );
      final second = await service.load(
        kAppleIntelligenceSymbol,
        pointSize: 20,
        scale: 3,
      );

      check(first).isNotNull();
      check(second).isNotNull();
      check(requests).deepEquals([
        [kAppleIntelligenceSymbol, 20.0, 3.0],
      ]);
      // A settled entry is readable without awaiting again, so a list of
      // avatars never repaints through a pending future.
      check(
        service.cached(kAppleIntelligenceSymbol, pointSize: 20, scale: 3),
      ).isNotNull();

      await service.load(kAppleIntelligenceSymbol, pointSize: 40, scale: 3);
      check(requests).length.equals(2);
    });

    test('concurrent loads share one render', () async {
      var renders = 0;
      final service = NativeSymbolImageService(
        renderer: (name, pointSize, scale) async {
          renders++;
          await Future<void>.delayed(Duration.zero);
          return _pngBytes;
        },
      );

      await Future.wait([
        service.load(kAppleIntelligenceSymbol, pointSize: 20, scale: 2),
        service.load(kAppleIntelligenceSymbol, pointSize: 20, scale: 2),
        service.load(kAppleIntelligenceSymbol, pointSize: 20, scale: 2),
      ]);

      check(renders).equals(1);
    });

    test('a missing symbol settles as resolved without bytes', () async {
      var renders = 0;
      final service = NativeSymbolImageService(
        renderer: (name, pointSize, scale) async {
          renders++;
          return null;
        },
      );

      check(
        await service.load('not.a.symbol', pointSize: 20, scale: 2),
      ).isNull();
      check(
        service.isResolved('not.a.symbol', pointSize: 20, scale: 2),
      ).isTrue();

      // A system without the symbol must not be asked again on every repaint.
      await service.load('not.a.symbol', pointSize: 20, scale: 2);
      check(renders).equals(1);
    });

    test('a platform without symbols never renders', () async {
      // The default service targets Apple platforms only, and the test host is
      // not one, so nothing should reach the platform channel.
      final service = NativeSymbolImageService();

      check(
        await service.load(kAppleIntelligenceSymbol, pointSize: 20, scale: 2),
      ).isNull();
      check(
        service.isResolved(kAppleIntelligenceSymbol, pointSize: 20, scale: 2),
      ).isTrue();
    });
  });

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
        renderer: (name, pointSize, scale) =>
            name == 'pending.symbol' ? slowGlyph.future : Future.value(currentBytes),
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

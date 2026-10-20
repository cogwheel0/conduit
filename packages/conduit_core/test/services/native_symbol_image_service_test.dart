import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/services/native_symbol_image_service.dart';
import 'package:test/test.dart';

/// Stands in for a rasterized glyph; the cache never decodes it.
final Uint8List _pngBytes = Uint8List.fromList(const <int>[0x89, 0x50, 0x4E]);

void main() {
  tearDown(() => NativeSymbolImageService.hostRenderer = null);

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
      check(service.cached(kAppleIntelligenceSymbol, pointSize: 20, scale: 3))
          .isNotNull();

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

      check(await service.load('not.a.symbol', pointSize: 20, scale: 2))
          .isNull();
      check(service.isResolved('not.a.symbol', pointSize: 20, scale: 2))
          .isTrue();

      // A system without the symbol must not be asked again on every repaint.
      await service.load('not.a.symbol', pointSize: 20, scale: 2);
      check(renders).equals(1);
    });

    test('a host without symbols never renders', () async {
      // No renderer passed and none installed: Android, the daemon, tests.
      final service = NativeSymbolImageService();

      check(
        await service.load(kAppleIntelligenceSymbol, pointSize: 20, scale: 2),
      ).isNull();
      check(
        service.isResolved(kAppleIntelligenceSymbol, pointSize: 20, scale: 2),
      ).isTrue();
    });

    test('the host renderer serves the default service', () async {
      final requests = <String>[];
      NativeSymbolImageService.hostRenderer = (name, pointSize, scale) async {
        requests.add(name);
        return _pngBytes;
      };
      final service = NativeSymbolImageService();

      check(
        await service.load(kAppleIntelligenceSymbol, pointSize: 20, scale: 2),
      ).isNotNull();
      check(requests).deepEquals([kAppleIntelligenceSymbol]);
    });
  });
}

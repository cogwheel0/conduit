import 'dart:convert';
import 'dart:ui' as ui;

import 'package:conduit_core/features/direct_connections/services/model_logo_catalog.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Avatar URL scheme for a bundled models.dev logo: `modellogo:<id>`.
const String kModelLogoUrlScheme = 'modellogo:';

const String _kModelLogoDirectory = 'assets/model_logos';

/// The bundled models.dev logo catalog, loaded once at startup.
abstract final class ModelLogos {
  static ModelLogoCatalog? _catalog;
  static Future<void>? _loading;

  /// Loads `catalog.json`. Safe to call more than once; failures leave
  /// Direct models on the lettered avatar.
  static Future<void> load() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final json = await rootBundle.loadString(
        '$_kModelLogoDirectory/catalog.json',
      );
      _catalog = ModelLogoCatalog.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
    } catch (error) {
      DebugLogger.warning(
        'model-logo-catalog-load-failed',
        scope: 'model-logos',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  /// The avatar URL for a Direct [model] minted by this device, or `null`
  /// when its maker and provider are both unknown.
  static String? avatarUrlForDirectModel(Model model) {
    final catalog = _catalog;
    final metadata = model.metadata;
    final remoteId = metadata?['remoteModelId'];
    if (catalog == null || remoteId is! String) return null;
    final logo = catalog.logoFor(
      remoteModelId: remoteId,
      baseHost: metadata?['directBaseHost'] as String?,
      adapterKey: metadata?['adapterKey'] as String?,
    );
    return logo == null ? null : '$kModelLogoUrlScheme$logo';
  }

  /// Replaces the catalog, for tests.
  static void debugSetCatalog(ModelLogoCatalog? catalog) {
    _catalog = catalog;
    _loading = catalog == null ? null : Future.value();
  }
}

/// The logo id in a `modellogo:` avatar URL, or `null` for other URLs.
String? modelLogoIdFromUrl(String? url) {
  final trimmed = url?.trim();
  if (trimmed == null || !trimmed.startsWith(kModelLogoUrlScheme)) {
    return null;
  }
  final id = trimmed.substring(kModelLogoUrlScheme.length);
  return RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(id) ? id : null;
}

String modelLogoAssetPath(String id) => '$_kModelLogoDirectory/$id.svg';

/// Renders a logo as a square PNG for surfaces that can't draw SVG (the
/// native iOS model picker). Monochrome logos take [color]; the logo fills
/// [logoFraction] of the square so it sits inset on the avatar plate.
Future<Uint8List?> rasterizeModelLogo(
  String id, {
  required Color color,
  int pixelSize = 96,
  double logoFraction = 0.8,
}) async {
  try {
    final info = await vg.loadPicture(
      SvgAssetLoader(
        modelLogoAssetPath(id),
        theme: SvgTheme(currentColor: color),
      ),
      null,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final side = pixelSize.toDouble();
    final logoSide = side * logoFraction;
    final source = info.size;
    if (source.isEmpty) return null;
    final scale =
        logoSide /
        (source.width > source.height ? source.width : source.height);
    canvas
      ..translate(
        (side - source.width * scale) / 2,
        (side - source.height * scale) / 2,
      )
      ..scale(scale)
      ..drawPicture(info.picture);
    info.picture.dispose();
    final image = await recorder.endRecording().toImage(pixelSize, pixelSize);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

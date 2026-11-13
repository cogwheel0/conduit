import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/direct_connections/services/model_logo_catalog.dart';
import 'package:path/path.dart' as p;

/// Where the bundled models.dev logo catalog is: `CONDUIT_MODEL_LOGOS` (a
/// directory holding `catalog.json`), else `model_logos/` beside the
/// daemon's `bin/` in its bundle. Null when neither has one.
String? findModelLogoCatalog({
  Map<String, String>? environment,
  String? executable,
}) {
  final env = environment ?? Platform.environment;
  final given = env['CONDUIT_MODEL_LOGOS'];
  final dir = (given != null && given.isNotEmpty)
      ? given
      : p.join(
          File(executable ?? Platform.resolvedExecutable).parent.parent.path,
          'model_logos',
        );
  final file = p.join(dir, 'catalog.json');
  return File(file).existsSync() ? file : null;
}

/// Installs the catalog the core picks direct models' logos from, so
/// `models.list` can name each model's maker. Without one, every direct
/// model shows its initial, as on a phone whose catalog failed to load.
/// Answers whether one was installed.
bool installModelLogoCatalog({
  Map<String, String>? environment,
  String? executable,
}) {
  final path = findModelLogoCatalog(
    environment: environment,
    executable: executable,
  );
  if (path == null) return false;
  try {
    final json = jsonDecode(File(path).readAsStringSync());
    if (json is! Map<String, dynamic>) return false;
    installedModelLogoCatalog = ModelLogoCatalog.fromJson(json);
    return true;
  } on Object {
    return false;
  }
}

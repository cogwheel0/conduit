import 'package:hive_ce_flutter/hive_flutter.dart';

import 'hive_boxes.dart';

/// Sets up Hive and exposes lazily opened boxes used across the app.
class HiveBootstrap {
  HiveBootstrap._();

  static final HiveBootstrap instance = HiveBootstrap._();

  HiveBoxes? _boxes;

  /// Ensures Hive is initialized and all required boxes are open.
  Future<HiveBoxes> ensureInitialized() async {
    if (_boxes != null) {
      return _boxes!;
    }

    await Hive.initFlutter('conduit_hive');

    final opened = await Future.wait<Box<dynamic>>([
      Hive.openBox<dynamic>(HiveBoxNames.preferences),
      Hive.openBox<dynamic>(HiveBoxNames.caches),
      Hive.openBox<dynamic>(HiveBoxNames.attachmentQueue),
      Hive.openBox<dynamic>(HiveBoxNames.metadata),
    ]);

    _boxes = HiveBoxes(
      preferences: opened[0],
      caches: opened[1],
      attachmentQueue: opened[2],
      metadata: opened[3],
    );

    return _boxes!;
  }

  /// Access the cached boxes after [ensureInitialized] has completed.
  HiveBoxes get boxes {
    final cached = _boxes;
    if (cached == null) {
      throw StateError('HiveBootstrap.ensureInitialized must run first.');
    }
    return cached;
  }
}

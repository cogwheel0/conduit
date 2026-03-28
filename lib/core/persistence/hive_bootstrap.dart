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

    await Hive.initFlutter('qonduit_hive');

    final preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
    final caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
    final attachmentQueue = await Hive.openBox<dynamic>(
      HiveBoxNames.attachmentQueue,
    );
    final metadata = await Hive.openBox<dynamic>(HiveBoxNames.metadata);

    _boxes = HiveBoxes(
      preferences: preferences,
      caches: caches,
      attachmentQueue: attachmentQueue,
      metadata: metadata,
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

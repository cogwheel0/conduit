import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'hive_boxes.dart';

part 'persistence_providers.g.dart';

/// Provides access to eagerly opened Hive boxes. Must be overridden in [main].
@Riverpod(keepAlive: true)
HiveBoxes hiveBoxes(Ref ref) =>
    throw UnimplementedError('Hive boxes must be provided during bootstrap.');

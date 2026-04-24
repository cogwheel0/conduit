import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'conversation_store.dart';
import 'database/app_database.dart';
import 'hive_boxes.dart';

part 'persistence_providers.g.dart';

/// Provides access to eagerly opened Hive boxes. Must be overridden in [main].
@Riverpod(keepAlive: true)
HiveBoxes hiveBoxes(Ref ref) =>
    throw UnimplementedError('Hive boxes must be provided during bootstrap.');

/// The shared SQLite connection. Overridden in [main] after the database
/// has been opened.
@Riverpod(keepAlive: true)
AppDatabase appDatabase(Ref ref) =>
    throw UnimplementedError('AppDatabase must be provided during bootstrap.');

/// Repository over [AppDatabase] used by [OptimizedStorageService] and
/// chat providers for per-message reads/writes.
@Riverpod(keepAlive: true)
ConversationStore conversationStore(Ref ref) =>
    ConversationStore(ref.watch(appDatabaseProvider));

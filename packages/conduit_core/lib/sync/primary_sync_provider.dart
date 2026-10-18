import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/sync/primary_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';

/// The [PrimarySync] of the account that owns the Chats tab.
///
/// Only Open WebUI accounts sync so far, so this is always its engine;
/// LibreChat's joins here when its accounts can own the tab.
final primarySyncProvider = Provider<PrimarySync>(
  (ref) => ref.watch(syncEngineProvider.notifier),
);

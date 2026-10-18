import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/librechat/providers/librechat_sync_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/sync/primary_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';

/// The [PrimarySync] of the account that owns the Chats tab: Open WebUI's
/// engine, or the signed-in LibreChat account's while LibreChat owns it.
final primarySyncProvider = Provider<PrimarySync>(
  (ref) => switch (ref.watch(primaryAccountKindProvider)) {
    PrimaryAccountKind.openWebUi => ref.watch(syncEngineProvider.notifier),
    PrimaryAccountKind.libreChat => ref.watch(libreChatPrimarySyncProvider),
  },
);

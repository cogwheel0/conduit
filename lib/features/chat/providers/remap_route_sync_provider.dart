import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../core/utils/debug_logger.dart';

part 'remap_route_sync_provider.g.dart';

/// Wiring C: consumes [SyncEngine.remapEvents] and swaps the open route / active
/// chat id IN PLACE when a `local:<uuid>` is remapped to a server id (§7.3).
///
/// Mechanism is a STATE swap, NOT a go_router redirect: the chat route builds a
/// const page with no id in the URL, so the active-chat id lives entirely in
/// [activeConversationProvider]. Swapping it in place avoids any stale-route
/// window or visible rebuild (NON-NEGOTIABLE 6) — the message-list content is
/// unchanged, and the DB rows were already repointed inside the remap tx, so
/// the DB-watch re-binds under the new id.
///
/// Installed by being `ref.watch`ed from the startup listener block (alongside
/// `syncTriggersProvider`).
@Riverpod(keepAlive: true)
void remapRouteSync(Ref ref) {
  final sub = ref.read(syncEngineProvider.notifier).remapEvents.listen((event) {
    if (event.entityKind == 'chat') {
      final active = ref.read(activeConversationProvider);
      if (active != null && active.id == event.fromId) {
        DebugLogger.log(
          'remap-active-chat',
          scope: 'chat/remap',
          data: {'from': event.fromId, 'to': event.toId},
        );
        ref
            .read(activeConversationProvider.notifier)
            .set(active.copyWith(id: event.toId));
      }
    } else if (event.entityKind == 'folder') {
      final pending = ref.read(pendingFolderIdProvider);
      if (pending == event.fromId) {
        DebugLogger.log(
          'remap-pending-folder',
          scope: 'chat/remap',
          data: {'from': event.fromId, 'to': event.toId},
        );
        ref.read(pendingFolderIdProvider.notifier).set(event.toId);
      }
    }
  });
  ref.onDispose(sub.cancel);
}

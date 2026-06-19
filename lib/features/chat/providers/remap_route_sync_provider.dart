import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
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
  // Navigates an open route to its remapped target, logging the swap and
  // warning (without throwing) if go_router rejects the navigation.
  void goRemappedRoute(
    String? nextRoute, {
    required String logEvent,
    required String scope,
    required String fromId,
    required String toId,
  }) {
    if (nextRoute == null) return;
    DebugLogger.log(logEvent, scope: scope, data: {'from': fromId, 'to': toId});
    try {
      NavigationService.router.go(nextRoute);
    } catch (error) {
      DebugLogger.warning(
        'remap-navigation-failed',
        scope: scope,
        data: {'route': nextRoute, 'error': error.toString()},
      );
    }
  }

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
            .remapIdInPlace(fromId: event.fromId, toId: event.toId);
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
      goRemappedRoute(
        remappedFolderRouteForTesting(
          NavigationService.currentRoute,
          fromId: event.fromId,
          toId: event.toId,
        ),
        logEvent: 'remap-open-folder-route',
        scope: 'chat/remap',
        fromId: event.fromId,
        toId: event.toId,
      );
    } else if (event.entityKind == 'note') {
      goRemappedRoute(
        remappedNoteRouteForTesting(
          NavigationService.currentRoute,
          fromId: event.fromId,
          toId: event.toId,
        ),
        logEvent: 'remap-open-note-route',
        scope: 'notes/remap',
        fromId: event.fromId,
        toId: event.toId,
      );
    }
  });
  ref.onDispose(sub.cancel);
}

String? remappedNoteRouteForTesting(
  String? currentRoute, {
  required String fromId,
  required String toId,
}) => _remappedSingleSegmentRoute(
  currentRoute,
  prefix: 'notes',
  fromId: fromId,
  toId: toId,
);

String? remappedFolderRouteForTesting(
  String? currentRoute, {
  required String fromId,
  required String toId,
}) => _remappedSingleSegmentRoute(
  currentRoute,
  prefix: 'folder',
  fromId: fromId,
  toId: toId,
);

/// Rewrites a `/<prefix>/<fromId>` route to `/<prefix>/<toId>` (preserving
/// query params), or returns null when [currentRoute] does not target exactly
/// that entity. Shared by the note/folder remap branches.
String? _remappedSingleSegmentRoute(
  String? currentRoute, {
  required String prefix,
  required String fromId,
  required String toId,
}) {
  if (currentRoute == null) return null;
  final currentUri = Uri.tryParse(currentRoute);
  if (currentUri == null) return null;
  final segments = currentUri.pathSegments;
  if (segments.length != 2 ||
      segments.first != prefix ||
      segments[1] != fromId) {
    return null;
  }
  return currentUri
      .replace(path: '/$prefix/${Uri.encodeComponent(toId)}')
      .toString();
}

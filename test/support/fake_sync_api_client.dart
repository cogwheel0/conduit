/// Instrumented [SyncApiClient] over [FakeOpenWebUiServer] for pull-sync
/// unit tests (CDT-RFC-001 Phase 1, §12.2).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/core/sync/sync_api_client.dart';

import 'fake_open_webui_server.dart';

class FakeSyncApiClient implements SyncApiClient {
  FakeSyncApiClient(this.server);

  final FakeOpenWebUiServer server;

  // ---- failure injection ----
  /// 1-based main-list page numbers that throw.
  final Set<int> failChatListPages = <int>{};

  /// 1-based archived-list page numbers that throw.
  final Set<int> failArchivedListPages = <int>{};

  /// Chat ids whose [getChatRaw] throws.
  final Set<String> failChatIds = <String>{};

  /// Chat ids whose [getChatRaw] returns null (emulates a chat deleted
  /// between the list fetch and the body fetch — a 404 in production).
  final Set<String> nullChatIds = <String>{};

  /// When set, [getFoldersRaw] throws.
  bool failFolders = false;

  /// Mirrors a server-side 403: ([], false).
  bool foldersFeatureEnabled = true;

  /// Artificial latency inside [getChatRaw] (lets the pool fill up).
  Duration chatFetchDelay = Duration.zero;

  /// When set, every [getChatRaw] awaits this future before returning —
  /// lets a test hold a pull cycle open at a deterministic point.
  Future<void>? chatFetchGate;

  // ---- instrumentation ----
  int chatListPageRequests = 0;
  int archivedListPageRequests = 0;
  int foldersRequests = 0;

  /// Ids in the order [getChatRaw] calls STARTED.
  final List<String> chatFetchStarts = <String>[];
  int _activeChatFetches = 0;
  int maxConcurrentChatFetches = 0;

  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) async {
    chatListPageRequests++;
    if (failChatListPages.contains(page)) {
      throw StateError('injected main list failure (page $page)');
    }
    return server.getChatList(
      page: page,
      includePinned: true,
      includeFolders: true,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getArchivedChatListPage(int page) async {
    archivedListPageRequests++;
    if (failArchivedListPages.contains(page)) {
      throw StateError('injected archived list failure (page $page)');
    }
    return server.getArchivedChatList(page: page);
  }

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async {
    chatFetchStarts.add(id);
    _activeChatFetches++;
    maxConcurrentChatFetches = math.max(
      maxConcurrentChatFetches,
      _activeChatFetches,
    );
    try {
      if (chatFetchDelay > Duration.zero) {
        await Future<void>.delayed(chatFetchDelay);
      } else {
        // Yield so concurrent workers interleave like real I/O.
        await Future<void>.delayed(Duration.zero);
      }
      final gate = chatFetchGate;
      if (gate != null) {
        await gate;
      }
      if (failChatIds.contains(id)) {
        throw StateError('injected chat fetch failure ($id)');
      }
      if (nullChatIds.contains(id)) {
        return null;
      }
      return server.getChatById(id);
    } finally {
      _activeChatFetches--;
    }
  }

  @override
  Future<(List<Map<String, dynamic>>, bool)> getFoldersRaw() async {
    foldersRequests++;
    if (failFolders) {
      throw StateError('injected folders failure');
    }
    if (!foldersFeatureEnabled) {
      return (const <Map<String, dynamic>>[], false);
    }
    return (server.getFolders(), true);
  }
}

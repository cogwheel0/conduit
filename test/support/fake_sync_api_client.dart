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

  /// §7.5 reconcile probe: ids whose [probeChatExists] reports "gone" via the
  /// vendored normal-user 401 NOT_FOUND (rather than a 404). The reconcile
  /// treats both 404 and 401 as gone.
  final Set<String> probe401GoneIds = <String>{};

  /// §7.5 reconcile probe: ids whose [probeChatExists] throws a transient
  /// (network/5xx) error, so the reconcile must SKIP (not purge) them.
  final Set<String> probeThrowIds = <String>{};

  int probeChatExistsCalls = 0;

  /// §7.5 reconcile: ids hidden from BOTH list enumerations (main + archived)
  /// to model a pagination gap/race — the chat is still on the server (probe
  /// finds it) but missing from the page set, so the reconcile must NOT purge.
  final Set<String> hideFromListIds = <String>{};

  List<Map<String, dynamic>> _hide(List<Map<String, dynamic>> items) {
    if (hideFromListIds.isEmpty) return items;
    return [
      for (final item in items)
        if (!hideFromListIds.contains(item['id'])) item,
    ];
  }

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
    return _hide(
      server.getChatList(
        page: page,
        includePinned: true,
        includeFolders: true,
      ),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getArchivedChatListPage(int page) async {
    archivedListPageRequests++;
    if (failArchivedListPages.contains(page)) {
      throw StateError('injected archived list failure (page $page)');
    }
    return _hide(server.getArchivedChatList(page: page));
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
  Future<bool> probeChatExists(String id) async {
    probeChatExistsCalls++;
    await Future<void>.delayed(Duration.zero);
    if (probeThrowIds.contains(id)) {
      throw StateError('injected probe transient failure ($id)');
    }
    if (probe401GoneIds.contains(id)) {
      // Vendored normal-user not-ours 401 NOT_FOUND -> gone.
      return false;
    }
    // null (404) -> gone; a present record -> still exists.
    if (nullChatIds.contains(id)) return false;
    return server.getChatById(id) != null;
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

  // ---- Phase 2 write extensions (thin pass-throughs over the fake server,
  //      mirroring the vendored toggle/merge/error truth) ----

  /// Set ids whose write throws a retryable transport error, to exercise the
  /// drainer's backoff path.
  final Set<String> failWriteIds = <String>{};

  /// Chat ids whose write throws a terminal [SyncTerminalException] (403),
  /// simulating a not-owner / no-permission server response.
  final Set<String> terminalWriteIds = <String>{};

  int createChatCalls = 0;
  int updateChatCalls = 0;
  int deleteChatCalls = 0;

  /// When set, every [createChat] awaits this future before returning — lets a
  /// test hold a createChat op `inFlight` at a deterministic point (so a
  /// concurrent drain trigger can be exercised against a genuinely-in-flight
  /// op).
  Future<void>? createChatGate;

  /// Ids in the order [createChat] calls STARTED (records `__localId`).
  final List<String> createChatStarts = <String>[];

  void _maybeThrow(String id) {
    if (failWriteIds.contains(id)) {
      throw StateError('injected write failure ($id)');
    }
    if (terminalWriteIds.contains(id)) {
      throw const SyncTerminalException(statusCode: 403, message: 'forbidden');
    }
  }

  @override
  Future<Map<String, dynamic>> createChat(
    Map<String, dynamic> chatBlob, {
    String? folderId,
  }) async {
    createChatCalls++;
    createChatStarts.add(chatBlob['__localId'] as String? ?? 'create');
    await Future<void>.delayed(Duration.zero);
    final gate = createChatGate;
    if (gate != null) {
      await gate;
    }
    return server.createChat(chatBlob, folderId: folderId);
  }

  @override
  Future<Map<String, dynamic>?> updateChat(
    String id,
    Map<String, dynamic> fullBlob,
  ) async {
    updateChatCalls++;
    await Future<void>.delayed(Duration.zero);
    _maybeThrow(id);
    return server.updateChat(id, fullBlob);
  }

  @override
  Future<bool> deleteChat(String id) async {
    deleteChatCalls++;
    await Future<void>.delayed(Duration.zero);
    _maybeThrow(id);
    return server.deleteChat(id);
  }

  @override
  Future<bool> getChatPinned(String id) async {
    try {
      return server.getChatPinned(id);
    } on FakeOpenWebUiHttpException {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>?> togglePin(String id) async {
    return server.togglePin(id);
  }

  @override
  Future<Map<String, dynamic>?> toggleArchive(String id) async {
    return server.toggleArchive(id);
  }

  @override
  Future<Map<String, dynamic>?> moveChatToFolder(
    String id,
    String? folderId,
  ) async {
    return server.moveChatToFolder(id, folderId);
  }

  @override
  Future<Map<String, dynamic>> createFolder({
    required String name,
    String? parentId,
  }) async {
    await Future<void>.delayed(Duration.zero);
    return server.createFolder(name: name, parentId: parentId);
  }

  @override
  Future<void> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    server.updateFolder(id, name: name, data: data, meta: meta);
  }

  @override
  Future<void> updateFolderParent(String id, String? parentId) async {
    server.updateFolderParent(id, parentId);
  }

  @override
  Future<void> deleteFolder(String id, {bool deleteContents = false}) async {
    server.deleteFolder(id, deleteContents: deleteContents);
  }
}

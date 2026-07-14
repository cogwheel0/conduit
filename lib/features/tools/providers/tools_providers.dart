import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/models/tool.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/tools_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';

part 'tools_providers.g.dart';

@Riverpod(keepAlive: true)
class ToolsList extends _$ToolsList {
  @override
  Future<List<Tool>> build() async {
    final isAuthenticated = ref.watch(isAuthenticatedProvider2);
    if (!isAuthenticated) {
      return const <Tool>[];
    }

    ref.watch(openWebUiAuthSessionEpochProvider);
    ref.watch(openWebUiDatabaseAccessProvider);
    ref.watch(openWebUiCertifiedDatabaseServerProvider);
    ref.watch(activeServerProvider);
    final storage = ref.watch(optimizedStorageServiceProvider);
    final toolsService = ref.watch(toolsServiceProvider);
    final cacheOwnership = toolsService == null
        ? null
        : captureOpenWebUiCacheOwnership(
            ref,
            api: toolsService.apiService,
            requireAuthenticated: false,
          );
    if (toolsService != null && cacheOwnership == null) {
      return const <Tool>[];
    }
    final cached = await storage.getLocalTools();
    if (cacheOwnership != null &&
        !openWebUiCacheOwnershipIsCurrent(ref, cacheOwnership)) {
      return const <Tool>[];
    }

    if (cached.isNotEmpty) {
      _scheduleWarmRefresh(toolsService);
      return cached;
    }

    if (toolsService == null) {
      return const [];
    }

    return (await _fetchAndPersist(toolsService))?.tools ?? const <Tool>[];
  }

  Future<void> refresh() async {
    if (!ref.read(isAuthenticatedProvider2)) {
      state = const AsyncData<List<Tool>>(<Tool>[]);
      return;
    }

    final toolsService = ref.read(toolsServiceProvider);
    if (toolsService == null) {
      return;
    }
    final result = await AsyncValue.guard(() => _fetchAndPersist(toolsService));
    if (!ref.mounted) return;
    final owned = result.value;
    if (result.hasValue && owned == null) return;
    state = result.whenData((value) => value!.tools);
  }

  void _scheduleWarmRefresh(ToolsService? service) {
    if (service == null) {
      return;
    }
    Future.microtask(() async {
      if (!ref.mounted) return;
      await refresh();
    });
  }

  Future<_OwnedTools?> _fetchAndPersist(ToolsService service) async {
    final ownership = captureOpenWebUiCacheOwnership(
      ref,
      api: service.apiService,
      requireAuthenticated: false,
    );
    if (ownership == null) return null;
    final tools = await service.getTools();
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveLocalTools(tools);
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
    return (tools: tools, ownership: ownership);
  }
}

typedef _OwnedTools = ({
  List<Tool> tools,
  OpenWebUiCacheOwnershipSnapshot ownership,
});

@Riverpod(keepAlive: true)
class SelectedToolIds extends _$SelectedToolIds {
  @override
  List<String> build() => [];

  void set(List<String> ids) => state = List<String>.from(ids);
}

/// Tracks the currently selected terminal server for chat completions.
///
/// This mirrors OpenWebUI's `selectedTerminalId` behavior. The value may be a
/// backend-managed terminal `id` or a direct terminal `url`.
@Riverpod(keepAlive: true)
class SelectedTerminalId extends _$SelectedTerminalId {
  @override
  String? build() => null;

  void set(String? id) => state = id;

  void clear() => state = null;
}

/// Provider for selected filter IDs (toggle filters enabled by user).
///
/// These filters are dynamically created by OpenWebUI filters with
/// `toggle = True` set in their module. They appear as toggleable
/// buttons in the chat input UI.
@Riverpod(keepAlive: true)
class SelectedFilterIds extends _$SelectedFilterIds {
  @override
  List<String> build() => [];

  void set(List<String> ids) => state = List<String>.from(ids);

  void toggle(String id) {
    if (state.contains(id)) {
      state = state.where((i) => i != id).toList();
    } else {
      state = [...state, id];
    }
  }

  void clear() => state = [];
}

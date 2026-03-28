import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:qonduit/core/models/tool.dart';
import 'package:qonduit/core/providers/storage_providers.dart';
import 'package:qonduit/core/services/tools_service.dart';

part 'tools_providers.g.dart';

@Riverpod(keepAlive: true)
class ToolsList extends _$ToolsList {
  @override
  Future<List<Tool>> build() async {
    final storage = ref.watch(optimizedStorageServiceProvider);
    final toolsService = ref.watch(toolsServiceProvider);
    final cached = await storage.getLocalTools();

    if (cached.isNotEmpty) {
      _scheduleWarmRefresh(toolsService);
      return cached;
    }

    if (toolsService == null) {
      return const [];
    }

    return _fetchAndPersist(toolsService);
  }

  Future<void> refresh() async {
    final toolsService = ref.read(toolsServiceProvider);
    if (toolsService == null) {
      return;
    }
    final result = await AsyncValue.guard(() => _fetchAndPersist(toolsService));
    if (!ref.mounted) return;
    state = result;
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

  Future<List<Tool>> _fetchAndPersist(ToolsService service) async {
    final tools = await service.getTools();
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveLocalTools(tools);
    return tools;
  }
}

@Riverpod(keepAlive: true)
class SelectedToolIds extends _$SelectedToolIds {
  @override
  List<String> build() => [];

  void set(List<String> ids) => state = List<String>.from(ids);
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

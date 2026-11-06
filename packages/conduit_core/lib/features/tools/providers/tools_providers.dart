import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/chat_picks_session.dart';
import 'package:conduit_core/services/tools_service.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

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
        : _captureOwnership(toolsService);
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
    final ownership = _captureOwnership(service);
    if (ownership == null) return null;
    final tools = await service.getTools();
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveLocalTools(tools);
    if (!openWebUiCacheOwnershipIsCurrent(ref, ownership)) return null;
    return (tools: tools, ownership: ownership);
  }

  OpenWebUiCacheOwnershipSnapshot? _captureOwnership(ToolsService service) {
    return captureOpenWebUiCacheOwnership(
      ref,
      api: service.apiService,
      requireAuthenticated: false,
    );
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

/// The toggle filters a chat with [model] starts with: those set to "Start
/// enabled in new chats" on the model that it still offers, as Open WebUI's
/// own chat picks them.
List<String> defaultFilterIdsForModel(Model? model) {
  final offered = {for (final filter in model?.filters ?? const []) filter.id};
  if (offered.isEmpty) return const <String>[];
  final metadata = model?.metadata;
  final info = metadata?['info'];
  final defaults = <String>{};
  for (final meta in [metadata?['meta'], if (info is Map) info['meta']]) {
    if (meta is! Map) continue;
    final ids = meta['defaultFilterIds'];
    if (ids is List) defaults.addAll(ids.map((id) => id.toString()));
  }
  return [
    for (final id in defaults)
      if (offered.contains(id)) id,
  ];
}

/// What the selected filters follow: the model, its defaults, and the
/// filters it offers, so a filter the user turned on comes back when the
/// model offers it again.
(String?, String, String) _defaultFiltersKey(Model? model) => (
  model?.id,
  defaultFilterIdsForModel(model).join('\n'),
  [for (final filter in model?.filters ?? const <ToggleFilter>[]) filter.id]
      .join('\n'),
);

/// Provider for selected filter IDs (toggle filters enabled by user).
///
/// These filters are dynamically created by OpenWebUI filters with
/// `toggle = True` set in their module. They appear as toggleable
/// buttons in the chat input UI.
///
/// A new conversation starts from the selected model's default filters. On
/// a switch of model, as on Open WebUI 0.12.5, the new model's defaults apply
/// while the filters the user turned on or off stay so: one turned on stays
/// on where the new model offers it, and one turned off stays off.
@Riverpod(keepAlive: true)
class SelectedFilterIds extends _$SelectedFilterIds {
  /// What the user turned on and off since the conversation began. The
  /// notifier outlives a model switch, which rebuilds it.
  final Set<String> _added = <String>{};
  final Set<String> _removed = <String>{};
  Object? _session;

  @override
  List<String> build() {
    // Another chat or account starts from the defaults again.
    final session = ref.watch(chatPicksSessionProvider);
    if (!identical(session, _session)) {
      _session = session;
      _added.clear();
      _removed.clear();
    }
    ref.watch(selectedModelProvider.select(_defaultFiltersKey));
    final model = ref.read(selectedModelProvider);
    final defaults = defaultFilterIdsForModel(model);
    final offered = <String>{
      for (final filter in model?.filters ?? const <ToggleFilter>[]) filter.id,
    };
    return [
      for (final id in defaults)
        if (!_removed.contains(id)) id,
      for (final id in _added)
        if (offered.contains(id) && !defaults.contains(id)) id,
    ];
  }

  void set(List<String> ids) {
    final before = state.toSet();
    final after = ids.toSet();
    for (final id in after.difference(before)) {
      _added.add(id);
      _removed.remove(id);
    }
    for (final id in before.difference(after)) {
      _removed.add(id);
      _added.remove(id);
    }
    state = List<String>.from(ids);
  }

  /// Goes back to the selected model's default filters, for a new
  /// conversation.
  void reset() {
    _added.clear();
    _removed.clear();
    state = defaultFilterIdsForModel(ref.read(selectedModelProvider));
  }

  void toggle(String id) {
    if (state.contains(id)) {
      set(state.where((i) => i != id).toList());
    } else {
      set([...state, id]);
    }
  }

  void clear() => set(const <String>[]);
}

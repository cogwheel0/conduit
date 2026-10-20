part of 'api_service.dart';

mixin _UserSettingsApi on _ApiServiceBase {
  /// Runs a user-settings mutation after every mutation already submitted to
  /// this API service.
  ///
  /// Open WebUI replaces the complete settings document on update, so every
  /// read-modify-write sequence must share this boundary to avoid committing
  /// an older snapshot over another feature's change. A failed operation is
  /// still removed from the tail so it cannot poison later mutations.
  Future<T> serializeUserSettingsMutation<T>(Future<T> Function() operation) {
    final result = _userSettingsMutationQueue.then<T>((_) => operation());
    _userSettingsMutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  // User Settings
  Future<Map<String, dynamic>> getUserSettings({
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Fetching user settings');
    final response = await _dio.get(
      '/api/v1/users/user/settings',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final data = response.data;
    // Handle null response from server (happens for new users with no settings)
    if (data is Map<String, dynamic>) {
      return data;
    }
    return <String, dynamic>{};
  }

  Future<void> updateUserSettings(
    Map<String, dynamic> settings, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Updating user settings');
    // Align with web client update route
    await _postUserSettings(settings, authSnapshot: authSnapshot);
  }

  @override
  Future<ServerUserSettings> getServerUserSettingsModel() async {
    return ServerUserSettings.fromJson(await getUserSettings());
  }

  Future<ServerUserSettings> updateUserSystemPrompt(String? systemPrompt) {
    final authSnapshot = captureAuthSnapshot();
    return serializeUserSettingsMutation(() async {
      final settings = _deepCloneJsonMap(
        await getUserSettings(authSnapshot: authSnapshot),
      );
      final ui = _coerceJsonMap(settings['ui']) ?? <String, dynamic>{};
      final trimmed = _normalizeNullableString(systemPrompt);

      if (trimmed == null || trimmed.isEmpty) {
        // Open WebUI >= 0.11.4 patches `ui` per key: an omitted key keeps its
        // old value and only an explicit null resets it. Older servers store
        // the null literally, which the reader already treats as unset.
        ui['system'] = null;
      } else {
        ui['system'] = trimmed;
      }

      settings.remove('system');
      settings['ui'] = ui;
      _traceApi('Updating user system prompt');
      final response = await _postUserSettings(
        settings,
        authSnapshot: authSnapshot,
      );
      final data = _coerceResponseMap(response.data) ?? settings;
      return ServerUserSettings.fromJson(data);
    });
  }

  Future<ServerUserSettings> updateUserReasoningEffort(String? effort) {
    final authSnapshot = captureAuthSnapshot();
    return serializeUserSettingsMutation(() async {
      final settings = _deepCloneJsonMap(
        await getUserSettings(authSnapshot: authSnapshot),
      );
      final params = _coerceJsonMap(settings['params']) ?? <String, dynamic>{};
      final trimmed = _normalizeNullableString(effort);

      if (trimmed == null) {
        params.remove('reasoning_effort');
      } else {
        params['reasoning_effort'] = trimmed;
      }

      // OpenWebUI shallow-merges the top-level settings object. Posting no
      // `params` key would therefore preserve the previous nested map.
      settings['params'] = params;
      _traceApi('Updating user reasoning effort');
      final response = await _postUserSettings(
        settings,
        authSnapshot: authSnapshot,
      );
      final data = _coerceResponseMap(response.data) ?? settings;
      return ServerUserSettings.fromJson(data);
    });
  }

  Future<ServerUserSettings> updateUserMemoryEnabled(bool enabled) {
    final authSnapshot = captureAuthSnapshot();
    return serializeUserSettingsMutation(() async {
      final settings = _deepCloneJsonMap(
        await getUserSettings(authSnapshot: authSnapshot),
      );
      final ui = _coerceJsonMap(settings['ui']) ?? <String, dynamic>{};
      ui['memory'] = enabled;
      settings['ui'] = ui;

      final response = await _postUserSettings(
        settings,
        authSnapshot: authSnapshot,
      );
      final data = _coerceResponseMap(response.data) ?? settings;
      return ServerUserSettings.fromJson(data);
    });
  }

  /// Persists the notification preferences that Open WebUI stores server-side.
  /// These live at the top level of the user settings object (not under `ui`).
  /// Only non-null values are written so callers can update a subset.
  Future<ServerUserSettings> updateUserNotificationSettings({
    bool? notificationEnabled,
    bool? notificationSound,
    bool? notificationSoundAlways,
  }) {
    final authSnapshot = captureAuthSnapshot();
    return serializeUserSettingsMutation(() async {
      final settings = _deepCloneJsonMap(
        await getUserSettings(authSnapshot: authSnapshot),
      );
      if (notificationEnabled != null) {
        settings['notificationEnabled'] = notificationEnabled;
      }
      if (notificationSound != null) {
        settings['notificationSound'] = notificationSound;
      }
      if (notificationSoundAlways != null) {
        settings['notificationSoundAlways'] = notificationSoundAlways;
      }

      _traceApi('Updating user notification settings');
      final response = await _postUserSettings(
        settings,
        authSnapshot: authSnapshot,
      );
      final data = _coerceResponseMap(response.data) ?? settings;
      return ServerUserSettings.fromJson(data);
    });
  }

  /// Applies [edit] to the personal connection list [kind] and saves it under
  /// `ui`, where Open WebUI's own settings screen keeps it.
  ///
  /// The edit runs against the latest server copy inside the shared mutation
  /// queue, so it cannot overwrite a concurrent change to any other setting.
  /// [authSnapshot] is taken before queueing when the caller passes none: a
  /// write that waits behind other mutations still belongs to the account that
  /// asked for it, and is refused if that account has since changed. The
  /// returned lists come from the server's response, and a response that does
  /// not hold the written list throws [PersonalConnectionsWriteRejected].
  Future<PersonalConnectionsWrite> editPersonalConnections(
    PersonalConnectionKind kind,
    PersonalConnectionEdit edit, {
    ApiAuthSnapshot? authSnapshot,
  }) {
    final snapshot = authSnapshot ?? captureAuthSnapshot();
    return serializeUserSettingsMutation(() async {
      final settings = _deepCloneJsonMap(
        await getUserSettings(authSnapshot: snapshot),
      );
      final before = effectivePersonalServerList(settings, kind.settingsKey);
      final result = edit.apply(kind, before);

      final ui = _coerceJsonMap(settings['ui']) ?? <String, dynamic>{};
      ui[kind.settingsKey] = result.list;
      settings['ui'] = ui;
      _traceApi('Updating personal ${kind.name} connections');
      final response = await _postUserSettings(
        settings,
        authSnapshot: snapshot,
      );
      final canonical =
          _coerceResponseMap(response.data) ??
          await getUserSettings(authSnapshot: snapshot);
      final after = effectivePersonalServerList(canonical, kind.settingsKey);
      if (!const DeepCollectionEquality().equals(after, result.list)) {
        throw PersonalConnectionsWriteRejected(kind);
      }
      return PersonalConnectionsWrite(
        kind: kind,
        before: before,
        after: after,
        indexMap: result.indexMap,
        entryIndex: result.entryIndex,
        settings: canonical,
      );
    });
  }

  Future<ServerUserSettings> updateUserPinnedModels(List<String> modelIds) {
    final authSnapshot = captureAuthSnapshot();
    return serializeUserSettingsMutation(() async {
      final settings = _deepCloneJsonMap(
        await getUserSettings(authSnapshot: authSnapshot),
      );
      final ui = _coerceJsonMap(settings['ui']) ?? <String, dynamic>{};
      ui['pinnedModels'] = SettingsService.sanitizePinnedModels(modelIds);
      settings['ui'] = ui;

      final response = await _postUserSettings(
        settings,
        authSnapshot: authSnapshot,
      );
      final data = _coerceResponseMap(response.data) ?? settings;
      return ServerUserSettings.fromJson(data);
    });
  }

  // Memory & Notes
  Future<List<ServerMemory>> getMemories({
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Fetching memories');
    final response = await _dio.get(
      '/api/v1/memories/',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final data = response.data;
    if (data is List) {
      return data
          .whereType<Map>()
          .map((entry) => ServerMemory.fromJson(entry.cast<String, dynamic>()))
          .toList(growable: false);
    }
    return const <ServerMemory>[];
  }

  /// Creates a memory. Open WebUI defaults an omitted type to `context`, so a
  /// personal entry states [type] explicitly (`user`, as the web client does).
  /// [path] is sent only when non-empty.
  Future<ServerMemory> createMemory({
    required String content,
    String type = ServerMemory.userType,
    String? path,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Creating memory');
    final trimmedPath = path?.trim();
    final response = await _dio.post(
      '/api/v1/memories/add',
      data: {
        'content': content,
        'type': type,
        if (trimmedPath != null && trimmedPath.isNotEmpty) 'path': trimmedPath,
      },
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final data = _coerceResponseMap(response.data);
    if (data == null) {
      throw StateError('Unexpected memory create response type.');
    }
    return ServerMemory.fromJson(data);
  }

  /// Updates a memory. The server keeps whatever it already stores for a field
  /// that is omitted, so a content-only edit leaves the original type and path
  /// untouched. Pass [type] or [path] only to change them; an empty [path]
  /// clears it.
  Future<ServerMemory> updateMemory({
    required String memoryId,
    required String content,
    String? type,
    String? path,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Updating memory');
    final response = await _dio.post(
      '/api/v1/memories/$memoryId/update',
      data: {'content': content, 'type': ?type, 'path': ?path?.trim()},
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final data = _coerceResponseMap(response.data);
    if (data == null) {
      throw StateError('Unexpected memory update response type.');
    }
    return ServerMemory.fromJson(data);
  }

  Future<void> deleteMemory(
    String memoryId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Deleting memory');
    await _dio.delete(
      '/api/v1/memories/$memoryId',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  Future<void> clearAllMemories({ApiAuthSnapshot? authSnapshot}) async {
    _traceApi('Clearing all memories');
    await _dio.delete(
      '/api/v1/memories/delete/user',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }
}

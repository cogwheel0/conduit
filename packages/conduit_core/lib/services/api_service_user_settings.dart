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
  Future<List<ServerMemory>> getMemories() async {
    _traceApi('Fetching memories');
    final response = await _dio.get('/api/v1/memories/');
    final data = response.data;
    if (data is List) {
      return data
          .whereType<Map>()
          .map((entry) => ServerMemory.fromJson(entry.cast<String, dynamic>()))
          .toList(growable: false);
    }
    return const <ServerMemory>[];
  }

  Future<ServerMemory> createMemory({required String content}) async {
    _traceApi('Creating memory');
    final response = await _dio.post(
      '/api/v1/memories/add',
      data: {'content': content},
    );
    final data = _coerceResponseMap(response.data);
    if (data == null) {
      throw StateError('Unexpected memory create response type.');
    }
    return ServerMemory.fromJson(data);
  }

  Future<ServerMemory> updateMemory({
    required String memoryId,
    required String content,
  }) async {
    _traceApi('Updating memory');
    final response = await _dio.post(
      '/api/v1/memories/$memoryId/update',
      data: {'content': content},
    );
    final data = _coerceResponseMap(response.data);
    if (data == null) {
      throw StateError('Unexpected memory update response type.');
    }
    return ServerMemory.fromJson(data);
  }

  Future<void> deleteMemory(String memoryId) async {
    _traceApi('Deleting memory');
    await _dio.delete('/api/v1/memories/$memoryId');
  }

  Future<void> clearAllMemories() async {
    _traceApi('Clearing all memories');
    await _dio.delete('/api/v1/memories/delete/user');
  }
}

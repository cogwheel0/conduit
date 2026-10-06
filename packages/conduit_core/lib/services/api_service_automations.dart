part of 'api_service.dart';

/// Open WebUI scheduled tasks under `/api/v1/automations`.
///
/// Every call requires the [ApiAuthSnapshot] of the account that asked for it,
/// so a request admitted for one account can never be sent with the
/// credentials of the account that signed in afterwards on this same
/// [ApiService]. Only a task's owner can read or change it, an admin included.
///
/// These routes only record what the server will do. A task runs on the
/// server's schedule whether or not this device is online.
mixin _AutomationsApi on _ApiServiceBase {
  static const String _base = '/api/v1/automations';

  String _automationPath(String id) => '$_base/${Uri.encodeComponent(id)}';

  /// One page of the account's tasks, newest first. [page] counts from 1 and
  /// the server fixes the page size. [status] is `active` or `paused`; null
  /// lists both.
  Future<AutomationPage> getAutomations({
    String? query,
    String? status,
    String? folderId,
    int page = 1,
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Fetching automations');
    final trimmedQuery = query?.trim();
    final response = await _dio.get(
      '$_base/list',
      queryParameters: <String, dynamic>{
        if (trimmedQuery != null && trimmedQuery.isNotEmpty)
          'query': trimmedQuery,
        if (status != null && status != 'all') 'status': status,
        'page': page,
        if (folderId != null && folderId.isNotEmpty) 'folder_id': folderId,
      },
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = _requireResponseMap(response.data, 'automations');
    final items = body['items'];
    final total = body['total'];
    if (items is! List) {
      throw const FormatException('automations: missing items list');
    }
    return AutomationPage(
      items: List<Automation>.unmodifiable([
        for (final entry in items)
          if (entry is Map) Automation.fromJson(entry.cast<String, dynamic>()),
      ]),
      total: total is int ? total : items.length,
    );
  }

  Future<Automation> getAutomation(
    String id, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Fetching automation');
    final response = await _dio.get(
      _automationPath(id),
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return Automation.fromJson(
      _requireResponseMap(response.data, 'automation'),
    );
  }

  Future<Automation> createAutomation(
    AutomationForm form, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Creating automation');
    final response = await _dio.post(
      '$_base/create',
      data: form.toJson(),
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return Automation.fromJson(
      _requireResponseMap(response.data, 'automation'),
    );
  }

  /// Replaces the task with [form]. The server overwrites name, folder, data,
  /// meta and (when sent) the active flag from it, so the form must carry the
  /// task's whole `data` and `meta`.
  Future<Automation> updateAutomation(
    String id,
    AutomationForm form, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Updating automation');
    final response = await _dio.post(
      '${_automationPath(id)}/update',
      data: form.toJson(),
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return Automation.fromJson(
      _requireResponseMap(response.data, 'automation'),
    );
  }

  /// Flips the task between active and paused on the server. The result
  /// carries the state the server holds now.
  Future<Automation> toggleAutomation(
    String id, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Toggling automation');
    final response = await _dio.post(
      '${_automationPath(id)}/toggle',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return Automation.fromJson(
      _requireResponseMap(response.data, 'automation'),
    );
  }

  /// Asks the server to run the task now.
  ///
  /// The server starts the run in the background and answers with the task's
  /// definition, not a run record. A successful return means the request was
  /// accepted, not that the run finished or succeeded; the outcome appears in
  /// [getAutomationRuns] when the server records it.
  Future<Automation> runAutomation(
    String id, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Requesting automation run');
    final response = await _dio.post(
      '${_automationPath(id)}/run',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return Automation.fromJson(
      _requireResponseMap(response.data, 'automation'),
    );
  }

  Future<void> deleteAutomation(
    String id, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Deleting automation');
    final response = await _dio.delete(
      '${_automationPath(id)}/delete',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    if (response.data != true) {
      throw const FormatException('automation delete: server did not confirm');
    }
  }

  /// Whether the account may post to [channelId], as the server reports it on
  /// the channel itself. The channel list does not carry this, and the server
  /// refuses a task whose channel destination the owner cannot write to.
  Future<bool> getAutomationChannelWriteAccess(
    String channelId, {
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Reading channel write access');
    final response = await _dio.get(
      '/api/v1/channels/${Uri.encodeComponent(channelId)}',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = _requireResponseMap(response.data, 'channel');
    return body['write_access'] == true;
  }

  /// The task's history, newest first, [limit] entries from offset [skip].
  /// A page shorter than [limit] is the last.
  Future<List<AutomationRun>> getAutomationRuns(
    String id, {
    int skip = 0,
    int limit = automationRunsPageSize,
    required ApiAuthSnapshot authSnapshot,
  }) async {
    _traceApi('Fetching automation runs');
    final response = await _dio.get(
      '${_automationPath(id)}/runs',
      queryParameters: <String, dynamic>{'skip': skip, 'limit': limit},
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final body = response.data;
    if (body is! List) {
      throw const FormatException('automation runs: expected a list');
    }
    return List<AutomationRun>.unmodifiable([
      for (final entry in body)
        if (entry is Map) AutomationRun.fromJson(entry.cast<String, dynamic>()),
    ]);
  }
}

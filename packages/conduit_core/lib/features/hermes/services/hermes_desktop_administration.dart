part of 'hermes_desktop_api_service.dart';

final class _HermesDesktopAdministration {
  const _HermesDesktopAdministration(this._owner);

  final HermesDesktopApiService _owner;

  Future<List<HermesDesktopModelOption>> configuredModels() async {
    await _owner._ensureConnected();
    final result = _owner._object(
      await _owner._rpc.request<Object?>(
        'model.options',
        params: const {'explicit_only': true},
      ),
    );
    return parseHermesDesktopConfiguredModels(result)
        .map(HermesDesktopModelOption.fromJson)
        .where((model) => model.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> listSkills() async {
    await _owner._ensureConnected();
    final installed = _owner._object(
      await _owner._rpc.request<Object?>(
        'skills.manage',
        params: const {'action': 'list'},
      ),
    );
    final commands = await listCommands();
    final descriptions = <String, String>{};
    for (final command in commands) {
      descriptions[command['name']?.toString() ?? ''] =
          command['description']?.toString() ?? '';
    }
    // Hermes lists installed skills by category (`{category: [names]}`);
    // a plain list is read as well.
    final listed = installed['skills'];
    final rows = listed is Map
        ? [
            for (final names in listed.values)
              if (names is List) ...names,
          ]
        : listed;
    if (rows is! List) return const [];
    return rows
        .take(256)
        .map<Map<String, dynamic>>((row) {
          final map = row is Map ? Map<String, dynamic>.from(row) : null;
          final name = (map?['name'] ?? row).toString().replaceFirst(
            RegExp(r'^/'),
            '',
          );
          return {
            'name': name,
            'description':
                map?['description']?.toString() ?? descriptions[name] ?? '',
          };
        })
        .where((row) => (row['name'] as String).isNotEmpty)
        .toList();
  }

  Future<List<Map<String, dynamic>>> listCommands() async {
    await _owner._ensureConnected();
    final result = _owner._object(
      await _owner._rpc.request<Object?>('commands.catalog'),
    );
    final rows =
        result['pairs'] ??
        result['commands'] ??
        result['all'] ??
        result['items'];
    if (rows is! List) return const [];
    return rows
        .take(1000)
        .map<Map<String, dynamic>>((row) {
          if (row is List && row.isNotEmpty) {
            return {
              'name': row.first.toString().replaceFirst(RegExp(r'^/'), ''),
              'description': row.length > 1 ? row[1].toString() : '',
            };
          }
          return row is Map ? Map<String, dynamic>.from(row) : const {};
        })
        .where((row) => row.isNotEmpty)
        .toList();
  }

  Future<Map<String, dynamic>> reloadSkills() async {
    await _owner._ensureConnected();
    if (_owner._canonical) {
      // A session authority rescans skills for a chat it serves, which
      // refreshes the command map every chat reads. With no chat open there
      // is no map to refresh: the next chat reads the skills afresh.
      final storedId = _owner._bindings.values.firstOrNull?.storedId;
      if (storedId == null) return const {};
      final binding = await _owner._resume(storedId);
      return _owner._object(
        await _owner._rpc.request<Object?>(
          'skills.reload',
          params: {
            'session_id': binding.runtimeId,
            ..._owner._sessionScope(binding.storedId),
          },
        ),
      );
    }
    return _owner._object(await _owner._rpc.request<Object?>('skills.reload'));
  }

  /// `tools.list` takes no `profile` (Hermes 0.23 refuses one with 4000);
  /// it lists the gateway's own profile's toolsets.
  Future<List<Map<String, dynamic>>> listToolsets() async {
    await _owner._ensureConnected();
    final result = _owner._object(
      await _owner._rpc.request<Object?>(
        'tools.list',
        includeDefaultParams: false,
      ),
    );
    return _owner._objects(result['sections'] ?? result['toolsets']);
  }

  Future<void> configureTools(
    List<String> names, {
    required bool enabled,
  }) async {
    await _owner._ensureConnected();
    await _owner._rpc.request<Object?>(
      'tools.configure',
      params: {'action': enabled ? 'enable' : 'disable', 'names': names},
    );
  }

  Future<List<HermesMcpServer>> mcpServers() async => _owner
      ._objects((await mcpRequest('mcp.servers.list'))['servers'])
      .map(HermesMcpServer.fromJson)
      .where((server) => server.name.isNotEmpty)
      .toList(growable: false);

  Future<List<HermesMcpCatalogEntry>> mcpCatalog() async {
    final rows = (await mcpRequest('mcp.catalog'))['servers'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map(HermesMcpCatalogEntry.fromJson)
        .where((entry) => entry.name.isNotEmpty && !entry.installed)
        .toList(growable: false);
  }

  Future<void> addMcpServer({
    required String name,
    String? url,
    String? command,
    List<String> arguments = const [],
    String? bearerToken,
    HermesMcpToolFilter? toolFilter,
  }) async {
    await mcpRequest(
      'mcp.servers.add',
      params: {
        'name': name,
        'config': hermesMcpServerConfig(
          url: url,
          command: command,
          arguments: arguments,
          toolFilter: toolFilter,
        ),
        if (bearerToken?.isNotEmpty == true) 'bearer_token': bearerToken,
      },
    );
    await reloadMcp();
  }

  Future<void> addMcpPreset(String name) async {
    await mcpRequest('mcp.servers.add', params: {'name': name, 'preset': name});
    await reloadMcp();
  }

  Future<HermesMcpTestResult> testMcpServer(String name) async =>
      HermesMcpTestResult.fromJson(
        await mcpRequest('mcp.servers.test', params: {'name': name}),
      );

  Future<void> setMcpApiKey(String name, String value) async {
    await mcpRequest(
      'mcp.servers.set_api_key',
      params: {'name': name, 'value': value},
    );
    await reloadMcp();
  }

  Future<void> removeMcpServer(String name) async {
    await mcpRequest('mcp.servers.remove', params: {'name': name});
    await reloadMcp();
  }

  Future<bool> authenticateMcpServer(String name) async {
    final result = await _completeMcpOAuth(name);
    if (result == null) return false;
    await reloadMcp();
    return true;
  }

  Future<Map<String, dynamic>?> _completeMcpOAuth(String name) async {
    final started = await mcpRequest(
      'mcp.servers.oauth.start',
      params: {'name': name},
    );
    final flowId = validateHermesOpaqueIdentifier(started['session_id']);
    final authUrl = parseHermesOAuthUrl(started['auth_url']);
    if (flowId == null ||
        authUrl == null ||
        !await _owner._openExternalUrl.open(authUrl)) {
      return null;
    }
    for (var attempt = 0; attempt < 60; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final status = (await mcpRequest(
        'mcp.servers.oauth.poll',
        params: {'name': name, 'session_id': flowId},
      ));
      if (_owner._closed) return null;
      final state = status['status']?.toString();
      if (const {'approved', 'authorized', 'complete'}.contains(state)) {
        return status;
      }
      if (const {'error', 'failed', 'expired'}.contains(state)) return null;
    }
    return null;
  }

  Future<Map<String, dynamic>> mcpRequest(
    String method, {
    Map<String, dynamic> params = const {},
  }) async {
    await _owner._ensureConnected();
    try {
      return _owner._object(
        await _owner._rpc.request<Object?>(method, params: params),
      );
    } on HermesDesktopRpcException catch (error) {
      if (error.code != -32601) rethrow;
      if (method.startsWith('mcp.servers.')) {
        _owner._supportsMcpRpcLifecycle = false;
      }
      return _mcpRestFallback(method, params);
    }
  }

  Future<Map<String, dynamic>> _mcpRestFallback(
    String method,
    Map<String, dynamic> params,
  ) async {
    final name = params['name']?.toString() ?? '';
    final encodedName = Uri.encodeComponent(name);
    switch (method) {
      case 'mcp.servers.list':
        return _owner._object(
          await _owner._requestJson('GET', '/api/mcp/servers'),
        );
      case 'mcp.catalog':
        final result = _owner._object(
          await _owner._requestJson('GET', '/api/mcp/catalog'),
        );
        return {...result, 'servers': result['entries'] ?? const []};
      case 'mcp.servers.add':
        final preset = params['preset']?.toString();
        if (preset != null && preset.isNotEmpty) {
          return _owner._object(
            await _owner._requestJson(
              'POST',
              '/api/mcp/catalog/install',
              body: {'name': preset, 'enable': true},
            ),
          );
        }
        final config = _owner._object(params['config']);
        return _owner._object(
          await _owner._requestJson(
            'POST',
            '/api/mcp/servers',
            body: {
              'name': name,
              ...config,
              if (params['bearer_token'] != null)
                'bearer_token': params['bearer_token'],
            },
          ),
        );
      case 'mcp.servers.test':
        return _owner._object(
          await _owner._requestJson(
            'POST',
            '/api/mcp/servers/$encodedName/test',
          ),
        );
      case 'mcp.servers.remove':
        return _owner._object(
          await _owner._requestJson('DELETE', '/api/mcp/servers/$encodedName'),
        );
      case 'mcp.servers.oauth.start':
        final result = _owner._object(
          await _owner._requestJson(
            'POST',
            '/api/mcp/servers/$encodedName/auth',
          ),
        );
        return {
          ...result,
          'session_id': result['flow_id'],
          'auth_url': result['authorization_url'],
        };
      case 'mcp.servers.oauth.poll':
        final flowId = Uri.encodeComponent(
          params['session_id']?.toString() ?? '',
        );
        return _owner._object(
          await _owner._requestJson('GET', '/api/mcp/oauth/flows/$flowId'),
        );
      default:
        throw StateError(
          'Upgrade Hermes Desktop Gateway to use this MCP operation.',
        );
    }
  }

  Future<void> setMcpServerEnabled(String name, bool enabled) async {
    await _owner._requestJson(
      'PUT',
      '/api/mcp/servers/${Uri.encodeComponent(name)}/enabled',
      body: {'enabled': enabled},
    );
    await reloadMcp();
  }

  Future<void> reloadMcp({String? runtimeId}) async {
    await _owner._ensureConnected();
    final runtimeIds = <String>{};
    if (runtimeId != null) {
      runtimeIds.add(runtimeId);
    } else {
      for (final storedId
          in _owner._bindings.values
              .map((binding) => binding.storedId)
              .toSet()) {
        runtimeIds.add((await _owner._resume(storedId)).runtimeId);
      }
    }
    for (final id in runtimeIds) {
      // Takes no `profile` (Hermes 0.23 refuses one with 4000): the session
      // id scopes it, bot chats in another profile included.
      await _owner._rpc.request<Object?>(
        'reload.mcp',
        params: {'confirm': true, 'session_id': id},
        includeDefaultParams: false,
      );
    }
  }

  Future<Map<String, dynamic>> capabilities() async {
    Future<bool> supported(Future<Object?> Function() probe) async {
      try {
        await probe();
        return true;
      } on HermesDesktopRpcException catch (error) {
        if (error.code == -32601) return false;
        return false;
      } on DioException catch (error) {
        if (error.response?.statusCode == 404) return false;
        return false;
      } catch (_) {
        return false;
      }
    }

    await _owner._ensureConnected();
    final support = await Future.wait<bool>([
      supported(
        () => _owner._rpc.request<Object?>(
          'skills.manage',
          params: const {'action': 'list'},
        ),
      ),
      supported(
        () => _owner._rpc.request<Object?>(
          'tools.list',
          includeDefaultParams: false,
        ),
      ),
      supported(
        () => _owner._requestJson('GET', '/api/cron/jobs', query: {'limit': 1}),
      ),
    ]);
    final [skills, toolsets, jobs] = support;
    return {
      'run_approval': true,
      'skills': skills,
      'toolsets': toolsets,
      'jobs': jobs,
      'jobs_admin': jobs,
      'sessions': true,
      'desktop_gateway': true,
      'desktop_uploads': _owner._desktopContract >= 2,
      'authoritative_running': _owner._authoritativeRunning,
    };
  }

  Future<List<Map<String, dynamic>>> listJobs() async =>
      _owner._objects(await _owner._requestJson('GET', '/api/cron/jobs'));

  Future<Map<String, dynamic>> createJob({
    required String name,
    required String prompt,
    required String schedule,
  }) async => _owner._object(
    await _owner._requestJson(
      'POST',
      '/api/cron/jobs',
      body: {
        'name': name,
        'prompt': prompt,
        'schedule': schedule,
        'deliver': 'local',
      },
    ),
  );

  Future<void> updateJob(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
    bool? enabled,
  }) async {
    await _owner._requestJson(
      'PUT',
      '/api/cron/jobs/${Uri.encodeComponent(id)}',
      body: {
        'updates': {
          'name': ?name,
          'prompt': ?prompt,
          'schedule': ?schedule,
          'enabled': ?enabled,
        },
      },
    );
  }

  Future<void> mutateJob(String id, String method, String suffix) async {
    await _owner._requestJson(
      method,
      '/api/cron/jobs/${Uri.encodeComponent(id)}$suffix',
    );
  }

  Future<List<Map<String, dynamic>>> listJobRuns(String id) async =>
      _owner._objects(
        await _owner._requestJson(
          'GET',
          '/api/cron/jobs/${Uri.encodeComponent(id)}/runs',
          query: {'limit': 20},
        ),
        'runs',
      );
  /// Approves or skips one target of a connection operation (the
  /// `manage_connections` card). Hermes does the work itself once a target
  /// is approved: it installs, enables, or starts the authorization, whose
  /// browser link arrives in a later `connection.update`.
  ///
  /// A target whose sign-in Hermes started before sending the card (an MCP
  /// authorization, a hosted connector) waits on its link alone: approving
  /// it opens the link.
  Future<void> respondToConnection({
    required String runtimeId,
    required String cardId,
    required bool approved,
  }) async {
    final card = parseHermesConnectionCardId(cardId);
    final target = _owner._rpc.connectionCardTarget(cardId);
    if (card == null || target == null) {
      throw StateError('Hermes returned an invalid connection request.');
    }
    final link = approved ? _owner._rpc.connectionLink(cardId) : null;
    if (link != null) {
      if (!await _owner._openExternalUrl.open(link)) {
        throw StateError('Could not open the sign-in link.');
      }
      return;
    }
    if (approved) _owner._approvedConnectionTargets.add(cardId);
    await _owner._rpc.request<Object?>(
      'connection.respond',
      params: {
        'owner': {'type': 'session', 'session_id': runtimeId},
        'op_id': card.operationId,
        'result': {
          'targets': [
            {'name': target, 'status': approved ? 'approved' : 'skipped'},
          ],
        },
        ..._owner._runtimeScope(runtimeId),
      },
    );
  }

  /// Opens the authorization link of a target the user approved here, once:
  /// a connection update carries it when the target's sign-in starts.
  ///
  /// An approved install Hermes keeps waiting instead names the credentials
  /// it still lacks (`required_env`), which only the Hermes host can supply:
  /// its card comes back, so the user can set them there and approve again,
  /// or skip it. That update is the target's own refresh, still `pending`.
  void openApprovedConnectionLink(Map<String, dynamic> update) {
    final operationId = update['op_id']?.toString();
    final targets = update['targets'];
    if (operationId == null || targets is! List) return;
    for (final target in targets.whereType<Map>()) {
      final cardId = hermesConnectionCardId(operationId, '${target['name']}');
      if (target['state'] == 'pending' &&
          update['target'] == target['name'] &&
          update['from'] == 'pending' &&
          update['to'] == 'pending' &&
          _needsCredentials(target['required_env']) &&
          _owner._approvedConnectionTargets.remove(cardId)) {
        _owner._rpc.offerConnectionTargetAgain(cardId, update);
        continue;
      }
      final link = parseHermesOAuthUrl(target['connect_url']);
      if (link == null ||
          target['state'] != 'initiated' ||
          !_owner._approvedConnectionTargets.remove(cardId)) {
        continue;
      }
      unawaited(_openApprovedLink(cardId, link, update));
    }
  }

  /// Whether a target's `required_env` names a credential the install
  /// cannot run without.
  bool _needsCredentials(Object? fields) =>
      fields is List &&
      fields.whereType<Map>().any((field) => field['required'] != false);

  /// Opens [link]; when the device refuses it, [cardId]'s card comes back,
  /// and approving it again opens the link from there.
  Future<void> _openApprovedLink(
    String cardId,
    Uri link,
    Map<String, dynamic> update,
  ) async {
    var opened = false;
    try {
      opened = await _owner._openExternalUrl.open(link);
    } catch (_) {
      opened = false;
    }
    if (!opened) _owner._rpc.offerConnectionTargetAgain(cardId, update);
  }
}

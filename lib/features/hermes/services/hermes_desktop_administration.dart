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
    final rows = installed['skills'];
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
    return _owner._object(await _owner._rpc.request<Object?>('skills.reload'));
  }

  Future<List<Map<String, dynamic>>> listToolsets() async {
    await _owner._ensureConnected();
    final result = _owner._object(
      await _owner._rpc.request<Object?>('tools.list'),
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
  }) async {
    await mcpRequest(
      'mcp.servers.add',
      params: {
        'name': name,
        'config': {
          if (url?.isNotEmpty == true) 'url': url,
          if (command?.isNotEmpty == true) 'command': command,
          if (arguments.isNotEmpty) 'args': arguments,
        },
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
        !await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
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
      await _owner._rpc.request<Object?>(
        'reload.mcp',
        // Bound sessions can include bot chats, which live in another profile.
        params: {'confirm': true, 'session_id': id, ..._owner._runtimeScope(id)},
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
      supported(() => _owner._rpc.request<Object?>('tools.list')),
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
  Future<void> respondToMcpSetup({
    required String runtimeId,
    required String requestId,
    required bool approved,
    required String? server,
    required String? action,
  }) async {
    final safeServer = validateHermesBoundedString(server, maxCharacters: 128);
    final safeAction = const {'authorize', 'enable', 'install'}.contains(action)
        ? action
        : null;
    if (safeServer == null || safeAction == null) {
      throw StateError('Hermes returned an invalid MCP setup request.');
    }
    Map<String, dynamic> outcome = {'server': safeServer, 'status': 'declined'};
    if (approved) {
      try {
        switch (safeAction) {
          case 'install':
            await mcpRequest(
              'mcp.servers.add',
              params: {'name': safeServer, 'preset': safeServer},
            );
            outcome = {'server': safeServer, 'status': 'installed'};
          case 'enable':
            await setMcpServerEnabled(safeServer, true);
            outcome = {'server': safeServer, 'status': 'enabled'};
          case 'authorize':
            final approvedResult = await _completeMcpOAuth(safeServer);
            if (approvedResult == null) {
              throw TimeoutException('MCP authorization timed out.');
            }
            outcome = {
              'server': safeServer,
              'status': 'authorized',
              if (approvedResult['tools'] is List)
                'tools': (approvedResult['tools'] as List)
                    .take(1000)
                    .map((tool) => tool.toString())
                    .toList(growable: false),
            };
        }
        await reloadMcp(runtimeId: runtimeId);
      } catch (error) {
        DebugLogger.warning(
          'mcp-setup-failed',
          scope: 'hermes/mcp',
          data: {'errorType': error.runtimeType.toString()},
        );
        outcome = {
          'server': safeServer,
          'status': 'error',
          'detail': 'MCP setup failed. Open Hermes MCP settings to retry.',
        };
      }
    }
    await _owner._rpc.request<Object?>(
      'mcp.setup.respond',
      params: {
        'session_id': runtimeId,
        'request_id': requestId,
        'result': jsonEncode(outcome),
        ..._owner._runtimeScope(runtimeId),
      },
    );
    await HermesPendingDecisionStore.resolve(
      origin: _owner._origin,
      runtimeId: runtimeId,
      requestId: requestId,
    );
  }
}

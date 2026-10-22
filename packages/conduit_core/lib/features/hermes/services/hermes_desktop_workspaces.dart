part of 'hermes_desktop_api_service.dart';

extension _HermesDesktopWorkspaces on HermesDesktopApiService {
  void _validateProfile(String profile) {
    if (!HermesConfig.isValidDesktopProfile(profile)) {
      throw ArgumentError('Invalid profile');
    }
  }

  Future<Map<String, dynamic>> _profileRow(String profile) async {
    _validateProfile(profile);
    final list = await _messagesProfileRequest('profiles.list', {
      'include_sessions': false,
    });
    for (final row in _objects(list['profiles'])) {
      if (row['name'] == profile) return row;
    }
    throw StateError('This bot no longer exists. Refresh the bot list.');
  }

  Future<void> _configureBot(
    String profile,
    Map<String, dynamic> changes,
  ) async {
    _validateProfile(profile);
    const allowed = {
      'soul',
      'description',
      'model',
      'provider',
      'disabled_skills',
      'enabled_toolsets',
      'enabled_mcp_servers',
      'ui_meta',
      'ui_meta_expected_revisions',
      'confirm_expensive_model',
    };
    if (changes.keys.any((key) => !allowed.contains(key))) {
      throw ArgumentError('Unsupported bot setting');
    }
    final result = await _messagesProfileRequest('profiles.configure', {
      ...changes,
      'name': profile,
      'profile': profile,
    });
    final applied = result['applied'];
    if (result['confirm_required'] == true) {
      throw HermesBotModelConfirmation(
        result['confirm_message']?.toString() ??
            'Confirm this model before using it.',
      );
    }
    if (result['ok'] == false ||
        applied is! Map ||
        applied.values.any((value) => value == false) ||
        applied['ui_meta_conflicts'] is Map) {
      throw StateError(
        'Hermes could not save all settings. Refresh before retrying.',
      );
    }
  }

  Future<String> _botHome(String profile) async {
    _validateProfile(profile);
    final profiles = _objects(
      _object(await _requestJson('GET', '/api/profiles'))['profiles'],
    );
    final row = profiles.where((row) => row['name'] == profile).firstOrNull;
    final path = hermesFilePath(row?['path']);
    if (path == null ||
        !(path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path))) {
      throw StateError('Hermes did not expose this bot’s home folder.');
    }
    return path;
  }

  Future<String> _botWorkspace(String profile) async {
    _validateProfile(profile);
    final config = _object(
      await _requestJson('GET', '/api/config', query: {'profile': profile}),
    );
    final cfg = config['config'] is Map ? config['config'] as Map : config;
    final terminal = cfg['terminal'];
    final path = hermesFilePath(terminal is Map ? terminal['cwd'] : null);
    // Never substitute the main profile’s home for a named bot.
    if (path != null && (path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path))) return path;
    final home = await _botHome(profile);
    final root = '$home/workspace';
    try { await _filesList(root, null); } on DioException catch (error) { if (error.response?.statusCode == 404) throw HermesWorkspaceMissing(root); rethrow; }
    return root;
  }

  Future<String> _readBotMemory(String profile, bool aboutUser) async {
    final home = await _botHome(profile);
    final path = '$home/memories/${aboutUser ? 'USER.md' : 'MEMORY.md'}';
    try {
      final data = await _filesRead(path);
      return utf8.decode(UriData.parse(data).contentAsBytes());
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return '';
      rethrow;
    }
  }

  Future<void> _writeBotMemory(
    String profile,
    String content,
    String expected,
    bool aboutUser,
  ) async {
    if (utf8.encode(content).length > 64 * 1024) {
      throw ArgumentError('Memory is too large.');
    }
    if (await _readBotMemory(profile, aboutUser) != expected) {
      throw StateError(
        'This memory changed in Hermes. Reopen it before saving.',
      );
    }
    final home = await _botHome(profile);
    await _requestJson(
      'POST',
      '/api/files/upload',
      body: {
        'path': '$home/memories/${aboutUser ? 'USER.md' : 'MEMORY.md'}',
        'data_url':
            'data:text/plain;charset=utf-8;base64,${base64Encode(utf8.encode(content))}',
        'overwrite': true,
      },
    );
  }

  Future<void> _setBotHidden(HermesBot bot, bool hidden) async {
    final row = await _profileRow(bot.name);
    final meta = row['ui_meta'] is Map ? row['ui_meta'] as Map : const {};
    final botMeta = meta['hermes-bots'] is Map
        ? Map<String, dynamic>.from(meta['hermes-bots'])
        : <String, dynamic>{};
    final revisions = row['ui_meta_revisions'];
    await _configureBot(bot.name, {
      'ui_meta': {
        'hermes-bots': {...botMeta, 'hidden': hidden},
      },
      if (revisions is Map)
        'ui_meta_expected_revisions': {
          'hermes-bots': revisions['hermes-bots'] ?? 0,
        },
    });
  }

  Future<Map<String, dynamic>> _groupRequest(
    String action,
    Map<String, dynamic> params,
  ) async {
    if (!const {
      'list',
      'create',
      'state',
      'send',
      'log',
      'stop',
      'retry',
      'approve',
      'rename',
      'disband',
    }.contains(action)) {
      throw ArgumentError('Unsupported group action');
    }
    return _messagesProfileRequest('groups.$action', {
      ...params,
      'profile': 'default',
    });
  }
}

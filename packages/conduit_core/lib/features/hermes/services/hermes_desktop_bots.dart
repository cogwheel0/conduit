part of 'hermes_desktop_api_service.dart';

/// Data-URL cap for a profile avatar. The gateway stores at most 2MB of image
/// bytes; base64 inflates that by 4/3 plus the scheme prefix.
const int _kMaxHermesBotAvatarCharacters = 3 * 1024 * 1024;

/// Title of the canonical forever-chat every Bot Mode agent owns.
const String kHermesBotChatTitle = 'Bot Chat';

extension _HermesDesktopBots on HermesDesktopApiService {
  Future<HermesBot> _createBot(HermesBotDraft draft) async {
    draft.validate();
    final roster = await _messagesProfileRequest('profiles.list', {
      'include_sessions': false,
    });
    if (roster['bot_mode_protocol'] != true) {
      throw UnsupportedError('Update Hermes to create bots.');
    }
    await _messagesProfileRequest('profiles.create', {
      'name': draft.profile,
      'description': draft.description,
      'clone_from': draft.cloneFrom,
      'share_auth': draft.shareAuth,
      'mirror_credentials': draft.shareAuth,
      'soul': draft.soul,
      'model': ?draft.model,
      'provider': ?draft.provider,
    });
    try {
      return await _finishBotSetup(draft);
    } catch (_) {
      throw HermesBotSetupIncomplete(draft.profile);
    }
  }

  Future<HermesBot> _finishBotSetup(HermesBotDraft draft) async {
    draft.validate();
    final result = await _messagesProfileRequest('profiles.configure', {
      'name': draft.profile,
      if (draft.disabledSkills != null) 'disabled_skills': draft.disabledSkills,
      if (draft.toolsets != null) 'enabled_toolsets': draft.toolsets,
      if (draft.mcpServers != null) 'enabled_mcp_servers': draft.mcpServers,
      'ui_meta': {
        'hermes-bots': {
          'title': draft.title.trim(),
          'shape': 'squircle',
          'color': '#8b5cf6',
          'imageKind': 'shape',
          'created': DateTime.now().millisecondsSinceEpoch,
        },
      },
    });
    final applied = result['applied'];
    if (applied is! Map ||
        applied['ui_meta'] != true ||
        applied.values.any((value) => value == false) ||
        result['confirm_required'] == true) {
      throw StateError(
        'The profile was created, but Hermes could not finish bot setup. Review the profile in Hermes before retrying.',
      );
    }
    return HermesBot(
      name: draft.profile,
      title: draft.title.trim(),
      description: draft.description,
    );
  }

  /// The Bot Mode roster: only profiles carrying `ui_meta['hermes-bots']`.
  /// Empty when the gateway predates Bot Mode (no `bot_mode_protocol` flag),
  /// which is how the sidebar section stays hidden.
  Future<List<HermesBot>> _listBots() async {
    await _ensureConnected();
    final result = _object(
      await _rpc.request<Object?>(
        'profiles.list',
        params: const {'include_sessions': true},
      ),
    );
    return HermesBot.rosterFromProfilesList(result);
  }

  /// The selected profile's display title: `ui_meta['hermes-bots'].title`
  /// when it is a Bot Mode bot, else its profile name. Null when the gateway
  /// does not list the profile.
  Future<String?> _suggestedDisplayName() async {
    await _ensureConnected();
    final result = _object(
      await _rpc.request<Object?>(
        'profiles.list',
        params: const {'include_sessions': false},
      ),
    );
    final rows = result['profiles'];
    if (rows is! List) return null;
    for (final row in rows) {
      if (row is! Map || row['name'] != config.desktopProfile) continue;
      final meta = row['ui_meta'];
      final botMeta = meta is Map ? meta['hermes-bots'] : null;
      return validateHermesBoundedString(
            botMeta is Map ? botMeta['title'] : null,
            maxCharacters: kMaxHermesBotTitleCharacters,
          ) ??
          config.desktopProfile;
    }
    return null;
  }

  /// A bot's avatar as a `data:image/...` URL, or null when it has none.
  Future<String?> _botAvatar(String profile) async {
    await _ensureConnected();
    final result = _object(
      await _rpc.request<Object?>(
        'profiles.get_asset',
        params: {'name': profile, 'asset': 'avatar'},
      ),
    );
    if (result['found'] != true) return null;
    final data = result['data'];
    if (data is! String ||
        data.length > _kMaxHermesBotAvatarCharacters ||
        !data.startsWith('data:image/')) {
      return null;
    }
    return data;
  }

  /// Resolves the bot's canonical Bot Chat, creating it when absent, and binds
  /// every later call for that session to the bot's profile.
  ///
  /// Returns the stored session id.
  Future<String> _openBotChat(HermesBot bot) async {
    await _ensureConnected();
    final canonical = await findBotChat(bot.name);
    if (canonical != null) {
      bindBotSession(bot.name, canonical.id);
      // A failed resume must surface; it must never create a duplicate bot chat.
      final binding = await _resume(canonical.id, refresh: true);
      bindBotSession(bot.name, binding.storedId);
      return binding.storedId;
    }
    if (bot.chatSessionId != null) {
      throw StateError(
        'Hermes could not confirm the existing Bot Chat registry. Refresh before opening.',
      );
    }
    final stored = await _runtimeCreateDesktopSession(
      title: kHermesBotChatTitle,
      options: const HermesDesktopSessionOptions(),
      profile: bot.name,
      hidden: true,
    );
    _sessionProfiles[stored] = bot.name;
    return stored;
  }
}

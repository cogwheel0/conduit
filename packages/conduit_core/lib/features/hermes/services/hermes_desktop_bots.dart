part of 'hermes_desktop_api_service.dart';

/// Data-URL cap for a profile avatar. The gateway stores at most 2MB of image
/// bytes; base64 inflates that by 4/3 plus the scheme prefix.
const int _kMaxHermesBotAvatarCharacters = 3 * 1024 * 1024;

/// Title of the canonical forever-chat every Bot Mode agent owns.
const String kHermesBotChatTitle = 'Bot Chat';

extension _HermesDesktopBots on HermesDesktopApiService {
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
    for (final candidate in <String?>[bot.chatSessionId, kHermesBotChatTitle]) {
      if (candidate == null) continue;
      _sessionProfiles[candidate] = bot.name;
      try {
        final binding = await _resume(candidate, refresh: true);
        _sessionProfiles[binding.storedId] = bot.name;
        return binding.storedId;
      } catch (error) {
        _sessionProfiles.remove(candidate);
        DebugLogger.warning(
          'bot-chat-resume-failed',
          scope: 'hermes/desktop/bots',
          data: {'errorType': error.runtimeType.toString()},
        );
      } finally {
        // Every bot resolves its canonical chat by the same title, so the
        // lookup key must never stay cached as an alias for one bot's
        // session — only the resolved stored id may.
        if (candidate == kHermesBotChatTitle) {
          _sessionProfiles.remove(candidate);
          _bindings.remove(candidate);
          _bindingSocketGenerations.remove(candidate);
        }
      }
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

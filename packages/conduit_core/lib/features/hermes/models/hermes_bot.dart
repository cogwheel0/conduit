import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/utils/hermes_time_parsing.dart';

const int kMaxHermesBotTitleCharacters = 256;
const int kMaxHermesBotPreviewCharacters = 512;
const String kHermesBotTitleMetadataKey = 'hermesBotTitle';
const String kHermesBotAvatarMetadataKey = 'hermesBotAvatar';
const String kHermesBotShapeMetadataKey = 'hermesBotShape';
const String kHermesBotColorMetadataKey = 'hermesBotColor';
const String kHermesBotImageKindMetadataKey = 'hermesBotImageKind';

const _hermesBotShapes = {
  'circle',
  'squircle',
  'pill',
  'triangle',
  'hexagon',
  'cloud',
  'drop',
};

/// A Hermes Bot Mode agent. Upstream, a bot *is* a Hermes profile — this is one
/// `profiles.list` row projected onto the sidebar roster.
class HermesBot {
  const HermesBot({
    required this.name,
    required this.title,
    this.description,
    this.preview,
    this.chatSessionId,
    this.chatSessionIds = const {},
    this.hasAvatar = false,
    this.avatarShape = 'squircle',
    this.avatarColor = '#8b5cf6',
    this.avatarImageKind,
    this.lastActive,
  });

  /// Profile name; also the RPC `profile` scope for this bot's session calls.
  final String name;

  /// Display title from `ui_meta['hermes-bots'].title`, falling back to [name].
  final String title;

  final String? description;

  /// Preview of the newest message in the bot's canonical chat.
  final String? preview;

  /// Primary stored id of the canonical "Bot Chat", when the profile has one.
  final String? chatSessionId;

  /// All known stored ids for this bot's canonical "Bot Chat" (logical root,
  /// compression tip, and any legacy pinned id). Canonical authorities return
  /// the logical root on `session.resume`, while legacy sockets return the
  /// compression tip, so correlation checks every alias.
  final Set<String> chatSessionIds;

  /// Whether [sessionId] matches any known stored id for this bot's Bot Chat.
  bool ownsSession(String? sessionId) =>
      sessionId != null &&
      (sessionId == chatSessionId || chatSessionIds.contains(sessionId));

  final bool hasAvatar;

  final String avatarShape;
  final String avatarColor;
  final String? avatarImageKind;

  final DateTime? lastActive;

  /// Whether upstream considers this `profiles.list` row a Bot Mode bot.
  ///
  /// Upstream marks a bot by giving its `profile.yaml` a `ui_meta['hermes-bots']`
  /// mapping (`tools/bot_mode_probe.py` `_bots_meta` / `_is_bot_managed`), and
  /// `profiles.list` surfaces that mapping as `ui_meta`. Every other profile,
  /// including an untouched `default`, is just a profile. An empty mapping still
  /// counts: upstream tests `is not None` on a dict, not truthiness.
  static bool isBotRow(Map<String, dynamic> json) {
    final meta = json['ui_meta'];
    return meta is Map && meta['hermes-bots'] is Map;
  }

  /// Projects a `profiles.list` result onto the Bot Mode roster.
  ///
  /// Empty when the gateway predates Bot Mode (no `bot_mode_protocol` flag).
  /// That flag arrived with the teammate protocol, after `ui_meta` was already
  /// served on every row, so a flagged gateway always carries the bot marker.
  static List<HermesBot> rosterFromProfilesList(
    Map<String, dynamic> result, {
    int limit = 256,
    bool preferCanonicalRoot = false,
  }) {
    if (result['bot_mode_protocol'] != true) return const [];
    final rows = result['profiles'];
    if (rows is! List) return const [];
    final bots = <HermesBot>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final json = Map<String, dynamic>.from(row);
      if (!isBotRow(json)) continue;
      final bot = fromJson(json, preferCanonicalRoot: preferCanonicalRoot);
      if (bot != null) bots.add(bot);
      if (bots.length >= limit) break;
    }
    return bots;
  }

  /// Parses one `profiles.list` row, or null when it is not a usable bot.
  static HermesBot? fromJson(
    Map<String, dynamic> json, {
    bool preferCanonicalRoot = false,
  }) {
    final name = validateHermesBoundedString(json['name'], maxCharacters: 64);
    if (name == null || !HermesConfig.isValidDesktopProfile(name)) return null;

    final meta = json['ui_meta'];
    final botMeta = meta is Map ? meta['hermes-bots'] : null;
    final canonical = json['canonical_session'];
    final canonicalRow = canonical is Map ? canonical : null;
    final session =
        canonicalRow ?? json['preferred_session'] ?? json['last_session'];
    final sessionRow = session is Map ? session : const {};
    final canonicalResolvedId = validateHermesOpaqueIdentifier(
      canonicalRow?['resolved_id'],
    );
    final canonicalId = validateHermesOpaqueIdentifier(canonicalRow?['id']);
    final legacyChatId = validateHermesOpaqueIdentifier(
      botMeta is Map ? botMeta['chat'] : null,
    );
    final chatSessionId = preferCanonicalRoot
        ? (canonicalId ?? canonicalResolvedId ?? legacyChatId)
        : (canonicalResolvedId ?? canonicalId ?? legacyChatId);
    final chatSessionIds = Set<String>.unmodifiable(<String>{
      ?canonicalId,
      ?canonicalResolvedId,
      ?legacyChatId,
    });
    final rawShape = validateHermesBoundedString(
      botMeta is Map ? botMeta['shape'] : null,
      maxCharacters: 96,
    );
    final rawColor = validateHermesBoundedString(
      botMeta is Map ? botMeta['color'] : null,
      maxCharacters: 7,
    );
    final rawImageKind = validateHermesBoundedString(
      botMeta is Map ? botMeta['imageKind'] : null,
      maxCharacters: 16,
    );

    return HermesBot(
      name: name,
      title:
          validateHermesBoundedString(
            botMeta is Map ? botMeta['title'] : null,
            maxCharacters: kMaxHermesBotTitleCharacters,
          ) ??
          name,
      description: validateHermesBoundedString(
        json['description'],
        maxCharacters: kMaxHermesBotTitleCharacters,
      ),
      preview: validateHermesBoundedString(
        sessionRow['preview'],
        maxCharacters: kMaxHermesBotPreviewCharacters,
      ),
      chatSessionId: chatSessionId,
      chatSessionIds: chatSessionIds,
      hasAvatar: json['has_avatar'] == true,
      avatarShape: _validHermesBotShape(rawShape) ?? 'squircle',
      avatarColor: _validHermesBotColor(rawColor) ?? '#8b5cf6',
      avatarImageKind: rawImageKind == 'photo' || rawImageKind == 'shape'
          ? rawImageKind
          : null,
      lastActive: parseHermesTimestamp(sessionRow['last_active']),
    );
  }
}

String? _validHermesBotShape(String? value) {
  if (value == null) return null;
  if (_hermesBotShapes.contains(value) || value.startsWith('blobatar')) {
    return value;
  }
  return null;
}

String? _validHermesBotColor(String? value) {
  if (value == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return value.toLowerCase();
}

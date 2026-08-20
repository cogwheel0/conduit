import '../models/hermes_config.dart';
import '../services/hermes_identifier.dart';
import '../utils/hermes_time_parsing.dart';

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

  /// Pinned stored id of the canonical "Bot Chat", when the profile has one.
  final String? chatSessionId;

  final bool hasAvatar;

  final String avatarShape;
  final String avatarColor;
  final String? avatarImageKind;

  final DateTime? lastActive;

  /// Parses one `profiles.list` row, or null when it is not a usable bot.
  static HermesBot? fromJson(Map<String, dynamic> json) {
    final name = validateHermesBoundedString(json['name'], maxCharacters: 64);
    if (name == null || !HermesConfig.isValidDesktopProfile(name)) return null;

    final meta = json['ui_meta'];
    final botMeta = meta is Map ? meta['hermes-bots'] : null;
    final session = json['preferred_session'] ?? json['last_session'];
    final sessionRow = session is Map ? session : const {};
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
      chatSessionId: validateHermesOpaqueIdentifier(
        botMeta is Map ? botMeta['chat'] : null,
      ),
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

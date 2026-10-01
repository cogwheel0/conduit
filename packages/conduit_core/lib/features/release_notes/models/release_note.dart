import 'release_version.dart';

/// One version's bundled release note.
///
/// Bullet icons are names (see `releaseNoteIconNames`), not framework icon
/// data, so this model has no UI dependency. The widget layers map a name to
/// a glyph or an image asset.
class ReleaseNote {
  ReleaseNote({
    required this.version,
    required this.title,
    required this.intro,
    required this.bullets,
    this.bulletIcons = const <String?>[],
  }) : parsedVersion = ReleaseVersion.parse(version);

  final String version;
  final String title;
  final String intro;
  final List<String> bullets;

  /// Optional leading icon name per bullet, aligned by index with [bullets].
  /// Bullets without a matching name fall back to a plain ordinal.
  final List<String?> bulletIcons;
  final ReleaseVersion parsedVersion;

  /// The icon name for bullet [index], or null.
  String? iconNameForBullet(int index) =>
      index < bulletIcons.length ? bulletIcons[index] : null;
}

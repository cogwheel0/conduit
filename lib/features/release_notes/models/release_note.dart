import 'package:flutter/widgets.dart';

import 'release_version.dart';

class ReleaseNote {
  ReleaseNote({
    required this.version,
    required this.title,
    required this.intro,
    required this.bullets,
    this.bulletIcons = const <IconData?>[],
    this.bulletIconAssets = const <String?>[],
  }) : parsedVersion = ReleaseVersion.parse(version);

  final String version;
  final String title;
  final String intro;
  final List<String> bullets;

  /// Optional leading glyph per bullet, aligned by index with [bullets].
  /// Bullets without a matching icon fall back to a plain dot.
  final List<IconData?> bulletIcons;
  final List<String?> bulletIconAssets;
  final ReleaseVersion parsedVersion;

  IconData? iconForBullet(int index) =>
      index < bulletIcons.length ? bulletIcons[index] : null;

  String? iconAssetForBullet(int index) =>
      index < bulletIconAssets.length ? bulletIconAssets[index] : null;
}

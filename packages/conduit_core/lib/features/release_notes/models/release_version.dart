class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion._(this.raw, this.major, this.minor, this.patch);

  final String raw;
  final int major;
  final int minor;
  final int patch;

  static final RegExp _versionPattern = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
  );

  factory ReleaseVersion.parse(String value) {
    final parsed = tryParse(value);
    if (parsed == null) {
      throw FormatException('Invalid release version', value);
    }
    return parsed;
  }

  static ReleaseVersion? tryParse(String value) {
    final raw = value.trim();
    final match = _versionPattern.firstMatch(raw);
    if (match == null) return null;

    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = int.tryParse(match.group(3)!);
    if (major == null || minor == null || patch == null) {
      return null;
    }
    return ReleaseVersion._(raw, major, minor, patch);
  }

  @override
  int compareTo(ReleaseVersion other) {
    final majorCompare = major.compareTo(other.major);
    if (majorCompare != 0) return majorCompare;
    final minorCompare = minor.compareTo(other.minor);
    if (minorCompare != 0) return minorCompare;
    return patch.compareTo(other.patch);
  }

  bool isAfter(ReleaseVersion other) => compareTo(other) > 0;

  bool isBeforeOrSame(ReleaseVersion other) => compareTo(other) <= 0;

  @override
  String toString() => raw;
}

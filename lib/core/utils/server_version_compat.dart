/// Compatibility gate for the Open WebUI server this app talks to.
///
/// Conduit tracks the Open WebUI API surface via the vendored `openwebui-src/`
/// submodule. When the upstream server jumps ahead of what this build has been
/// validated against, endpoints and payloads can drift in ways that silently
/// break the app. Rather than fail in confusing ways deep in a feature, the app
/// refuses to operate against servers newer than [maxSupportedVersion] and
/// surfaces a clear "downgrade or wait for an update" message.
///
/// This is a pure leaf utility with no Flutter dependencies so it can be unit
/// tested in isolation and reused from models, providers, and views alike.
class ServerVersionCompat {
  ServerVersionCompat._();

  /// The newest Open WebUI server version this app build is known to support.
  ///
  /// Servers reporting a `/api/config` `version` strictly greater than this are
  /// gated off. Bump this (and re-verify against `openwebui-src/`) whenever a
  /// newer server release is validated.
  static const String maxSupportedVersion = '0.10.1';

  /// Parsed [maxSupportedVersion] components: `[major, minor, patch]`.
  static const List<int> _maxSupported = [0, 10, 1];

  /// Whether [rawVersion] is within the supported range (<= [maxSupportedVersion]).
  ///
  /// Fails open: a `null`, empty, or unparseable version is treated as
  /// supported so the gate never locks users out of a server whose version
  /// string we simply don't understand. The gate only triggers when we can
  /// confidently determine the server is newer than we support.
  static bool isSupported(String? rawVersion) {
    final parsed = _parse(rawVersion);
    if (parsed == null) return true; // fail open on unknown versions
    return _compare(parsed, _maxSupported) <= 0;
  }

  /// Convenience inverse of [isSupported] for readable call sites.
  static bool isUnsupported(String? rawVersion) => !isSupported(rawVersion);

  /// Parses a semantic-ish version string into up to three numeric components.
  ///
  /// Tolerates a leading `v`/`V` and drops any pre-release or build metadata
  /// suffix (e.g. `0.10.1-dev`, `0.10.1+build.5`). Returns `null` when no
  /// leading numeric component can be found.
  static List<int>? _parse(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('v') || s.startsWith('V')) {
      s = s.substring(1);
    }
    // Strip pre-release / build metadata so `0.10.1-rc1` compares as `0.10.1`.
    final cut = s.indexOf(RegExp(r'[-+ ]'));
    if (cut != -1) {
      s = s.substring(0, cut);
    }
    final match = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(s);
    if (match == null) return null;
    final major = int.tryParse(match.group(1) ?? '');
    if (major == null) return null;
    final minor = int.tryParse(match.group(2) ?? '0') ?? 0;
    final patch = int.tryParse(match.group(3) ?? '0') ?? 0;
    return [major, minor, patch];
  }

  /// Compares two `[major, minor, patch]` triples, returning -1/0/1.
  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) return av < bv ? -1 : 1;
    }
    return 0;
  }
}

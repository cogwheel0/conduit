import 'dart:convert';
import 'dart:io';

/// The fake LibreChat server `tool/local_librechat/librechat.sh` starts.
///
/// `librechat.sh start` writes an env file of its invented accounts:
/// `LIBRECHAT_URL`, `LIBRECHAT_2FA_EMAIL`/`_PASSWORD`/`_CODE`/`_BACKUP_CODE`
/// (an account with two-step verification), and `LIBRECHAT_EMAIL`/
/// `_PASSWORD` (one without). This reads that file and nothing else.
class LocalLibreChat {
  const LocalLibreChat._(this.values);

  final Map<String, String> values;

  String get url => values['LIBRECHAT_URL']!;
  String get twoFactorEmail => values['LIBRECHAT_2FA_EMAIL']!;
  String get twoFactorPassword => values['LIBRECHAT_2FA_PASSWORD']!;
  String get twoFactorCode => values['LIBRECHAT_2FA_CODE']!;
  String get backupCode => values['LIBRECHAT_2FA_BACKUP_CODE']!;
  String get email => values['LIBRECHAT_EMAIL']!;
  String get password => values['LIBRECHAT_PASSWORD']!;

  /// The env file, or null when there is none, so a clean clone and CI skip
  /// whatever needs the server.
  static LocalLibreChat? read({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final file = File(envPath(env));
    if (!file.existsSync()) return null;
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(file.readAsStringSync())) {
      final match = RegExp(r'^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$').firstMatch(line);
      if (match != null) values[match.group(1)!] = match.group(2)!;
    }
    if ((values['LIBRECHAT_URL'] ?? '').isEmpty) return null;
    return LocalLibreChat._(values);
  }

  /// `CONDUIT_LIBRECHAT_ENV`, else `local-librechat.env` in
  /// `CONDUIT_LIBRECHAT_DIR`, else in `local-librechat` under the cache root.
  static String envPath(Map<String, String> environment) {
    String? set(String key) {
      final value = environment[key];
      return value == null || value.isEmpty ? null : value;
    }

    final explicit = set('CONDUIT_LIBRECHAT_ENV');
    if (explicit != null) return explicit;
    final dir = set('CONDUIT_LIBRECHAT_DIR');
    if (dir != null) return '$dir/local-librechat.env';
    final home = environment['HOME'] ?? '';
    final cache =
        set('CONDUIT_DEV_CACHE') ??
        (Platform.isMacOS
            ? '$home/Library/Caches/conduit-dev'
            : '${set('XDG_CACHE_HOME') ?? '$home/.cache'}/conduit-dev');
    return '$cache/local-librechat/local-librechat.env';
  }

  /// The fake's own view of what it holds (`/__fake/state`).
  Future<Map<String, dynamic>> state() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$url/__fake/state'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  /// Puts the fake back to its seed.
  Future<void> reset() => _post('/__fake/reset');

  /// Ends every session, as when refresh tokens lapse.
  Future<void> endSessions() => _post('/__fake/end-sessions');

  Future<void> _post(String path) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$url$path'));
      await (await request.close()).drain<void>();
    } finally {
      client.close(force: true);
    }
  }
}

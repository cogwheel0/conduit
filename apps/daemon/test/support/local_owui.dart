import 'dart:convert';
import 'dart:io';

/// The local Open WebUI that `tool/local_owui/owui.sh` starts and seeds.
///
/// `owui.sh seed` writes an env file of synthetic credentials for it:
/// `OWUI_URL`, `OWUI_EMAIL`, `OWUI_PASSWORD`, `OWUI_MODEL` (the fake
/// model) and `OWUI_REFUSED_MODEL` (one that always answers 400), among
/// others. This reads that file and nothing else.
class LocalOwui {
  const LocalOwui._(this.values);

  /// Every key in the env file.
  final Map<String, String> values;

  String get url => values['OWUI_URL']!;
  String get email => values['OWUI_EMAIL']!;
  String get password => values['OWUI_PASSWORD']!;

  /// The fake model every turn runs on.
  String get model => values['OWUI_MODEL'] ?? 'fake-model';

  /// A second fake model, whose answers start "B: ".
  String get secondModel => values['OWUI_SECOND_MODEL'] ?? 'fake-model-b';

  /// A model the server offers and its provider refuses with a 400.
  String get refusedModel => values['OWUI_REFUSED_MODEL'] ?? 'fake-refused';

  /// The env file, or null when there is none or it lacks a sign-in, so a
  /// clean clone and CI skip whatever needs the server.
  static LocalOwui? read({Map<String, String>? environment}) {
    final file = File(envPath(environment ?? Platform.environment));
    if (!file.existsSync()) return null;
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(file.readAsStringSync())) {
      final match = RegExp(r'^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$')
          .firstMatch(line);
      if (match == null) continue;
      values[match.group(1)!] = match
          .group(2)!
          .replaceAll(RegExp('^["\']|["\']\$'), '');
    }
    for (final key in const ['OWUI_URL', 'OWUI_EMAIL', 'OWUI_PASSWORD']) {
      if ((values[key] ?? '').isEmpty) return null;
    }
    return LocalOwui._(values);
  }

  /// Where `owui.sh` writes the env file: `CONDUIT_OWUI_ENV`, else
  /// `local-owui.env` in `CONDUIT_OWUI_DIR`, else in `local-owui` under the
  /// cache root (`CONDUIT_DEV_CACHE`, or the platform's user cache).
  static String envPath(Map<String, String> environment) {
    String? set(String key) {
      final value = environment[key];
      return value == null || value.isEmpty ? null : value;
    }

    final explicit = set('CONDUIT_OWUI_ENV');
    if (explicit != null) return explicit;
    final dir = set('CONDUIT_OWUI_DIR');
    if (dir != null) return '$dir/local-owui.env';
    final home = set('HOME') ?? '';
    final cache =
        set('CONDUIT_DEV_CACHE') ??
        (Platform.isMacOS
            ? '$home/Library/Caches/conduit-dev'
            : '${set('XDG_CACHE_HOME') ?? '$home/.cache'}/conduit-dev');
    return '$cache/local-owui/local-owui.env';
  }
}

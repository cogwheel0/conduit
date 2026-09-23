/// What the window may be asked to open (M9): from a `conduit://` link, a
/// notification, the tray, or the quick-ask panel. The main process has
/// already checked it; the renderer maps it onto its own navigation.
class OpenRequest {
  const OpenRequest(this.kind, {this.id, this.text, this.tab});

  const OpenRequest.chat(String id) : this('chat', id: id);

  const OpenRequest.newChat({String? text}) : this('newChat', text: text);

  /// `chat`, `newChat`, `channel`, `note` or `settings`.
  final String kind;
  final String? id;
  final String? text;
  final String? tab;

  static OpenRequest? fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    if (kind is! String) return null;
    return OpenRequest(
      kind,
      id: json['id'] as String?,
      text: json['text'] as String?,
      tab: json['tab'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'id': ?id,
    'text': ?text,
    'tab': ?tab,
  };

  @override
  bool operator ==(Object other) =>
      other is OpenRequest &&
      other.kind == kind &&
      other.id == id &&
      other.text == text &&
      other.tab == tab;

  @override
  int get hashCode => Object.hash(kind, id, text, tab);

  @override
  String toString() => 'OpenRequest(${toJson()})';
}

/// The shell's own settings, as the main process keeps them.
class ShellSettings {
  const ShellSettings({
    this.closeToTray = false,
    this.launchAtLogin = false,
    this.quickAskEnabled = true,
    this.quickAskShortcut = 'CommandOrControl+Shift+Space',
    this.quickAskRegistered = false,
    this.notifyAnswers = true,
    this.notifyChannels = true,
    this.shortcuts = const <String, String>{},
  });

  factory ShellSettings.fromJson(Map<String, dynamic> json) => ShellSettings(
    closeToTray: json['closeToTray'] == true,
    launchAtLogin: json['launchAtLogin'] == true,
    quickAskEnabled: json['quickAskEnabled'] != false,
    quickAskShortcut:
        json['quickAskShortcut'] as String? ?? 'CommandOrControl+Shift+Space',
    quickAskRegistered: json['quickAskRegistered'] == true,
    notifyAnswers: json['notifyAnswers'] != false,
    notifyChannels: json['notifyChannels'] != false,
    shortcuts: <String, String>{
      if (json['shortcuts'] case final Map<dynamic, dynamic> map)
        for (final MapEntry(:key, :value) in map.entries)
          if (key is String && value is String) key: value,
    },
  );

  final bool closeToTray;
  final bool launchAtLogin;
  final bool quickAskEnabled;

  /// An Electron accelerator, e.g. `CommandOrControl+Shift+Space`.
  final String quickAskShortcut;

  /// Whether the shortcut is held: another app may own it.
  final bool quickAskRegistered;
  final bool notifyAnswers;
  final bool notifyChannels;

  /// The user's own keys, by action name, as `encodeStroke` writes them
  /// (WP-9.4).
  final Map<String, String> shortcuts;
}

/// The desktop around the window (M9). Unavailable outside Electron.
abstract interface class DesktopShellPort {
  /// Whether there is a shell at all; the dev browser has none.
  bool get available;

  /// The settings, changed by [patch] when given.
  Future<ShellSettings> settings([Map<String, Object?>? patch]);

  /// An OS notification; clicking it opens [open].
  Future<bool> notify({
    required String title,
    String body = '',
    OpenRequest? open,
  });

  /// Hears open requests. Called once, by the app shell.
  void onOpen(void Function(OpenRequest request) handler);

  /// From the quick-ask panel: continue in the main window.
  void openInMain(OpenRequest request);

  /// Hides this window.
  void hideWindow();

  /// Whether this window has the user's attention.
  bool get focused;
}

/// Records what it was asked. The default outside Electron.
final class RecordingDesktopShell implements DesktopShellPort {
  RecordingDesktopShell({this.available = false});

  @override
  final bool available;

  ShellSettings current = const ShellSettings();
  final List<Map<String, Object?>> patches = <Map<String, Object?>>[];
  final List<({String title, String body, OpenRequest? open})> notified =
      <({String title, String body, OpenRequest? open})>[];
  final List<OpenRequest> openedInMain = <OpenRequest>[];
  int hidden = 0;
  void Function(OpenRequest request)? handler;

  @override
  bool focused = true;

  @override
  Future<ShellSettings> settings([Map<String, Object?>? patch]) async {
    if (patch != null) {
      patches.add(patch);
      current = ShellSettings.fromJson(<String, dynamic>{
        'closeToTray': current.closeToTray,
        'launchAtLogin': current.launchAtLogin,
        'quickAskEnabled': current.quickAskEnabled,
        'quickAskShortcut': current.quickAskShortcut,
        'quickAskRegistered': current.quickAskRegistered,
        'notifyAnswers': current.notifyAnswers,
        'notifyChannels': current.notifyChannels,
        'shortcuts': current.shortcuts,
        ...patch,
      });
    }
    return current;
  }

  @override
  Future<bool> notify({
    required String title,
    String body = '',
    OpenRequest? open,
  }) async {
    notified.add((title: title, body: body, open: open));
    return true;
  }

  @override
  void onOpen(void Function(OpenRequest request) handler) =>
      this.handler = handler;

  /// Delivers [request] as the main process would.
  void open(OpenRequest request) => handler?.call(request);

  @override
  void openInMain(OpenRequest request) => openedInMain.add(request);

  @override
  void hideWindow() => hidden++;
}

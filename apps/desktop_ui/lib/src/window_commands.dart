import 'shortcuts.dart';

/// The two things a shortcut needs the window to do (WP-3.7).
///
/// A port for the same reason [ThemeApplierPort] is one: focusing an element
/// and writing the clipboard are `document` operations, and the pages that
/// trigger them are tested on the VM where `document` does not exist.
///
/// Narrow on purpose. "Focus this id" and "copy this string" are the whole
/// surface a keyboard binding needs; anything wider would turn into a second
/// way to reach the DOM from code that should not have one.
abstract interface class WindowCommandsPort {
  /// Moves focus to the element with [id], if it is on screen.
  void focus(String id);

  /// Writes [text] to the system clipboard. False if the browser refused.
  Future<bool> copy(String text);

  /// The clipboard's text, or null when it is empty or unreadable. Only
  /// read for a prompt that asks for `{{CLIPBOARD}}`, when the user has
  /// just chosen that prompt.
  Future<String?> readClipboard();

  /// Sets the value of the field with [id].
  ///
  /// Needed for `textarea` and nothing else. Jaspr reconciles a `value`
  /// attribute into the DOM *property* for `input` and `select`, which is
  /// what makes those controlled -- but a textarea's value is its child
  /// text only until the user types, after which the property and the
  /// markup diverge and nothing in the framework closes the gap. So
  /// clearing `_text` in the composer left the sent message sitting in the
  /// box, and the next one would have been sent with it still attached.
  void setValue(String id, String text);

  /// Scrolls [id] to its end, unless the user has scrolled away from it.
  ///
  /// The exception is the whole feature. A transcript that always jumps to
  /// the bottom yanks someone out of the message they went back to read,
  /// every time a token arrives -- so "follow the conversation" has to mean
  /// "keep following it if that is where they already were".
  void scrollToEnd(String id);

  /// Scrolls the least distance that brings [id] into view, if it is not.
  ///
  /// For a highlight moved by the keyboard: a row the arrows reached but the
  /// eye cannot see is a selection the user does not know they made.
  void reveal(String id);

  /// Opens [url] in the system browser -- the shell sends an http(s)
  /// `window.open` there -- if this is the window the user is in, so that
  /// several open windows do not each open it.
  void openExternal(String url);

  /// Tells [onChange] whether the element [id] is near enough the viewport
  /// to be worth drawing, now and as that changes (WP-10.1). Returns what
  /// stops it.
  void Function() observeNearView(String id, void Function(bool near) onChange);

  /// A value this window kept, by [key], across launches: layout choices
  /// that belong to the window rather than the account.
  String? stored(String key);

  /// Keeps [value] under [key] for [stored].
  void store(String key, String value);

  /// Follows the pointer until it is released, for a drag that started on
  /// an element: [onMove] gets its x in viewport pixels. The page shows
  /// [cursor] and selects no text meanwhile.
  void trackPointer({
    required void Function(double x) onMove,
    void Function()? onEnd,
    String cursor = 'col-resize',
  });
}

/// Records what it was asked to do. The default outside a browser.
final class RecordingWindowCommands implements WindowCommandsPort {
  final List<String> focused = <String>[];
  final List<String> copied = <String>[];

  @override
  void focus(String id) => focused.add(id);

  @override
  Future<bool> copy(String text) async {
    copied.add(text);
    return true;
  }

  @override
  void setValue(String id, String text) => values.add((id: id, text: text));

  @override
  void scrollToEnd(String id) => scrolled.add(id);

  final List<String> scrolled = <String>[];

  @override
  void reveal(String id) => revealed.add(id);

  /// What [readClipboard] answers.
  String? clipboardText;

  @override
  Future<String?> readClipboard() async => clipboardText;

  final List<String> revealed = <String>[];

  @override
  void openExternal(String url) => opened.add(url);

  final List<String> opened = <String>[];

  /// What [observeNearView] reports: near, by default, so a test sees
  /// everything drawn.
  bool near = true;
  final List<String> observed = <String>[];

  @override
  void Function() observeNearView(
    String id,
    void Function(bool near) onChange,
  ) {
    observed.add(id);
    onChange(near);
    return () => observed.remove(id);
  }

  final List<({String id, String text})> values =
      <({String id, String text})>[];

  final Map<String, String> storage = <String, String>{};

  @override
  String? stored(String key) => storage[key];

  @override
  void store(String key, String value) => storage[key] = value;

  /// The drag in progress, for a test to move and release.
  ({void Function(double x) onMove, void Function()? onEnd})? drag;

  @override
  void trackPointer({
    required void Function(double x) onMove,
    void Function()? onEnd,
    String cursor = 'col-resize',
  }) => drag = (onMove: onMove, onEnd: onEnd);
}

/// Installs the document-level keydown listener.
///
/// Separate from [WindowCommandsPort] because the two have different
/// lifetimes: commands are called, this is bound once and torn down with the
/// window.
abstract interface class ShortcutBindingPort {
  void install(void Function(ShortcutAction action) onAction);

  /// Matches keys against [table] from now on (WP-9.4).
  void rebind(List<Shortcut> table);
  void dispose();
}

/// Binds nothing. The default outside a browser.
final class NoShortcutBinding implements ShortcutBindingPort {
  void Function(ShortcutAction action)? handler;

  List<Shortcut> table = defaultShortcuts;

  @override
  void install(void Function(ShortcutAction action) onAction) =>
      handler = onAction;

  @override
  void rebind(List<Shortcut> table) => this.table = table;

  @override
  void dispose() => handler = null;
}

/// The window's `online` and `offline` events (WP-3.3).
///
/// A port for the same reason as the others: `window` is not there on the
/// VM. [online] is `navigator.onLine` at the time of asking.
abstract interface class NetworkEventsPort {
  bool get online;
  Stream<bool> get changes;
}

/// Always online, and never says otherwise. The default outside a browser.
final class SteadyNetwork implements NetworkEventsPort {
  const SteadyNetwork();

  @override
  bool get online => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

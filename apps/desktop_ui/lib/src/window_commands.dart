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

  final List<({String id, String text})> values =
      <({String id, String text})>[];
}

/// Installs the document-level keydown listener.
///
/// Separate from [WindowCommandsPort] because the two have different
/// lifetimes: commands are called, this is bound once and torn down with the
/// window.
abstract interface class ShortcutBindingPort {
  void install(void Function(ShortcutAction action) onAction);
  void dispose();
}

/// Binds nothing. The default outside a browser.
final class NoShortcutBinding implements ShortcutBindingPort {
  void Function(ShortcutAction action)? handler;

  @override
  void install(void Function(ShortcutAction action) onAction) =>
      handler = onAction;

  @override
  void dispose() => handler = null;
}

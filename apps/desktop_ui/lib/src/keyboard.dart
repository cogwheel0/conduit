import 'package:jaspr/jaspr.dart' show EventCallback;
// `universal_web` rather than `package:web`, and not interchangeably: it is
// the mirror Jaspr's own `EventCallback` is typed against, and it compiles
// on the VM -- which is what lets the composer import this file and keep
// its tests. The two packages' `Event` types are not assignable.
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import 'shortcuts.dart';
import 'window_commands.dart';

/// Binds [shortcuts] to the document (WP-3.7).
///
/// One listener on `document` rather than one per control. A shortcut is a
/// property of the window, not of whatever happens to hold focus, and
/// per-component handlers only fire for the component the user is already
/// in -- which is the one case a shortcut is least needed.
///
/// The translation from a DOM event to a [KeyStroke] lives here and nowhere
/// else, so the matching rules stay testable without a browser.
final class ShortcutDispatcher implements ShortcutBindingPort {
  ShortcutDispatcher({required this.isMac, this.table = defaultShortcuts});

  final bool isMac;
  final List<Shortcut> table;

  void Function(ShortcutAction action)? _onAction;
  web.EventListener? _listener;

  @override
  void install(void Function(ShortcutAction action) onAction) {
    _onAction = onAction;
    final listener = (web.Event event) {
      _handle(event as web.KeyboardEvent);
    }.toJS;
    _listener = listener;
    web.document.addEventListener('keydown', listener);
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener == null) return;
    web.document.removeEventListener('keydown', listener);
    _listener = null;
    _onAction = null;
  }

  void _handle(web.KeyboardEvent event) {
    // A dead key or an IME composition arrives as a keydown too, and
    // acting on one would fire a shortcut in the middle of composing a
    // character in Japanese or Korean.
    if (event.isComposing || event.keyCode == 229) return;

    final stroke = strokeFrom(event, isMac: isMac);
    if (stroke == null) return;

    final action = resolveShortcut(
      stroke,
      typing: isEditable(event.target),
      table: table,
    );
    if (action == null) return;

    // Only once a binding matched. Cancelling earlier would take Cmd+A and
    // Cmd+C away from every field in the app.
    event.preventDefault();
    _onAction?.call(action);
  }
}

/// [WindowCommandsPort] against the real document.
final class DocumentWindowCommands implements WindowCommandsPort {
  DocumentWindowCommands();

  /// Whether each scrollable pane is still following its own end.
  ///
  /// Starts true and is recomputed from the pane's own scroll events, which
  /// is the only way to tell "the user went back to read something" from
  /// "the content grew past the viewport and nobody has scrolled yet".
  /// Comparing positions at scroll time cannot: both look like a pane whose
  /// bottom is off screen, and treating them the same either yanks the
  /// reader back down or never follows at all.
  final Map<String, bool> _pinned = <String, bool>{};
  final Map<String, web.Element> _watched = <String, web.Element>{};

  @override
  void focus(String id) {
    final element = web.document.getElementById(id);
    if (element.isA<web.HTMLElement>()) {
      (element! as web.HTMLElement).focus();
    }
  }

  @override
  void setValue(String id, String text) {
    final element = web.document.getElementById(id);
    if (element.isA<web.HTMLTextAreaElement>()) {
      (element! as web.HTMLTextAreaElement).value = text;
    } else if (element.isA<web.HTMLInputElement>()) {
      (element! as web.HTMLInputElement).value = text;
    }
  }

  @override
  void scrollToEnd(String id) {
    final element = web.document.getElementById(id);
    if (!element.isA<web.HTMLElement>()) return;
    final pane = element! as web.HTMLElement;

    // Re-attached when the element itself is replaced, which a route
    // change does: the listener goes with the old node, and without this
    // the pane would be stuck at whatever it was pinned to before.
    if (!identical(_watched[id], pane)) {
      _watched[id] = pane;
      _pinned[id] = true;
      pane.addEventListener(
        'scroll',
        ((web.Event _) => _pinned[id] = _atEnd(pane)).toJS,
      );
    }

    if (_pinned[id] != true) return;
    pane.scrollTop = pane.scrollHeight.toDouble();
  }

  @override
  void reveal(String id) {
    web.document
        .getElementById(id)
        ?.scrollIntoView(web.ScrollIntoViewOptions(block: 'nearest'));
  }

  /// Within a line or so of the bottom.
  ///
  /// Slack rather than equality: a fractional scroll position and subpixel
  /// layout mean an element that is visually at its end is rarely exactly
  /// at it, and a strict comparison would unpin on the app's own scroll.
  static bool _atEnd(web.HTMLElement pane) =>
      pane.scrollHeight - pane.scrollTop - pane.clientHeight <= 48;

  @override
  Future<String?> readClipboard() async {
    // Rejects for the same reasons writing does, and a prompt should fill
    // `{{CLIPBOARD}}` with nothing rather than fail.
    try {
      final text = await web.window.navigator.clipboard.readText().toDart;
      return text.toDart;
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> copy(String text) async {
    // `navigator.clipboard` is promise-based and rejects when the document
    // is not focused, which happens often enough -- a click on the window
    // chrome is enough -- that an unhandled rejection would be routine.
    try {
      await web.window.navigator.clipboard.writeText(text).toDart;
      return true;
    } on Object {
      return false;
    }
  }
}

/// The chord [event] represents, or null if it is not one this app matches.
///
/// Returns null when the *other* platform's accelerator is held: Ctrl+K on
/// macOS is a text-editing binding people actually use, and firing the
/// Cmd+K action for it would be the app reaching past the OS.
KeyStroke? strokeFrom(web.KeyboardEvent event, {required bool isMac}) {
  if (isMac ? event.ctrlKey : event.metaKey) return null;
  return KeyStroke(
    event.key.toLowerCase(),
    primary: isMac ? event.metaKey : event.ctrlKey,
    shift: event.shiftKey,
    alt: event.altKey,
  );
}

/// Whether [target] is something the user is typing into.
///
/// `isContentEditable` as well as the two tags: a rich-text surface is a
/// field even though it is a `div`, and M3's composer may become one.
bool isEditable(web.EventTarget? target) {
  if (!target.isA<web.HTMLElement>()) return false;
  final element = target as web.HTMLElement;
  if (element.isContentEditable) return true;
  final tag = element.tagName.toLowerCase();
  return tag == 'input' || tag == 'textarea' || tag == 'select';
}

/// A composer keydown handler: Enter sends, Shift+Enter breaks the line.
///
/// Here rather than in the page so the page stays free of `package:web` and
/// keeps its VM tests; the rule itself is [sendsMessage], which is pure.
EventCallback sendOnEnter(void Function() send) => (web.Event event) {
  final key = event as web.KeyboardEvent;
  if (!sendsMessage(
    key: key.key,
    shift: key.shiftKey,
    isComposing: key.isComposing || key.keyCode == 229,
  )) {
    return;
  }
  // Without this the newline lands in the field a moment after the message
  // is sent, so the next message starts with a blank line.
  event.preventDefault();
  send();
};

/// Arrow keys and Enter inside the command palette's field (WP-3.1).
///
/// On the field rather than the document: the palette is the one place
/// arrows mean "move the highlight", and everywhere else they must keep
/// moving the caret.
EventCallback paletteKeys({
  required void Function({required bool down}) move,
  required void Function() choose,
}) => (web.Event event) {
  final key = event as web.KeyboardEvent;
  if (key.isComposing || key.keyCode == 229) return;
  switch (key.key) {
    case 'ArrowDown':
      event.preventDefault();
      move(down: true);
    case 'ArrowUp':
      event.preventDefault();
      move(down: false);
    case 'Enter':
      event.preventDefault();
      choose();
  }
};

/// The composer's keys, with the `/` menu open or not (WP-3.3).
///
/// While the menu shows, the arrows move its highlight, Enter and Tab
/// choose, and Esc closes it -- and goes no further, because the document
/// listener would otherwise take the same Esc as "stop the running turn".
/// Otherwise this is [sendOnEnter].
EventCallback composerKeys({
  required bool Function() menuOpen,
  required void Function({required bool down}) move,
  required void Function() choose,
  required void Function() dismiss,
  required void Function() send,
}) {
  final onEnter = sendOnEnter(send);
  return (web.Event event) {
    final key = event as web.KeyboardEvent;
    final composing = key.isComposing || key.keyCode == 229;
    if (!composing && menuOpen()) {
      switch (key.key) {
        case 'ArrowDown':
          event.preventDefault();
          move(down: true);
          return;
        case 'ArrowUp':
          event.preventDefault();
          move(down: false);
          return;
        case 'Enter' || 'Tab' when !key.shiftKey:
          event.preventDefault();
          choose();
          return;
        case 'Escape':
          event
            ..preventDefault()
            ..stopPropagation();
          dismiss();
          return;
      }
    }
    onEnter(event);
  };
}

/// Enter and Esc in a one-line field that is its own small form -- naming a
/// tag, say (WP-3.8). Esc stops here: the document listener would take it
/// as "stop the running turn" otherwise.
EventCallback submitOrCancel({
  required void Function() submit,
  required void Function() cancel,
}) => (web.Event event) {
  final key = event as web.KeyboardEvent;
  if (key.isComposing || key.keyCode == 229) return;
  switch (key.key) {
    case 'Enter':
      event.preventDefault();
      submit();
    case 'Escape':
      event
        ..preventDefault()
        ..stopPropagation();
      cancel();
  }
};

/// A right-click, claimed so the browser's own menu does not open over the
/// app's (WP-3.1). [open] gets where the pointer was.
EventCallback contextMenuAt(void Function(double x, double y) open) =>
    (web.Event event) {
      final mouse = event as web.MouseEvent;
      event.preventDefault();
      open(mouse.clientX.toDouble(), mouse.clientY.toDouble());
    };

/// A right-click that only closes what is open.
EventCallback suppressContextMenu(void Function() close) => (web.Event event) {
  event.preventDefault();
  close();
};

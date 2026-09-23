import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'note_editor.dart';

/// Quill 2, loaded by index.html from the vendored copy.
@JS('Quill')
extension type _Quill._(JSObject _) implements JSObject {
  external factory _Quill(web.Element container, JSAny options);

  external _Delta getContents();
  external void setContents(JSAny delta, [String source]);
  external void on(String event, JSFunction handler);
  external void focus();
}

/// Quill's `Delta`: a class instance, which `dartify` does not unwrap --
/// only its `ops`, plain objects, convert.
extension type _Delta._(JSObject _) implements JSObject {
  external JSArray<JSAny?> get ops;
}

/// [NoteEditorPort] over Quill in the real document.
final class QuillNoteEditor implements NoteEditorPort {
  const QuillNoteEditor();

  /// The toolbar: what markdown can keep. Colours, fonts and alignment
  /// would be lost on the next save, so they are not offered.
  static final JSAny _toolbar = <Object?>[
    <Object?>[
      <String, Object?>{
        'header': <Object?>[1, 2, 3, false],
      },
    ],
    <Object?>['bold', 'italic', 'underline', 'strike', 'code'],
    <Object?>[
      <String, Object?>{'list': 'ordered'},
      <String, Object?>{'list': 'bullet'},
      <String, Object?>{'list': 'check'},
    ],
    <Object?>['blockquote', 'code-block', 'link'],
    <Object?>['clean'],
  ].jsify()!;

  @override
  NoteEditorSession open(
    String hostId, {
    required List<Map<String, dynamic>> ops,
    required String placeholder,
    required void Function(List<Map<String, dynamic>> ops) onChange,
  }) {
    final host = web.document.getElementById(hostId);
    if (host == null) return const _NoSession();
    // Quill adds its toolbar beside the element it is given, so it gets an
    // element of its own inside the host. The host is the page's; what is
    // inside it is Quill's.
    while (host.firstChild != null) {
      host.removeChild(host.firstChild!);
    }
    final container = web.document.createElement('div');
    host.appendChild(container);
    final quill = _Quill(
      container,
      <String, Object?>{
        'theme': 'snow',
        'placeholder': placeholder,
        'modules': <String, Object?>{'toolbar': _toolbar},
      }.jsify()!,
    );
    quill.setContents(<String, Object?>{'ops': ops}.jsify()!, 'silent');
    quill.on(
      'text-change',
      ((JSAny? delta, JSAny? old, JSString source) {
        // Only the user's own edits. `replace` sets contents silently, and
        // an API change is the page's own doing.
        if (source.toDart != 'user') return;
        onChange(_ops(quill));
      }).toJS,
    );
    return _QuillSession(host, quill);
  }

  static List<Map<String, dynamic>> _ops(_Quill quill) =>
      <Map<String, dynamic>>[
        for (final op in quill.getContents().ops.toDart)
          if (op.dartify() case final Map<Object?, Object?> map)
            <String, dynamic>{
              for (final entry in map.entries) '${entry.key}': entry.value,
            },
      ];
}

final class _QuillSession implements NoteEditorSession {
  _QuillSession(this._host, this._quill);

  final web.Element _host;
  final _Quill _quill;

  @override
  void replace(List<Map<String, dynamic>> ops) =>
      _quill.setContents(<String, Object?>{'ops': ops}.jsify()!, 'silent');

  @override
  void focus() => _quill.focus();

  @override
  void close() {
    while (_host.firstChild != null) {
      _host.removeChild(_host.firstChild!);
    }
  }
}

final class _NoSession implements NoteEditorSession {
  const _NoSession();

  @override
  void replace(List<Map<String, dynamic>> ops) {}

  @override
  void focus() {}

  @override
  void close() {}
}

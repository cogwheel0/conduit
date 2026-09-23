import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../attachments.dart';
import '../l10n/strings.g.dart';
import '../note_editor.dart';
import '../rpc/chat_providers.dart' show fileUrlProvider;
import '../rpc/notes_providers.dart';
import '../rpc/rpc_providers.dart' show attachmentsProvider;
import '../widgets/form_field.dart';

/// Notes (M5): the list on the left, the note on the right.
///
/// The same notes as mobile and the web client: stored as markdown in the
/// account, edited here in Quill. Saved as you type, a moment after you
/// stop, so there is no Save button to forget.
class NotesPage extends StatelessComponent {
  const NotesPage({this.noteId, super.key});

  /// The note open on the right; null shows the empty state.
  final String? noteId;

  @override
  Component build(BuildContext context) {
    final id = noteId;
    return div(classes: 'flex h-screen min-h-0 bg-background text-foreground', [
      _NoteList(openId: id),
      main_(classes: 'flex min-w-0 flex-1 flex-col', [
        if (id == null)
          const _NoNote()
        else
          _NoteEditorPane(key: ValueKey('note-$id'), id: id),
      ]),
    ]);
  }
}

class _NoteList extends StatelessComponent {
  const _NoteList({required this.openId});

  /// The note on the right, marked in the list.
  final String? openId;

  @override
  Component build(BuildContext context) {
    final list = context.watch(noteListProvider);
    final query = context.watch(noteSearchProvider);
    final notes = list.value?.notes ?? const <NoteSummary>[];
    return nav(
      classes: 'flex w-72 shrink-0 flex-col gap-3 border-r border-border bg-card p-3',
      attributes: <String, String>{'aria-label': t.app.notes},
      [
        div(classes: 'flex items-center gap-2', [
          // `Link`, not a bare anchor: an anchor reloads the whole app.
          Link(
            to: '/',
            classes: 'rounded px-2 py-1 text-sm hover:bg-accent',
            attributes: <String, String>{'aria-label': t.app.back},
            child: Component.text('←'),
          ),
          h1(classes: 'flex-1 text-sm font-semibold', [
            Component.text(t.app.notes),
          ]),
          button(
            [Component.text(t.app.createNote)],
            classes:
                'rounded bg-primary px-2.5 py-1 text-xs '
                'text-primary-foreground',
            type: ButtonType.button,
            onClick: () async {
              final router = Router.of(context);
              final created = await context
                  .read(noteActionsProvider)
                  .save(const NoteSave(title: ''));
              router.push('/notes/${created.summary.id}');
            },
          ),
        ]),
        textField(
          id: 'note-search',
          labelText: t.app.searchNotes,
          hideLabel: true,
          placeholder: t.app.searchNotes,
          value: query,
          onInput: (value) =>
              context.read(noteSearchProvider.notifier).set(value),
        ),
        if (list.isLoading && list.value == null)
          p(classes: 'text-xs text-muted-foreground', [
            Component.text(t.app.loadingNotes),
          ])
        else if (list.hasError && list.value == null)
          formError(t.app.failedToLoadNotes)
        else if (notes.isEmpty)
          p(classes: 'text-xs text-muted-foreground', [
            Component.text(
              query.trim().isEmpty ? t.app.noNotesYet : t.app.noNotesFound,
            ),
          ]),
        ul(classes: 'min-h-0 flex-1 space-y-1 overflow-y-auto', [
          for (final note in notes)
            li([
              Link(
                to: '/notes/${note.id}',
                classes:
                    'block rounded px-2 py-1.5 hover:bg-accent '
                    'aria-[current=page]:bg-accent',
                attributes: <String, String>{
                  if (note.id == openId) 'aria-current': 'page',
                },
                children: [
                  span(classes: 'flex items-center gap-1 text-sm', [
                    if (note.pinned)
                      span(
                        classes: 'text-xs',
                        attributes: <String, String>{'aria-label': t.app.pin},
                        [Component.text('★')],
                      ),
                    span(classes: 'truncate font-medium', [
                      Component.text(
                        note.title.isEmpty ? t.app.untitled : note.title,
                      ),
                    ]),
                    // Both versions of a note edited in two places at once:
                    // this one is this computer's, kept rather than lost.
                    if (note.conflictCopy)
                      span(
                        classes:
                            'shrink-0 rounded-full border border-destructive/50 '
                            'px-1.5 text-[10px] text-destructive',
                        [Component.text(t.app.noteConflictCopyBadge)],
                      ),
                  ]),
                  if (note.preview.isNotEmpty)
                    span(
                      classes: 'block truncate text-xs text-muted-foreground',
                      [Component.text(_plain(note.preview))],
                    ),
                ],
              ),
            ]),
        ]),
      ],
    );
  }

  /// The preview without markdown's markers: a line's leading `#`, `>` or
  /// list marker, and emphasis, strike-through and code around words.
  static String _plain(String markdown) => markdown
      .split('\n')
      .map(
        (row) => row
            .replaceFirst(RegExp(r'^\s*([#>*-]+|\d+\.)\s*(\[[ xX]\]\s*)?'), '')
            .replaceAll(RegExp(r'\*\*|__|~~|`'), ''),
      )
      .where((row) => row.trim().isNotEmpty)
      .join(' · ');
}

class _NoNote extends StatelessComponent {
  const _NoNote();

  @override
  Component build(BuildContext context) =>
      div(classes: 'm-auto max-w-sm space-y-2 p-8 text-center', [
        p(classes: 'text-sm font-medium', [Component.text(t.app.notes)]),
        p(classes: 'text-sm text-muted-foreground', [
          Component.text(t.app.createFirstNoteHint),
        ]),
      ]);
}

/// One note: its title, pin and delete, and the editor.
class _NoteEditorPane extends StatefulComponent {
  const _NoteEditorPane({required this.id, super.key});

  final String id;

  @override
  State<_NoteEditorPane> createState() => _NoteEditorPaneState();
}

enum _SaveState { idle, saving, saved, failed }

class _NoteEditorPaneState extends State<_NoteEditorPane> {
  /// Long enough to not save on every keystroke, short enough that closing
  /// the window straight after typing rarely finds anything unsaved -- and
  /// leaving the note saves what is pending anyway.
  static const Duration _saveDelay = Duration(milliseconds: 800);

  static const String _hostId = 'note-editor-host';

  NoteEditorSession? _session;

  /// Taken while building: the save that leaving the note triggers runs in
  /// `dispose`, where the context can no longer be read.
  NoteActions? _actions;
  String _title = '';
  bool _pinned = false;
  bool _loaded = false;

  /// What changed since the last save: the body, the title, or both.
  List<Map<String, dynamic>>? _pendingOps;
  bool _titleChanged = false;
  Timer? _saveTimer;
  _SaveState _state = _SaveState.idle;
  bool _confirmingDelete = false;

  /// A model is writing the title or the body; both buttons wait.
  bool _asking = false;

  /// What the last AI action said: done, or why not.
  String? _notice;

  /// The note's attachments, as last saved.
  List<NoteFile> _files = const <NoteFile>[];
  bool _recording = false;

  /// Files on their way up: shown until they are attached.
  int _uploading = 0;

  /// Uploads [picked] and attaches it to the note.
  Future<void> _attachPicked(PickedAttachment picked) async {
    final actions = _actions;
    if (actions == null) return;
    final attachments = context.read(attachmentsProvider);
    setState(() => _uploading++);
    try {
      final fileId = await attachments.upload(picked.handle);
      final detail = await actions.attach(
        component.id,
        NoteFile(
          id: fileId,
          name: picked.name,
          size: picked.size,
          contentType: picked.contentType.isEmpty ? null : picked.contentType,
        ),
      );
      if (mounted) setState(() => _files = detail.files);
    } on Object {
      if (mounted) setState(() => _notice = t.app.failedToAttachContent);
    } finally {
      if (mounted) setState(() => _uploading--);
    }
  }

  Future<void> _attachFiles() async {
    final picked = await context.read(attachmentsProvider).pick();
    for (final file in picked) {
      await _attachPicked(file);
    }
  }

  Future<void> _toggleRecording() async {
    final attachments = context.read(attachmentsProvider);
    if (_recording) {
      setState(() => _recording = false);
      final recording = await attachments.stopRecording();
      if (recording != null) {
        await _attachPicked(recording);
        if (mounted) setState(() => _notice = t.app.audioRecordingSaved);
      }
      return;
    }
    final started = await attachments.startRecording();
    if (!mounted) return;
    setState(() {
      _recording = started;
      _notice = started ? null : t.app.microphonePermissionDenied;
    });
  }

  Future<void> _detach(NoteFile file) async {
    final actions = _actions;
    if (actions == null) return;
    try {
      final detail = await actions.detach(component.id, file.id);
      if (mounted) setState(() => _files = detail.files);
    } on Object {
      if (mounted) setState(() => _notice = t.desktop.desktopNoteSaveFailed);
    }
  }

  /// The editor's text, for a model to read; null when there is none.
  List<Map<String, dynamic>>? _textForModel() {
    final ops = _session?.contents() ?? const <Map<String, dynamic>>[];
    final text = ops.map((op) => op['insert']).whereType<String>().join();
    return text.trim().isEmpty ? null : ops;
  }

  Future<void> _generateTitle() async {
    final actions = _actions;
    if (_asking || actions == null) return;
    final ops = _textForModel();
    if (ops == null) {
      setState(() => _notice = t.app.noContentToGenerateTitle);
      return;
    }
    setState(() {
      _asking = true;
      _notice = t.app.generatingTitle;
    });
    try {
      final title = await actions.generateTitle(ops);
      if (!mounted) return;
      setState(() {
        _title = title;
        _notice = null;
      });
      _titleChanged = true;
      _scheduleSave();
    } on Object {
      if (mounted) setState(() => _notice = t.app.failedToGenerateTitle);
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  Future<void> _enhance() async {
    final actions = _actions;
    if (_asking || actions == null) return;
    final ops = _textForModel();
    if (ops == null) {
      setState(() => _notice = t.app.noContentToEnhance);
      return;
    }
    setState(() {
      _asking = true;
      _notice = null;
    });
    try {
      final enhanced = await actions.enhance(ops);
      if (!mounted) return;
      // Shown, then saved like any edit: the user can undo it by editing,
      // and it is never saved behind their back unseen.
      _session?.replace(enhanced);
      _pendingOps = enhanced;
      _scheduleSave();
      setState(() => _notice = t.app.noteEnhanced);
    } on Object {
      if (mounted) setState(() => _notice = t.app.failedToEnhanceNote);
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Leaving the note is not a reason to lose what was typed.
    if (_pendingOps != null || _titleChanged) unawaited(_save());
    _session?.close();
    super.dispose();
  }

  /// Takes the loaded note once, then leaves the editor alone: it is the
  /// source of truth while it is open.
  void _adopt(NoteDetail detail) {
    if (_loaded) return;
    _loaded = true;
    _title = detail.summary.title;
    _pinned = detail.summary.pinned;
    _files = detail.files;
    final editor = context.read(noteEditorProvider);
    // After the frame that renders the host element.
    Future<void>.microtask(() {
      if (!mounted) return;
      _session = editor.open(
        _hostId,
        ops: detail.ops,
        placeholder: t.app.writeNote,
        onChange: (ops) {
          _pendingOps = ops;
          _scheduleSave();
        },
      );
    });
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(_save()));
    if (_state != _SaveState.saving) setState(() => _state = _SaveState.idle);
  }

  Future<void> _save() async {
    final ops = _pendingOps;
    final titleChanged = _titleChanged;
    if (ops == null && !titleChanged) return;
    final actions = _actions;
    if (actions == null) return;
    _pendingOps = null;
    _titleChanged = false;
    if (mounted) setState(() => _state = _SaveState.saving);
    try {
      await actions.save(
        NoteSave(id: component.id, title: _title.trim(), ops: ops),
      );
      if (mounted && _pendingOps == null && !_titleChanged) {
        setState(() => _state = _SaveState.saved);
      }
    } on Object {
      // Kept for the next attempt rather than dropped.
      _pendingOps ??= ops;
      _titleChanged = _titleChanged || titleChanged;
      if (mounted) setState(() => _state = _SaveState.failed);
    }
  }

  /// Attach and record, and the files already on the note: a recording
  /// plays in place, anything else opens.
  Component _attachmentsRow(BuildContext context) {
    final url = context.watch(fileUrlProvider);
    return div(classes: 'space-y-2', [
      div(classes: 'flex flex-wrap items-center gap-2', [
        button(
          [Component.text(t.app.attach)],
          classes:
              'rounded border border-border px-2.5 py-1 text-xs '
              'hover:bg-accent disabled:opacity-50',
          type: ButtonType.button,
          disabled: _recording,
          onClick: () => unawaited(_attachFiles()),
        ),
        button(
          [
            Component.text(
              _recording ? t.app.stopRecording : t.app.recordAudio,
            ),
          ],
          classes:
              'rounded border px-2.5 py-1 text-xs hover:bg-accent '
              '${_recording ? 'border-destructive text-destructive' : 'border-border'}',
          type: ButtonType.button,
          attributes: <String, String>{'aria-pressed': '$_recording'},
          onClick: () => unawaited(_toggleRecording()),
        ),
        if (_recording)
          span(
            classes: 'text-xs text-destructive',
            attributes: const <String, String>{'role': 'status'},
            [Component.text(t.app.recordingAudio)],
          ),
        if (_uploading > 0)
          span(classes: 'text-xs text-muted-foreground', [
            Component.text(t.app.processingRecording),
          ]),
      ]),
      if (_files.isNotEmpty)
        ul(
          classes: 'space-y-1',
          attributes: <String, String>{'aria-label': t.app.attachments},
          [
            for (final file in _files)
              li(classes: 'flex items-center gap-2 text-sm', [
                if (url != null &&
                    (file.contentType?.startsWith('audio/') ?? false))
                  audio(
                    src: url(file.id),
                    controls: true,
                    classes: 'h-8',
                    attributes: <String, String>{'aria-label': file.name},
                    [],
                  )
                else if (url != null)
                  a(
                    href: url(file.id),
                    target: Target.blank,
                    classes: 'truncate text-primary underline',
                    [Component.text(file.name)],
                  )
                else
                  span(classes: 'truncate', [Component.text(file.name)]),
                if (file.contentType?.startsWith('audio/') ?? false)
                  span(classes: 'truncate text-xs text-muted-foreground', [
                    Component.text(file.name),
                  ]),
                button(
                  [Component.text('×')],
                  classes: 'rounded px-1.5 text-xs hover:bg-accent',
                  type: ButtonType.button,
                  attributes: <String, String>{
                    'aria-label': '${t.app.delete}: ${file.name}',
                  },
                  onClick: () => unawaited(_detach(file)),
                ),
              ]),
          ],
        ),
    ]);
  }

  @override
  Component build(BuildContext context) {
    _actions = context.read(noteActionsProvider);
    final detail = context.watch(noteDetailProvider(component.id));
    final note = detail.value;
    if (note != null) _adopt(note);
    if (detail.isLoading && note == null) {
      return p(classes: 'm-auto text-sm text-muted-foreground', [
        Component.text(t.app.loadingNote),
      ]);
    }
    if (note == null) {
      return p(classes: 'm-auto text-sm text-muted-foreground', [
        Component.text(t.app.noteNotFound),
      ]);
    }
    return div(classes: 'flex min-h-0 flex-1 flex-col gap-3 p-6', [
      div(classes: 'flex items-center gap-2', [
        input(
          id: 'note-title',
          classes:
              'min-w-0 flex-1 bg-transparent text-xl font-semibold '
              'outline-none placeholder:text-muted-foreground',
          type: InputType.text,
          value: _title,
          attributes: <String, String>{
            'placeholder': t.app.untitled,
            'aria-label': t.app.untitled,
          },
          onInput: (value) {
            _title = '$value';
            _titleChanged = true;
            _scheduleSave();
          },
        ),
        span(
          classes: 'text-xs text-muted-foreground',
          attributes: const <String, String>{'role': 'status'},
          [
            Component.text(switch (_state) {
              _SaveState.saving => t.app.saving,
              _SaveState.saved => t.app.saved,
              _SaveState.failed => t.desktop.desktopNoteSaveFailed,
              _SaveState.idle => '',
            }),
          ],
        ),
        button(
          [Component.text(t.app.generateTitle)],
          classes:
              'rounded px-2.5 py-1 text-xs hover:bg-accent disabled:opacity-50',
          type: ButtonType.button,
          disabled: _asking,
          onClick: () => unawaited(_generateTitle()),
        ),
        button(
          [Component.text(t.app.enhanceNote)],
          classes:
              'rounded px-2.5 py-1 text-xs hover:bg-accent disabled:opacity-50',
          type: ButtonType.button,
          disabled: _asking,
          onClick: () => unawaited(_enhance()),
        ),
        button(
          [Component.text(_pinned ? t.app.unpin : t.app.pin)],
          classes: 'rounded px-2.5 py-1 text-xs hover:bg-accent',
          type: ButtonType.button,
          attributes: <String, String>{'aria-pressed': '$_pinned'},
          onClick: () async {
            final pinned = !_pinned;
            setState(() => _pinned = pinned);
            await context
                .read(noteActionsProvider)
                .setPinned(component.id, pinned: pinned);
          },
        ),
        button(
          [Component.text(t.app.delete)],
          classes:
              'rounded px-2.5 py-1 text-xs text-destructive '
              'hover:bg-destructive/10',
          type: ButtonType.button,
          onClick: () => setState(() => _confirmingDelete = true),
        ),
      ]),
      _attachmentsRow(context),
      if (_notice case final notice?)
        p(
          classes: 'text-xs text-muted-foreground',
          attributes: const <String, String>{'role': 'status'},
          [Component.text(notice)],
        ),
      if (_confirmingDelete)
        div(
          classes:
              'space-y-2 rounded border border-destructive/40 '
              'bg-destructive/10 p-3 text-sm',
          attributes: const <String, String>{'role': 'alertdialog'},
          [
            p([Component.text(t.app.deleteNoteTitle)]),
            div(classes: 'flex gap-2', [
              button(
                [Component.text(t.app.delete)],
                classes:
                    'rounded bg-destructive px-2.5 py-1 text-xs '
                    'text-destructive-foreground',
                type: ButtonType.button,
                onClick: () async {
                  final router = Router.of(context);
                  _saveTimer?.cancel();
                  _pendingOps = null;
                  _titleChanged = false;
                  await context.read(noteActionsProvider).delete(component.id);
                  router.replace('/notes');
                },
              ),
              button(
                [Component.text(t.app.cancel)],
                classes: 'rounded px-2.5 py-1 text-xs hover:bg-accent',
                type: ButtonType.button,
                onClick: () => setState(() => _confirmingDelete = false),
              ),
            ]),
          ],
        ),
      // Quill's; the page renders nothing inside it.
      div(id: _hostId, classes: 'note-editor flex min-h-0 flex-1 flex-col', []),
    ]);
  }
}

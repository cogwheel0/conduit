@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/note_editor.dart';
import 'package:conduit_desktop_ui/src/pages/notes_page.dart';
import 'package:conduit_desktop_ui/src/rpc/notes_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// Saves recorded instead of sent.
class _RecordingActions extends NoteActions {
  _RecordingActions(super.ref);

  final List<NoteSave> saves = <NoteSave>[];
  final List<(String, bool)> pins = <(String, bool)>[];

  @override
  Future<NoteDetail> save(NoteSave note) async {
    saves.add(note);
    return NoteDetail(
      summary: NoteSummary(
        id: note.id ?? 'new',
        title: note.title,
        updatedAtMs: 1,
      ),
    );
  }

  @override
  Future<void> setPinned(String id, {required bool pinned}) async =>
      pins.add((id, pinned));

  @override
  Future<String> generateTitle(List<Map<String, dynamic>> ops) async =>
      '🛒 Shopping';

  @override
  Future<List<Map<String, dynamic>>> enhance(
    List<Map<String, dynamic>> ops,
  ) async => const <Map<String, dynamic>>[
    <String, dynamic>{'insert': 'Shopping\n'},
  ];
}

const _list = NoteList(
  notes: <NoteSummary>[
    NoteSummary(
      id: 'n1',
      title: 'Groceries',
      updatedAtMs: 1,
      pinned: true,
      preview: '## Shop\n- **milk**',
    ),
    NoteSummary(id: 'n2', title: '', updatedAtMs: 1),
    NoteSummary(
      id: 'local:n3',
      title: 'Ideas (conflict copy)',
      updatedAtMs: 1,
      conflictCopy: true,
    ),
  ],
);

const _detail = NoteDetail(
  summary: NoteSummary(id: 'n1', title: 'Groceries', updatedAtMs: 1),
  ops: <Map<String, dynamic>>[
    <String, dynamic>{'insert': 'milk\n'},
  ],
);

void main() {
  late _RecordingActions actions;
  late RecordingNoteEditor editor;

  Component page({String? id}) {
    editor = RecordingNoteEditor();
    return ProviderScope(
      overrides: [
        noteListProvider.overrideWith((ref) async => _list),
        noteDetailProvider.overrideWith((ref, id) async => _detail),
        noteEditorProvider.overrideWithValue(editor),
        noteActionsProvider.overrideWith(
          (ref) => actions = _RecordingActions(ref),
        ),
      ],
      child: NotesPage(noteId: id),
    );
  }

  testComponents('lists notes, pinned marked and untitled named', (
    tester,
  ) async {
    tester.pumpComponent(page());
    await pumpEventQueue();
    expect(find.text('Groceries'), findsOneComponent);
    expect(find.text(t.app.untitled), findsOneComponent);
    expect(find.text('★'), findsOneComponent);
    expect(find.text(t.app.noteConflictCopyBadge), findsOneComponent);
    // The preview without its markdown.
    expect(find.text('Shop · milk'), findsOneComponent);
    expect(find.text(t.app.createFirstNoteHint), findsOneComponent);
  });

  testComponents('opens the note in the editor, and saves what is typed', (
    tester,
  ) async {
    tester.pumpComponent(page(id: 'n1'));
    await pumpEventQueue();
    expect(editor.sessions, hasLength(1));
    expect(editor.last.ops, _detail.ops);

    editor.last.type(const <Map<String, dynamic>>[
      <String, dynamic>{'insert': 'milk and eggs\n'},
    ]);
    // Not on every keystroke: a moment after typing stops.
    await pumpEventQueue();
    expect(actions.saves, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await pumpEventQueue();
    expect(actions.saves.single.id, 'n1');
    expect(actions.saves.single.ops!.single['insert'], 'milk and eggs\n');
    expect(actions.saves.single.title, 'Groceries');
  });

  testComponents('a model titles and rewrites the note, which then saves', (
    tester,
  ) async {
    tester.pumpComponent(page(id: 'n1'));
    await pumpEventQueue();

    Finder buttonWith(String text) =>
        find.ancestor(of: find.text(text), matching: find.tag('button'));

    await tester.click(buttonWith(t.app.enhanceNote));
    await pumpEventQueue();
    // Shown in the editor, and said so.
    expect(editor.last.ops.single['insert'], 'Shopping\n');
    expect(find.text(t.app.noteEnhanced), findsOneComponent);

    await tester.click(buttonWith(t.app.generateTitle));
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await pumpEventQueue();
    final saved = actions.saves.last;
    expect(saved.title, '🛒 Shopping');
    expect(saved.ops!.single['insert'], 'Shopping\n');
  });
}

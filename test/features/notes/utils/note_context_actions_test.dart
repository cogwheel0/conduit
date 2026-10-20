import 'package:conduit/features/notes/utils/note_context_actions.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/note.dart';
import 'package:conduit_core/models/user.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _me = User(
  id: 'me',
  username: 'me',
  email: 'me@example.com',
  role: 'user',
);

Note _note({String owner = 'me', bool? writeAccess, String? ownerName}) => Note(
  id: 'note-1',
  userId: owner,
  title: 'Plan',
  createdAt: 0,
  updatedAt: 0,
  writeAccess: writeAccess,
  user: ownerName == null ? null : NoteUser(id: owner, name: ownerName),
);

/// The note menu as the list builds it, for the signed-in account.
Future<List<ConduitContextMenuAction>> _actions(
  WidgetTester tester,
  Note note,
) async {
  late List<ConduitContextMenuAction> actions;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider2.overrideWithValue(_me),
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => WorkspaceCapabilities.all,
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Consumer(
          builder: (context, ref, _) {
            ref.watch(workspaceCapabilitiesProvider);
            actions = buildNoteContextMenuActions(
              context: context,
              ref: ref,
              note: note,
              onEdit: (_) async {},
              onTogglePin: (_) async {},
              onDelete: (_) async {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return actions;
}

void main() {
  testWidgets('your own note can be edited, shared and deleted, with Delete '
      'last', (tester) async {
    final labels = [
      for (final action in await _actions(tester, _note())) action.label,
    ];

    expect(labels.first, 'Edit');
    expect(labels, contains('Share note'));
    expect(labels.last, 'Delete');
  });

  testWidgets('a note shared read-only opens rather than edits and offers no '
      'Delete', (tester) async {
    final actions = await _actions(
      tester,
      _note(owner: 'casey', writeAccess: false, ownerName: 'Casey'),
    );
    final labels = [for (final action in actions) action.label];

    expect(labels.first, 'Open');
    expect(labels, isNot(contains('Edit')));
    expect(labels, isNot(contains('Delete')));
    expect(labels, isNot(contains('Share note')));
    expect(actions.any((action) => action.destructive), isFalse);
  });

  test('the owner is named only on someone else\'s note', () {
    expect(noteSharedOwner(_note(ownerName: 'Me'), accountId: 'me'), isNull);
    expect(
      noteSharedOwner(
        _note(owner: 'casey', ownerName: 'Casey'),
        accountId: 'me',
      )?.name,
      'Casey',
    );
    // An owner the note does not name is not shown by id.
    expect(noteSharedOwner(_note(owner: 'casey'), accountId: 'me'), isNull);
  });
}

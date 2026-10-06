import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';

WorkspaceAccessGrantInput _user(
  String id, {
  WorkspaceGrantPermission permission = WorkspaceGrantPermission.read,
}) => WorkspaceAccessGrantInput(
  principalType: WorkspacePrincipalType.user,
  principalId: id,
  permission: permission,
);

WorkspaceAccessGrantInput _group(
  String id, {
  WorkspaceGrantPermission permission = WorkspaceGrantPermission.read,
}) => WorkspaceAccessGrantInput(
  principalType: WorkspacePrincipalType.group,
  principalId: id,
  permission: permission,
);

const _publicGrant = WorkspaceAccessGrantInput(
  principalType: WorkspacePrincipalType.user,
  principalId: '*',
  permission: WorkspaceGrantPermission.read,
);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<WorkspaceAccessGrantInput> grants,
  required WorkspaceSectionCapabilities capabilities,
  required bool allowUserGrants,
  bool allowGroupGrants = true,
  bool readOnly = false,
  WorkspacePrincipalDirectory? directory,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (directory != null)
          workspacePrincipalDirectoryProvider.overrideWithValue(directory),
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WorkspaceAccessGrantSheet(
            initialGrants: grants,
            capabilities: capabilities,
            allowUserGrants: allowUserGrants,
            allowGroupGrants: allowGroupGrants,
            readOnly: readOnly,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Switch _switchIn(WidgetTester tester, Key tileKey) {
  return tester.widget<Switch>(
    find.descendant(of: find.byKey(tileKey), matching: find.byType(Switch)),
  );
}

Future<void> _pumpPrincipalPicker(
  WidgetTester tester, {
  required WorkspacePrincipalDirectory directory,
  bool allowUsers = true,
  bool allowGroups = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: WorkspacePrincipalPicker(
            directory: directory,
            allowUsers: allowUsers,
            allowGroups: allowGroups,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('grant algebra', () {
    test('normalize drops duplicates and empty principals', () {
      final result = normalizeWorkspaceGrants([
        _user('a'),
        _user('a'),
        _user(''),
        _group('g'),
      ]);
      expect(result, hasLength(2));
      expect(result.where((g) => g.principalId == 'a'), hasLength(1));
    });

    test('public grant is a single wildcard user read grant', () {
      expect(workspaceGrantsArePublic([_user('a')]), isFalse);
      final made = setWorkspacePublicGrant([_user('a')], true);
      expect(workspaceGrantsArePublic(made), isTrue);
      expect(made.where((g) => g.principalId == '*'), hasLength(1));
      // Public principals are not surfaced as normal shared principals.
      expect(
        workspaceSharedPrincipals(made).where((p) => p.id == '*'),
        isEmpty,
      );
      final cleared = setWorkspacePublicGrant(made, false);
      expect(workspaceGrantsArePublic(cleared), isFalse);
    });

    test('setting write keeps read and toggling off leaves read', () {
      var grants = <WorkspaceAccessGrantInput>[_user('a')];
      grants = setWorkspacePrincipalWrite(
        grants,
        WorkspacePrincipalType.user,
        'a',
        true,
      );
      expect(
        workspacePrincipalCanWrite(grants, WorkspacePrincipalType.user, 'a'),
        isTrue,
      );
      // read + write entries, de-duplicated.
      expect(grants.where((g) => g.principalId == 'a'), hasLength(2));
      grants = setWorkspacePrincipalWrite(
        grants,
        WorkspacePrincipalType.user,
        'a',
        false,
      );
      expect(
        workspacePrincipalCanWrite(grants, WorkspacePrincipalType.user, 'a'),
        isFalse,
      );
      expect(grants.where((g) => g.principalId == 'a'), hasLength(1));
    });

    test('removing a principal drops all its grants', () {
      final grants = removeWorkspacePrincipal(
        [
          _user('a', permission: WorkspaceGrantPermission.write),
          _user('a'),
          _group('g'),
        ],
        WorkspacePrincipalType.user,
        'a',
      );
      expect(grants.any((g) => g.principalId == 'a'), isFalse);
      expect(grants.any((g) => g.principalId == 'g'), isTrue);
    });
  });

  group('WorkspaceAccessGrantSheet capability gating', () {
    testWidgets('read-only hides save and add, shows sharing-disabled notice', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        grants: [_group('g')],
        capabilities: WorkspaceSectionCapabilities.all,
        allowUserGrants: true,
        readOnly: true,
      );

      expect(find.byKey(const Key('workspace-access-save')), findsNothing);
      expect(find.byKey(const Key('workspace-access-add')), findsNothing);
      // Public toggle present but disabled.
      expect(
        _switchIn(tester, const Key('workspace-access-public')).onChanged,
        isNull,
      );
    });

    testWidgets('share=false forces read-only even when readOnly is false', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        grants: const [],
        capabilities: const WorkspaceSectionCapabilities(
          manage: true,
          share: false,
        ),
        allowUserGrants: true,
      );

      expect(find.byKey(const Key('workspace-access-save')), findsNothing);
      expect(find.byKey(const Key('workspace-access-add')), findsNothing);
    });

    testWidgets('sharePublicly=false disables the public toggle', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        grants: const [],
        capabilities: const WorkspaceSectionCapabilities(
          manage: true,
          share: true,
          sharePublicly: false,
        ),
        allowUserGrants: true,
      );

      // Editable (save + add present) but public toggle is locked off.
      expect(find.byKey(const Key('workspace-access-save')), findsOneWidget);
      expect(
        _switchIn(tester, const Key('workspace-access-public')).onChanged,
        isNull,
      );
    });

    testWidgets('allowUserGrants=false shows the groups-only add label', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(
        tester,
        grants: const [],
        capabilities: WorkspaceSectionCapabilities.all,
        allowUserGrants: false,
      );

      expect(find.text(l10n.workspaceAccessAddGroups), findsOneWidget);
      expect(find.text(l10n.workspaceAccessAddPeople), findsNothing);
    });

    testWidgets('public initial grant renders the public switch on', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        grants: const [_publicGrant],
        capabilities: WorkspaceSectionCapabilities.all,
        allowUserGrants: true,
      );

      final publicSwitch = _switchIn(
        tester,
        const Key('workspace-access-public'),
      );
      expect(publicSwitch.value, isTrue);
      expect(publicSwitch.onChanged, isNotNull);
      // Wildcard grant does not appear as a normal shared principal row.
      expect(find.byKey(const Key('workspace-access-empty')), findsOneWidget);
    });
  });

  group('independent user and group grant permissions', () {
    Future<void> openPicker(
      WidgetTester tester,
      _RecordingDirectory recording, {
      required bool allowUsers,
      required bool allowGroups,
    }) async {
      await _pumpSheet(
        tester,
        grants: const [],
        capabilities: WorkspaceSectionCapabilities.all,
        allowUserGrants: allowUsers,
        allowGroupGrants: allowGroups,
        directory: recording.directory,
      );
      await tester.tap(find.byKey(const Key('workspace-access-add')));
      await tester.pumpAndSettle();
    }

    testWidgets('users only: searches people, never requests groups', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      final recording = _RecordingDirectory();
      await openPicker(tester, recording, allowUsers: true, allowGroups: false);

      expect(
        find.byKey(const Key('workspace-principal-tab-users')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('workspace-principal-tab-groups')),
        findsNothing,
      );
      await tester.enterText(find.byType(EditableText), 'ali');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('workspace-principal-user-u-alice')),
      );
      await tester.pumpAndSettle();

      expect(recording.searches, ['ali']);
      expect(recording.groupLoads, 0);
      expect(
        find.byKey(const Key('workspace-access-principal-user-u-alice')),
        findsOneWidget,
      );
      expect(find.text(l10n.workspaceAccessAddUsers), findsOneWidget);
      expect(find.text(l10n.workspaceAccessGroupsDisabled), findsOneWidget);
    });

    testWidgets('groups only: lists groups, never searches people', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      final recording = _RecordingDirectory();
      await openPicker(tester, recording, allowUsers: false, allowGroups: true);

      expect(recording.groupLoads, 1);
      expect(
        find.byKey(const Key('workspace-principal-tab-users')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('workspace-principal-tab-groups')),
        findsNothing,
      );
      expect(find.byType(EditableText), findsNothing);
      await tester.tap(
        find.byKey(const Key('workspace-principal-group-g-staff')),
      );
      await tester.pumpAndSettle();

      expect(recording.searches, isEmpty);
      expect(
        find.byKey(const Key('workspace-access-principal-group-g-staff')),
        findsOneWidget,
      );
      expect(find.text(l10n.workspaceAccessAddGroups), findsOneWidget);
      expect(find.text(l10n.workspaceAccessUsersDisabled), findsOneWidget);
    });

    testWidgets('both allowed: groups load only when their tab is chosen', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      final recording = _RecordingDirectory();
      await openPicker(tester, recording, allowUsers: true, allowGroups: true);

      expect(
        find.byKey(const Key('workspace-principal-tab-users')),
        findsOneWidget,
      );
      expect(recording.groupLoads, 0);
      await tester.tap(find.byKey(const Key('workspace-principal-tab-groups')));
      await tester.pumpAndSettle();

      expect(recording.groupLoads, 1);
      expect(find.text('Staff'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('workspace-access-add')),
          matching: find.text(l10n.workspaceAccessAddPeople),
        ),
        findsOneWidget,
      );
    });

    testWidgets('neither allowed: no way to add and nothing is requested', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      final recording = _RecordingDirectory();
      await _pumpSheet(
        tester,
        grants: const [],
        capabilities: WorkspaceSectionCapabilities.all,
        allowUserGrants: false,
        allowGroupGrants: false,
        directory: recording.directory,
      );

      expect(find.byKey(const Key('workspace-access-add')), findsNothing);
      expect(find.text(l10n.workspaceAccessGrantsDisabled), findsOneWidget);
      expect(recording.searches, isEmpty);
      expect(recording.groupLoads, 0);
    });

    testWidgets('a picker shown with neither kind allowed requests nothing', (
      tester,
    ) async {
      final recording = _RecordingDirectory();
      await _pumpPrincipalPicker(
        tester,
        directory: recording.directory,
        allowUsers: false,
        allowGroups: false,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('workspace-principal-none-allowed')),
        findsOneWidget,
      );
      expect(find.byType(EditableText), findsNothing);
      expect(recording.searches, isEmpty);
      expect(recording.groupLoads, 0);
    });

    testWidgets('grants of a kind that can no longer be added are kept on '
        'save', (tester) async {
      List<WorkspaceAccessGrantInput>? saved;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    // The sheet pops its grants on save; a pushed page hosts it
                    // without the modal's height cap.
                    saved = await Navigator.of(context)
                        .push<List<WorkspaceAccessGrantInput>>(
                          MaterialPageRoute(
                            builder: (_) => Scaffold(
                              body: WorkspaceAccessGrantSheet(
                                initialGrants: [
                                  _group(
                                    'g-legacy',
                                    permission: WorkspaceGrantPermission.write,
                                  ),
                                  _user('u1'),
                                ],
                                capabilities: WorkspaceSectionCapabilities.all,
                                allowUserGrants: true,
                                allowGroupGrants: false,
                              ),
                            ),
                          ),
                        );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('workspace-access-principal-group-g-legacy')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('workspace-access-save')));
      await tester.pumpAndSettle();

      expect(
        saved!.map(
          (g) =>
              '${g.principalType.name}:${g.principalId}:${g.permission.name}',
        ),
        unorderedEquals(['group:g-legacy:write', 'user:u1:read']),
      );
    });
  });

  group('WorkspacePrincipalPicker request ordering', () {
    testWidgets('newer user search wins when responses finish out of order', (
      tester,
    ) async {
      final first = Completer<List<WorkspacePrincipalPreview>>();
      final second = Completer<List<WorkspacePrincipalPreview>>();
      await _pumpPrincipalPicker(
        tester,
        directory: WorkspacePrincipalDirectory(
          searchUsers: (query) =>
              query == 'first' ? first.future : second.future,
          loadGroups: () async => const [],
        ),
      );

      final field = find.byType(EditableText);
      await tester.enterText(field, 'first');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.enterText(field, 'second');
      await tester.pump(const Duration(milliseconds: 301));

      second.complete(const [
        WorkspacePrincipalPreview(
          id: 'new',
          type: WorkspacePrincipalType.user,
          name: 'New result',
        ),
      ]);
      await tester.pump();
      first.complete(const [
        WorkspacePrincipalPreview(
          id: 'old',
          type: WorkspacePrincipalType.user,
          name: 'Old result',
        ),
      ]);
      await tester.pump();

      expect(find.text('New result'), findsOneWidget);
      expect(find.text('Old result'), findsNothing);
    });

    testWidgets('user search cannot overwrite the groups tab', (tester) async {
      final users = Completer<List<WorkspacePrincipalPreview>>();
      final groups = Completer<List<WorkspacePrincipalPreview>>();
      await _pumpPrincipalPicker(
        tester,
        directory: WorkspacePrincipalDirectory(
          searchUsers: (_) => users.future,
          loadGroups: () => groups.future,
        ),
      );

      await tester.enterText(find.byType(EditableText), 'person');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.tap(find.byKey(const Key('workspace-principal-tab-groups')));
      await tester.pump();
      groups.complete(const [
        WorkspacePrincipalPreview(
          id: 'group',
          type: WorkspacePrincipalType.group,
          name: 'Current group',
        ),
      ]);
      await tester.pump();
      users.complete(const [
        WorkspacePrincipalPreview(
          id: 'user',
          type: WorkspacePrincipalType.user,
          name: 'Stale user',
        ),
      ]);
      await tester.pump();

      expect(find.text('Current group'), findsOneWidget);
      expect(find.text('Stale user'), findsNothing);
    });
  });
}

const _alice = WorkspacePrincipalPreview(
  id: 'u-alice',
  type: WorkspacePrincipalType.user,
  name: 'Alice Example',
);
const _staff = WorkspacePrincipalPreview(
  id: 'g-staff',
  type: WorkspacePrincipalType.group,
  name: 'Staff',
);

/// A principal directory that records which lookups the picker really makes.
final class _RecordingDirectory {
  final searches = <String>[];
  int groupLoads = 0;

  late final directory = WorkspacePrincipalDirectory(
    searchUsers: (query) async {
      searches.add(query);
      return const [_alice];
    },
    loadGroups: () async {
      groupLoads++;
      return const [_staff];
    },
  );
}

Future<AppLocalizations> _loadL10n(WidgetTester tester) async {
  late AppLocalizations l10n;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          l10n = AppLocalizations.of(context)!;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return l10n;
}

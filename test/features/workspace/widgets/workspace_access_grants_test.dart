import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/sharing/providers/principal_lookup.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

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

List<String> _keys(Iterable<WorkspaceAccessGrantInput>? grants) => [
  for (final g in grants ?? const <WorkspaceAccessGrantInput>[])
    '${g.principalType.name}:${g.principalId}:${g.permission.name}',
];

/// A lookup that answers from fixed people and groups and records what it was
/// asked.
final class _FakeLookup {
  _FakeLookup({
    this.users = const {},
    this.groups = const [],
    this.owner,
  });

  final Object? owner;
  final Map<String, WorkspacePrincipalPreview> users;
  final List<WorkspacePrincipalPreview> groups;
  final asked = <String>[];
  int groupLoads = 0;

  late final lookup = WorkspacePrincipalLookup(
    owner: owner,
    fetchUser: (id) async {
      asked.add(id);
      return users[id];
    },
    fetchGroups: () async {
      groupLoads++;
      return groups;
    },
  );
}

/// Swaps the lookup the way an account switch rebuilds the provider.
class _LookupHolder extends Notifier<WorkspacePrincipalLookup?> {
  @override
  WorkspacePrincipalLookup? build() => null;

  void set(WorkspacePrincipalLookup? value) => state = value;
}

final _lookupHolder =
    NotifierProvider<_LookupHolder, WorkspacePrincipalLookup?>(
      _LookupHolder.new,
    );

Widget _app(Widget home, {List overrides = const []}) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<WorkspaceAccessGrantInput> grants,
  WorkspaceSectionCapabilities capabilities = WorkspaceSectionCapabilities.all,
  bool allowUserGrants = true,
  bool allowGroupGrants = true,
  bool allowWriteGrants = true,
  bool readOnly = false,
  WorkspacePrincipalDirectory? directory,
  WorkspacePrincipalLookup? lookup,
  WorkspaceAudienceChoice? audience,
  WorkspaceAccessOwner? owner,
  String? resourceName,
}) async {
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: WorkspaceAccessGrantSheet(
          initialGrants: grants,
          capabilities: capabilities,
          allowUserGrants: allowUserGrants,
          allowGroupGrants: allowGroupGrants,
          allowWriteGrants: allowWriteGrants,
          readOnly: readOnly,
          audience: audience,
          owner: owner,
          resourceName: resourceName,
        ),
      ),
      overrides: [
        if (directory != null)
          workspacePrincipalDirectoryProvider.overrideWithValue(directory),
        workspacePrincipalLookupProvider.overrideWithValue(lookup),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

/// Hosts the sheet on a pushed page so it can close, and records what it
/// closed with.
final class _Opened {
  List<WorkspaceAccessGrantInput>? closedWith;
  bool closed = false;
}

Future<_Opened> _openSheet(
  WidgetTester tester, {
  required List<WorkspaceAccessGrantInput> grants,
  WorkspaceSectionCapabilities capabilities = WorkspaceSectionCapabilities.all,
  bool allowUserGrants = true,
  bool allowGroupGrants = true,
  WorkspaceAudienceChoice? audience,
  WorkspacePrincipalDirectory? directory,
  WorkspacePrincipalLookup? lookup,
  Future<WorkspaceAccessSaveOutcome> Function(
    List<WorkspaceAccessGrantInput> grants,
    ResourceAudience? audience,
  )?
  onSave,
}) async {
  final opened = _Opened();
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              opened.closedWith = await Navigator.of(context)
                  .push<List<WorkspaceAccessGrantInput>>(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        body: WorkspaceAccessGrantSheet(
                          initialGrants: grants,
                          capabilities: capabilities,
                          allowUserGrants: allowUserGrants,
                          allowGroupGrants: allowGroupGrants,
                          audience: audience,
                          onSave: onSave,
                        ),
                      ),
                    ),
                  );
              opened.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
      overrides: [
        workspacePrincipalDirectoryProvider.overrideWithValue(
          directory ?? _RecordingDirectory().directory,
        ),
        workspacePrincipalLookupProvider.overrideWithValue(lookup),
      ],
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return opened;
}

Future<void> _pumpPrincipalPicker(
  WidgetTester tester, {
  required WorkspacePrincipalDirectory directory,
  bool allowUsers = true,
  bool allowGroups = true,
  bool multiple = false,
  Set<String> existing = const {},
  String? existingLabel,
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
            multiple: multiple,
            existing: existing,
            existingLabel: existingLabel,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _level(String suffix) =>
    find.byKey(Key('workspace-access-level-$suffix'));

Future<void> _chooseLevel(
  WidgetTester tester,
  String suffix,
  String action,
) async {
  await tester.tap(_level(suffix));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('workspace-access-$action-$suffix')));
  await tester.pumpAndSettle();
}

Future<void> _openGeneralMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('workspace-access-general')));
  await tester.pumpAndSettle();
}

/// The general access option of that name in the open menu.
Finder _menuOption(String label) => find.ancestor(
  of: find.text(label).last,
  matching: find.byType(PopupMenuItem<int>),
);

Future<void> _pickGeneral(WidgetTester tester, String label) async {
  await _openGeneralMenu(tester);
  await tester.tap(_menuOption(label));
  await tester.pumpAndSettle();
}

String _generalShown(WidgetTester tester, AppLocalizations l10n) {
  for (final label in [
    l10n.libraryAccessOnlyPeopleAdded,
    l10n.libraryAccessEveryoneOnServer,
    l10n.libraryAccessAnyoneWithLink,
  ]) {
    final shown = find.descendant(
      of: find.byKey(const Key('workspace-access-general')),
      matching: find.text(label),
    );
    if (shown.evaluate().isNotEmpty) return label;
  }
  return 'none';
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

    test('grant keys ignore order and duplicates', () {
      expect(
        workspaceGrantKeys([_user('a'), _group('g'), _user('a')]),
        workspaceGrantKeys([_group('g'), _user('a')]),
      );
      expect(
        workspaceGrantKeys([_user('a')]),
        isNot(
          workspaceGrantKeys([
            _user('a', permission: WorkspaceGrantPermission.write),
          ]),
        ),
      );
    });

    test('dropped principals are those submitted that were not kept', () {
      final dropped = workspaceDroppedPrincipals(
        [_user('a'), _user('b', permission: WorkspaceGrantPermission.write)],
        [_user('b')],
      );
      expect(dropped.map((p) => p.id), ['a']);
    });
  });

  group('access summary', () {
    testWidgets('reads only you, a count, or everyone on the server', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      expect(workspaceAccessSummary(l10n, const []), 'Only you');
      expect(
        workspaceAccessSummary(l10n, [_user('a')]),
        'Shared with 1 person or group',
      );
      expect(
        workspaceAccessSummary(l10n, [_user('a'), _group('g')]),
        'Shared with 2 people or groups',
      );
      expect(
        workspaceAccessSummary(l10n, [_user('a'), _publicGrant]),
        'Everyone on this server',
      );
    });
  });

  group('WorkspaceAccessGrantSheet capability gating', () {
    testWidgets('read-only hides save and add and says who can change it', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(tester, grants: [_group('g')], readOnly: true);

      expect(find.byKey(const Key('workspace-access-save')), findsNothing);
      expect(find.byKey(const Key('workspace-access-add')), findsNothing);
      expect(find.text(l10n.libraryAccessOwnerOnlyNotice), findsOneWidget);
      // The level is shown, not offered.
      expect(
        tester.widget<Text>(_level('group-g')).data,
        l10n.libraryAccessCanView,
      );
      await _openGeneralMenu(tester);
      expect(find.byType(PopupMenuItem<int>), findsNothing);
    });

    testWidgets('share=false says the account cannot share', (tester) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(
        tester,
        grants: const [],
        capabilities: const WorkspaceSectionCapabilities(
          manage: true,
          share: false,
        ),
      );

      expect(find.byKey(const Key('workspace-access-save')), findsNothing);
      expect(find.byKey(const Key('workspace-access-add')), findsNothing);
      expect(find.text(l10n.libraryAccessAccountCantShare), findsOneWidget);
      expect(find.text(l10n.libraryAccessOwnerOnlyNotice), findsNothing);
    });

    testWidgets('sharePublicly=false disables Everyone on this server and says '
        'why', (tester) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(
        tester,
        grants: const [],
        capabilities: const WorkspaceSectionCapabilities(
          manage: true,
          share: true,
          sharePublicly: false,
        ),
      );

      expect(find.text(l10n.workspaceAccessPublicDisabled), findsOneWidget);
      await _openGeneralMenu(tester);
      expect(
        tester
            .widget<PopupMenuItem<int>>(
              _menuOption(l10n.libraryAccessEveryoneOnServer),
            )
            .enabled,
        isFalse,
      );
    });

    testWidgets('a resource already shared with everyone shows no "cannot '
        'share publicly" notice', (tester) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(
        tester,
        grants: const [_publicGrant],
        capabilities: const WorkspaceSectionCapabilities(
          manage: true,
          share: true,
          sharePublicly: false,
        ),
      );

      expect(_generalShown(tester, l10n), l10n.libraryAccessEveryoneOnServer);
      expect(find.text(l10n.workspaceAccessPublicDisabled), findsNothing);
    });

    testWidgets('allowUserGrants=false shows the groups-only add label', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(tester, grants: const [], allowUserGrants: false);

      expect(find.text(l10n.workspaceAccessAddGroups), findsOneWidget);
      expect(find.text(l10n.workspaceAccessAddPeople), findsNothing);
    });

    testWidgets('a public grant shows as Everyone on this server, not as a '
        'person', (tester) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(tester, grants: const [_publicGrant]);

      expect(_generalShown(tester, l10n), l10n.libraryAccessEveryoneOnServer);
      expect(find.text(l10n.libraryAccessEveryoneHint), findsOneWidget);
      expect(find.byKey(const Key('workspace-access-empty')), findsOneWidget);
    });

    testWidgets('the title is Share with the resource name under it', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(tester, grants: const [], resourceName: 'Roadmap');

      expect(find.text(l10n.libraryShareTitle), findsOneWidget);
      expect(find.text('Roadmap'), findsOneWidget);
    });
  });

  group('names', () {
    const alice = WorkspacePrincipalPreview(
      id: 'u-alice',
      type: WorkspacePrincipalType.user,
      name: 'Alice Example',
      email: 'alice@example.com',
    );
    const zed = WorkspacePrincipalPreview(
      id: 'u-zed',
      type: WorkspacePrincipalType.user,
      name: 'Zed Person',
      email: 'zed@example.com',
    );
    const staff = WorkspacePrincipalPreview(
      id: 'g-staff',
      type: WorkspacePrincipalType.group,
      name: 'Staff',
    );

    testWidgets('people and groups are named, sorted people first, and an '
        'unknown person never shows their id', (tester) async {
      final l10n = await _loadL10n(tester);
      final fake = _FakeLookup(
        users: {'u-alice': alice, 'u-zed': zed},
        groups: const [staff],
      );
      await _pumpSheet(
        tester,
        grants: [
          _group('g-staff'),
          _user('u-zed'),
          _user('u-gone'),
          _user('u-alice'),
        ],
        lookup: fake.lookup,
      );

      expect(fake.asked, unorderedEquals(['u-alice', 'u-zed', 'u-gone']));
      expect(fake.groupLoads, 1);
      expect(find.text('Alice Example'), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget);
      expect(find.text('Staff'), findsOneWidget);
      expect(find.text(l10n.libraryAccessUnknownPerson), findsOneWidget);
      expect(find.textContaining('u-gone'), findsNothing);
      expect(find.textContaining('u-alice'), findsNothing);

      double top(String suffix) => tester
          .getTopLeft(find.byKey(Key('workspace-access-principal-$suffix')))
          .dy;
      expect(top('user-u-alice'), lessThan(top('user-u-zed')));
      expect(top('user-u-zed'), lessThan(top('user-u-gone')));
      expect(top('user-u-gone'), lessThan(top('group-g-staff')));
    });

    testWidgets('names read for one account are hidden once another signs in', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      final first = _FakeLookup(users: {'u-alice': alice}, owner: 'account-a');
      final container = ProviderContainer(
        overrides: [
          workspacePrincipalLookupProvider.overrideWith(
            (ref) => ref.watch(_lookupHolder),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(_lookupHolder.notifier).set(first.lookup);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: WorkspaceAccessGrantSheet(
                initialGrants: [_user('u-alice')],
                capabilities: WorkspaceSectionCapabilities.all,
                allowUserGrants: true,
                allowGroupGrants: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alice Example'), findsOneWidget);

      // Another account: a new, empty lookup.
      container
          .read(_lookupHolder.notifier)
          .set(_FakeLookup(owner: 'account-b').lookup);
      await tester.pumpAndSettle();

      expect(find.text('Alice Example'), findsNothing);
      expect(find.text(l10n.libraryAccessUnknownPerson), findsOneWidget);
    });

    testWidgets('a lookup rebuilt for the same account keeps naming people', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          workspacePrincipalLookupProvider.overrideWith(
            (ref) => ref.watch(_lookupHolder),
          ),
        ],
      );
      addTearDown(container.dispose);
      // The sheet opens before the account's lookup exists.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: WorkspaceAccessGrantSheet(
                initialGrants: [_user('u-alice')],
                capabilities: WorkspaceSectionCapabilities.all,
                allowUserGrants: true,
                allowGroupGrants: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alice Example'), findsNothing);

      // The lookup arrives, then the provider rebuilds for the same account.
      container
          .read(_lookupHolder.notifier)
          .set(_FakeLookup(owner: 'account-a').lookup);
      await tester.pumpAndSettle();
      container
          .read(_lookupHolder.notifier)
          .set(_FakeLookup(users: {'u-alice': alice}, owner: 'account-a').lookup);
      await tester.pumpAndSettle();

      expect(find.text('Alice Example'), findsOneWidget);
    });

    testWidgets('the owner is shown first with an Owner label', (tester) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(
        tester,
        grants: [_user('u-alice')],
        lookup: _FakeLookup(users: {'u-alice': alice}).lookup,
        owner: const WorkspaceAccessOwner(isYou: true),
      );

      final owner = find.byKey(const Key('workspace-access-owner'));
      expect(
        find.descendant(of: owner, matching: find.text(l10n.you)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: owner,
          matching: find.text(l10n.libraryAccessOwner),
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(owner).dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(
                  const Key('workspace-access-principal-user-u-alice'),
                ),
              )
              .dy,
        ),
      );
    });
  });

  group('access levels', () {
    testWidgets('Can edit and Remove access come from one menu per row', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      final opened = await _openSheet(
        tester,
        grants: [_user('u-bob'), _user('u-eve')],
      );

      expect(
        find.descendant(
          of: _level('user-u-bob'),
          matching: find.text('${l10n.libraryAccessCanView} ▾'),
        ),
        findsOneWidget,
      );
      await _chooseLevel(tester, 'user-u-bob', 'edit');
      expect(
        find.descendant(
          of: _level('user-u-bob'),
          matching: find.text('${l10n.workspaceAccessCanEdit} ▾'),
        ),
        findsOneWidget,
      );
      await _chooseLevel(tester, 'user-u-eve', 'remove');
      expect(
        find.byKey(const Key('workspace-access-principal-user-u-eve')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('workspace-access-save')));
      await tester.pumpAndSettle();
      expect(
        _keys(opened.closedWith),
        unorderedEquals(['user:u-bob:read', 'user:u-bob:write']),
      );
    });

    testWidgets('without write grants a row offers only Remove access', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      await _pumpSheet(
        tester,
        grants: [_user('u-bob')],
        allowWriteGrants: false,
      );

      await tester.tap(_level('user-u-bob'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workspace-access-edit-user-u-bob')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('workspace-access-remove-user-u-bob')),
        findsOneWidget,
      );
      expect(find.text(l10n.workspaceAccessCanEdit), findsNothing);
    });

    testWidgets('rows name the person in their accessibility labels', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final l10n = await _loadL10n(tester);
      await _pumpSheet(
        tester,
        grants: [_user('u-bob')],
        lookup: _FakeLookup(
          users: {
            'u-bob': const WorkspacePrincipalPreview(
              id: 'u-bob',
              type: WorkspacePrincipalType.user,
              name: 'Bob',
            ),
          },
        ).lookup,
      );

      expect(
        find.bySemanticsLabel(RegExp(l10n.libraryAccessLevelFor('Bob'))),
        findsOneWidget,
      );
      final row = tester.getSemantics(
        find.byKey(const Key('workspace-access-principal-user-u-bob')),
      );
      expect(
        row.getSemanticsData().customSemanticsActionIds,
        isNotEmpty,
        reason: l10n.libraryAccessRemovePrincipal('Bob'),
      );
      handle.dispose();
    });
  });

  group('unsaved changes', () {
    testWidgets('Save stays off until something changes', (tester) async {
      await _openSheet(
        tester,
        grants: [_user('u-bob')],
        onSave: (_, _) async => const WorkspaceAccessSaveOutcome.saved(),
      );
      ConduitButton save() => tester.widget<ConduitButton>(
        find.byKey(const Key('workspace-access-save')),
      );
      expect(save().onPressed, isNull);

      await _chooseLevel(tester, 'user-u-bob', 'edit');
      expect(save().onPressed, isNotNull);

      // Back to where it started: nothing to save again.
      await _chooseLevel(tester, 'user-u-bob', 'view');
      expect(save().onPressed, isNull);
    });

    testWidgets('closing an untouched sheet does not ask', (tester) async {
      final opened = await _openSheet(tester, grants: [_user('u-bob')]);

      await tester.tap(find.byType(SheetCloseButton));
      await tester.pumpAndSettle();

      expect(opened.closed, isTrue);
      expect(opened.closedWith, isNull);
    });

    testWidgets('closing with edits asks first; Keep editing keeps them and '
        'Discard closes', (tester) async {
      final l10n = await _loadL10n(tester);
      final opened = await _openSheet(tester, grants: [_user('u-bob')]);
      await _chooseLevel(tester, 'user-u-bob', 'remove');

      await tester.tap(find.byType(SheetCloseButton));
      await tester.pumpAndSettle();
      expect(find.text(l10n.workspaceEditorDiscardTitle), findsOneWidget);
      await tester.tap(find.text(l10n.workspaceEditorKeepEditing));
      await tester.pumpAndSettle();
      expect(opened.closed, isFalse);
      expect(
        find.byKey(const Key('workspace-access-principal-user-u-bob')),
        findsNothing,
        reason: 'the edit is still there',
      );

      // The system back gesture asks the same question.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(l10n.workspaceEditorDiscardTitle), findsOneWidget);
      await tester.tap(find.text(l10n.workspaceEditorDiscardConfirm));
      await tester.pumpAndSettle();
      expect(opened.closed, isTrue);
      expect(opened.closedWith, isNull);
    });

    testWidgets('swiping the sheet down with edits asks first', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      List<WorkspaceAccessGrantInput>? result;
      var closed = false;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await WorkspaceAccessGrantSheet.show(
                    context,
                    initialGrants: [_user('u-bob')],
                    capabilities: WorkspaceSectionCapabilities.all,
                    allowUserGrants: true,
                    allowGroupGrants: true,
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
          overrides: [workspacePrincipalLookupProvider.overrideWithValue(null)],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await _chooseLevel(tester, 'user-u-bob', 'edit');

      await tester.fling(
        find.text(l10n.libraryShareTitle),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.workspaceEditorDiscardTitle), findsOneWidget);
      await tester.tap(find.text(l10n.workspaceEditorKeepEditing));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      expect(find.text(l10n.libraryShareTitle), findsOneWidget);

      // Untouched again, the same swipe just closes it.
      await _chooseLevel(tester, 'user-u-bob', 'view');
      await tester.fling(
        find.text(l10n.libraryShareTitle),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.workspaceEditorDiscardTitle), findsNothing);
      expect(closed, isTrue);
      expect(result, isNull);
    });

    testWidgets('Done without onSave returns the grants only when changed', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      var opened = await _openSheet(tester, grants: [_user('u-bob')]);
      expect(find.text(l10n.libraryAccessDone), findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace-access-save')));
      await tester.pumpAndSettle();
      expect(opened.closed, isTrue);
      expect(opened.closedWith, isNull);

      opened = await _openSheet(tester, grants: [_user('u-bob')]);
      await _pickGeneral(tester, l10n.libraryAccessEveryoneOnServer);
      await tester.tap(find.byKey(const Key('workspace-access-save')));
      await tester.pumpAndSettle();
      expect(
        _keys(opened.closedWith),
        unorderedEquals(['user:u-bob:read', 'user:*:read']),
      );
    });
  });

  group('a save the server keeps only part of', () {
    testWidgets('stays open on what was kept and names who was dropped', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      final opened = await _openSheet(
        tester,
        grants: [_user('u-bob')],
        lookup: _FakeLookup(
          users: {
            'u-bob': const WorkspacePrincipalPreview(
              id: 'u-bob',
              type: WorkspacePrincipalType.user,
              name: 'Bob',
            ),
          },
        ).lookup,
        directory: _RecordingDirectory().directory,
        onSave: (grants, _) async => WorkspaceAccessSaveOutcome.partial(
          keptGrants: [_user('u-bob')],
          message: 'generic',
        ),
      );
      await tester.tap(find.byKey(const Key('workspace-access-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'ali');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('workspace-principal-user-u-alice')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('workspace-principal-add')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workspace-access-principal-user-u-alice')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('workspace-access-save')));
      await tester.pumpAndSettle();

      expect(opened.closed, isFalse);
      expect(
        find.text(l10n.libraryAccessPartialSave('Alice Example')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('workspace-access-principal-user-u-alice')),
        findsNothing,
      );
      // What is on screen is the server's answer, so nothing is unsaved.
      expect(
        tester
            .widget<ConduitButton>(
              find.byKey(const Key('workspace-access-save')),
            )
            .onPressed,
        isNull,
      );
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
        find.byKey(const Key('workspace-principal-tabs')),
        findsNothing,
      );
      await tester.enterText(find.byType(EditableText), 'ali');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('workspace-principal-user-u-alice')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('workspace-principal-add')));
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
        find.byKey(const Key('workspace-principal-tabs')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const Key('workspace-principal-group-g-staff')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('workspace-principal-add')));
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

      expect(find.byKey(const Key('workspace-principal-tabs')), findsOneWidget);
      expect(recording.groupLoads, 0);
      await tester.tap(find.text(l10n.workspacePrincipalGroupsTab));
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
      final opened = await _openSheet(
        tester,
        grants: [
          _group('g-legacy', permission: WorkspaceGrantPermission.write),
          _user('u1'),
        ],
        allowUserGrants: true,
        allowGroupGrants: false,
      );

      expect(
        find.byKey(const Key('workspace-access-principal-group-g-legacy')),
        findsOneWidget,
      );
      await _chooseLevel(tester, 'user-u1', 'edit');
      await tester.tap(find.byKey(const Key('workspace-access-save')));
      await tester.pumpAndSettle();

      expect(
        _keys(opened.closedWith),
        unorderedEquals([
          'group:g-legacy:write',
          'user:u1:read',
          'user:u1:write',
        ]),
      );
    });
  });

  // Save waits for the owner's answer, which can take a while. What the user
  // sees and what the sheet returns must stay what was submitted until then.
  group('while a save is in flight', () {
    late Completer<WorkspaceAccessSaveOutcome> answer;
    late AppLocalizations l10n;
    List<WorkspaceAccessGrantInput>? submitted;
    ResourceAudience? submittedAudience;
    late _Opened opened;

    Future<void> frames(WidgetTester tester) async {
      // A saving button spins for as long as it waits, so settling would not
      // end.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> openSheet(
      WidgetTester tester, {
      WorkspaceAudienceChoice? audience,
    }) async {
      l10n = await _loadL10n(tester);
      answer = Completer<WorkspaceAccessSaveOutcome>();
      submitted = null;
      submittedAudience = null;
      opened = await _openSheet(
        tester,
        grants: [_user('u-bob')],
        audience: audience,
        onSave: (grants, picked) {
          submitted = grants;
          submittedAudience = picked;
          return answer.future;
        },
      );
    }

    Future<void> startSave(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('workspace-access-save')));
      await frames(tester);
      expect(submitted, isNotNull);
    }

    testWidgets('general access, levels, removing and adding are all locked, '
        'and closing waits', (tester) async {
      await openSheet(
        tester,
        audience: const WorkspaceAudienceChoice(
          initial: ResourceAudience.private,
          canChooseOpen: true,
        ),
      );
      await _chooseLevel(tester, 'user-u-bob', 'edit');
      await startSave(tester);

      await tester.tap(find.byKey(const Key('workspace-access-general')));
      await tester.tap(_level('user-u-bob'), warnIfMissed: false);
      await tester.tap(find.byKey(const Key('workspace-access-add')));
      await tester.tap(find.byType(SheetCloseButton));
      await frames(tester);

      expect(find.byType(PopupMenuItem<int>), findsNothing);
      expect(_generalShown(tester, l10n), l10n.libraryAccessOnlyPeopleAdded);
      expect(
        find.byKey(const Key('workspace-principal-tabs')),
        findsNothing,
        reason: 'no picker opened',
      );
      expect(opened.closed, isFalse);

      answer.complete(const WorkspaceAccessSaveOutcome.saved());
      await tester.pumpAndSettle();
      expect(
        _keys(submitted),
        unorderedEquals(['user:u-bob:read', 'user:u-bob:write']),
      );
      // No audience was picked, so none is sent.
      expect(submittedAudience, isNull);
      expect(_keys(opened.closedWith), _keys(submitted));
    });

    testWidgets('a failed save keeps the edits and shows why', (tester) async {
      await openSheet(tester);
      await _pickGeneral(tester, l10n.libraryAccessEveryoneOnServer);
      await startSave(tester);

      answer.complete(const WorkspaceAccessSaveOutcome.failed('Refused'));
      await tester.pumpAndSettle();
      expect(opened.closed, isFalse);
      expect(
        find.descendant(
          of: find.byKey(const Key('workspace-access-save-error')),
          matching: find.text('Refused'),
        ),
        findsOneWidget,
      );
      expect(_generalShown(tester, l10n), l10n.libraryAccessEveryoneOnServer);
    });

    testWidgets('a person chosen in a picker that was already open is not '
        'added, and the sheet closes with what was submitted', (tester) async {
      await openSheet(
        tester,
        audience: const WorkspaceAudienceChoice(
          initial: ResourceAudience.private,
          canChooseOpen: true,
        ),
      );
      await _pickGeneral(tester, l10n.libraryAccessEveryoneOnServer);
      await _chooseLevel(tester, 'user-u-bob', 'edit');
      await tester.tap(find.byKey(const Key('workspace-access-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'ali');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();

      // The picker covers Save, so a touch cannot reach it; the save is
      // started the way a keyboard or an assistive tool still can.
      tester
          .widget<ConduitButton>(find.byKey(const Key('workspace-access-save')))
          .onPressed!();
      await tester.pump();
      expect(submitted, isNotNull);
      await tester.tap(
        find.byKey(const Key('workspace-principal-user-u-alice')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('workspace-principal-add')));
      await frames(tester);

      expect(
        find.byKey(const Key('workspace-access-principal-user-u-alice')),
        findsNothing,
      );

      answer.complete(const WorkspaceAccessSaveOutcome.saved());
      await tester.pumpAndSettle();
      final expected = ['user:u-bob:read', 'user:u-bob:write', 'user:*:read'];
      expect(_keys(submitted), unorderedEquals(expected));
      expect(submittedAudience, ResourceAudience.public);
      expect(_keys(opened.closedWith), unorderedEquals(expected));
    });
  });

  group('WorkspacePrincipalPicker', () {
    testWidgets('several people and groups can be checked and added at once; '
        'who already has access is checked and cannot be picked', (
      tester,
    ) async {
      final l10n = await _loadL10n(tester);
      List<WorkspacePrincipalPreview>? picked;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await WorkspacePrincipalPicker.showMany(
                    context,
                    directory: WorkspacePrincipalDirectory(
                      searchUsers: (_) async => const [_alice, _bob],
                      loadGroups: () async => const [_staff],
                    ),
                    allowUsers: true,
                    allowGroups: true,
                    existing: const {'user:u-bob'},
                    existingLabel: l10n.libraryPickerHasAccess,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      ConduitButton add() => tester.widget<ConduitButton>(
        find.byKey(const Key('workspace-principal-add')),
      );
      expect(add().onPressed, isNull);

      await tester.enterText(find.byType(EditableText), 'a');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(find.text(l10n.libraryPickerHasAccess), findsOneWidget);
      final bobCheck = tester.widget<AdaptiveCheckbox>(
        find.byKey(const Key('workspace-principal-check-user-u-bob')),
      );
      expect(bobCheck.value, isTrue);
      expect(bobCheck.onChanged, isNull);
      await tester.tap(find.byKey(const Key('workspace-principal-user-u-bob')));
      await tester.tap(
        find.byKey(const Key('workspace-principal-user-u-alice')),
      );
      await tester.pump();

      // Groups are searched with the same field.
      await tester.tap(find.text(l10n.workspacePrincipalGroupsTab));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'sta');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('workspace-principal-group-g-staff')),
      );
      await tester.pump();
      expect(find.text(l10n.libraryPickerAddCount(2)), findsOneWidget);

      await tester.tap(find.byKey(const Key('workspace-principal-add')));
      await tester.pumpAndSettle();
      expect(picked!.map((p) => p.id), ['u-alice', 'g-staff']);
    });

    testWidgets('a failed load offers Retry', (tester) async {
      var attempts = 0;
      await _pumpPrincipalPicker(
        tester,
        allowUsers: false,
        directory: WorkspacePrincipalDirectory(
          searchUsers: (_) async => const [],
          loadGroups: () async {
            attempts++;
            if (attempts == 1) throw Exception('offline');
            return const [_staff];
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workspace-principal-error')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('workspace-principal-retry')));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('Staff'), findsOneWidget);
    });

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
      final l10n = await _loadL10n(tester);
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
      await tester.tap(find.text(l10n.workspacePrincipalGroupsTab));
      await tester.pump();
      groups.complete(const [
        WorkspacePrincipalPreview(
          id: 'group',
          type: WorkspacePrincipalType.group,
          name: 'Current person group',
        ),
      ]);
      await tester.pump();
      users.complete(const [
        WorkspacePrincipalPreview(
          id: 'user',
          type: WorkspacePrincipalType.user,
          name: 'Stale person',
        ),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('Current person group'), findsOneWidget);
      expect(find.text('Stale person'), findsNothing);
    });
  });

  group('SheetCloseButton', () {
    testWidgets('a tap just outside its 36pt look still closes', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: SheetCloseButton(onPressed: () => taps++)),
          ),
        ),
      );
      final box = tester.getRect(find.byType(SheetCloseButton));
      expect(box.width, greaterThanOrEqualTo(44));
      expect(box.height, greaterThanOrEqualTo(44));
      // A corner of the 44pt square, outside the 36pt button.
      await tester.tapAt(box.topLeft + const Offset(1, 1));
      await tester.tapAt(box.center);
      expect(taps, 2);
    });
  });
}

const _alice = WorkspacePrincipalPreview(
  id: 'u-alice',
  type: WorkspacePrincipalType.user,
  name: 'Alice Example',
);
const _bob = WorkspacePrincipalPreview(
  id: 'u-bob',
  type: WorkspacePrincipalType.user,
  name: 'Bob Example',
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

import 'dart:async';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/openwebui_direct_connection_store.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'direct_connections_ui_test_support.dart';

void main() {
  testWidgets('a new server draft is revoked when the account changes', (
    tester,
  ) async {
    final accountA = OpenWebUiDirectConnectionsCodec(
      serverId: 'server',
      accountId: 'account-a',
    ).decode({'ui': <String, Object?>{}});
    final accountB = OpenWebUiDirectConnectionsCodec(
      serverId: 'server',
      accountId: 'account-b',
    ).decode({'ui': <String, Object?>{}});
    final controller = DirectTestMutableOpenWebUiConnections(accountA);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(() => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.create(
              source: DirectConnectionEditorSource.openWebUi,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('direct-base-url-field')),
      'https://account-a.example/v1',
    );

    controller.setSnapshot(accountB);
    await tester.pumpAndSettle();

    expect(
      find.text('Open WebUI connections are unavailable.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('direct-base-url-field')),
      findsNothing,
    );
  });

  testWidgets(
    'server probe stops when the account changes during confirmation',
    (tester) async {
      final accountA =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account-a',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': ['https://old.example/v1'],
                'OPENAI_API_KEYS': ['old-secret'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'bearer'},
                },
              },
            },
          });
      final accountB = OpenWebUiDirectConnectionsCodec(
        serverId: 'server',
        accountId: 'account-b',
      ).decode({'ui': <String, Object?>{}});
      final remoteController = DirectTestMutableOpenWebUiConnections(accountA);
      final localController = DirectTestStaticDirectProfiles(const []);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            directConnectionProfilesProvider.overrideWith(
              () => localController,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              mode: DirectConnectionEditorMode.edit(
                profileId: accountA.records.single.profile.id,
                source: DirectConnectionEditorSource.openWebUi,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-base-url-field')),
        'https://new.example/v1',
      );
      await tester.scrollUntilVisible(
        find.byKey(
          const ValueKey<String>('direct-api-key-field'),
          skipOffstage: false,
        ),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-api-key-field')),
        'new-secret',
      );
      await tester.scrollUntilVisible(
        find.text('Test connection'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Test connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Use credentials with new server?'), findsOneWidget);
      remoteController.setSnapshot(accountB);
      await tester.pump();
      await tester.tap(find.text('Use credentials'));
      await tester.pumpAndSettle();

      expect(localController.probeCalls, 0);
    },
  );

  testWidgets(
    'server save reports unavailable when auth changes during confirmation',
    (tester) async {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': ['https://old.example/v1'],
                'OPENAI_API_KEYS': ['old-secret'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'bearer'},
                },
              },
            },
          });
      final remoteController = DirectTestMutableOpenWebUiConnections(snapshot);
      final epochSource = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
        DirectTestMutableAuthEpoch.new,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochSource),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              mode: DirectConnectionEditorMode.edit(
                profileId: snapshot.records.single.profile.id,
                source: DirectConnectionEditorSource.openWebUi,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-base-url-field')),
        'https://new.example/v1',
      );
      await tester.scrollUntilVisible(
        find.byKey(
          const ValueKey<String>('direct-api-key-field'),
          skipOffstage: false,
        ),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-api-key-field')),
        'new-secret',
      );
      final save = tester.widget<ConduitButton>(
        find.byWidgetPredicate(
          (widget) => widget is ConduitButton && widget.text == 'Save',
          skipOffstage: false,
        ),
      );
      save.onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Use credentials with new server?'), findsOneWidget);
      container.read(epochSource.notifier).rotate();
      await tester.tap(find.text('Use credentials'));
      await tester.pumpAndSettle();

      expect(remoteController.updateCalls, 0);
      expect(
        find.text('Open WebUI connections are unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Could not save this connection.'), findsNothing);
    },
  );

  testWidgets(
    'server editor preserves its draft and submits a refreshed reindexed record',
    (tester) async {
      final codec = OpenWebUiDirectConnectionsCodec(
        serverId: 'server',
        accountId: 'account',
      );
      final initial = codec.decode({
        'ui': {
          'directConnections': {
            'OPENAI_API_BASE_URLS': [
              'https://earlier.example/v1',
              'https://target.example/v1',
            ],
            'OPENAI_API_KEYS': ['earlier-secret', 'target-secret'],
            'OPENAI_API_CONFIGS': {
              '0': {'auth_type': 'bearer'},
              '1': {'auth_type': 'bearer'},
            },
          },
        },
      });
      final reindexed = codec.decode({
        'ui': {
          'directConnections': {
            'OPENAI_API_BASE_URLS': ['https://target.example/v1'],
            'OPENAI_API_KEYS': ['target-secret'],
            'OPENAI_API_CONFIGS': {
              '0': {'auth_type': 'bearer'},
            },
          },
        },
      });
      final initialRecord = initial.records[1];
      final refreshedRecord = reindexed.records.single;
      expect(refreshedRecord.profile.id, initialRecord.profile.id);
      expect(refreshedRecord.index, 0);
      expect(refreshedRecord.revision, isNot(initialRecord.revision));

      final updateStarted = Completer<void>();
      final releaseUpdate = Completer<void>();
      addTearDown(() {
        if (!releaseUpdate.isCompleted) releaseUpdate.complete();
      });
      final remoteController = DirectTestMutableOpenWebUiConnections(initial)
        ..updateHandler = () async {
          if (!updateStarted.isCompleted) updateStarted.complete();
          await releaseUpdate.future;
        };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              mode: DirectConnectionEditorMode.edit(
                profileId: initialRecord.profile.id,
                source: DirectConnectionEditorSource.openWebUi,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await directTestExpandAdvancedSettings(tester);
      final apiVersionField = find.byKey(
        const ValueKey<String>('direct-api-version-field'),
      );
      await tester.scrollUntilVisible(
        apiVersionField,
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(apiVersionField, '2026-07-15');

      remoteController.setSnapshot(reindexed);
      await tester.pumpAndSettle();

      expect(
        tester.widget<AccessibleFormField>(apiVersionField).controller!.text,
        '2026-07-15',
      );
      await tester.scrollUntilVisible(
        find.text('Save'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      final save = tester.widget<ConduitButton>(
        find.byWidgetPredicate(
          (widget) => widget is ConduitButton && widget.text == 'Save',
          skipOffstage: false,
        ),
      );
      save.onPressed!();
      await tester.pump();
      await updateStarted.future.timeout(const Duration(seconds: 1));

      expect(remoteController.updateCalls, 1);
      expect(remoteController.lastUpdatedRecord?.index, refreshedRecord.index);
      expect(
        remoteController.lastUpdatedRecord?.revision,
        refreshedRecord.revision,
      );
      expect(
        remoteController.lastUpdatedRecord?.profile.id,
        refreshedRecord.profile.id,
      );
      expect(remoteController.lastUpdatedProfile?.apiVersion, '2026-07-15');

      releaseUpdate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'server editor retains its stale CAS base for a same-id content edit',
    (tester) async {
      final codec = OpenWebUiDirectConnectionsCodec(
        serverId: 'server',
        accountId: 'account',
      );
      final initial = codec.decode({
        'ui': {
          'directConnections': {
            'OPENAI_API_BASE_URLS': ['https://target.example/v1'],
            'OPENAI_API_KEYS': ['target-secret'],
            'OPENAI_API_CONFIGS': {
              '0': {
                'auth_type': 'bearer',
                'enable': true,
                'tags': [
                  {'name': 'initial'},
                ],
              },
            },
          },
        },
      });
      final editedElsewhere = codec.decode({
        'ui': {
          'directConnections': {
            'OPENAI_API_BASE_URLS': ['https://target.example/v1'],
            'OPENAI_API_KEYS': ['target-secret'],
            'OPENAI_API_CONFIGS': {
              '0': {
                'auth_type': 'bearer',
                'enable': true,
                'tags': [
                  {'name': 'remote-edit'},
                ],
              },
            },
          },
        },
      });
      final initialRecord = initial.records.single;
      final remoteRecord = editedElsewhere.records.single;
      expect(remoteRecord.profile.id, initialRecord.profile.id);
      expect(
        remoteRecord.contentRevision,
        isNot(initialRecord.contentRevision),
      );

      final remoteController = DirectTestMutableOpenWebUiConnections(initial);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              mode: DirectConnectionEditorMode.edit(
                profileId: initialRecord.profile.id,
                source: DirectConnectionEditorSource.openWebUi,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await directTestExpandAdvancedSettings(tester);
      final apiVersionField = find.byKey(
        const ValueKey<String>('direct-api-version-field'),
      );
      await tester.scrollUntilVisible(
        apiVersionField,
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(apiVersionField, 'draft-version');

      remoteController.setSnapshot(editedElsewhere);
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Save'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      final save = tester.widget<ConduitButton>(
        find.byWidgetPredicate(
          (widget) => widget is ConduitButton && widget.text == 'Save',
          skipOffstage: false,
        ),
      );
      save.onPressed!();
      await tester.pumpAndSettle();

      expect(remoteController.updateCalls, 1);
      expect(
        remoteController.lastUpdatedRecord?.revision,
        initialRecord.revision,
      );
      expect(
        remoteController.lastUpdatedRecord?.contentRevision,
        initialRecord.contentRevision,
      );
    },
  );

  testWidgets(
    'server conflict completing after auth rotation reports unavailable',
    (tester) async {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': ['https://provider.example/v1'],
                'OPENAI_API_KEYS': ['provider-secret'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'bearer'},
                },
              },
            },
          });
      final updateStarted = Completer<void>();
      final releaseUpdate = Completer<void>();
      addTearDown(() {
        if (!releaseUpdate.isCompleted) releaseUpdate.complete();
      });
      final remoteController = DirectTestMutableOpenWebUiConnections(snapshot)
        ..updateHandler = () async {
          if (!updateStarted.isCompleted) updateStarted.complete();
          await releaseUpdate.future;
          throw OpenWebUiDirectConnectionConflictException(snapshot);
        };
      final epochSource = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
        DirectTestMutableAuthEpoch.new,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochSource),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DirectConnectionEditorPage(
              mode: DirectConnectionEditorMode.edit(
                profileId: snapshot.records.single.profile.id,
                source: DirectConnectionEditorSource.openWebUi,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await directTestExpandAdvancedSettings(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DirectConnectionEditorPage)),
      );
      final apiVersionField = find.byKey(
        const ValueKey<String>('direct-api-version-field'),
      );
      await tester.scrollUntilVisible(
        apiVersionField,
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(apiVersionField, '2026-07-15');
      await tester.scrollUntilVisible(
        find.text('Save'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      final save = tester.widget<ConduitButton>(
        find.byWidgetPredicate(
          (widget) => widget is ConduitButton && widget.text == 'Save',
          skipOffstage: false,
        ),
      );
      save.onPressed!();
      await tester.pump();
      await updateStarted.future.timeout(const Duration(seconds: 1));

      container.read(epochSource.notifier).rotate();
      releaseUpdate.complete();
      await tester.pumpAndSettle();

      expect(remoteController.updateCalls, 1);
      expect(
        find.text('Open WebUI connections are unavailable.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'This connection changed elsewhere. Reopen it before saving.',
        ),
        findsNothing,
      );
      expect(find.text('Could not save this connection.'), findsNothing);
    },
  );

  testWidgets('server delete stops when auth changes during profile lookup', (
    tester,
  ) async {
    final snapshot =
        OpenWebUiDirectConnectionsCodec(
          serverId: 'server',
          accountId: 'account',
        ).decode({
          'ui': {
            'directConnections': {
              'OPENAI_API_BASE_URLS': ['https://delete.example/v1'],
              'OPENAI_API_KEYS': ['delete-secret'],
              'OPENAI_API_CONFIGS': {
                '0': {'auth_type': 'bearer'},
              },
            },
          },
        });
    final backup = DirectConnectionProfile(
      id: 'backup',
      name: 'Backup',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://backup.example/v1',
    );
    final profilesReadStarted = Completer<void>();
    final releaseProfiles = Completer<void>();
    addTearDown(() {
      if (!releaseProfiles.isCompleted) releaseProfiles.complete();
    });
    final remoteController = DirectTestMutableOpenWebUiConnections(snapshot);
    final epochSource = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
      DirectTestMutableAuthEpoch.new,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          openWebUiDirectConnectionsProvider.overrideWith(
            () => remoteController,
          ),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(epochSource),
          ),
          effectiveDirectConnectionProfilesFutureProvider.overrideWith((
            ref,
          ) async {
            if (!profilesReadStarted.isCompleted) {
              profilesReadStarted.complete();
            }
            await releaseProfiles.future;
            return [snapshot.records.single.profile, backup];
          }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DirectConnectionEditorPage(
            mode: DirectConnectionEditorMode.edit(
              profileId: snapshot.records.single.profile.id,
              source: DirectConnectionEditorSource.openWebUi,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectConnectionEditorPage)),
    );
    await tester.scrollUntilVisible(
      find.text('Delete connection'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await profilesReadStarted.future.timeout(const Duration(seconds: 1));

    container.read(epochSource.notifier).rotate();
    releaseProfiles.complete();
    await tester.pumpAndSettle();

    expect(remoteController.deleteCalls, 0);
  });
}

import 'dart:async';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/services/openwebui_direct_connection_store.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'direct_connections_ui_test_support.dart';

void main() {
  testWidgets(
    'server delete restores preference and reports changed ownership',
    (tester) async {
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
      final remoteController = DirectTestMutableOpenWebUiConnections(snapshot);
      final epochSource = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
        DirectTestMutableAuthEpoch.new,
      );
      final backendController = DirectTestBlockingPreferredBackendController();
      addTearDown(backendController.release);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochSource),
            ),
            effectiveDirectConnectionProfilesFutureProvider.overrideWith(
              (ref) async => [snapshot.records.single.profile],
            ),
            preferredBackendProvider.overrideWith(() => backendController),
          ],
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
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
        find.text('Delete'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await backendController.unsetStarted.future.timeout(
        const Duration(seconds: 1),
      );

      container.read(epochSource.notifier).rotate();
      backendController.release();
      await tester.pumpAndSettle();

      expect(remoteController.deleteCalls, 0);
      expect(backendController.writes, [
        PreferredBackend.unset,
        PreferredBackend.direct,
      ]);
      expect(container.read(preferredBackendProvider), PreferredBackend.direct);
      expect(
        find.text('Open WebUI connections are unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Could not delete this connection.'), findsNothing);
    },
  );

  testWidgets(
    'committed server delete does not restore preference after ownership change',
    (tester) async {
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
      final deleteStarted = Completer<void>();
      final releaseDelete = Completer<void>();
      addTearDown(() {
        if (!releaseDelete.isCompleted) releaseDelete.complete();
      });
      final remoteController = DirectTestMutableOpenWebUiConnections(snapshot)
        ..deleteHandler = () async {
          if (!deleteStarted.isCompleted) deleteStarted.complete();
          await releaseDelete.future;
        };
      final epochSource = NotifierProvider<DirectTestMutableAuthEpoch, Object>(
        DirectTestMutableAuthEpoch.new,
      );
      final backendController = DirectTestTrackingPreferredBackendController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(epochSource),
            ),
            effectiveDirectConnectionProfilesFutureProvider.overrideWith(
              (ref) async => [snapshot.records.single.profile],
            ),
            preferredBackendProvider.overrideWith(() => backendController),
          ],
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
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
        find.text('Delete'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await deleteStarted.future.timeout(const Duration(seconds: 1));

      expect(container.read(preferredBackendProvider), PreferredBackend.unset);
      container.read(epochSource.notifier).rotate();
      releaseDelete.complete();
      await tester.pumpAndSettle();

      expect(remoteController.deleteCalls, 1);
      expect(backendController.writes, [PreferredBackend.unset]);
      expect(container.read(preferredBackendProvider), PreferredBackend.unset);
      expect(
        find.text('Open WebUI connections are unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Could not delete this connection.'), findsNothing);
    },
  );

  testWidgets(
    'commit-uncertain server delete leaves the direct preference cleared',
    (tester) async {
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
      final remoteController = DirectTestMutableOpenWebUiConnections(snapshot)
        ..deleteHandler = () async {
          throw const OpenWebUiDirectConnectionCommitUncertainException();
        };
      final backendController = DirectTestTrackingPreferredBackendController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => remoteController,
            ),
            effectiveDirectConnectionProfilesFutureProvider.overrideWith(
              (ref) async => [snapshot.records.single.profile],
            ),
            preferredBackendProvider.overrideWith(() => backendController),
          ],
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
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
        find.text('Delete'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(remoteController.deleteCalls, 1);
      expect(backendController.writes, [PreferredBackend.unset]);
      expect(container.read(preferredBackendProvider), PreferredBackend.unset);
      expect(find.text('Could not delete this connection.'), findsOneWidget);
    },
  );

  testWidgets(
    'unsupported OpenRouter server auth blocks execution but permits deletion',
    (tester) async {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': [kOpenRouterApiBaseUrl],
                'OPENAI_API_KEYS': ['must-not-be-forwarded'],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'session'},
                },
              },
            },
          });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => DirectTestStaticOpenWebUiConnections(snapshot),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
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
      await tester.scrollUntilVisible(
        find.text('Delete'),
        500,
        scrollable: find.byType(Scrollable).first,
      );

      final buttons = tester.widgetList<ConduitButton>(
        find.byType(ConduitButton, skipOffstage: false),
      );
      expect(
        buttons.singleWhere((button) => button.text == 'Save').onPressed,
        isNull,
      );
      expect(
        buttons
            .singleWhere((button) => button.text == 'Test connection')
            .onPressed,
        isNull,
      );
      expect(
        buttons
            .singleWhere((button) => button.text == 'Delete')
            .onPressed,
        isNotNull,
      );
      expect(find.textContaining('cannot safely use'), findsOneWidget);
    },
  );

  testWidgets(
    'OpenRouter server none auth opens and switching to bearer requires a key',
    (tester) async {
      final snapshot =
          OpenWebUiDirectConnectionsCodec(
            serverId: 'server',
            accountId: 'account',
          ).decode({
            'ui': {
              'directConnections': {
                'OPENAI_API_BASE_URLS': [kOpenRouterApiBaseUrl],
                'OPENAI_API_KEYS': [''],
                'OPENAI_API_CONFIGS': {
                  '0': {'auth_type': 'none'},
                },
              },
            },
          });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiDirectConnectionsProvider.overrideWith(
              () => DirectTestStaticOpenWebUiConnections(snapshot),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
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
      await tester.scrollUntilVisible(
        find.text('No authentication'),
        500,
        scrollable: find.byType(Scrollable).first,
      );

      final authenticationSelector = tester
          .widget<DropdownButtonFormField<DirectAuthenticationMode>>(
            find.byKey(const Key('direct-authentication-selector-openrouter')),
          );
      authenticationSelector.onChanged?.call(DirectAuthenticationMode.bearer);
      await tester.pump();

      final save = tester.widget<ConduitButton>(
        find.byWidgetPredicate(
          (widget) => widget is ConduitButton && widget.text == 'Save',
          skipOffstage: false,
        ),
      );
      save.onPressed!();
      await tester.pump();

      final keyField = tester.widget<AccessibleFormField>(
        find.byKey(
          const ValueKey<String>('direct-api-key-field'),
          skipOffstage: false,
        ),
      );
      expect(
        keyField.errorText,
        'Enter an API key or choose no authentication.',
      );
    },
  );
}

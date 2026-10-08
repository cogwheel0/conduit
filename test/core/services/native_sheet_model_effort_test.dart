import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart' show InMemoryKeyValueStore;
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_providers.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/reasoning_effort_provider.dart'
    show serverModelReasoningEffortProvider;
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _NoPersonalization extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async => const ServerUserSettings();
}

class _WorkspaceApi extends ApiService {
  _WorkspaceApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'effort-test',
          name: 'Effort test',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  final details = Completer<Map<String, dynamic>?>();

  @override
  Future<Map<String, dynamic>?> getModelDetails(String modelId) =>
      details.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final presentChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.conduit.NativeSheetHostApi.presentModelSelector',
    NativeSheetHostApi.pigeonChannelCodec,
  );
  final effortChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.conduit.NativeSheetHostApi.updateModelSelectorReasoningEffort',
    NativeSheetHostApi.pigeonChannelCodec,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    NativeSheetBridge.instance.debugIsIOSOverride = true;
  });
  tearDown(() {
    messenger.setMockDecodedMessageHandler<Object?>(presentChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(effortChannel, null);
    NativeSheetBridge.instance.debugIsIOSOverride = null;
    PreferencesStore.debugReset();
  });

  testWidgets('native effort pick survives closing and reopening after the '
      'workspace capability probe', (tester) async {
    // Only the private detail response reveals reasoning support. The catalog
    // deliberately omits params, as Open WebUI does for workspace models.
    final model = Model.fromJson({
      'id': 'workspace-model',
      'name': 'Workspace model',
      'info': {
        'id': 'workspace-model',
        'user_id': 'owner',
        'base_model_id': 'custom-model',
        'meta': {
          'capabilities': {'reasoning_effort': true},
        },
      },
    });
    final api = _WorkspaceApi();
    addTearDown(api.dispose);
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        authTokenProvider3.overrideWithValue(null),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        personalizationSettingsProvider.overrideWith(_NoPersonalization.new),
        appLocaleProvider.overrideWithValue(null),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        openWebUiAccountAvailableProvider.overrideWithValue(false),
        appDatabaseProvider.overrideWith((ref) => throw StateError('unused')),
        openWebUiChatSettingsAccessProvider.overrideWith(
          (ref) async => OpenWebUiChatSettingsAccess.denied,
        ),
      ],
    );
    addTearDown(container.dispose);

    late BuildContext context;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final requests = <PlatformNativeSheetModelSelectorRequest>[];
    var dismissed = Completer<Object?>();
    addTearDown(() {
      if (!dismissed.isCompleted) dismissed.complete(<Object?>[null]);
    });
    messenger.setMockDecodedMessageHandler<Object?>(presentChannel, (
      message,
    ) async {
      requests.add(
        (message! as List<Object?>).single!
            as PlatformNativeSheetModelSelectorRequest,
      );
      return dismissed.future;
    });
    final hydratedValues = <String>[];
    messenger.setMockDecodedMessageHandler<Object?>(effortChannel, (
      message,
    ) async {
      hydratedValues.add((message! as List<Object?>)[1]! as String);
      return <Object?>[null];
    });

    // Complete the private capability probe before opening the sheet. Its
    // previous observer stops listening once the native presentation begins.
    final probe = container.listen(
      serverModelReasoningEffortProvider(model),
      (_, _) {},
    );
    api.details.complete({
      'params': {'reasoning_effort': 'automatic'},
      'write_access': true,
    });
    await container.read(serverModelReasoningEffortProvider(model).future);
    final service = container.read(nativeSheetHydrationServiceProvider);
    Future<String?> open() => service.presentModelSelector(
      context,
      title: 'Models',
      models: [model],
      selectedModelId: model.id,
    );
    final first = open();
    probe.close();
    await tester.pump();
    await tester.pump();
    check(requests).length.equals(1);
    check(requests.single.reasoningEffortValue).equals('automatic');
    check(requests.single.reasoningEffortOptions).contains('high');

    // A native sheet has no Flutter widget watching the effort provider.
    // Let automatic disposal run before the user chooses High.
    await tester.pump(const Duration(seconds: 1));
    NativeSheetBridge.instance.onReasoningEffortChanged(
      PlatformNativeSheetReasoningEffortChangedEvent(value: 'high'),
    );
    await tester.pump();
    await tester.pump();
    dismissed.complete(<Object?>[null]);
    await tester.pump();
    await first;
    await tester.pump();

    dismissed = Completer<Object?>();
    hydratedValues.clear();
    final reopened = open();
    await container.read(serverModelReasoningEffortProvider(model).future);
    // The bridge's update queue awaits a future created outside the fake clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();
    check(requests).length.equals(2);
    final displayedValue = hydratedValues.isEmpty
        ? requests.last.reasoningEffortValue
        : hydratedValues.last;
    check(displayedValue).equals('high');
    check(
      jsonDecode(
        PreferencesStore.getString(PreferenceKeys.reasoningEffortByModel)!,
      ),
    ).isA<Map>().deepEquals({'openwebui:effort-test:workspace-model': 'high'});
    dismissed.complete(<Object?>[null]);
    await tester.pump();
    await reopened;
  });
}

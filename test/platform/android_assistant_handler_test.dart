import 'dart:async';

import 'package:conduit/features/chat/voice_call/presentation/voice_call_launcher.dart';
import 'package:conduit/features/navigation/providers/sidebar_providers.dart';
import 'package:conduit/features/navigation/widgets/drawer_shell_page.dart';
import 'package:conduit/platform/android_assistant_handler.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/widgets/sidebar_layout_contract.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _codec = StandardMethodCodec();
const _model = Model(id: 'model-a', name: 'Model A');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });

  tearDown(() {
    AndroidAssistantHandler.platform.setMethodCallHandler(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidAssistantHandler.platform, null);
    PreferencesStore.debugReset();
  });

  testWidgets('a new chat from the assistant closes Settings over chat', (
    tester,
  ) async {
    final resets = <int>[];
    final container = await _pumpApp(tester, resets: resets);
    container.read(androidAssistantProvider);
    unawaited(NavigationService.pushTo(Routes.profile));
    await tester.pumpAndSettle();
    // The router reports the page under a pushed one, so Settings over chat
    // reads as chat.
    expect(NavigationService.currentRoute, Routes.chat);
    expect(find.text('Settings'), findsOneWidget);

    await _invokeAssistant(tester, const MethodCall('startNewChat'));

    expect(find.text('Settings'), findsNothing);
    expect(find.text('Chat'), findsOneWidget);
    expect(resets, hasLength(1));
    expect(container.read(sidebarOverlayDismissRequestProvider), 1);
    expect(container.read(inputFocusTriggerProvider), 0);
  });

  testWidgets('the overlay text box opens the new chat ready to type', (
    tester,
  ) async {
    final container = await _pumpApp(tester);
    container.read(androidAssistantProvider);

    await _invokeAssistant(
      tester,
      const MethodCall('startNewChat', {'focusComposer': true}),
    );

    expect(container.read(inputFocusTriggerProvider), 1);
  });

  testWidgets('a voice call asked for before Dart listened still starts', (
    tester,
  ) async {
    final launches = <bool>[];
    final container = await _pumpApp(
      tester,
      pendingAction: const {'method': 'startVoiceCall', 'arguments': null},
      launcher: (ref) => _RecordingVoiceCallLauncher(ref, launches),
    );
    unawaited(NavigationService.pushTo(Routes.profile));
    await tester.pumpAndSettle();

    container.read(androidAssistantProvider);
    await tester.pumpAndSettle();

    expect(launches, [isTrue]);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('the sidebar closes when asked to, from outside the drawer', (
    tester,
  ) async {
    final drawer = _RecordingDrawer();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: SidebarDrawerControllerScope(
            controller: drawer,
            child: const SidebarOverlayDismissListener(
              child: SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );

    container.read(sidebarOverlayDismissRequestProvider.notifier).request();
    await tester.pump();

    expect(drawer.closeCalls, 1);
  });
}

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  List<int>? resets,
  Map<String, Object?>? pendingAction,
  VoiceCallLauncher Function(Ref ref)? launcher,
}) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(AndroidAssistantHandler.platform, (call) async {
        if (call.method == 'takePendingAction') return pendingAction;
        return null;
      });
  final router = GoRouter(
    navigatorKey: NavigationService.navigatorKey,
    initialLocation: Routes.chat,
    routes: [
      GoRoute(
        path: Routes.chat,
        builder: (_, _) => const Scaffold(body: Text('Chat')),
      ),
      GoRoute(
        path: Routes.profile,
        builder: (_, _) => const Scaffold(body: Text('Settings')),
      ),
    ],
  );
  NavigationService.attachRouter(router);
  addTearDown(router.dispose);
  final container = ProviderContainer(
    overrides: [
      chatEntryReadyProvider.overrideWithValue(true),
      selectedModelProvider.overrideWithValue(_model),
      // The real reset needs the app's storage, which this rig doesn't have.
      androidAssistantProvider.overrideWith(
        (ref) => AndroidAssistantHandler(
          ref,
          resetChat: (_) => resets?.add(resets.length),
        ),
      ),
      if (launcher != null) voiceCallLauncherProvider.overrideWith(launcher),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _invokeAssistant(WidgetTester tester, MethodCall call) async {
  await tester.runAsync(() async {
    final completer = Completer<ByteData?>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          AndroidAssistantHandler.platform.name,
          _codec.encodeMethodCall(call),
          completer.complete,
        );
    await completer.future;
  });
  await tester.pumpAndSettle();
}

final class _RecordingVoiceCallLauncher extends VoiceCallLauncher {
  _RecordingVoiceCallLauncher(super.ref, this.launches);

  final List<bool> launches;

  @override
  Future<void> launch({required bool startNewConversation}) async {
    launches.add(startNewConversation);
  }
}

final class _RecordingDrawer implements SidebarDrawerController {
  var closeCalls = 0;

  @override
  bool get isOpen => true;

  @override
  void open({double velocity = 0.0}) {}

  @override
  void close({double velocity = 0.0}) => closeCalls++;

  @override
  void toggle() {}
}

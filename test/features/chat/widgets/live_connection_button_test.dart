import 'dart:async';

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/chat/widgets/live_connection_button.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/models/socket_health.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Socket extends Fake implements SocketService {
  final health = StreamController<SocketHealth>.broadcast();
  bool connected = true;
  int attempts = 0;
  Completer<bool>? pending;

  @override
  SocketHealth get currentHealth => SocketHealth(
    latencyMs: -1,
    isConnected: connected,
    transport: 'websocket',
    reconnectCount: 2,
    lastHeartbeat: DateTime.now(),
  );
  @override
  Stream<SocketHealth> get healthStream => health.stream;
  void changeHealth(bool value) {
    connected = value;
    health.add(currentHealth);
  }

  @override
  Future<bool> ensureConnected({
    Duration timeout = const Duration(seconds: 2),
  }) {
    attempts++;
    return pending!.future;
  }
}

Widget _harness(_Socket socket, {double textScale = 1}) => ProviderScope(
  overrides: [
    openWebUiAccountAvailableProvider.overrideWithValue(true),
    socketServiceProvider.overrideWithValue(socket),
  ],
  child: MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Consumer(
        builder: (context, ref, _) =>
            ref.watch(liveConnectionDisconnectedProvider).value == true
            ? const LiveConnectionButton()
            : const SizedBox(),
      ),
    ),
  ),
);

final _detailsChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.presentResultSheet',
  NativeSheetHostApi.pigeonChannelCodec,
);

void main() {
  setUp(() => PlatformUiCapabilities.debugNativeIOS26Override = false);
  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
    NativeSheetBridge.instance.debugIsIOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(_detailsChannel, null);
  });
  test('no Open WebUI account produces no connection warning', () async {
    final container = ProviderContainer(
      overrides: [
        openWebUiAccountAvailableProvider.overrideWithValue(false),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(liveConnectionDisconnectedProvider, (_, _) {});
    addTearDown(sub.close);
    await container.pump();
    expect(container.read(liveConnectionDisconnectedProvider).value, isNull);
  });

  testWidgets(
    'health changes show recovery, suppress duplicate retries, and clear on reconnect',
    (tester) async {
      final socket = _Socket();
      addTearDown(socket.health.close);
      await tester.pumpWidget(_harness(socket));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('live-connection-retry')), findsNothing);
      socket.changeHealth(false);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('live-connection-retry')),
        findsOneWidget,
      );
      socket.pending = Completer<bool>();
      await tester.tap(find.byKey(const ValueKey('live-connection-retry')));
      await tester.pumpAndSettle();
      expect(socket.attempts, 0);
      expect(find.text('Live updates'), findsOneWidget);
      expect(find.textContaining('WebSocket transport'), findsOneWidget);
      expect(find.textContaining('Reconnects: 2'), findsOneWidget);
      expect(find.textContaining('Last heartbeat:'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(socket.attempts, 1);
      expect(find.byKey(const ValueKey('live-connection-retry')), findsNothing);
      socket.pending!.completeError(
        StateError('Synthetic transport diagnostic'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Synthetic transport'), findsNothing);
      expect(
        find.textContaining('Live updates are still disconnected.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      socket.pending = Completer<bool>();
      await tester.tap(find.byKey(const ValueKey('live-connection-retry')));
      await tester.pumpAndSettle();
      expect(socket.attempts, 1);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(socket.attempts, 2);
      socket.changeHealth(true);
      socket.pending!.complete(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('live-connection-retry')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(socket.health.hasListener, isFalse);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets('iOS uses native glass details and waits for an explicit retry', (
    tester,
  ) async {
    final socket = _Socket()..connected = false;
    addTearDown(socket.health.close);
    await tester.pumpWidget(_harness(socket));
    await tester.pumpAndSettle();
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    NativeSheetBridge.instance.debugIsIOSOverride = true;
    final response = Completer<PlatformNativeSheetActionResult?>();
    final requests = <PlatformNativeSheetResultRequest>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      _detailsChannel,
      (message) async {
        requests.add(
          (message! as List<Object?>).single!
              as PlatformNativeSheetResultRequest,
        );
        return [await response.future];
      },
    );
    final button = tester.widget<ConduitAdaptiveAppBarIconButton>(
      find.byKey(const ValueKey('live-connection-retry')),
    );
    button.onPressed!();
    button.onPressed!();
    await tester.pump();
    expect(requests, hasLength(1));
    expect(requests.single.root.title, 'Live updates');
    expect(
      requests.single.root.sections.first.footer,
      contains('Replies and chat changes may be delayed'),
    );
    expect(
      requests.single.root.sections.first.footer,
      contains('WebSocket transport'),
    );
    expect(
      requests.single.root.sections.first.footer,
      contains('Reconnects: 2'),
    );
    expect(requests.single.root.sections.last.items.single.actionId, 'retry');
    expect(socket.attempts, 0);
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    socket.pending = Completer<bool>();
    response.complete(
      PlatformNativeSheetActionResult(actionId: 'retry', values: {}),
    );
    await tester.pump();
    expect(socket.attempts, 1);
    socket.changeHealth(true);
    socket.pending!.complete(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-connection-retry')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing details does not reconnect', (tester) async {
    final socket = _Socket()..connected = false;
    addTearDown(socket.health.close);
    await tester.pumpWidget(_harness(socket));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('live-connection-retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(socket.attempts, 0);
    expect(find.text('Live updates'), findsNothing);
  });

  testWidgets('native presentation failure keeps details available', (
    tester,
  ) async {
    final socket = _Socket()..connected = false;
    addTearDown(socket.health.close);
    await tester.pumpWidget(_harness(socket));
    await tester.pumpAndSettle();
    final button = tester.widget<ConduitAdaptiveAppBarIconButton>(
      find.byKey(const ValueKey('live-connection-retry')),
    );
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    NativeSheetBridge.instance.debugIsIOSOverride = true;
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      _detailsChannel,
      (_) async => ['unavailable', 'Synthetic bridge diagnostic', null],
    );
    button.onPressed!();
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    await tester.pumpAndSettle();
    expect(find.text('Live updates'), findsOneWidget);
    expect(find.textContaining('Synthetic bridge'), findsNothing);
    expect(socket.attempts, 0);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'details and retry remain reachable with large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final socket = _Socket()..connected = false;
      addTearDown(socket.health.close);
      await tester.pumpWidget(_harness(socket, textScale: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-connection-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Retry').hitTestable(), findsOneWidget);
      expect(find.text('Close').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}

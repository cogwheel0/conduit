import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/chat/widgets/usage_stats_modal.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _nativeSheetChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.presentResultSheet',
  NativeSheetHostApi.pigeonChannelCodec,
);

void main() {
  /// Opens the usage of [usage] from a button. With [anchorKey], the button
  /// asks for a popover pointing at it, as the response footer does; with
  /// [anchorOnScreen] false the key is on no widget.
  Future<AppLocalizations> openSheet(
    WidgetTester tester,
    Map<String, dynamic> usage, {
    GlobalKey? anchorKey,
    bool anchorOnScreen = true,
  }) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => LegacyDesignCompatibility(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              l10n = AppLocalizations.of(context)!;
              return TextButton(
                key: anchorOnScreen ? anchorKey : null,
                onPressed: () =>
                    UsageStatsModal.show(context, usage, anchorKey: anchorKey),
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return l10n;
  }

  testWidgets('usage Open WebUI marks incomplete says the figures may be low', (
    tester,
  ) async {
    final l10n = await openSheet(tester, <String, dynamic>{
      'input_tokens': 1500,
      'output_tokens': 120,
      'incomplete': true,
    });

    expect(find.text(l10n.usageTokenCount(120)), findsOneWidget);
    expect(find.text(l10n.usageIncomplete), findsOneWidget);
  });

  testWidgets('complete usage carries no such note', (tester) async {
    final l10n = await openSheet(tester, <String, dynamic>{
      'input_tokens': 1500,
      'output_tokens': 120,
    });

    expect(find.text(l10n.usageTokenCount(120)), findsOneWidget);
    expect(find.text(l10n.usageIncomplete), findsNothing);
  });

  test('the native sheet text carries the note too', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('de'));
    final partial = UsageStatsModal.buildUsageSummaryText(<String, dynamic>{
      'output_tokens': 120,
      'incomplete': true,
    }, l10n);
    expect(partial, endsWith(l10n.usageIncomplete));
    expect(
      UsageStatsModal.buildUsageSummaryText(<String, dynamic>{
        'output_tokens': 120,
      }, l10n),
      isNot(contains(l10n.usageIncomplete)),
    );
  });

  group('on iOS', () {
    const channel = MethodChannel('cn_popover');
    final calls = <MethodCall>[];
    final sheets = <PlatformNativeSheetResultRequest>[];

    setUp(() {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
      PlatformUiCapabilities.debugNativeIOS26Override = true;
      NativeSheetBridge.instance.debugIsIOSOverride = true;
      calls.clear();
      sheets.clear();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // Both answer as the native side does once closed without a choice.
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockDecodedMessageHandler<Object?>(_nativeSheetChannel, (
        message,
      ) async {
        sheets.add(
          (message! as List<Object?>).single!
              as PlatformNativeSheetResultRequest,
        );
        return <Object?>[null];
      });
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockDecodedMessageHandler<Object?>(
        _nativeSheetChannel,
        null,
      );
      NativeSheetBridge.instance.debugIsIOSOverride = null;
      PlatformUiCapabilities.resetDebugOverrides();
    });

    testWidgets('from iOS 26 the figures open in a popover, not a sheet', (
      tester,
    ) async {
      final l10n = await openSheet(tester, <String, dynamic>{
        'eval_count': 120,
        'eval_duration': 4000000000,
        'input_tokens': 1500,
        'total_duration': 5000000000,
        'incomplete': true,
      }, anchorKey: GlobalKey());

      expect(calls, hasLength(1));
      expect(calls.single.method, 'show');
      final content = (calls.single.arguments as Map)['content'] as Map;
      expect(content['title'], l10n.usageInfoTitle);
      expect(content['message'], l10n.usageIncomplete);
      expect(
        [
          for (final row in content['rows'] as List)
            (row['title'], row['subtitle'], row['trailingText']),
        ],
        [
          (
            l10n.usageTokenGeneration,
            l10n.usageTokenCount(120),
            l10n.usageTokensPerSecond('30.0'),
          ),
          (l10n.usagePromptEval, null, l10n.usageTokenCount(1500)),
          (l10n.usageTotalDuration, null, l10n.usageSecondsFormat('5.00')),
        ],
      );
      expect(sheets, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    for (final fallback in [
      (
        name: 'before iOS 26',
        iOSVersion: 18,
        usage: <String, dynamic>{'output_tokens': 120},
        field: 'Output Tokens: 120',
        anchorOnScreen: true,
      ),
      (
        name: 'for usage with no figure the summary knows',
        iOSVersion: 26,
        usage: <String, dynamic>{'cache_hits': 3},
        field: 'Cache Hits: 3',
        anchorOnScreen: true,
      ),
      (
        name: 'when the anchor is not on screen',
        iOSVersion: 26,
        usage: <String, dynamic>{'output_tokens': 120},
        field: 'Output Tokens: 120',
        anchorOnScreen: false,
      ),
    ]) {
      testWidgets('the native sheet lists the raw fields ${fallback.name}', (
        tester,
      ) async {
        PlatformUiCapabilities.debugIOSMajorVersionOverride =
            fallback.iOSVersion;
        final l10n = await openSheet(
          tester,
          fallback.usage,
          anchorKey: GlobalKey(),
          anchorOnScreen: fallback.anchorOnScreen,
        );

        expect(calls, isEmpty);
        expect(sheets, hasLength(1));
        final root = sheets.single.root;
        expect(root.title, l10n.usageInfoTitle);
        expect(root.items.single.value, contains(fallback.field));
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  });
}

import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/chat/widgets/usage_stats_modal.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
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
    int? contextLength,
    Locale? locale,
    double textScale = 1,
  }) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        locale: locale,
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: LegacyDesignCompatibility(child: child!),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              l10n = AppLocalizations.of(context)!;
              return TextButton(
                key: anchorOnScreen ? anchorKey : null,
                onPressed: () => UsageStatsModal.show(
                  context,
                  usage,
                  anchorKey: anchorKey,
                  contextLength: contextLength,
                ),
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

  testWidgets('the context window shows when the model\'s length is known', (
    tester,
  ) async {
    const usage = <String, dynamic>{
      'prompt_tokens': 78000,
      'completion_tokens': 1360,
    };
    var l10n = await openSheet(tester, usage, contextLength: 128000);
    expect(find.text(l10n.usageContextWindow), findsOneWidget);
    expect(find.text('62% \u00b7 79K of 128K'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    l10n = await openSheet(tester, usage);
    expect(find.text(l10n.usageContextWindow), findsNothing);

    // A length of whole 1,024-token blocks is named as models name it.
    await tester.pumpWidget(const SizedBox.shrink());
    await openSheet(tester, const <String, dynamic>{
      'prompt_tokens': 19500,
      'completion_tokens': 820,
    }, contextLength: 32768);
    expect(find.text('62% \u00b7 20K of 32K'), findsOneWidget);
  });

  testWidgets('counts round as iOS rounds them, ties to even', (tester) async {
    for (final (tokens, length, figure) in [
      (9500, 128000, '7% \u00b7 9.5K of 128K'),
      // Under ten of a unit keeps one decimal, ties going to the even digit.
      (9850, 128000, '8% \u00b7 9.8K of 128K'),
      // Rounding up into the next ten or the next unit.
      (9950, 128000, '8% \u00b7 10K of 128K'),
      (999500, 2000000, '50% \u00b7 1M of 2M'),
      (999499, 2000000, '50% \u00b7 999K of 2M'),
    ]) {
      await openSheet(tester, <String, dynamic>{
        'prompt_tokens': tokens,
        'completion_tokens': 0,
      }, contextLength: length);
      expect(find.text(figure), findsOneWidget, reason: '$tokens tokens');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('a long context figure wraps on a narrow sheet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // German has no short form for thousands, so the figure is long.
    final l10n = await openSheet(
      tester,
      const <String, dynamic>{
        'prompt_tokens': 78000,
        'completion_tokens': 1360,
        'prompt_time': 0.25,
      },
      contextLength: 128000,
      locale: const Locale('de'),
      textScale: 1.3,
    );

    expect(tester.takeException(), isNull);
    final value = find.textContaining('79360');
    final label = find.text(l10n.usageContextWindow);
    expect(value, findsOneWidget);
    expect(
      tester.getRect(value).left,
      greaterThan(tester.getRect(label).right),
    );
    expect(tester.getRect(value).right, lessThanOrEqualTo(320));
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
      // The rows only show figures: a tap keeps the popover open, and
      // VoiceOver reads them as text rather than as buttons.
      expect(content['rows'], everyElement(containsPair('readOnly', true)));
      expect(sheets, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    List<Map<Object?, Object?>> popoverRows() => [
      for (final row
          in ((calls.last.arguments as Map)['content'] as Map)['rows'] as List)
        row as Map<Object?, Object?>,
    ];

    testWidgets('the context window leads, with a gauge of how full it was', (
      tester,
    ) async {
      final l10n = await openSheet(
        tester,
        <String, dynamic>{'prompt_tokens': 78000, 'completion_tokens': 1360},
        anchorKey: GlobalKey(),
        contextLength: 128000,
      );

      final rows = popoverRows();
      expect(
        (
          rows.first['title'],
          rows.first['trailingText'],
          rows.first['leadingSfSymbol'],
        ),
        (
          l10n.usageContextWindow,
          '62% \u00b7 79K of 128K',
          'gauge.with.dots.needle.67percent',
        ),
      );
      expect(
        rows.skip(1).map((row) => row['leadingSfSymbol']),
        everyElement(isNull),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('the gauge shows the needle nearest to the fill', (
      tester,
    ) async {
      final needles = <String?>[];
      for (final tokens in [10000, 50000, 70000, 95000, 150000]) {
        await openSheet(
          tester,
          <String, dynamic>{'prompt_tokens': tokens, 'completion_tokens': 0},
          anchorKey: GlobalKey(),
          contextLength: 128000,
        );
        needles.add(popoverRows().first['leadingSfSymbol'] as String?);
        await tester.pumpWidget(const SizedBox.shrink());
      }
      // 8%, 39%, 55%, 74% and, past the length, 117%.
      expect(needles, [
        'gauge.with.dots.needle.0percent',
        'gauge.with.dots.needle.33percent',
        'gauge.with.dots.needle.50percent',
        'gauge.with.dots.needle.67percent',
        'gauge.with.dots.needle.100percent',
      ]);
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

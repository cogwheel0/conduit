import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/adaptive_date_time_picker.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Pumps a button that runs [open] and keeps what it returned.
Future<List<Object?>> pumpOpener(
  WidgetTester tester, {
  required TargetPlatform platform,
  required Future<Object?> Function(BuildContext context) open,
  bool alwaysUse24HourFormat = false,
}) async {
  final results = <Object?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(alwaysUse24HourFormat: alwaysUse24HourFormat),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async => results.add(await open(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  group('showAdaptiveDatePicker', () {
    testWidgets('uses the Material calendar off iOS and returns the day', (
      tester,
    ) async {
      final results = await pumpOpener(
        tester,
        platform: TargetPlatform.android,
        open: (context) => showAdaptiveDatePicker(
          context,
          initial: DateTime.utc(2026, 10, 6, 17, 9),
          first: DateTime(2000),
          last: DateTime(2100),
          title: 'Starts',
        ),
      );

      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(find.text('Starts'), findsOneWidget);
      await tester.tap(find.text('8'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(results, [DateTime(2026, 10, 8)]);
    });

    testWidgets('uses a wheel on iOS, and a cancel returns nothing', (
      tester,
    ) async {
      final results = await pumpOpener(
        tester,
        platform: TargetPlatform.iOS,
        open: (context) => showAdaptiveDatePicker(
          context,
          initial: DateTime(2026, 10, 6),
          first: DateTime(2000),
          last: DateTime(2100),
          title: 'Starts',
        ),
      );

      final picker = tester.widget<CupertinoDatePicker>(
        find.byType(CupertinoDatePicker),
      );
      expect(picker.mode, CupertinoDatePickerMode.date);
      expect(find.text('Starts'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(results, [null]);
    });

    testWidgets('keeps the starting day within the allowed days', (
      tester,
    ) async {
      final results = await pumpOpener(
        tester,
        platform: TargetPlatform.iOS,
        open: (context) => showAdaptiveDatePicker(
          context,
          initial: DateTime(1990, 1, 1),
          first: DateTime(2020, 5, 2, 15),
          last: DateTime(2030),
        ),
      );

      await tester.tap(find.byKey(const Key('adaptive-picker-done')));
      await tester.pumpAndSettle();

      expect(results, [DateTime(2020, 5, 2)]);
    });
  });

  group('showAdaptiveTimePicker', () {
    testWidgets('uses the Material clock off iOS', (tester) async {
      final results = await pumpOpener(
        tester,
        platform: TargetPlatform.android,
        open: (context) => showAdaptiveTimePicker(
          context,
          initial: const TimeOfDay(hour: 17, minute: 9),
        ),
      );

      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(results, [const TimeOfDay(hour: 17, minute: 9)]);
    });

    for (final use24 in [true, false]) {
      testWidgets('uses a wheel on iOS that follows the 24-hour setting '
          '($use24)', (tester) async {
        final results = await pumpOpener(
          tester,
          platform: TargetPlatform.iOS,
          alwaysUse24HourFormat: use24,
          open: (context) => showAdaptiveTimePicker(
            context,
            initial: const TimeOfDay(hour: 17, minute: 9),
            title: 'Start time',
          ),
        );

        final picker = tester.widget<CupertinoDatePicker>(
          find.byType(CupertinoDatePicker),
        );
        expect(picker.mode, CupertinoDatePickerMode.time);
        expect(picker.use24hFormat, use24);
        expect(picker.initialDateTime.hour, 17);
        expect(picker.initialDateTime.minute, 9);
        await tester.tap(find.byKey(const Key('adaptive-picker-done')));
        await tester.pumpAndSettle();

        expect(results, [const TimeOfDay(hour: 17, minute: 9)]);
      });
    }
  });
}

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/sign_out_options_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sign-out defaults to clearing server details', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 667);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    bool? result;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showSignOutOptionsDialog(context);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final checkbox = tester.widget<CheckboxListTile>(
      find.byKey(const Key('sign-out-keep-server-details')),
    );
    expect(checkbox.value, isFalse);
    expect(find.text('Keep server details'), findsOneWidget);
    expect(
      find.textContaining("data on your server aren't affected"),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('sign-out-confirm')));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('sign-out can retain server details explicitly', (tester) async {
    bool? result;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showSignOutOptionsDialog(context);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sign-out-keep-server-details')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sign-out-confirm')));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });
}

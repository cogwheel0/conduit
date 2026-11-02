import 'package:conduit/features/channels/widgets/channel_form_dialog.dart';
import 'package:conduit/features/direct_connections/views/direct_mcp_server_editor_page.dart';
import 'package:conduit/shared/widgets/adaptive_dropdown_field.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';

import '../../../support/native_platform_views.dart';

void main() {
  setUp(() {
    stubNativePlatformViews();
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 27;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Widget host(Widget child) => ProviderScope(
    child: MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      builder: (context, child) => LegacyDesignCompatibility(child: child!),
      home: Scaffold(
        body: Material(
          type: MaterialType.transparency,
          child: Center(child: child),
        ),
      ),
    ),
  );

  for (final configuration in [
    (platform: TargetPlatform.android, native: false),
    (platform: TargetPlatform.iOS, native: false),
    (platform: TargetPlatform.iOS, native: true),
  ]) {
    testWidgets(
      'merged switch rows announce one label (native: ${configuration.native})',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = configuration.platform;
        PlatformUiCapabilities.debugIOSMajorVersionOverride =
            configuration.native ? 27 : 18;
        PlatformUiCapabilities.debugNativeIOS26Override = configuration.native;
        FlutterSecureStorage.setMockInitialValues({});
        final semantics = tester.ensureSemantics();
        try {
          late BuildContext context;
          await tester.pumpWidget(
            host(
              Builder(
                builder: (value) {
                  context = value;
                  return const SizedBox();
                },
              ),
            ),
          );
          final l10n = AppLocalizations.of(context)!;
          final form = showCreateChannelFormDialog(context);
          await tester.pumpAndSettle();
          final privacyRow = find.widgetWithText(ListTile, l10n.channelPrivate);
          final privacyLabel = tester
              .getSemantics(
                find
                    .ancestor(
                      of: privacyRow,
                      matching: find.byType(MergeSemantics),
                    )
                    .first,
              )
              .getSemanticsData()
              .label;
          if (configuration.native) {
            expect(
              tester.widget<CNSwitch>(find.byType(CNSwitch)).semanticLabel,
              l10n.channelPrivate,
            );
          }
          Navigator.of(context).pop();
          await tester.pumpAndSettle();
          await form;
          await tester.pumpWidget(const SizedBox());

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                directMcpServersProvider.overrideWithBuild(
                  (ref, notifier) async => const [],
                ),
              ],
              child: host(const DirectMcpServerEditorPage(serverId: 'new')),
            ),
          );
          await tester.pumpAndSettle();
          final enabledRow = find.byKey(const ValueKey('direct-mcp-enabled'));
          await tester.ensureVisible(enabledRow);
          await tester.pumpAndSettle();
          final enabledLabel = tester
              .getSemantics(
                find
                    .ancestor(
                      of: enabledRow,
                      matching: find.byType(MergeSemantics),
                    )
                    .first,
              )
              .getSemanticsData()
              .label;
          // UIKit supplies its own label; Flutter fallbacks supply the row label.
          final nativeView = find.descendant(
            of: find.byType(CNSwitch),
            matching: find.byType(UiKitView),
          );
          final flutterLabelCount = nativeView.evaluate().isEmpty ? 1 : 0;
          expect(
            {
              'privacy': l10n.channelPrivate.allMatches(privacyLabel).length,
              'enabled': l10n.enabledLabel.allMatches(enabledLabel).length,
            },
            {'privacy': flutterLabelCount, 'enabled': flutterLabelCount},
            reason: 'Merged row labels: $privacyLabel / $enabledLabel',
          );
          if (configuration.native) {
            expect(
              tester.widget<CNSwitch>(find.byType(CNSwitch)).semanticLabel,
              l10n.enabledLabel,
            );
          }
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant.only(configuration.platform),
    );
  }

  testWidgets('empty native choice fields render their hint once', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AdaptiveDropdownField<String?>(
          value: null,
          options: const [
            AdaptiveDropdownOption<String?>(value: 'boat', label: 'Paper boat'),
          ],
          onChanged: (_) {},
          decoration: const InputDecoration(hintText: 'Choose a shape'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CNPopupMenuButton>(find.byType(CNPopupMenuButton))
          .buttonLabel,
      'Choose a shape',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final enabled in [true, false]) {
    testWidgets(
      'choice values are announced once with a field name (enabled: $enabled)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            host(
              AdaptiveDropdownField<String>(
                value: 'kite',
                options: const [
                  AdaptiveDropdownOption(value: 'kite', label: 'Kite'),
                ],
                onChanged: enabled ? (_) {} : null,
                decoration: const InputDecoration(
                  labelText: 'Shape',
                  errorText: 'Choose another shape',
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final label = tester.semantics
              .simulatedAccessibilityTraversal()
              .map((node) => node.getSemanticsData().label)
              .join('\n');
          final nativeView = find.byType(UiKitView);
          expect(
            'Kite'.allMatches(label),
            hasLength(nativeView.evaluate().isEmpty ? 1 : 0),
          );
          expect(
            enabled
                ? tester
                      .widget<CNPopupMenuButton>(find.byType(CNPopupMenuButton))
                      .semanticLabel
                : tester.widget<CNButton>(find.byType(CNButton)).semanticLabel,
            'Shape, Kite',
          );
          // The form caption is separate from the control's complete name.
          // UIKit's name is outside Flutter's tree; its fallback is inside it.
          expect(
            'Shape'.allMatches(label),
            hasLength(nativeView.evaluate().isEmpty ? 2 : 1),
          );
          expect(find.bySemanticsLabel('Choose another shape'), findsOneWidget);
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets('native switch remains controlled and has an accessible action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var value = false;
      var changes = 0;
      late StateSetter update;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return AdaptiveSwitch(
                value: value,
                semanticLabel: 'Keep sketch',
                onChanged: (next) => setState(() {
                  value = next;
                  changes++;
                }),
              );
            },
          ),
        ),
      );
      expect(
        tester.widget<CNSwitch>(find.byType(CNSwitch)).semanticLabel,
        'Keep sketch',
      );
      final nativeView = find.descendant(
        of: find.byType(CNSwitch),
        matching: find.byType(UiKitView),
      );
      if (nativeView.evaluate().isEmpty) {
        expect(
          tester.getSemantics(find.byType(AdaptiveSwitch)),
          matchesSemantics(
            label: 'Keep sketch',
            hasToggledState: true,
            isToggled: false,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
          ),
        );
        tester.semantics.tap(find.semantics.byLabel('Keep sketch'));
      } else {
        // The stub has no UIKit accessibility tree. Check its creation data;
        // native VoiceOver is verified on iOS, without a duplicate Flutter node.
        expect(
          tester.widget<UiKitView>(nativeView).creationParams,
          containsPair('semanticLabel', 'Keep sketch'),
        );
        expect(find.bySemanticsLabel('Keep sketch'), findsNothing);
        tester.widget<CNSwitch>(find.byType(CNSwitch)).onChanged(true);
      }
      await tester.pump();
      expect(value, isTrue);
      expect(changes, 1);
      // Native SwiftUI reports both user changes and programmatic updates.
      tester.widget<CNSwitch>(find.byType(CNSwitch)).onChanged(true);
      expect(changes, 1);
      update(() => value = false);
      await tester.pump();
      final control = tester.widget<CNSwitch>(find.byType(CNSwitch));
      expect(control.value, isFalse);
      control.onChanged(false);
      expect(changes, 1);
      control.onChanged(true);
      expect(changes, 2);
      // Two native events can arrive before the next Flutter frame.
      control.onChanged(false);
      expect(changes, 3);
    } finally {
      semantics.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'disabled switches and explicit thumb colors retain their contracts',
    (tester) async {
      await tester.pumpWidget(
        host(
          const AdaptiveSwitch(
            value: true,
            onChanged: null,
            semanticLabel: 'Unavailable',
          ),
        ),
      );
      expect(tester.widget<CNSwitch>(find.byType(CNSwitch)).enabled, isFalse);
      await tester.pumpWidget(
        host(
          AdaptiveSwitch(
            value: true,
            onChanged: (_) {},
            thumbColor: CupertinoColors.systemRed,
          ),
        ),
      );
      expect(find.byType(CNSwitch), findsNothing);
      expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).thumbColor,
        CupertinoColors.systemRed,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

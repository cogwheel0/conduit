import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/settings/settings_controller.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/features/settings/views/settings_page_view.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// Keeps what Settings pages send instead of acting on it.
final class _RecordingController extends SettingsController {
  final List<({NativeSheetEvent event, SettingsEventSource source})> events =
      [];

  @override
  void handle(
    NativeSheetEvent event, {
    SettingsEventSource source = SettingsEventSource.nativeSheet,
  }) => events.add((event: event, source: source));

  List<(String, Object?)> get changes => [
    for (final (:event, source: _) in events)
      if (event case NativeSheetControlChanged(:final id, :final value))
        (id, value),
  ];
}

Future<_RecordingController> _pumpPage(
  WidgetTester tester,
  NativeSheetDetailConfig detail, {
  List<NativeSheetDetailConfig> known = const [],
}) async {
  final controller = _RecordingController();
  final container = ProviderContainer(
    overrides: [settingsControllerProvider.overrideWithValue(controller)],
  );
  addTearDown(container.dispose);
  container.read(settingsPagesProvider.notifier).register(known);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => SettingsPageView(detail: detail),
      ),
      GoRoute(
        path: Routes.settingsPage,
        name: RouteNames.settingsPage,
        builder: (_, state) => Text('page ${state.pathParameters['id']}'),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Finder _row(String id) => find.byKey(ValueKey<String>('settings-row-$id'));

NativeSheetDetailConfig _detail(List<NativeSheetItemConfig> items) =>
    NativeSheetDetailConfig(
      id: 'chats',
      title: 'Chats',
      sections: [NativeSheetSectionConfig(items: items)],
    );

void main() {
  testWidgets('a switch sends its new value as a Flutter Settings change, '
      'and keeps the position it was flipped to', (tester) async {
    final controller = await _pumpPage(
      tester,
      _detail([
        const NativeSheetItemConfig(
          id: 'send-on-enter',
          title: 'Send on Enter',
          kind: NativeSheetItemKind.toggle,
          value: false,
        ),
      ]),
    );

    await tester.tap(_row('send-on-enter'));
    await tester.pumpAndSettle();

    check(controller.changes).deepEquals([('send-on-enter', true)]);
    check(controller.events.single.source).equals(SettingsEventSource.flutter);
    await tester.tap(_row('send-on-enter'));
    await tester.pumpAndSettle();
    check(controller.changes.last).equals(('send-on-enter', false));
  });

  testWidgets('a row naming a known page opens that page rather than '
      'sending a change', (tester) async {
    final controller = await _pumpPage(
      tester,
      _detail([const NativeSheetItemConfig(id: 'voice', title: 'Voice')]),
      known: [NativeSheetDetailConfig(id: 'voice', title: 'Voice')],
    );

    await tester.tap(_row('voice'));
    await tester.pumpAndSettle();

    check(find.text('page voice').evaluate()).isNotEmpty();
    check(controller.changes).isEmpty();
  });

  testWidgets('a row the native sheet closes before acting sends its action '
      'here, under the page', (tester) async {
    final controller = await _pumpPage(
      tester,
      _detail([
        const NativeSheetItemConfig(
          id: 'open-calendar',
          title: 'Calendar',
          dismissOnSelect: true,
          actionId: 'open-calendar',
          actionValue: true,
        ),
      ]),
    );

    await tester.tap(_row('open-calendar'));
    await tester.pumpAndSettle();

    check(controller.changes).deepEquals([('open-calendar', true)]);
  });

  testWidgets('a choice row shows its value, opens its options, and sends '
      'the one picked', (tester) async {
    final controller = await _pumpPage(
      tester,
      _detail([
        const NativeSheetItemConfig(
          id: 'tts-engine',
          title: 'Text to Speech',
          kind: NativeSheetItemKind.segment,
          value: 'device',
          options: [
            NativeSheetOptionConfig(id: 'device', label: 'On device'),
            NativeSheetOptionConfig(id: 'server', label: 'Server'),
          ],
        ),
      ]),
    );
    check(find.text('On device').evaluate()).isNotEmpty();

    await tester.tap(_row('tts-engine'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('settings-option-server')),
    );
    await tester.pumpAndSettle();

    check(controller.changes).deepEquals([('tts-engine', 'server')]);
    check(
      find
          .descendant(of: _row('tts-engine'), matching: find.text('Server'))
          .evaluate(),
    ).isNotEmpty();
  });

  testWidgets('text stays a draft until Done sends it', (tester) async {
    final controller = await _pumpPage(
      tester,
      _detail([
        const NativeSheetItemConfig(
          id: 'stt-language-code',
          title: 'Transcription language',
          kind: NativeSheetItemKind.textField,
          value: '',
        ),
      ]),
    );

    await tester.enterText(
      find.descendant(
        of: _row('stt-language-code'),
        matching: find.byType(EditableText),
      ),
      'fr',
    );
    await tester.pumpAndSettle();
    check(controller.changes).isEmpty();

    await tester.tap(find.bySemanticsLabel('Done'));
    await tester.pumpAndSettle();

    check(controller.changes).deepEquals([('stt-language-code', 'fr')]);
  });

  testWidgets('text typed on the page is sent before a choice is made', (
    tester,
  ) async {
    final controller = await _pumpPage(
      tester,
      _detail([
        const NativeSheetItemConfig(
          id: 'stt-language-code',
          title: 'Transcription language',
          kind: NativeSheetItemKind.textField,
          value: '',
        ),
        const NativeSheetItemConfig(
          id: 'tts-voice',
          title: 'Voice',
          kind: NativeSheetItemKind.searchablePicker,
          value: 'alloy',
          options: [
            NativeSheetOptionConfig(id: 'alloy', label: 'Alloy'),
            NativeSheetOptionConfig(id: 'verse', label: 'Verse'),
          ],
        ),
      ]),
    );

    await tester.enterText(
      find.descendant(
        of: _row('stt-language-code'),
        matching: find.byType(EditableText),
      ),
      'fr',
    );
    await tester.tap(_row('tts-voice'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('settings-option-verse')),
    );
    await tester.pumpAndSettle();

    // The choice can describe the page again, so the text goes first.
    check(controller.changes)
        .deepEquals([('stt-language-code', 'fr'), ('tts-voice', 'verse')]);
  });

  testWidgets('a page described again drops the values set on the last one', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWithValue(_RecordingController()),
      ],
    );
    addTearDown(container.dispose);
    final page = ValueNotifier<NativeSheetDetailConfig>(
      _detail([
        const NativeSheetItemConfig(
          id: 'advanced-features',
          title: 'Advanced',
          kind: NativeSheetItemKind.toggle,
          value: false,
        ),
      ]),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ValueListenableBuilder(
            valueListenable: page,
            builder: (_, detail, _) => SettingsPageView(detail: detail),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_row('advanced-features'));
    await tester.pumpAndSettle();
    bool switchOn() => tester
        .widget<AdaptiveSwitch>(
          find.descendant(
            of: _row('advanced-features'),
            matching: find.byType(AdaptiveSwitch),
          ),
        )
        .value;
    check(switchOn()).isTrue();

    // The controller saved something else, and the page says so.
    page.value = _detail([
      const NativeSheetItemConfig(
        id: 'advanced-features',
        title: 'Advanced',
        kind: NativeSheetItemKind.toggle,
        value: false,
      ),
    ]);
    await tester.pumpAndSettle();

    check(switchOn()).isFalse();
  });

  testWidgets('a form asks before Back drops what was changed, and not when '
      'nothing was', (tester) async {
    NativeSheetDetailConfig form() => NativeSheetDetailConfig(
      id: 'webhook-new',
      title: 'New Destination',
      confirmActionId: 'webhook.save:webhook-new',
      discardPrompt: const NativeSheetDiscardPrompt(
        title: 'Discard changes?',
        message: 'Unsaved changes will be lost.',
        discardLabel: 'Discard',
        keepLabel: 'Keep Editing',
      ),
      sections: [
        const NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: 'webhook.enabled:webhook-new',
              title: 'Enabled',
              kind: NativeSheetItemKind.toggle,
              value: true,
            ),
          ],
        ),
      ],
    );
    final controller = _RecordingController();
    final container = ProviderContainer(
      overrides: [settingsControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Text('settings root'),
          routes: [
            GoRoute(
              path: 'form',
              builder: (_, _) => SettingsPageView(detail: form()),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    final l10n = lookupAppLocalizations(const Locale('en'));

    // Untouched, Back leaves at once.
    router.push('/form');
    await tester.pumpAndSettle();
    await router.routerDelegate.navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    check(find.text('settings root').evaluate()).isNotEmpty();

    // Changed, Back asks; keeping the edits stays on the form.
    router.push('/form');
    await tester.pumpAndSettle();
    await tester.tap(_row('webhook.enabled:webhook-new'));
    await tester.pumpAndSettle();
    await router.routerDelegate.navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    check(find.text(l10n.workspaceEditorDiscardTitle).evaluate()).isNotEmpty();
    await tester.tap(find.text(l10n.workspaceEditorKeepEditing));
    await tester.pumpAndSettle();
    check(find.text('New Destination').evaluate()).isNotEmpty();
  });
}

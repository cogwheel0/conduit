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

  testWidgets('the account password rows are AutoFill password fields, and '
      'other secrets stay out of AutoFill', (tester) async {
    await _pumpPage(
      tester,
      _detail([
        NativeSheetItemConfig(
          id: 'current-password',
          title: 'Current Password',
          kind: NativeSheetItemKind.secureTextField,
          passwordRole: NativeSheetPasswordRole.current,
        ),
        NativeSheetItemConfig(
          id: 'new-password',
          title: 'New Password',
          kind: NativeSheetItemKind.secureTextField,
          passwordRole: NativeSheetPasswordRole.newPassword,
        ),
        NativeSheetItemConfig(
          id: 'api-key',
          title: 'API Key',
          kind: NativeSheetItemKind.secureTextField,
        ),
      ]),
    );
    Iterable<String>? hints(String id) => tester
        .widget<EditableText>(
          find.descendant(of: _row(id), matching: find.byType(EditableText)),
        )
        .autofillHints;

    check(hints('current-password'))
        .isNotNull()
        .deepEquals([AutofillHints.password]);
    check(hints('new-password'))
        .isNotNull()
        .deepEquals([AutofillHints.newPassword]);
    check(hints('api-key')).isNull();
  });

  testWidgets('a choice in use is marked, as iOS marks it', (tester) async {
    await _pumpPage(
      tester,
      _detail(const [
        NativeSheetItemConfig(
          id: 'delivery-auto',
          title: 'Automatic',
          kind: NativeSheetItemKind.info,
          checked: true,
        ),
        NativeSheetItemConfig(
          id: 'delivery-fcm',
          title: 'Google',
          kind: NativeSheetItemKind.info,
        ),
      ]),
    );

    expect(
      find.descendant(
        of: _row('delivery-auto'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row('delivery-fcm'),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
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

  testWidgets("a bar button naming a page pushes it, as a row leading to it "
      'would, and sends nothing', (tester) async {
    final controller = await _pumpPage(
      tester,
      NativeSheetDetailConfig(
        id: 'month',
        title: 'Calendar',
        trailingActionDetailId: 'new-event',
        trailingActionSfSymbol: 'plus',
        items: const [NativeSheetItemConfig(id: 'row', title: 'Row')],
      ),
      known: [NativeSheetDetailConfig(id: 'new-event', title: 'New Event')],
    );

    // Read by what it does, not by its symbol.
    await tester.tap(
      find.bySemanticsLabel(
        lookupAppLocalizations(const Locale('en')).settingsAddAction,
      ),
    );
    await tester.pumpAndSettle();

    check(find.text('page new-event').evaluate()).isNotEmpty();
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

  testWidgets('a date row shows its day and sends the day picked, at the time '
      'it held; a time row shows its time', (tester) async {
    final controller = await _pumpPage(
      tester,
      _detail([
        NativeSheetItemConfig(
          id: 'run-day',
          title: 'Date',
          kind: NativeSheetItemKind.date,
          value: nativeSheetDateValue(DateTime(2026, 3, 10, 9, 30)),
          min: DateTime(2026, 3, 1).millisecondsSinceEpoch.toDouble(),
          max: DateTime(2026, 3, 31).millisecondsSinceEpoch.toDouble(),
        ),
        NativeSheetItemConfig(
          id: 'run-time',
          title: 'Time',
          kind: NativeSheetItemKind.time,
          value: nativeSheetDateValue(DateTime(2000, 1, 1, 17, 5)),
        ),
      ]),
    );
    check(
      find
          .descendant(of: _row('run-day'), matching: find.text('Mar 10, 2026'))
          .evaluate(),
    ).isNotEmpty();
    check(
      find
          .descendant(
            of: _row('run-time'),
            matching: find.textContaining('5:05'),
          )
          .evaluate(),
    ).isNotEmpty();

    await tester.tap(_row('run-day'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    check(controller.changes)
        .deepEquals([('run-day', '2026-03-15T09:30:00.000')]);
  });

  testWidgets('a diff line shows its glyph and line, and is read with what '
      'happened to it', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpPage(
      tester,
      _detail([
        NativeSheetItemConfig(
          id: 'gone',
          title: 'Pack a towel.',
          subtitle: 'Removed: Pack a towel.',
          kind: NativeSheetItemKind.diffLine,
          value: NativeSheetDiffLine.removed.name,
        ),
        NativeSheetItemConfig(
          id: 'new',
          title: 'Pack a hat.',
          subtitle: 'Added: Pack a hat.',
          kind: NativeSheetItemKind.diffLine,
          value: NativeSheetDiffLine.added.name,
        ),
      ]),
    );

    check(
      find
          .descendant(of: _row('gone'), matching: find.text('\u2212'))
          .evaluate(),
    ).isNotEmpty();
    check(find.descendant(of: _row('new'), matching: find.text('+')).evaluate())
        .isNotEmpty();
    check(find.bySemanticsLabel('Removed: Pack a towel.').evaluate())
        .isNotEmpty();
    check(find.bySemanticsLabel('Added: Pack a hat.').evaluate()).isNotEmpty();
    semantics.dispose();
  });

  testWidgets('a row of code is typed as is, in a monospaced font, and goes '
      'back as a text row does', (tester) async {
    final controller = await _pumpPage(
      tester,
      _detail([
        const NativeSheetItemConfig(
          id: 'source',
          title: 'Python Source',
          kind: NativeSheetItemKind.code,
          value: 'class Tools:',
        ),
      ]),
    );

    final field = tester.widget<AdaptiveTextField>(
      find.descendant(
        of: _row('source'),
        matching: find.byType(AdaptiveTextField),
      ),
    );
    check(field.autocorrect).isFalse();
    check(field.enableSuggestions).isFalse();
    check(field.maxLines).isNull();
    check(field.style?.fontFamily).isNotNull();

    await tester.enterText(find.byType(EditableText), 'class Tools:\n    pass');
    await tester.pump();
    check(controller.changes).isEmpty();
    // Done, which typed text brings up, sends it.
    await tester.tap(
      find.bySemanticsLabel(lookupAppLocalizations(const Locale('en')).done),
    );
    await tester.pumpAndSettle();

    check(controller.changes)
        .deepEquals([('source', 'class Tools:\n    pass')]);
  });

  testWidgets("a page's search sends what is typed once typing pauses, and "
      'keeps it when the page is described again', (tester) async {
    final controller = _RecordingController();
    final container = ProviderContainer(
      overrides: [settingsControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(container.dispose);
    NativeSheetDetailConfig page(String value) => NativeSheetDetailConfig(
      id: 'tasks',
      title: 'Tasks',
      search: NativeSheetSearchConfig(
        id: 'tasks.search',
        placeholder: 'Search tasks',
        value: value,
      ),
      sections: const [
        NativeSheetSectionConfig(
          items: [NativeSheetItemConfig(id: 'row', title: 'Row')],
        ),
      ],
    );
    Future<void> show(NativeSheetDetailConfig detail) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsPageView(detail: detail),
        ),
      ),
    );
    final field = find.descendant(
      of: find.byKey(const ValueKey<String>('settings-search-tasks.search')),
      matching: find.byType(EditableText),
    );
    String text() => tester.widget<EditableText>(field).controller.text;
    await show(page(''));

    await tester.enterText(field, 'new');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(field, 'news');
    await tester.pump(const Duration(milliseconds: 100));
    check(controller.changes).isEmpty();
    await tester.pump(settingsSearchDebounce);
    check(controller.changes).deepEquals([('tasks.search', 'news')]);

    // Described again while more is typed: the text stays.
    await tester.enterText(field, 'news d');
    await show(page('news'));
    check(text()).equals('news d');
    await tester.pump(settingsSearchDebounce);

    // A query of the page's own replaces it.
    await show(page(''));
    check(text()).equals('');

    // Echoed back trimmed, the query keeps the space typed after it.
    final before = controller.changes.length;
    await tester.enterText(field, 'weekly ');
    await tester.pump(settingsSearchDebounce);
    await show(page('weekly'));
    check(text()).equals('weekly ');

    // Show All while typing waits: the text goes, and so does its send.
    await tester.enterText(field, 'weekly re');
    await show(page(''));
    check(text()).equals('');
    await tester.pump(settingsSearchDebounce);
    check(controller.changes.skip(before).toList())
        .deepEquals([('tasks.search', 'weekly ')]);

    // An earlier query answered after a later one leaves what is typed.
    await tester.enterText(field, 'a');
    await tester.pump(settingsSearchDebounce);
    await tester.enterText(field, 'ab');
    await tester.pump(settingsSearchDebounce);
    await tester.enterText(field, 'abc');
    await show(page('a'));
    check(text()).equals('abc');
    await show(page('ab'));
    check(text()).equals('abc');
    await tester.pump(settingsSearchDebounce);

    // Emptied by hand, the query goes at once.
    final emptied = controller.changes.length;
    await tester.enterText(field, 'tide');
    await tester.pump(settingsSearchDebounce);
    await tester.enterText(field, '');
    await tester.pump();
    check(controller.changes.skip(emptied).toList())
        .deepEquals([('tasks.search', 'tide'), ('tasks.search', '')]);
  });

  testWidgets('text typed on a page with no discard question is kept as '
      'it is left', (tester) async {
    final controller = _RecordingController();
    final container = ProviderContainer(
      overrides: [settingsControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/rule',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Text('editor'),
          routes: [
            GoRoute(
              path: 'rule',
              builder: (_, _) => SettingsPageView(
                detail: _detail([
                  const NativeSheetItemConfig(
                    id: 'rule',
                    title: 'Rule',
                    kind: NativeSheetItemKind.textField,
                    value: '',
                  ),
                ]),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
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
    await tester.enterText(
      find.descendant(of: _row('rule'), matching: find.byType(EditableText)),
      'FREQ=WEEKLY',
    );
    await tester.pumpAndSettle();
    check(controller.changes).isEmpty();

    router.pop();
    await tester.pumpAndSettle();

    check(controller.changes).deepEquals([('rule', 'FREQ=WEEKLY')]);
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

  testWidgets('text typed on the page is sent before a switch is flipped', (
    tester,
  ) async {
    final controller = await _pumpPage(
      tester,
      _detail([
        const NativeSheetItemConfig(
          id: 'webhook.url:webhook-new',
          title: 'URL',
          kind: NativeSheetItemKind.textField,
          value: '',
        ),
        const NativeSheetItemConfig(
          id: 'webhook.enabled:webhook-new',
          title: 'Enabled',
          kind: NativeSheetItemKind.toggle,
          value: true,
        ),
      ]),
    );

    await tester.enterText(
      find.descendant(
        of: _row('webhook.url:webhook-new'),
        matching: find.byType(EditableText),
      ),
      'https://hooks.example.com/a',
    );
    await tester.tap(_row('webhook.enabled:webhook-new'));
    await tester.pumpAndSettle();

    check(controller.changes).deepEquals([
      ('webhook.url:webhook-new', 'https://hooks.example.com/a'),
      ('webhook.enabled:webhook-new', false),
    ]);
  });

  testWidgets('text typed and not yet done stays when the page is described '
      'again without changing that field', (tester) async {
    final controller = _RecordingController();
    final container = ProviderContainer(
      overrides: [settingsControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(container.dispose);
    NativeSheetDetailConfig form({required String profile}) => _detail([
      const NativeSheetItemConfig(
        id: 'name',
        title: 'Name',
        kind: NativeSheetItemKind.textField,
        value: 'Home',
      ),
      const NativeSheetItemConfig(
        id: 'url',
        title: 'URL',
        kind: NativeSheetItemKind.textField,
        value: '',
      ),
      NativeSheetItemConfig(id: 'profile', title: 'Profile', subtitle: profile),
    ]);
    final page = ValueNotifier(form(profile: 'Loading'));
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
    Finder field(String id) =>
        find.descendant(of: _row(id), matching: find.byType(EditableText));
    await tester.enterText(field('url'), 'https://home.example');
    await tester.pumpAndSettle();

    // Read in the meantime, the profile fills in; the URL is as it was.
    page.value = form(profile: 'Default');
    await tester.pumpAndSettle();

    check(tester.widget<EditableText>(field('url')).controller.text)
        .equals('https://home.example');
    // Not done yet, so not sent either.
    check(controller.changes).isEmpty();
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

  testWidgets('a page opened again after an earlier close stays open when '
      'Settings registers its pages again', (tester) async {
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWithValue(_RecordingController()),
      ],
    );
    addTearDown(container.dispose);
    final pages = container.read(settingsPagesProvider.notifier);
    pages.register([
      NativeSheetDetailConfig(
        id: 'memory-add',
        title: 'Add Memory',
        items: [const NativeSheetItemConfig(id: 'content', title: 'Text')],
      ),
    ]);
    // An earlier Add Memory, saved and closed.
    pages.requestClose('memory-add');
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Text('settings root'),
          routes: [
            GoRoute(
              path: 'add',
              builder: (_, _) =>
                  const SettingsDetailPage(detailId: 'memory-add'),
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
    router.push('/add');
    await tester.pumpAndSettle();

    // The root describes its pages again, as after a profile refresh.
    pages.register([
      NativeSheetDetailConfig(
        id: 'voice',
        title: 'Voice',
        items: [const NativeSheetItemConfig(id: 'speed', title: 'Speed')],
      ),
    ]);
    await tester.pumpAndSettle();
    check(find.text('settings root').evaluate()).isEmpty();

    // A save that closes it now does.
    pages.requestClose('memory-add');
    await tester.pumpAndSettle();
    check(find.text('settings root').evaluate()).isNotEmpty();
  });

  testWidgets('a form asks before Back drops what was changed, and not when '
      'nothing was', (tester) async {
    NativeSheetDetailConfig form() => NativeSheetDetailConfig(
      id: 'webhook-new',
      title: 'New Destination',
      confirmActionId: 'webhook.save:webhook-new',
      discardPrompt: const NativeSheetDiscardPrompt(
        title: 'Drop this destination?',
        message: 'It has not been saved.',
        discardLabel: 'Drop',
        keepLabel: 'Stay',
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
    // The page's own question.
    check(find.text('Drop this destination?').evaluate()).isNotEmpty();
    check(find.text('It has not been saved.').evaluate()).isNotEmpty();
    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    check(find.text('New Destination').evaluate()).isNotEmpty();

    // Dropping the changes leaves.
    await router.routerDelegate.navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drop'));
    await tester.pumpAndSettle();
    check(find.text('settings root').evaluate()).isNotEmpty();
  });

  testWidgets('a form its owner says is saved no longer asks before Back', (
    tester,
  ) async {
    NativeSheetDetailConfig form({required bool edited}) =>
        NativeSheetDetailConfig(
          id: 'hermes-connection:new',
          title: 'New Connection',
          confirmActionId: 'hermes-connection.save:new',
          edited: edited,
          discardPrompt: const NativeSheetDiscardPrompt(
            title: 'Discard changes?',
            message: 'Your changes will be lost.',
            discardLabel: 'Discard',
            keepLabel: 'Keep Editing',
          ),
          sections: [
            const NativeSheetSectionConfig(
              items: [
                NativeSheetItemConfig(
                  id: 'hermes-connection.self-signed:new',
                  title: 'Allow Self-Signed',
                  kind: NativeSheetItemKind.toggle,
                  value: false,
                ),
              ],
            ),
          ],
        );
    final detail = ValueNotifier(form(edited: false));
    addTearDown(detail.dispose);
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWithValue(_RecordingController()),
      ],
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
              builder: (_, _) => ValueListenableBuilder(
                valueListenable: detail,
                builder: (_, page, _) => SettingsPageView(detail: page),
              ),
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
    router.push('/form');
    await tester.pumpAndSettle();
    await tester.tap(_row('hermes-connection.self-signed:new'));
    await tester.pumpAndSettle();
    // Its owner marks it edited, then saves it without closing it.
    detail.value = form(edited: true);
    await tester.pumpAndSettle();
    detail.value = form(edited: false);
    await tester.pumpAndSettle();

    await router.routerDelegate.navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    check(find.text('Discard changes?').evaluate()).isEmpty();
    check(find.text('settings root').evaluate()).isNotEmpty();
  });

  testWidgets('a form its owner says is edited asks before Back, with nothing '
      'changed here', (tester) async {
    NativeSheetDetailConfig form({required bool edited}) =>
        NativeSheetDetailConfig(
          id: 'hermes-connection:new',
          title: 'New Connection',
          confirmActionId: 'hermes-connection.save:new',
          edited: edited,
          discardPrompt: const NativeSheetDiscardPrompt(
            title: 'Discard changes?',
            message: 'Your changes will be lost.',
            discardLabel: 'Discard',
            keepLabel: 'Keep Editing',
          ),
          sections: [
            const NativeSheetSectionConfig(
              items: [
                NativeSheetItemConfig(
                  id: 'hermes-connection.self-signed:new',
                  title: 'Allow Self-Signed',
                  kind: NativeSheetItemKind.toggle,
                  value: false,
                ),
              ],
            ),
          ],
        );
    final detail = ValueNotifier(form(edited: false));
    addTearDown(detail.dispose);
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWithValue(_RecordingController()),
      ],
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
              builder: (_, _) => ValueListenableBuilder(
                valueListenable: detail,
                builder: (_, page, _) => SettingsPageView(detail: page),
              ),
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
    router.push('/form');
    await tester.pumpAndSettle();
    // Edited on a page of its own, with no change on this one.
    detail.value = form(edited: true);
    await tester.pumpAndSettle();

    await router.routerDelegate.navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    check(find.text('Discard changes?').evaluate()).isNotEmpty();
  });
}

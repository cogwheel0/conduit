import 'dart:async';

import 'package:conduit/features/deepseek_harness/deepseek_harness_chats.dart';
import 'package:conduit/features/deepseek_harness/harness_workspace_sidebar.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness_client.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;

class _Grant extends Fake implements DeepSeekHarnessConnection {}

class _Client extends Fake implements DeepSeekHarnessClient {
  final observed = <(String, int)>[];
  final sent = <(String, String)>[];
  final requestIds = <String>[];
  final stopped = <String>[];
  final created = <String>[];
  final models = <String>[];
  final streams = <StreamController<HarnessTranscript>>[];
  bool sendFails = false;
  Completer<void>? acknowledgment;

  List<HarnessSession> sessions = const [
    HarnessSession('tray', 'Tray notes', false, false),
    HarnessSession('fern', 'Fern log', false, false),
    HarnessSession('archive', 'Archived tray', false, true),
  ];

  Completer<List<HarnessSession>>? nextSessions;

  @override
  Future<List<HarnessSession>> listSessions() async {
    final pending = nextSessions;
    nextSessions = null;
    return pending == null ? sessions : await pending.future;
  }

  @override
  Future<HarnessDirectoryListing> listDirectories([String? path]) async =>
      throw const HarnessWorkspaceException(
        HarnessWorkspaceIssue.browseUnavailable,
      );

  final addedPaths = <String>[];
  @override
  Future<HarnessWorkspace> createWorkspace(String path) async {
    addedPaths.add(path);
    final newWorkspace = HarnessWorkspace(
      'orchard',
      'Orchard',
      const [],
      path: path,
    );
    workspaces = [...workspaces, newWorkspace];
    return newWorkspace;
  }

  List<HarnessWorkspace> workspaces = const [
    HarnessWorkspace('greenhouse', 'Greenhouse', ['tray']),
    HarnessWorkspace('terrarium', 'Terrarium', ['fern']),
  ];

  @override
  Future<List<HarnessWorkspace>> listWorkspaces() async => workspaces;

  @override
  Future<String> createSession({required String workspaceId}) async {
    created.add(workspaceId);
    return 'new-tray';
  }

  @override
  Future<List<HarnessModel>> listModels() async => const [
    HarnessModel('garden', 'field', 'Field Notes'),
  ];

  @override
  Future<void> selectModel(String sessionId, HarnessModel model) async {
    models.add('$sessionId/${model.id}');
  }

  @override
  Stream<HarnessTranscript> follow(String sessionId, {int maxMessages = 100}) {
    observed.add((sessionId, maxMessages));
    final stream = StreamController<HarnessTranscript>();
    streams.add(stream);
    return stream.stream;
  }

  @override
  Future<void> send(
    String sessionId,
    String text, {
    required String requestId,
  }) async {
    sent.add((sessionId, text));
    requestIds.add(requestId);
    await acknowledgment?.future;
    if (sendFails) {
      throw const DeepSeekHarnessException(DeepSeekHarnessFailure.unavailable);
    }
  }

  @override
  Future<void> interrupt(String sessionId) async => stopped.add(sessionId);

  void emit({
    List<HarnessMessage> messages = const [],
    bool running = false,
    bool needsWorkspace = false,
    bool pending = false,
    bool more = false,
    bool failed = false,
    String? title,
  }) => streams.last.add(
    HarnessTranscript(
      messages: messages,
      running: running,
      needsWorkspace: needsWorkspace,
      hasPendingRequest: pending,
      lastTurnFailed: failed,
      title: title,
      hasMore: more,
    ),
  );

  @override
  void close() {
    for (final stream in streams) {
      unawaited(stream.close());
    }
  }
}

void main() {
  late _Client client;
  late List<String?> opened;
  late Completer<void> closeWorkspace;

  setUp(() {
    client = _Client();
    opened = [];
    closeWorkspace = Completer<void>();
  });

  final selections = <String?>[];
  Future<void> open(
    WidgetTester tester, {
    String? initial,
    bool tablet = false,
  }) async {
    selections.clear();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = tablet
        ? const Size(1000, 750)
        : const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          harnessClientFactoryProvider.overrideWithValue((_) => client),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DeepSeekHarnessChats(
            connection: _Grant(),
            initialWorkspaceId: initial,
            onWorkspaceSelected: (id) async => selections.add(id),
            onExit: () {},
            onReady: () {},
            onEditConnection: () {},
            onOpenWorkspace: (id) {
              opened.add(id);
              return closeWorkspace.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String title) async {
    await tester.tap(find.text(title).first);
    await tester.pump();
    await tester.pump();
  }

  Future<void> session(WidgetTester tester, String title) async {
    await choose(tester, title);
    client.emit();
    await tester.pumpAndSettle();
  }

  Finder action(String label) => find.byWidgetPredicate(
    (w) => w is AdaptiveButton && w.semanticLabel == label,
  );
  Finder field() => find.descendant(
    of: find.byKey(const ValueKey('harness-message-field')),
    matching: find.byType(EditableText),
  );

  testWidgets('sessions requiring the workspace open there directly', (
    tester,
  ) async {
    await open(tester);
    final archived = find.byKey(const ValueKey('archive'));
    expect(
      find.descendant(
        of: archived,
        matching: find.text('Open Harness workspace'),
      ),
      findsOneWidget,
    );
    await choose(tester, 'Archived tray');
    expect(opened, ['Archived tray']);
    expect(client.observed, isEmpty);
    closeWorkspace.complete();
    await tester.pumpAndSettle();
    expect(find.text('Tray notes'), findsOneWidget);
  });

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)).hitTestable());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'phone sidebar filters chats and targets the selected workspace',
    (tester) async {
      await open(tester);
      await tapKey(tester, 'harness-workspaces-button');
      await tapKey(tester, 'harness-workspace-greenhouse');
      expect(selections, ['greenhouse']);
      expect(find.text('Tray notes'), findsOneWidget);
      expect(find.text('Fern log'), findsNothing);
      await tester.tap(find.byTooltip('New Chat'));
      await tester.pump();
      await tester.pump();
      expect(client.created, ['greenhouse']);
      client.emit();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Workspaces'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'harness-all-chats');
      expect(selections, ['greenhouse', null]);
      expect(find.text('Fern log'), findsOneWidget);
      expect(find.text('Archived tray'), findsOneWidget);
    },
  );

  testWidgets('the iOS navigation bar leaves the workspace row tappable', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    tester.view.padding = const FakeViewPadding(top: 59);
    addTearDown(tester.view.resetPadding);

    await open(tester);
    await tapKey(tester, 'harness-workspaces-button');
    await tapKey(tester, 'harness-workspace-terrarium');
    expect(selections, ['terrarium']);
    expect(find.text('Fern log'), findsOneWidget);
  });

  testWidgets('a deleted active workspace returns to All chats on reload', (
    tester,
  ) async {
    await open(tester, initial: 'greenhouse');
    expect(find.text('Fern log'), findsNothing);
    client.workspaces = [client.workspaces.last];
    await choose(tester, 'Reload');
    await tester.pumpAndSettle();
    expect(selections, [null]);
    expect(find.text('Fern log'), findsOneWidget);
    await tapKey(tester, 'harness-workspaces-button');
    expect(
      find.byKey(const ValueKey('harness-workspace-terrarium')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('harness-new-workspace')).hitTestable(),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('harness-workspaces-button')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('add the first workspace, then start its first chat', (
    tester,
  ) async {
    client.sessions = [];
    client.workspaces = [];
    await open(tester);
    await tester.tap(find.text('New workspace').hitTestable());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '/gardens/Orchard');
    await tester.tap(find.text('Use this folder').hitTestable());
    await tester.pumpAndSettle();
    expect(client.addedPaths, ['/gardens/Orchard']);
    expect(selections, ['orchard']);
    expect(find.text('Orchard'), findsOneWidget);
    await tester.tap(find.text('New Chat').hitTestable());
    await tester.pump();
    await tester.pump();
    expect(client.created, ['orchard']);
    client.emit();
    await tester.pumpAndSettle();
  });

  testWidgets('a late title lookup cannot open the previous workspace', (
    tester,
  ) async {
    await open(tester, initial: 'greenhouse');
    await tester.tap(find.byTooltip('New Chat'));
    await tester.pump();
    await tester.pump();
    client.emit();
    await tester.pumpAndSettle();
    final pending = Completer<List<HarnessSession>>();
    client.nextSessions = pending;
    await tester.tap(find.byTooltip('Open Harness workspace'));
    await tester.pump();
    await tester.tap(find.byTooltip('Workspaces'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'harness-workspace-terrarium');
    pending.completeError(
      const DeepSeekHarnessException(DeepSeekHarnessFailure.unavailable),
    );
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.text('Fern log'), findsOneWidget);
  });

  testWidgets('tablet keeps workspaces beside the current chat list', (
    tester,
  ) async {
    await open(tester, tablet: true, initial: 'terrarium');
    expect(find.text('Fern log'), findsOneWidget);
    expect(find.text('Tray notes'), findsNothing);
    expect(
      find.byKey(const ValueKey('harness-workspaces-button')),
      findsNothing,
    );
    await tapKey(tester, 'harness-workspace-greenhouse');
    expect(find.text('Tray notes'), findsOneWidget);
    expect(find.byType(HarnessWorkspaceSidebar), findsOneWidget);
    expect(
      find.byKey(const ValueKey('harness-workspace-terrarium')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets(
    'failed send and navigating between sessions preserve only the matching draft',
    (tester) async {
      await open(tester);
      await session(tester, 'Tray notes');
      await tester.enterText(field(), 'Label the tray');
      await tester.pump();
      client.sendFails = true;
      await tester.tap(action('Send'));
      await tester.pumpAndSettle();
      expect(client.sent, [('tray', 'Label the tray')]);
      expect(find.textContaining('didn’t confirm the send'), findsOneWidget);
      expect(
        tester.widget<EditableText>(field()).controller.text,
        'Label the tray',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await session(tester, 'Fern log');
      expect(tester.widget<EditableText>(field()).controller.text, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await session(tester, 'Tray notes');
      expect(
        tester.widget<EditableText>(field()).controller.text,
        'Label the tray',
      );
      client.sendFails = false;
      await tester.tap(action('Send'));
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(field()).controller.text, isEmpty);
      expect(client.requestIds, [
        client.requestIds.first,
        client.requestIds.first,
      ]);
      await tester.enterText(field(), 'Label the tray');
      await tester.pump();
      await tester.tap(action('Send'));
      await tester.pumpAndSettle();
      expect(client.requestIds.last, isNot(client.requestIds.first));
      client.sendFails = true;
      await tester.enterText(field(), 'Water the tray');
      await tester.pump();
      await tester.tap(action('Send'));
      await tester.pumpAndSettle();
      final editedId = client.requestIds.last;
      await tester.enterText(field(), 'Check tray');
      await tester.enterText(field(), 'Water the tray');
      await tester.pump();
      await tester.tap(action('Send'));
      await tester.pumpAndSettle();
      expect(client.requestIds.last, isNot(editedId));
    },
  );

  testWidgets('an in-flight send survives Back without erasing a newer draft', (
    tester,
  ) async {
    await open(tester);
    await session(tester, 'Tray notes');
    client.acknowledgment = Completer<void>();
    await tester.enterText(field(), 'First reading');
    await tester.pump();
    await tester.tap(action('Send'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await session(tester, 'Tray notes');
    expect(tester.widget<AdaptiveButton>(action('Send')).onPressed, isNull);
    await tester.enterText(field(), 'Next reading');
    client.acknowledgment!.complete();
    await tester.pumpAndSettle();
    expect(client.sent, [('tray', 'First reading')]);
    expect(
      tester.widget<EditableText>(field()).controller.text,
      'Next reading',
    );
  });

  testWidgets('chooses workspace, creates session and changes its model', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('New Chat'));
    await tester.pumpAndSettle();
    await choose(tester, 'Greenhouse');
    await tester.pump(const Duration(seconds: 1));
    expect(client.created, ['greenhouse']);
    expect(client.observed.last, ('new-tray', 100));
    client.emit();
    await tester.pumpAndSettle();
    await tester.tap(action('Choose a model'));
    await tester.pumpAndSettle();
    await choose(tester, 'Field Notes');
    await tester.pump(const Duration(seconds: 1));
    expect(client.models, ['new-tray/field']);
  });

  testWidgets(
    'interruption, history pagination and recovery keep the session identity',
    (tester) async {
      await open(tester);
      await session(tester, 'Tray notes');
      client.emit(
        running: true,
        more: true,
        messages: const [HarnessMessage('user', 'Inspect tray')],
      );
      await tester.pumpAndSettle();
      await tester.tap(action('Stop Generating'));
      await tester.pump();
      expect(client.stopped, ['tray']);
      await choose(tester, 'Load More');
      expect(client.observed.last, ('tray', 200));
      expect(find.text('Inspect tray'), findsOneWidget);
      expect(
        tester.widget<AdaptiveButton>(action('Stop Generating')).onPressed,
        isNull,
      );
      client.streams.last.addError(
        const DeepSeekHarnessException(DeepSeekHarnessFailure.unavailable),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AdaptiveButton>(action('Stop Generating')).onPressed,
        isNull,
      );
      await choose(tester, 'Retry');
      expect(client.observed.last, ('tray', 200));
      expect(
        tester.widget<AdaptiveButton>(action('Stop Generating')).onPressed,
        isNull,
      );
      client.emit(running: true);
      await tester.pumpAndSettle();
      await tester.tap(action('Stop Generating'));
      await tester.pump();
      expect(client.stopped, ['tray', 'tray']);
      client.emit(failed: true);
      await tester.pumpAndSettle();
      expect(find.text("The reply couldn't be finished."), findsOneWidget);
      expect(find.text('Open Harness workspace'), findsOneWidget);
      client.emit(
        messages: const [HarnessMessage('assistant', 'Tray counted')],
      );
      await tester.pumpAndSettle();
      expect(find.text("The reply couldn't be finished."), findsNothing);
      expect(find.text('Open Harness workspace'), findsNothing);
      client.emit(needsWorkspace: true);
      await tester.pumpAndSettle();
      expect(find.text('Review request in Harness'), findsNothing);
      client.emit(needsWorkspace: true, pending: true, title: 'Spring tray');
      await tester.pumpAndSettle();
      await choose(tester, 'Review request in Harness');
      expect(opened, ['Spring tray']);
      expect(client.streams.last.hasListener, isFalse);
      closeWorkspace.complete();
      await tester.pump();
      expect(client.observed.last, ('tray', 200));
    },
  );

  testWidgets(
    'background disconnects follow without stopping the turn; foreground restores it',
    (tester) async {
      await open(tester);
      await session(tester, 'Tray notes');
      client.emit(running: true);
      await tester.pump();
      final change = tester.binding.handleAppLifecycleStateChanged;
      change(AppLifecycleState.inactive);
      expect(client.streams.last.hasListener, isTrue);
      change(AppLifecycleState.hidden);
      change(AppLifecycleState.paused);
      expect(client.streams.last.hasListener, isFalse);
      expect(client.stopped, isEmpty);
      change(AppLifecycleState.hidden);
      change(AppLifecycleState.inactive);
      change(AppLifecycleState.resumed);
      await tester.pump();
      expect(client.observed, [('tray', 100), ('tray', 100)]);
      client.emit(
        running: false,
        messages: const [HarnessMessage('user', 'Return to the tray')],
      );
      await tester.pumpAndSettle();
      expect(find.text('Return to the tray'), findsOneWidget);
    },
  );

  testWidgets(
    'stream updates keep the reading position in an older conversation',
    (tester) async {
      await open(tester);
      await session(tester, 'Tray notes');
      final history = List.generate(
        80,
        (i) => HarnessMessage('user', 'Tray reading $i'),
      );
      client.emit(messages: history);
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      final scroll = tester.state<ScrollableState>(scrollable).position;
      scroll.jumpTo(120);
      await tester.pumpAndSettle();
      final before = scroll.pixels;
      client.emit(
        messages: [...history, const HarnessMessage('user', 'Newest reading')],
        running: true,
      );
      await tester.pumpAndSettle();
      expect(scroll.pixels, before);
    },
  );
}

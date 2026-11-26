import 'dart:async';

import 'package:conduit/features/deepseek_harness/deepseek_harness_chats.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;

class _Grant extends Fake implements DeepSeekHarnessConnection {}

class _Client extends Fake implements DeepSeekHarnessClient {
  final observed = <(String, int)>[];
  final sent = <(String, String)>[];
  final stopped = <String>[];
  final created = <String>[];
  final models = <String>[];
  final streams = <StreamController<HarnessTranscript>>[];
  bool sendFails = false;
  Completer<void>? acknowledgment;

  @override
  Future<List<HarnessSession>> listSessions() async => const [
    HarnessSession('tray', 'Tray notes', false, false),
    HarnessSession('fern', 'Fern log', false, false),
    HarnessSession('archive', 'Archived tray', false, true),
  ];

  @override
  Future<List<HarnessWorkspace>> listWorkspaces() async => const [
    HarnessWorkspace('greenhouse', 'Greenhouse', ['tray']),
    HarnessWorkspace('terrarium', 'Terrarium', ['fern']),
  ];

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
  Future<void> send(String sessionId, String text) async {
    sent.add((sessionId, text));
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

  Future<void> open(WidgetTester tester) async {
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
      client.streams.last.addError(
        const DeepSeekHarnessException(DeepSeekHarnessFailure.unavailable),
      );
      await tester.pumpAndSettle();
      await choose(tester, 'Retry');
      expect(client.observed.last, ('tray', 200));
      client.emit(failed: true);
      await tester.pumpAndSettle();
      expect(find.text("The reply couldn't be finished."), findsOneWidget);
      expect(find.text('Open Harness workspace'), findsOneWidget);
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

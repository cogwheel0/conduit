import 'dart:async';

import 'package:conduit/features/deepseek_harness/deepseek_harness_browser_data.dart';
import 'package:conduit/features/deepseek_harness/deepseek_harness_page.dart';
import 'package:conduit/features/deepseek_harness/deepseek_harness_workspace.dart';
import 'package:conduit/features/deepseek_harness/deepseek_harness_chats.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as browser;
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;

class _CookieJar extends mocktail.Mock implements browser.CookieManager {}

class _Grant extends Fake implements DeepSeekHarnessConnection {
  _Grant({this.isExpired = false});

  @override
  final bool isExpired;

  @override
  final Uri root = Uri.parse('https://workspace.example/harness/');

  @override
  String get cookiePath => root.path;

  @override
  String get cookieName => 'dsh-auth-demo';

  @override
  String get cookieValue => 'synthetic-workspace-session';
}

class _Connections extends DeepSeekHarnessConnections {
  _Connections(this.saved);
  DeepSeekHarnessConnection? saved;
  final attempts = <String>[];
  DeepSeekHarnessFailure? failure;

  @override
  Future<DeepSeekHarnessConnection?> build() async => saved;

  @override
  Future<DeepSeekHarnessConnection> connect(
    String launchUrl, {
    Future<void> Function()? beforeSave,
  }) async {
    attempts.add(launchUrl);
    final problem = failure;
    if (problem != null) throw DeepSeekHarnessException(problem);
    await beforeSave?.call();
    final next = _Grant();
    state = AsyncData(saved = next);
    return next;
  }

  @override
  Future<void> disconnect() async {
    saved = null;
    state = const AsyncData(null);
  }
}

class _EmptyCatalog extends Fake implements DeepSeekHarnessClient {
  @override
  Future<List<HarnessSession>> listSessions() async => const [];
  @override
  Future<List<HarnessWorkspace>> listWorkspaces() async => const [];
  @override
  void close() {}
}

class _Cookies extends HarnessBrowserData {
  final removed = <DeepSeekHarnessConnection>[];
  final installed = <DeepSeekHarnessConnection>[];

  @override
  Future<void> install(DeepSeekHarnessConnection connection) {
    installed.add(connection);
    // Exercise native connection management without starting a platform view.
    return Completer<void>().future;
  }

  final forgotten = <DeepSeekHarnessConnection>[];

  @override
  Future<void> forget(DeepSeekHarnessConnection connection) async {
    forgotten.add(connection);
  }

  @override
  Future<void> remove(DeepSeekHarnessConnection connection) async {
    removed.add(connection);
  }
}

void main() {
  late _Connections connections;
  late _Cookies cookies;
  late int connected;
  late int exited;
  late int disconnected;

  setUp(() {
    connections = _Connections(null);
    cookies = _Cookies();
    connected = exited = disconnected = 0;
  });

  Future<void> open(
    WidgetTester tester, {
    bool edit = false,
    bool workspace = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deepSeekHarnessConnectionProvider.overrideWith(() => connections),
          deepSeekHarnessBrowserDataProvider.overrideWithValue(cookies),
          harnessClientFactoryProvider.overrideWithValue(
            (_) => _EmptyCatalog(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: workspace
              ? DeepSeekHarnessWorkspacePage(
                  sessionTitle: null,
                  onExit: () {},
                  onReconnect: () {},
                )
              : DeepSeekHarnessPage(
                  editConnection: edit,
                  onOpenWorkspace: (_) async => false,
                  onConnected: () async {
                    connected++;
                  },
                  onExit: () {
                    exited++;
                  },
                  onDisconnected: () async {
                    disconnected++;
                  },
                ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations strings(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(DeepSeekHarnessPage)))!;

  Future<void> press(WidgetTester tester, String label) async {
    final button = find.text(label).last;
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  test(
    'absent WebKit cookie can be forgotten; a remaining grant is reported',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final jar = _CookieJar();
      final grant = _Grant();
      final data = HarnessBrowserData(() => jar);
      final url = browser.WebUri.uri(grant.root);
      mocktail
          .when(
            () => jar.deleteCookie(
              url: url,
              name: grant.cookieName,
              path: grant.cookiePath,
              domain: grant.root.host,
            ),
          )
          .thenAnswer((_) async => false);
      final cookies = <browser.Cookie>[
        browser.Cookie(
          name: grant.cookieName,
          value: 'neighbor',
          path: '/other/',
          domain: grant.root.host,
        ),
      ];
      mocktail
          .when(() => jar.getCookies(url: url))
          .thenAnswer((_) async => cookies);
      await data.remove(grant);
      cookies.add(
        browser.Cookie(
          name: grant.cookieName,
          value: grant.cookieValue,
          path: grant.cookiePath,
          domain: grant.root.host,
        ),
      );
      await expectLater(data.remove(grant), throwsStateError);
    },
  );

  testWidgets('a pasted launch URL goes straight to the concealed field', (
    tester,
  ) async {
    await open(tester);
    final fields = find.byType(EditableText);
    const address = 'https://workspace.example/harness/';
    await tester.enterText(fields.first, '$address?token=demo%2Btoken');
    await tester.pump();
    final url = tester.widget<EditableText>(fields.first);
    final token = tester.widget<EditableText>(fields.last);
    expect(url.controller.text, address);
    expect(token.controller.text, 'demo+token');
    expect(token.obscureText, isTrue);
    expect(token.enableSuggestions, isFalse);
    await press(tester, strings(tester).connectToServerButton);
    expect(connections.attempts.single, '$address?token=demo%2Btoken');
    expect(connected, 1);
    expect(find.byType(DeepSeekHarnessChats), findsOneWidget);
    expect(cookies.installed, isEmpty);
  });

  testWidgets('opening the full workspace installs the saved browser grant', (
    tester,
  ) async {
    connections.saved = _Grant();
    await open(tester, workspace: true);
    expect(cookies.installed, [connections.saved]);
  });

  testWidgets(
    'invalid launch links and embedded credentials never appear in the form',
    (tester) async {
      await open(tester);
      final fields = find.byType(EditableText);
      for (final link in [
        'https://workspace.example/?token=demo&token=extra',
        'https://account:example@workspace.example/?token=demo',
        'https://workspace.example/#demo',
      ]) {
        await tester.enterText(fields.first, link);
        await tester.pump();
        expect(
          tester.widget<EditableText>(fields.first).controller.text,
          isNot(contains('demo')),
        );
        expect(
          tester.widget<EditableText>(fields.last).controller.text,
          isEmpty,
        );
        expect(
          find.text(strings(tester).deepSeekHarnessInvalidAddress),
          findsOneWidget,
        );
      }
      expect(connections.attempts, isEmpty);
    },
  );

  testWidgets(
    'failed replacement preserves the workspace and Cancel restores it',
    (tester) async {
      final previous = _Grant();
      connections.saved = previous;
      connections.failure = DeepSeekHarnessFailure.unauthorized;
      await open(tester);
      final l10n = strings(tester);
      tester
          .widget<DeepSeekHarnessChats>(find.byType(DeepSeekHarnessChats))
          .onEditConnection();
      await tester.pump();
      await tester.enterText(find.byType(EditableText).last, 'invalid-demo');
      await press(tester, l10n.connectToServerButton);
      expect(connections.saved, same(previous));
      expect(cookies.forgotten, isEmpty);
      expect(find.text(l10n.deepSeekHarnessUnauthorized), findsOneWidget);
      await press(tester, l10n.cancel);
      final chats = tester.widget<DeepSeekHarnessChats>(
        find.byType(DeepSeekHarnessChats),
      );
      expect(chats.connection, same(previous));
      expect(exited, 0);
      chats.onReady();
      chats.onReady();
      expect(connected, 1);
      chats.onExit();
      expect(exited, 1);
    },
  );

  testWidgets(
    'expired grant can be reconnected or forgotten on a small phone',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 480);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final expired = _Grant(isExpired: true);
      connections.saved = expired;
      await open(tester);
      final l10n = strings(tester);
      expect(find.text(l10n.deepSeekHarnessUnauthorized), findsOneWidget);
      expect(find.byType(DeepSeekHarnessWorkspace), findsNothing);
      await press(tester, l10n.deepSeekHarnessForget);
      await press(tester, l10n.cancel);
      expect(connections.saved, same(expired));
      await press(tester, l10n.deepSeekHarnessForget);
      await press(tester, l10n.deepSeekHarnessForget);
      expect(cookies.forgotten, [expired]);
      expect(connections.saved, isNull);
      expect(disconnected, 1);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        isEmpty,
      );
    },
  );

  test('workspace disables bridge, external windows, third-party cookies and file access', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final settings = harnessWebViewSettings(
          Uri.parse('https://workspace.example/mount/'),
        );
        expect(settings.javaScriptBridgeEnabled, false);
        expect(settings.javaScriptCanOpenWindowsAutomatically, false);
        expect(settings.thirdPartyCookiesEnabled, false);
        expect(settings.allowFileAccess, false);
        expect(settings.allowContentAccess, false);
        if (platform == TargetPlatform.iOS) {
          expect(settings.contentBlockers, hasLength(4));
        } else {
          expect(settings.useShouldInterceptRequest, true);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });
}

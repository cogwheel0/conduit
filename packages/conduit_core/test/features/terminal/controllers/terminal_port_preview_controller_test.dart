import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_port_preview_controller.dart';
import 'package:conduit_core/features/terminal/services/terminal_port_preview.dart';
import 'package:test/test.dart';

void main() {
  final base = Uri.parse('https://owui.test/api/v1/terminals/t1');
  const session = TerminalBrowserSession(id: 'sid', token: 'ticket');
  const view = 'https://owui.test/api/v1/terminals/t1/browser/view/sid/ticket';
  const proxy = 'https://owui.test/api/v1/terminals/t1/proxy';

  late List<TerminalBrowserSession> closed;

  setUp(() => closed = []);

  TerminalPortPreview preview({
    Future<TerminalBrowserSession> Function()? openSession,
  }) => TerminalPortPreview(
    port: 5173,
    terminalBaseUri: base,
    bearerToken: 'jwt',
    openSession: openSession,
    closeSession: (session) async => closed.add(session),
  );

  test('prefers a browser session and closes it when it goes', () async {
    final controller = TerminalPortPreviewController(
      preview(openSession: () async => session),
    );
    var notified = 0;
    controller.addListener(() => notified++);
    check(controller.navigator).isNull();

    await controller.start();

    check(notified).equals(1);
    check(controller.navigator).isNotNull().has(
      (n) => n.usesSession,
      'usesSession',
    ).isTrue();
    final request = controller.initialRequest!;
    check(request.uri).equals(
      Uri.parse('$view/frame/http/localhost%3A5173/'),
    );
    check(request.headers).isEmpty();
    check(controller.externalUri).equals(request.uri);

    controller.dispose();
    await pumpEventQueue();
    check(closed).deepEquals([session]);
  });

  test('falls back to the proxy when no session opens', () async {
    final controller = TerminalPortPreviewController(
      preview(openSession: () async => throw Exception('404')),
    );

    await controller.start();

    final request = controller.initialRequest!;
    check(request.uri).equals(Uri.parse('$proxy/5173/'));
    check(request.headers).deepEquals({'Authorization': 'Bearer jwt'});
    // The proxy needs the account's token, which leaves the app with no page.
    check(controller.externalUri).isNull();

    controller.dispose();
    await pumpEventQueue();
    check(closed).isEmpty();
  });

  test('a terminal without sessions goes straight to the proxy', () async {
    final controller = TerminalPortPreviewController(preview());

    await controller.start();

    check(controller.navigator!.usesSession).isFalse();
    controller.dispose();
  });

  test('a session that opens after the page closed is closed', () async {
    final opening = Completer<TerminalBrowserSession>();
    final controller = TerminalPortPreviewController(
      preview(openSession: () => opening.future),
    );
    var notified = 0;
    controller.addListener(() => notified++);
    final started = controller.start();

    controller.dispose();
    opening.complete(session);
    await started;
    await pumpEventQueue();

    check(closed).deepEquals([session]);
    check(notified).equals(0);
    check(controller.navigator).isNull();
  });

  test('a closing failure stays quiet', () async {
    final controller = TerminalPortPreviewController(
      TerminalPortPreview(
        port: 5173,
        terminalBaseUri: base,
        openSession: () async => session,
        closeSession: (_) async => throw Exception('gone'),
      ),
    );
    await controller.start();

    controller.dispose();
    await pumpEventQueue();
  });

  test('a page load the app made is let through once', () async {
    final controller = TerminalPortPreviewController(preview());
    await controller.start();
    final start = Uri.parse('$proxy/5173/');

    // iOS asks about the first load too; it carries the credential.
    check(controller.decide(start)).isA<TerminalPreviewAllow>();

    final next = Uri.parse('$proxy/5173/next');
    final decision = controller.decide(next);
    check(decision).isA<TerminalPreviewLoad>();
    check(controller.decide(next)).isA<TerminalPreviewAllow>();
    // The page's own navigation to it again needs the credential again.
    check(controller.decide(next)).isA<TerminalPreviewLoad>();
    controller.dispose();
  });

  test('a finished load forgets the load it expected', () async {
    final controller = TerminalPortPreviewController(preview());
    await controller.start();

    // Android never asks about loads the app makes.
    controller.pageLoaded(Uri.parse('$proxy/5173/'));

    check(
      controller.decide(Uri.parse('$proxy/5173/')),
    ).isA<TerminalPreviewLoad>();
    controller.dispose();
  });

  test('tracks the address and title the page shows', () async {
    final controller = TerminalPortPreviewController(
      preview(openSession: () async => session),
    );
    await controller.start();
    var notified = 0;
    controller.addListener(() => notified++);
    check(controller.address).equals(Uri.parse('http://localhost:5173/'));

    controller
      ..pageChanged(Uri.parse('$view/frame/http/localhost%3A5173/docs'))
      ..pageChanged(Uri.parse('$view/frame/http/localhost%3A5173/docs'))
      ..pageChanged(Uri.parse('https://elsewhere.test/'))
      ..pageChanged(null)
      ..titleChanged('  Docs  ')
      ..titleChanged('Docs');

    check(controller.address).equals(
      Uri.parse('http://localhost:5173/docs'),
    );
    check(controller.title).equals('Docs');
    check(notified).equals(2);
    controller.dispose();
  });

  test('blocks navigation before it knows how pages load', () {
    final controller = TerminalPortPreviewController(preview());

    check(
      controller.decide(Uri.parse('http://localhost:5173/')),
    ).isA<TerminalPreviewBlock>();
    check(controller.initialRequest).isNull();
    controller.dispose();
  });
}

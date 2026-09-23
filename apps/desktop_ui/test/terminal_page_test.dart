@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/attachments.dart';
import 'package:conduit_desktop_ui/src/file_saver.dart';
import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/terminal_page.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/terminal_providers.dart';
import 'package:conduit_desktop_ui/src/terminal_port.dart';
import 'package:conduit_desktop_ui/src/window_commands.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// The daemon, in memory.
class _FakeActions extends TerminalActions {
  _FakeActions(super.ref);

  final List<String> listed = [];
  final List<(TerminalFileOp, String, String?)> actions = [];

  @override
  Future<TerminalAttached> attach(
    String serverId, {
    String scopeId = '',
  }) async => const TerminalAttached(handle: 'h1', cwd: '/work/');

  @override
  Future<TerminalListing> list(String handle, String path) async {
    listed.add(path);
    return path == '/work/'
        ? const TerminalListing(
            path: '/work/',
            entries: [
              TerminalEntry(name: 'src', path: '/work/src/', directory: true),
              TerminalEntry(name: 'notes.txt', path: '/work/notes.txt'),
            ],
          )
        : TerminalListing(path: path);
  }

  @override
  Future<TerminalFileContent> read(String handle, String path) async =>
      const TerminalFileContent(name: 'notes.txt', text: 'hello there');

  @override
  Future<TerminalFileContent> download(String handle, String path) async =>
      const TerminalFileContent(name: 'notes.txt', base64: 'aGk=');

  @override
  Future<void> fileAction(
    String handle,
    TerminalFileOp op,
    String path, {
    String? destination,
  }) async => actions.add((op, path, destination));

  @override
  Future<TerminalPorts> ports(String handle) async =>
      const TerminalPorts(ports: [TerminalPort(port: 3000, process: 'node')]);

  @override
  Future<String> previewPort(String handle, int port) async =>
      'http://127.0.0.1:5555/.conduit-preview/k';
}

void main() {
  late _FakeActions actions;
  late RecordingTerminalView view;
  late RecordingFileSaver saver;
  late RecordingAttachments attachments;
  late RecordingWindowCommands commands;

  Component page(TerminalServers servers) {
    view = RecordingTerminalView();
    saver = RecordingFileSaver();
    attachments = RecordingAttachments(
      picks: const [
        PickedAttachment(
          handle: 'pick-1',
          name: 'up.txt',
          size: 2,
          contentType: 'text/plain',
        ),
      ],
    );
    commands = RecordingWindowCommands();
    return ProviderScope(
      overrides: [
        terminalServersProvider.overrideWith((ref) async => servers),
        terminalActionsProvider.overrideWith(
          (ref) => actions = _FakeActions(ref),
        ),
        terminalViewProvider.overrideWithValue(view),
        fileSaverProvider.overrideWithValue(saver),
        attachmentsProvider.overrideWithValue(attachments),
        windowCommandsProvider.overrideWithValue(commands),
      ],
      child: const TerminalPage(),
    );
  }

  const one = TerminalServers(
    servers: [TerminalServerDto(id: 't1', name: 'Build box')],
  );

  Finder buttonWith(String text) => find.componentWithText(button, text);

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await pumpEventQueue();
    }
  }

  testComponents('an account without terminal servers is told so', (
    tester,
  ) async {
    tester.pumpComponent(page(const TerminalServers()));
    await settle();
    expect(find.text(t.app.terminalNoServersConfigured), findsOneComponent);
    expect(terminalOffered(const TerminalServers()), isFalse);
    expect(terminalOffered(one), isTrue);
  });

  testComponents('opens a shell on the server, with its files and ports', (
    tester,
  ) async {
    tester.pumpComponent(page(one));
    await settle();
    expect(find.text('Build box'), findsOneComponent);
    expect(view.last.handle, 'h1');
    expect(view.last.hostId, 'terminal-host');
    expect(find.text(t.app.terminalConnectingStatus), findsOneComponent);
    view.last.report(TerminalLinkState.connected);
    await settle();
    expect(find.text(t.app.terminalConnectedStatus), findsOneComponent);

    expect(actions.listed, ['/work/']);
    expect(find.text('src'), findsOneComponent);
    expect(find.text('notes.txt'), findsOneComponent);
    expect(find.text('3000'), findsOneComponent);
    expect(find.text('node'), findsOneComponent);

    await tester.click(buttonWith(t.app.terminalOpenInBrowserAction));
    await settle();
    expect(commands.opened, ['http://127.0.0.1:5555/.conduit-preview/k']);

    // Disconnected, and back.
    await tester.click(buttonWith(t.app.terminalDisconnectAction));
    await settle();
    expect(view.last.closed, isTrue);
    await tester.click(buttonWith(t.app.terminalConnectAction));
    await settle();
    expect(view.sessions, hasLength(2));

    // Full screen fits the terminal to its new size.
    await tester.click(buttonWith(t.app.terminalExpandAction));
    await settle();
    expect(view.last.fitted, 1);
    expect(find.text('notes.txt'), findsNothing);
  });

  testComponents('a file a model asked to show opens with the page', (
    tester,
  ) async {
    late ProviderContainer container;
    tester.pumpComponent(
      Builder(
        builder: (context) {
          return page(one);
        },
      ),
    );
    // Asked for before the page could show it: waits for the attach.
    container = ProviderScope.containerOf(
      find.byType(TerminalPage).evaluate().first,
      listen: false,
    );
    container
        .read(terminalDisplayFileProvider.notifier)
        .show('/work/out/report.md');
    await settle();
    expect(actions.listed, containsAll(<String>['/work/', '/work/out/']));
    expect(find.text('hello there'), findsOneComponent);
    expect(container.read(terminalDisplayFileProvider), isNull);
  });

  testComponents('browses, previews, downloads, uploads and deletes', (
    tester,
  ) async {
    tester.pumpComponent(page(one));
    await settle();

    await tester.click(buttonWith('notes.txt'));
    await settle();
    expect(find.text('hello there'), findsOneComponent);
    await tester.click(buttonWith(t.app.download));
    await settle();
    expect(saver.saved.single.filename, 'notes.txt');
    await tester.click(buttonWith(t.app.close));
    await settle();

    await tester.click(buttonWith(t.app.terminalUploadAction));
    await settle();
    expect(attachments.uploadedTo.single, (handle: 'h1', directory: '/work/'));

    await tester.click(
      find.byComponentPredicate(
        (c) =>
            c is DomComponent &&
            c.attributes?['aria-label'] == '${t.app.delete}: notes.txt',
      ),
    );
    await settle();
    await tester.click(buttonWith(t.app.delete).last);
    await settle();
    expect(actions.actions.single, (
      TerminalFileOp.delete,
      '/work/notes.txt',
      null,
    ));

    await tester.click(buttonWith('src'));
    await settle();
    expect(actions.listed.last, '/work/src/');
    expect(find.text(t.app.terminalNoFiles), findsOneComponent);
    await tester.click(buttonWith('..'));
    await settle();
    expect(actions.listed.last, '/work/');
  });
}

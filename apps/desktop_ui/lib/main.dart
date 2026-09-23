import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:web/web.dart' as web;

import 'src/app.dart';
import 'src/attachments_bridge.dart';
import 'src/bridge.dart';
import 'src/keyboard.dart';
import 'src/quill_editor.dart';
import 'src/rpc/notes_providers.dart';
import 'src/rpc/terminal_providers.dart';
import 'src/rpc/voice_providers.dart';
import 'src/terminal_bridge.dart';
import 'src/voice_bridge.dart';
import 'src/sandbox_bridge.dart';
import 'src/l10n/strings.g.dart';
import 'src/rpc/rpc_providers.dart';
import 'src/rpc/settings_providers.dart';

/// Client-mode entrypoint. Compiled to `web/main.dart.js` and loaded by
/// `web/index.html`, which Electron serves from `app://conduit`.
Future<void> main() async {
  final bridge = resolveShellBridge();
  if (bridge == null) {
    // Without a port and token there is nothing to connect to, and the app
    // would render an empty shell that looks broken. Say what is wrong
    // instead — this only happens outside Electron.
    _renderBootstrapError();
    return;
  }

  // Load the catalog before the first paint. slang splits every non-base
  // locale into a deferred chunk, so this is asynchronous even though the
  // bytes are local; rendering first would flash English at everyone else.
  await LocaleSettings.setLocaleRaw(web.window.navigator.language);

  final container = ProviderContainer(
    overrides: [
      shellBridgeProvider.overrideWithValue(bridge),
      // Only when there is a shell to open a window. The dev browser keeps
      // the unavailable default, which says so rather than doing nothing.
      if (bridge.isElectron)
        externalSignInProvider.overrideWithValue(
          const ElectronExternalSignIn(),
        ),
      // Not gated on the shell: the palette applies in the dev browser too,
      // and looking right there is most of what makes it worth developing in.
      themeApplierProvider.overrideWithValue(const DocumentThemeApplier()),
      filePickerProvider.overrideWithValue(const BrowserFilePicker()),
      fileSaverProvider.overrideWithValue(const BrowserFileSaver()),
      windowCommandsProvider.overrideWithValue(DocumentWindowCommands()),
      networkEventsProvider.overrideWithValue(WindowNetworkEvents()),
      // `platform` is the shell's own report, not a user-agent guess: the
      // difference decides whether the accelerator is Cmd or Ctrl, and
      // binding the wrong one makes every shortcut in the app dead.
      shortcutBindingProvider.overrideWithValue(
        ShortcutDispatcher(isMac: bridge.platform == 'darwin'),
      ),
      sandboxProvider.overrideWithValue(DocumentSandbox()),
      attachmentsProvider.overrideWithValue(BrowserAttachments(bridge)),
      noteEditorProvider.overrideWithValue(const QuillNoteEditor()),
      terminalViewProvider.overrideWithValue(XtermTerminal(bridge)),
      voicePortProvider.overrideWithValue(BrowserVoice(bridge)),
    ],
  );
  // Start connecting before the first paint so the status card usually
  // renders already-connected rather than flashing "connecting".
  unawaited(container.read(rpcClientProvider).start());

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ConduitDesktopApp(),
    ),
  );
}

void _renderBootstrapError() {
  runApp(
    div(
      attributes: const <String, String>{
        'style': 'font-family: system-ui; padding: 2rem; line-height: 1.5',
      },
      [
        Component.text(
          'Conduit could not find the core connection details. Launch the '
          'desktop app through Electron, or pass ?port=<rpcPort>&token=<token> '
          'when developing against a daemon started by hand.',
        ),
      ],
    ),
  );
}

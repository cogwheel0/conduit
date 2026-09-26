@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/ollama_models.dart';
import 'package:conduit_desktop_ui/src/rpc/direct_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// A fake Ollama behind the actions: two models, one loaded.
class _FakeDirect extends DirectActions {
  _FakeDirect(super.ref);

  final List<(String, OllamaModelAction?)> calls =
      <(String, OllamaModelAction?)>[];
  bool bigLoaded = true;

  @override
  Future<OllamaModelList> ollama(
    String method, {
    required String connectionId,
    OllamaModelAction? action,
  }) async {
    calls.add((method, action));
    if (method == ConduitMethods.directOllamaUnload) bigLoaded = false;
    return OllamaModelList(
      lifecycle: true,
      models: <OllamaModelStatus>[
        const OllamaModelStatus(id: 'tiny:1b', name: 'tiny:1b', loaded: false),
        OllamaModelStatus(
          id: 'big:70b',
          name: 'big:70b',
          loaded: bigLoaded,
          keepAlive: '30m',
        ),
      ],
    );
  }
}

void main() {
  late _FakeDirect fake;

  Component panel() => ProviderScope(
    overrides: [
      directActionsProvider.overrideWith((ref) => fake = _FakeDirect(ref)),
    ],
    child: const OllamaModels(connectionId: 'c1'),
  );

  Finder buttonWith(String text) =>
      find.ancestor(of: find.text(text), matching: find.tag('button'));

  testComponents('shows what is loaded, and unloads it', (tester) async {
    tester.pumpComponent(panel());
    await pumpEventQueue();
    expect(find.text('tiny:1b'), findsOneComponent);
    expect(find.text(t.app.ollamaModelLoaded), findsOneComponent);
    // Load for the one that is not, Unload for the one that is.
    expect(buttonWith(t.app.ollamaLoadModel), findsOneComponent);

    await tester.click(buttonWith(t.app.ollamaUnloadModel));
    await pumpEventQueue();
    expect(fake.calls.last.$1, ConduitMethods.directOllamaUnload);
    expect(fake.calls.last.$2?.model, 'big:70b');
    expect(find.text(t.app.ollamaModelLoaded), findsNothing);
  });
}

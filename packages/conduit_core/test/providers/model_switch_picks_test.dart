/// A switch of model keeps what the user turned on and off, as Open WebUI
/// 0.12.5 does: tools, web search and image generation.
library;

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/chat_picks_session.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _SignedIn extends AuthStateManager {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'token');
}

final class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => [
    for (final id in ['t1', 't2', 't3', 't4']) Tool(id: id, name: id),
  ];
}

final class _SwitchableModel extends SelectedModel {
  @override
  Model? build() => null;

  void choose(Model? model) => state = model;
}

Model _model(String id, {List<String>? toolIds, List<String>? features}) =>
    Model(
      id: id,
      name: id,
      toolIds: toolIds,
      metadata: {
        'meta': {'defaultFeatureIds': ?features},
      },
    );

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late ProviderContainer container;

  setUp(() async {
    container = ProviderContainer(
      overrides: [
        authStateManagerProvider.overrideWith(_SignedIn.new),
        toolsListProvider.overrideWith(_Tools.new),
        selectedModelProvider.overrideWith(_SwitchableModel.new),
      ],
    );
    await container.read(authStateManagerProvider.future);
    await container.read(toolsListProvider.future);
  });
  tearDown(() => container.dispose());

  void choose(Model? model) =>
      (container.read(selectedModelProvider.notifier) as _SwitchableModel)
          .choose(model);

  test('tools turned on and off stay so through switches of model', () async {
    container.read(modelToolsAutoSelectionProvider);
    choose(_model('a', toolIds: ['t1', 't2']));
    await _settle();
    check(container.read(selectedToolIdsProvider)).deepEquals(['t1', 't2']);

    // The user turns t2 off and t3 on.
    container.read(selectedToolIdsProvider.notifier).set(['t1', 't3']);

    choose(_model('b', toolIds: ['t2', 't4']));
    await _settle();
    // t2 stays off although b defaults to it; t3 stays on; t4 is b's.
    check(container.read(selectedToolIdsProvider)).deepEquals(['t4', 't3']);

    choose(_model('c'));
    await _settle();
    // c has no defaults: only the user's own pick remains.
    check(container.read(selectedToolIdsProvider)).deepEquals(['t3']);
  });

  test('web search turned on in a chat stays through a switch of model, and '
      'a new chat starts from the defaults', () async {
    choose(_model('a'));
    check(container.read(webSearchEnabledProvider)).isFalse();

    container.read(webSearchEnabledProvider.notifier).set(true);
    // b's defaults differ from a's (image generation), so the toggles are
    // worked out again for it.
    choose(_model('b', features: ['image_generation']));
    check(container.read(imageGenerationEnabledProvider)).isTrue();
    check(container.read(webSearchEnabledProvider)).isTrue();

    clearSelectedFiltersForConversationBoundary(container);
    check(container.read(webSearchEnabledProvider)).isFalse();

    // Without a choice of the user's, the model's default applies.
    choose(_model('c', features: ['web_search', 'image_generation']));
    check(container.read(webSearchEnabledProvider)).isTrue();
    check(container.read(imageGenerationEnabledProvider)).isTrue();
  });

  test('another chat starts from the model\'s default tools again', () async {
    container.read(modelToolsAutoSelectionProvider);
    choose(_model('a', toolIds: ['t1', 't2']));
    await _settle();
    // In this chat the user turns t1 off and t3 on.
    container.read(selectedToolIdsProvider.notifier).set(['t2', 't3']);

    clearSelectedFiltersForConversationBoundary(container);
    await _settle();
    check(container.read(selectedToolIdsProvider)).deepEquals(['t1', 't2']);

    // And a switch of model there applies the next defaults whole.
    choose(_model('b', toolIds: ['t1', 't4']));
    await _settle();
    check(container.read(selectedToolIdsProvider)).deepEquals(['t1', 't4']);
  });

  test('another account starts from the defaults too', () async {
    choose(_model('a', features: ['web_search']));
    container.read(webSearchEnabledProvider.notifier).set(false);
    check(container.read(webSearchEnabledProvider)).isFalse();

    container.invalidate(chatPicksSessionProvider);
    check(container.read(webSearchEnabledProvider)).isTrue();
  });

  test('a tool the user turned on stays theirs after a model that also '
      'defaults to it', () async {
    container.read(modelToolsAutoSelectionProvider);
    choose(_model('a'));
    await _settle();
    container.read(selectedToolIdsProvider.notifier).set(['t3']);

    choose(_model('b', toolIds: ['t3']));
    await _settle();
    check(container.read(selectedToolIdsProvider)).deepEquals(['t3']);

    choose(_model('c'));
    await _settle();
    check(container.read(selectedToolIdsProvider)).deepEquals(['t3']);
  });

  test('a filter turned on comes back when the model offers it again', () {
    const filter = ToggleFilter(id: 'f', name: 'F');
    choose(const Model(id: 'a', name: 'a', filters: [filter]));
    container.read(selectedFilterIdsProvider.notifier).set(['f']);

    choose(const Model(id: 'a', name: 'a'));
    check(container.read(selectedFilterIdsProvider)).isEmpty();
    // The same model, now offering the filter again.
    choose(const Model(id: 'a', name: 'a', filters: [filter]));
    check(container.read(selectedFilterIdsProvider)).deepEquals(['f']);
  });
}

import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/widgets/composer_overflow_items.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _toggleFilter = ToggleFilter(
  id: 'test-toggle-filter',
  name: 'Test Toggle Filter',
  description: 'Adds a test system instruction.',
);

void main() {
  final l10n = AppLocalizationsEn();

  test('shared overflow items include selected model filters', () {
    final items = buildComposerOverflowItems(
      l10n: l10n,
      attachmentAvailability: const ComposerOverflowAttachmentAvailability(),
      webSearchAvailable: false,
      webSearchEnabled: false,
      imageGenerationAvailable: false,
      imageGenerationEnabled: false,
      availableTools: const [],
      selectedToolIds: const [],
      availableFilters: const [_toggleFilter],
      selectedFilterIds: const ['test-toggle-filter'],
    );

    final item = items.singleWhere(
      (candidate) =>
          candidate.id ==
          ComposerOverflowActionIds.filter('test-toggle-filter'),
    );
    expect(item.kind, ComposerOverflowItemKind.toggle);
    expect(item.section, ComposerOverflowSection.filters);
    expect(item.label, 'Test Toggle Filter');
    expect(item.subtitle, 'Adds a test system instruction.');
    expect(item.selected, isTrue);
    expect(item.dismissesKeyboard, isFalse);
  });

  test('iOS action configuration includes filters for OpenWebUI models', () {
    final actions = buildIosKeyboardAttachmentActions(
      l10n: l10n,
      attachmentAvailability: const ComposerOverflowAttachmentAvailability(),
      hermesMode: false,
      directMode: false,
      webSearchAvailable: false,
      webSearchEnabled: false,
      imageGenerationAvailable: false,
      imageGenerationEnabled: false,
      availableTools: const [],
      selectedToolIds: const [],
      availableFilters: const [_toggleFilter],
      selectedFilterIds: const ['test-toggle-filter'],
    );

    final action = actions.singleWhere(
      (candidate) =>
          candidate.id ==
          ComposerOverflowActionIds.filter('test-toggle-filter'),
    );
    expect(action.label, 'Test Toggle Filter');
    expect(action.section, 'filters');
    expect(action.selected, isTrue);
    expect(action.dismissesKeyboard, isFalse);
  });

  test('iOS action configuration keeps direct and Hermes restrictions', () {
    const attachmentAvailability = ComposerOverflowAttachmentAvailability(
      file: true,
      serverFile: true,
      photo: true,
      camera: true,
      web: true,
    );

    List<String> actionIds({
      required bool hermesMode,
      required bool directMode,
    }) {
      return buildIosKeyboardAttachmentActions(
        l10n: l10n,
        attachmentAvailability: attachmentAvailability,
        hermesMode: hermesMode,
        directMode: directMode,
        webSearchAvailable: true,
        webSearchEnabled: true,
        imageGenerationAvailable: true,
        imageGenerationEnabled: true,
        availableTools: const [],
        selectedToolIds: const [],
        availableFilters: const [_toggleFilter],
        selectedFilterIds: const ['test-toggle-filter'],
      ).map((action) => action.id).toList();
    }

    expect(actionIds(hermesMode: false, directMode: true), [
      ComposerOverflowActionIds.file,
      ComposerOverflowActionIds.photo,
      ComposerOverflowActionIds.camera,
      ComposerOverflowActionIds.webSearch,
      ComposerOverflowActionIds.imageGeneration,
    ]);
    expect(actionIds(hermesMode: true, directMode: false), [
      ComposerOverflowActionIds.file,
      ComposerOverflowActionIds.photo,
      ComposerOverflowActionIds.camera,
    ]);
  });

  testWidgets('filter actions update selected filter state', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    late WidgetRef ref;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, widgetRef, child) {
            ref = widgetRef;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    toggleComposerOverflowSelection(
      ref,
      ComposerOverflowActionIds.filter('test-toggle-filter'),
    );
    expect(container.read(selectedFilterIdsProvider), ['test-toggle-filter']);

    setComposerOverflowSelection(
      ref,
      actionId: ComposerOverflowActionIds.filter('test-toggle-filter'),
      selected: false,
    );
    expect(container.read(selectedFilterIdsProvider), isEmpty);
  });

  testWidgets('local MCP and provider features are mutually exclusive', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    late WidgetRef ref;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, widgetRef, child) {
            ref = widgetRef;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    container.read(imageGenerationEnabledProvider.notifier).set(true);
    container.read(webSearchEnabledProvider.notifier).set(true);
    setComposerOverflowSelection(
      ref,
      actionId: ComposerOverflowActionIds.tool('local_mcp:home'),
      selected: true,
    );
    expect(container.read(selectedToolIdsProvider), ['local_mcp:home']);
    expect(container.read(imageGenerationEnabledProvider), isFalse);
    expect(container.read(webSearchEnabledProvider), isFalse);

    setComposerOverflowSelection(
      ref,
      actionId: ComposerOverflowActionIds.imageGeneration,
      selected: true,
    );
    expect(container.read(selectedToolIdsProvider), isEmpty);
  });
}

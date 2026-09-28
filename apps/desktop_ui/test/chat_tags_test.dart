@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/widgets/chat_tags.dart';
import 'package:conduit_desktop_ui/src/window_commands.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr/jaspr.dart' show Component;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

void main() {
  late List<String> calls;
  late RecordingWindowCommands commands;

  Component tags(List<String> ids) => ProviderScope(
    overrides: [windowCommandsProvider.overrideWithValue(commands)],
    child: ChatTags(
      tagIds: ids,
      names: const <String, String>{'work_notes': 'Work notes'},
      onAdd: (name) => calls.add('add($name)'),
      onRemove: (name) => calls.add('remove($name)'),
      onFilter: (name) => calls.add('filter($name)'),
    ),
  );

  setUp(() {
    calls = <String>[];
    commands = RecordingWindowCommands();
  });

  testComponents('names tags, falling back to the id read back', (
    tester,
  ) async {
    tester.pumpComponent(tags(const <String>['work_notes', 'q3_plan']));
    await pumpEventQueue();
    expect(find.text('Work notes'), findsOneComponent);
    // Not in the tag list yet -- added a moment ago.
    expect(find.text('q3 plan'), findsOneComponent);
  });

  testComponents('a tag filters, and its × removes it', (tester) async {
    tester.pumpComponent(tags(const <String>['work_notes']));
    await pumpEventQueue();
    await tester.click(find.componentWithText(button, 'Work notes'));
    expect(calls, <String>['filter(Work notes)']);

    await tester.click(
      find.byComponentPredicate(
        (component) =>
            component is button &&
            component.attributes?['aria-label'] ==
                t.desktop.desktopRemoveTag(name: 'Work notes'),
      ),
    );
    expect(calls.last, 'remove(Work notes)');
  });

  testComponents('Add tag opens a field and focuses it', (tester) async {
    tester.pumpComponent(tags(const <String>[]));
    await pumpEventQueue();
    await tester.click(
      find.componentWithText(button, '+ ${t.desktop.desktopAddTag}'),
    );
    await pumpEventQueue();
    expect(find.tag('input'), findsOneComponent);
    expect(commands.focused, contains('tag-draft'));
  });
}

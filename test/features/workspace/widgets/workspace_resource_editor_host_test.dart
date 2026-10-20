import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/widgets/workspace_resource_editor_host.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('route target makes create, existing, and invalid states explicit', () {
    check(
      WorkspaceEditorTarget.fromRoute(
        mode: WorkspaceRouteMode.create,
        resourceId: null,
      ),
    ).isA<WorkspaceCreateEditorTarget>();

    final existing = WorkspaceEditorTarget.fromRoute(
      mode: WorkspaceRouteMode.edit,
      resourceId: '  resource-id  ',
    );
    check(existing).isA<WorkspaceExistingEditorTarget>();
    check((existing as WorkspaceExistingEditorTarget).resourceId)
        .equals('resource-id');

    check(
      WorkspaceEditorTarget.fromRoute(
        mode: WorkspaceRouteMode.detail,
        resourceId: ' ',
      ),
    ).isA<WorkspaceInvalidEditorTarget>();
  });

  group('a new record for a page that is already showing one', () {
    Widget host(WorkspaceRouteMode mode, _Record record) => MaterialApp(
      home: WorkspaceResourceEditorHost<_Record>(
        title: 'Title',
        section: WorkspaceSection.models,
        mode: mode,
        resourceId: 'id-1',
        detail: AsyncData(record),
        errorMessage: 'error',
        onRetry: () {},
        builder: (record) => _DraftForm(record),
      ),
    );

    testWidgets('rebuilds the read-only detail page from it', (tester) async {
      await tester.pumpWidget(host(WorkspaceRouteMode.detail, _Record('old')));
      check(find.text('old').evaluate()).length.equals(1);

      await tester.pumpWidget(host(WorkspaceRouteMode.detail, _Record('new')));

      check(find.text('new').evaluate()).length.equals(1);
    });

    testWidgets('leaves the draft an editor holds alone', (tester) async {
      await tester.pumpWidget(host(WorkspaceRouteMode.edit, _Record('old')));

      await tester.pumpWidget(host(WorkspaceRouteMode.edit, _Record('new')));

      check(find.text('old').evaluate()).length.equals(1);
      check(find.text('new').evaluate()).isEmpty();
    });
  });
}

class _Record {
  _Record(this.name);

  final String name;
}

/// A form that takes its draft from the record once, as the editors do.
class _DraftForm extends StatefulWidget {
  const _DraftForm(this.record);

  final _Record record;

  @override
  State<_DraftForm> createState() => _DraftFormState();
}

class _DraftFormState extends State<_DraftForm> {
  late final String _draft = widget.record.name;

  @override
  Widget build(BuildContext context) => Text(_draft);
}

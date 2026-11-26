import 'dart:async';

import 'package:conduit/features/deepseek_harness/harness_directory_picker.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;

const _root = HarnessDirectoryEntry(
  name: 'Garden',
  path: '/garden',
  hidden: false,
);
const _child = HarnessDirectoryEntry(
  name: 'Trays',
  path: '/garden/trays',
  hidden: false,
);
const _hidden = HarnessDirectoryEntry(
  name: '.seeds',
  path: '/garden/.seeds',
  hidden: true,
);
const _new = HarnessDirectoryEntry(
  name: 'Herbs',
  path: '/garden/herbs',
  hidden: false,
);

class _Client extends Fake implements DeepSeekHarnessClient {
  final browsed = <String?>[];
  final registered = <String>[];
  final made = <(String, String)>[];
  bool manualOnly = false;
  bool browseFails = false;
  bool invalidPath = false;
  Completer<HarnessWorkspace>? pending;

  @override
  Future<HarnessDirectoryListing> listDirectories([String? path]) async {
    browsed.add(path);
    if (manualOnly) {
      throw const HarnessWorkspaceException(
        HarnessWorkspaceIssue.browseUnavailable,
      );
    }
    if (browseFails) throw StateError('synthetic transport failure');
    final directory = path == _child.path
        ? _child
        : path == _new.path
        ? _new
        : _root;
    return HarnessDirectoryListing(
      path: directory.path,
      home: _root.path,
      crumbs: [_root, if (directory != _root) directory],
      entries: [
        if (directory == _root) ...[_child, _hidden],
      ],
      truncated: directory == _root,
    );
  }

  @override
  Future<String> createDirectory(String parentPath, String name) async {
    made.add((parentPath, name));
    if (name == _child.name) {
      throw const HarnessWorkspaceException(
        HarnessWorkspaceIssue.directoryExists,
      );
    }
    return _new.path;
  }

  @override
  Future<HarnessWorkspace> createWorkspace(String path) async {
    registered.add(path);
    if (invalidPath) {
      throw const HarnessWorkspaceException(HarnessWorkspaceIssue.invalidPath);
    }
    return pending?.future ??
        HarnessWorkspace('garden-workspace', 'Garden', const [], path: path);
  }
}

void main() {
  late _Client client;
  late List<HarnessWorkspace?> results;
  setUp(() {
    client = _Client();
    results = [];
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Center(
            child: AdaptiveButton(
              label: 'Pick',
              onPressed: () async => results.add(
                await showHarnessWorkspacePicker(context, client),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    final item = find.text(text);
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'browses server paths, navigates up and uses the selected folder',
    (tester) async {
      await open(tester);
      expect(find.textContaining('Some folders are not shown'), findsOneWidget);
      await tap(tester, _child.name);
      expect(find.text(_child.path), findsOneWidget);
      expect(find.text('No subfolders'), findsOneWidget);
      await tap(tester, 'Parent folder');
      expect(find.text(_root.path), findsOneWidget);
      await tap(tester, 'Use this folder');
      expect(client.browsed, [null, _child.path, _root.path]);
      expect(client.registered, [_root.path]);
      expect(results.single?.path, _root.path);
    },
  );

  testWidgets('shows hidden server directories on request only', (
    tester,
  ) async {
    await open(tester);
    expect(find.text(_hidden.name), findsNothing);
    await tap(tester, 'Show hidden folders');
    expect(find.text(_hidden.name), findsOneWidget);
    await tap(tester, 'Show hidden folders');
    expect(find.text(_hidden.name), findsNothing);
    await tap(tester, _child.name);
    expect(find.text('Show hidden folders'), findsNothing);
  });

  testWidgets(
    'creates a child, retains its returned server path and registers it only on confirmation',
    (tester) async {
      await open(tester);
      await tap(tester, 'New Folder');
      await tester.enterText(find.byType(EditableText), '../trays');
      await tap(tester, 'Create');
      expect(client.made, isEmpty);
      expect(find.textContaining('without path separators'), findsOneWidget);
      await tester.enterText(find.byType(EditableText), _child.name);
      await tap(tester, 'Create');
      expect(find.textContaining('already exists'), findsOneWidget);
      await tester.enterText(find.byType(EditableText), _new.name);
      await tap(tester, 'Create');
      expect(client.made, [(_root.path, _child.name), (_root.path, _new.name)]);
      expect(find.text(_new.path), findsOneWidget);
      expect(client.registered, isEmpty);
      await tap(tester, 'Use this folder');
      expect(client.registered, [_new.path]);
      expect(results.single?.path, _new.path);
    },
  );

  testWidgets(
    'a manual-only server immediately accepts a server path and keeps it editable on failure',
    (tester) async {
      client.manualOnly = true;
      await open(tester);
      expect(find.byType(EditableText), findsOneWidget);
      expect(
        find.textContaining('existing folder on the Harness server'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing);
      client.invalidPath = true;
      const path = r'D:\Garden\Potted herbs';
      await tester.enterText(find.byType(EditableText), path);
      await tap(tester, 'Use this folder');
      expect(find.textContaining('you have access'), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        path,
      );
      expect(results, isEmpty);
      client.invalidPath = false;
      await tap(tester, 'Use this folder');
      expect(client.registered, [path, path]);
      expect(results.single?.path, path);
    },
  );

  testWidgets(
    'a temporary browse failure supports manual entry, cancel and retry',
    (tester) async {
      client.browseFails = true;
      await open(tester);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('synthetic transport failure'), findsNothing);
      await tap(tester, 'Enter folder path');
      expect(find.byType(EditableText), findsOneWidget);
      await tap(tester, 'Cancel');
      client.browseFails = false;
      await tap(tester, 'Retry');
      expect(find.text(_root.path), findsOneWidget);
      expect(client.registered, isEmpty);
    },
  );

  testWidgets(
    'a repeated press and cancellation cannot return a late workspace',
    (tester) async {
      client.pending = Completer<HarnessWorkspace>();
      await open(tester);
      final submit = tester
          .widget<AdaptiveButton>(
            find.widgetWithText(AdaptiveButton, 'Use this folder'),
          )
          .onPressed!;
      submit();
      submit();
      await tester.pump();
      expect(client.registered, [_root.path]);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(results, [null]);
      client.pending!.complete(const HarnessWorkspace('late', 'Garden', []));
      await tester.pumpAndSettle();
      expect(results, [null]);
      expect(find.text('Pick'), findsOneWidget);
    },
  );
}

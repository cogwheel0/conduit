import 'dart:async';

import 'package:conduit/features/hermes/providers/hermes_messages.dart';
import 'package:conduit/features/hermes/providers/hermes_workspace.dart';
import 'package:conduit/features/hermes/views/hermes_bot_workspace_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_workspace_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _bot = HermesBot(name: 'research', title: 'Researcher');

class _Workspace extends Fake implements HermesWorkspaceService {
  Completer<void>? pending;
  final changes = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> describeBot(String profile) async => {
    'soul': 'Keep useful research notes.',
  };

  @override
  Future<void> configureBot(String profile, Map<String, dynamic> change) async {
    changes.add(change);
    await pending?.future;
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  _Workspace? workspace,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(null),
        hermesWorkspaceServiceProvider.overrideWithValue(workspace),
        hermesMessagesBotsProvider.overrideWith((_) async => [_bot]),
      ],
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.conduit),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('SOUL save locks the draft and preserves it after a failure', (
    tester,
  ) async {
    final workspace = _Workspace()..pending = Completer<void>();
    await _pump(
      tester,
      const HermesBotWorkspacePage(bot: _bot),
      workspace: workspace,
    );
    await tester.tap(find.text('SOUL'));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('bot-text-editor-input'));
    final save = find.byKey(const ValueKey('bot-text-editor-save'));
    await tester.enterText(input, 'Compare the original research sources.');
    await tester.tap(save);
    await tester.pump();

    expect(tester.widget<TextField>(input).enabled, isFalse);
    expect(tester.widget<ConduitButton>(save).isLoading, isTrue);
    expect(
      workspace.changes.single['soul'],
      'Compare the original research sources.',
    );

    workspace.pending!.completeError(StateError('Connection interrupted'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).enabled, isTrue);
    expect(tester.widget<ConduitButton>(save).isLoading, isFalse);
    expect(
      tester.widget<TextField>(input).controller!.text,
      'Compare the original research sources.',
    );
    expect(
      find.text('Could not save. Your changes are kept here.'),
      findsOneWidget,
    );

    workspace.pending = null;
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(workspace.changes, hasLength(2));
    expect(
      workspace.changes.last['soul'],
      'Compare the original research sources.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('identity save locks controls without replacing the saved icon', (
    tester,
  ) async {
    final pending = Completer<bool>();
    Map<String, dynamic>? saved;
    await _pump(
      tester,
      Scaffold(
        body: HermesIdentityEditor(
          bot: _bot,
          description: 'Find primary sources.',
          onSave: (draft) {
            saved = draft;
            return pending.future;
          },
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('bot-identity-icon-check-bot')),
      findsOneWidget,
    );
    final name = find.byKey(const ValueKey('bot-identity-name'));
    final purpose = find.byKey(const ValueKey('bot-identity-purpose'));
    final save = find.byKey(const ValueKey('bot-identity-save'));
    await tester.enterText(name, 'Research partner');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();

    expect(tester.widget<TextField>(name).enabled, isFalse);
    expect(tester.widget<TextField>(purpose).enabled, isFalse);
    expect(tester.widget<ConduitButton>(save).isLoading, isTrue);
    expect(saved!['ui_meta']['hermes-bots']['conduitIcon'], isNull);
    expect(saved!['ui_meta']['hermes-bots']['title'], 'Research partner');
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('bot-identity-icon-code')))
          .onTap,
      isNull,
    );

    pending.complete(false);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(name).enabled, isTrue);
    expect(tester.widget<TextField>(name).controller!.text, 'Research partner');
    expect(tester.widget<ConduitButton>(save).isLoading, isFalse);
    expect(
      find.text('Could not save. Your changes are kept here.'),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('bot-identity-icon-code')),
    );
    await tester.tap(find.byKey(const ValueKey('bot-identity-icon-code')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('bot-identity-icon-check-code')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bot-identity-icon-check-bot')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

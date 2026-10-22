import 'package:conduit/features/hermes/widgets/hermes_approval_card.dart';
import 'package:conduit/features/hermes/widgets/hermes_approval_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.light(TweakcnThemes.t3Chat),
  localizationsDelegates: conduitLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('an explicitly incomplete command cannot be approved', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        HermesApprovalCard(
          state: HermesApprovalState.pending,
          summary: 'echo partial\n[…command truncated]',
          choices: const ['once', 'session', 'always', 'deny'],
          onChoice: (_) {},
          onDecision: (_) {},
        ),
      ),
    );
    for (final choice in ['once', 'session', 'always']) {
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(ValueKey('hermes-approval-$choice')),
            )
            .onPressed,
        isNull,
      );
    }
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('hermes-approval-deny')),
          )
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('approval actions are disabled while resolving', (tester) async {
    await tester.pumpWidget(
      host(
        HermesApprovalCard(
          state: HermesApprovalState.resolving,
          onDecision: (_) {},
        ),
      ),
    );
    final buttons = tester
        .widgetList<FilledButton>(find.byType(FilledButton))
        .toList();
    expect(buttons, hasLength(2));
    expect(buttons.every((button) => button.onPressed == null), isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('all advertised scopes remain exact with the selected order', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      host(
        HermesApprovalCard(
          state: HermesApprovalState.pending,
          choices: const ['once', 'session', 'always', 'deny'],
          onChoice: sent.add,
          onDecision: (_) {},
        ),
      ),
    );
    expect(
      tester
          .widgetList<FilledButton>(find.byType(FilledButton))
          .map((b) => b.key),
      [
        const ValueKey('hermes-approval-once'),
        const ValueKey('hermes-approval-deny'),
        const ValueKey('hermes-approval-always'),
        const ValueKey('hermes-approval-session'),
      ],
    );
    for (final choice in ['once', 'deny', 'always', 'session']) {
      await tester.tap(find.byKey(ValueKey('hermes-approval-$choice')));
    }
    expect(sent, ['once', 'deny', 'always', 'session']);
  });

  testWidgets('does not invent scopes for a boolean approval backend', (
    tester,
  ) async {
    final sent = <bool>[];
    await tester.pumpWidget(
      host(
        HermesApprovalCard(
          state: HermesApprovalState.pending,
          onDecision: sent.add,
        ),
      ),
    );
    expect(find.text('Allow always'), findsNothing);
    expect(find.text('Allow this session'), findsNothing);
    await tester.tap(find.text('Allow once'));
    await tester.tap(find.text('Deny'));
    expect(sent, [true, false]);
  });

  testWidgets('long command is limited to four visual lines and opens intact', (
    tester,
  ) async {
    final command = List.generate(
      80,
      (i) => 'echo step $i and check an output with a long filename',
    ).join('\n');
    await tester.pumpWidget(
      host(
        HermesApprovalCard(
          state: HermesApprovalState.pending,
          summary: command,
          onDecision: (_) {},
        ),
      ),
    );
    final preview = tester.widget<Text>(
      find.byKey(const ValueKey('hermes-command-preview-text')),
    );
    expect(preview.maxLines, 4);
    expect(preview.overflow, TextOverflow.ellipsis);
    await tester.tap(find.byKey(const ValueKey('hermes-command-preview')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      command,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Allow once'), findsOneWidget);
  });

  testWidgets(
    'dismiss and reopen the sheet without answering or auto reopening',
    (tester) async {
      final sent = <bool>[];
      await tester.pumpWidget(
        host(
          HermesApprovalSheetLauncher(
            builder: (context) => HermesApprovalCard(
              state: HermesApprovalState.pending,
              summary: 'npm ci',
              onDecision: sent.add,
              onDismiss: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Allow once'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(find.text('Allow once'), findsNothing);
      await tester.pump();
      expect(find.text('Allow once'), findsNothing);
      await tester.tap(find.text('Waiting for your response'));
      await tester.pumpAndSettle();
      expect(find.text('Allow once'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
    },
  );

  testWidgets('renders within the shared Cupertino app tree', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Theme(
          data: AppTheme.light(TweakcnThemes.t3Chat),
          child: HermesApprovalCard(
            state: HermesApprovalState.pending,
            onDecision: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Approval required'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow screen and large text keep all four controls available', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: HermesApprovalSheetLauncher(
            builder: (context) => HermesApprovalCard(
              state: HermesApprovalState.pending,
              summary: 'npm ci',
              choices: const ['once', 'deny', 'always', 'session'],
              onChoice: (_) {},
              onDecision: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FilledButton), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });
}

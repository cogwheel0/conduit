import 'package:conduit/features/hermes/widgets/hermes_conversation_stage.dart';
import 'package:conduit/features/hermes/widgets/hermes_messages_home.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('title visibility does not rebuild unrelated history rows', (
    tester,
  ) async {
    final link = HermesConversationLink();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Material(
            child: HermesConversationLinkScope(
              link: link,
              child: Column(
                children: [
                  HermesMessageRow(
                    conversationId: 'a',
                    title: 'Selected',
                    onOpen: () async {},
                  ),
                  HermesMessageRow(
                    conversationId: 'b',
                    title: 'Unrelated',
                    onOpen: () async {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final before = tester.widget<Text>(find.text('Unrelated'));
    link.begin('a', 'Selected', 1);
    link.moving = true;
    link.publish();
    await tester.pump();
    expect(
      identical(before, tester.widget<Text>(find.text('Unrelated'))),
      true,
    );
    final title = tester.element(find.text('Selected'));
    expect(title.findAncestorWidgetOfExactType<Opacity>()?.opacity, 0);
    link.moving = false;
    link.publish();
    await tester.pump();
    expect(title.findAncestorWidgetOfExactType<Opacity>()?.opacity, 1);
    expect(
      identical(before, tester.widget<Text>(find.text('Unrelated'))),
      true,
    );
    await tester.pumpWidget(const SizedBox());
    link.dispose();
  });
  for (final reduced in [false, true]) {
    testWidgets(
      'selected title enters and returns to a retained scrolled list reduced=$reduced',
      (tester) async {
        final logical = ValueNotifier(false);
        final removed = ValueNotifier(false);
        final scroll = ScrollController(initialScrollOffset: 144);
        final container = ProviderContainer(
          overrides: [hermesApiServiceProvider.overrideWithValue(null)],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              // Match the saved theme and AppBar styles from the physical app.
              theme: ThemeData(
                textTheme: const TextTheme(
                  bodyLarge: TextStyle(
                    inherit: false,
                    fontFamily: 'Roboto',
                    fontSize: 17,
                  ),
                ),
              ),
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Material(
                child: MediaQuery(
                  data: MediaQueryData(disableAnimations: reduced),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: logical,
                    builder: (_, detail, _) => HermesConversationStage(
                      chatArea: true,
                      logicalDetail: detail,
                      selectedId: 'a',
                      history: ValueListenableBuilder<bool>(
                        valueListenable: removed,
                        builder: (_, gone, _) => ListView(
                          controller: scroll,
                          children: [
                            const SizedBox(height: 220),
                            if (!gone)
                              Builder(
                                builder: (context) => HermesMessageRow(
                                  conversationId: 'a',
                                  title: 'Website redesign',
                                  onOpen: () async {
                                    HermesConversationLinkScope.of(context)!
                                        .begin('a', 'Website redesign', 7);
                                    HermesConversationLinkScope.of(context)!
                                        .finish(7, resolved: true);
                                    logical.value = true;
                                  },
                                ),
                              ),
                            const SizedBox(height: 1000),
                          ],
                        ),
                      ),
                      detail: Column(
                        children: [
                          SizedBox(
                            height: 72,
                            child: Center(
                              child: DefaultTextStyle(
                                style: const TextStyle(
                                  inherit: true,
                                  fontSize: 22,
                                ),
                                child: HermesConversationHeaderTitle(
                                  id: 'a',
                                  child: Text('Website redesign'),
                                ),
                              ),
                            ),
                          ),
                          const Expanded(child: Text('Resolved transcript')),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final original = scroll.offset;
        await tester.tap(find.text('Website redesign'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        if (!reduced) {
          expect(
            find.byKey(const ValueKey('conversation-carrier-a')),
            findsOneWidget,
          );
        } else {
          expect(
            find.byKey(const ValueKey('conversation-carrier-a')),
            findsNothing,
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('Resolved transcript'), findsOneWidget);
        if (!reduced) {
          final observer = tester.state(
            find.byType(HermesConversationStage),
          ) as WidgetsBindingObserver;
          final begin = PredictiveBackEvent.fromMap({
            'progress': 0.0,
            'swipeEdge': 0,
          });
          expect(observer.handleStartBackGesture(begin), true);
          observer.handleUpdateBackGestureProgress(
            PredictiveBackEvent.fromMap({'progress': .45, 'swipeEdge': 0}),
          );
          await tester.pump();
          expect(
            find.byKey(const ValueKey('conversation-carrier-a')),
            findsOneWidget,
          );
          observer.handleCancelBackGesture();
          await tester.pumpAndSettle();
          expect(find.text('Resolved transcript'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('conversation-carrier-a')),
            findsNothing,
          );
          container
              .read(hermesMobileNavigationProvider.notifier)
              .showConversation();
          expect(observer.handleStartBackGesture(begin), true);
          observer.handleUpdateBackGestureProgress(
            PredictiveBackEvent.fromMap({'progress': .35, 'swipeEdge': 0}),
          );
          observer.handleCommitBackGesture();
          expect(
            container.read(hermesMobileNavigationProvider).conversation,
            false,
          );
        }

        logical.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        if (!reduced) {
          expect(
            find.byKey(const ValueKey('conversation-carrier-a')),
            findsOneWidget,
          );
        }
        await tester.pumpAndSettle();
        expect(scroll.offset, original);
        expect(find.text('Resolved transcript'), findsNothing);
        expect(tester.takeException(), isNull);
        // Repeat, then remove the origin. Return must not target another row.
        await tester.tap(find.text('Website redesign'));
        await tester.pumpAndSettle();
        removed.value = true;
        await tester.pump();
        logical.value = false;
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('conversation-carrier-a')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
        logical.dispose();
        removed.dispose();
        container.dispose();
      },
    );
  }
  testWidgets(
    'an unrelated selected conversation never inherits the previous carrier',
    (tester) async {
      final detail = ValueNotifier(false),
          selected = ValueNotifier<String?>('a');
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(null)],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Material(
              child: ListenableBuilder(
                listenable: Listenable.merge([detail, selected]),
                builder: (_, _) => HermesConversationStage(
                  logicalDetail: detail.value,
                  selectedId: selected.value,
                  chatArea: true,
                  history: Builder(
                    builder: (context) => Center(
                      child: HermesMessageRow(
                        conversationId: 'a',
                        title: 'Conversation A',
                        onOpen: () async {
                          final link = HermesConversationLinkScope.of(context)!;
                          link.begin('a', 'Conversation A', 1);
                          link.finish(1, resolved: true);
                          detail.value = true;
                        },
                      ),
                    ),
                  ),
                  detail: Column(
                    children: [
                      HermesConversationHeaderTitle(
                        id: selected.value,
                        child: Text('Detail ${selected.value}'),
                      ),
                      const Expanded(child: Text('Content')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Conversation A'));
      await tester.pumpAndSettle();
      selected.value = 'b';
      await tester.pump();
      expect(
        find.byKey(const ValueKey('conversation-carrier-a')),
        findsNothing,
      );
      detail.value = false;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('conversation-carrier-a')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      selected.value = null;
      detail.value = true;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('conversation-carrier-a')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      detail.dispose();
      selected.dispose();
      container.dispose();
    },
  );

  test(
    'pending admission cancels on Back, navigation and service invalidation',
    () {
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final epoch = container
          .read(hermesSessionNavigationEpochProvider.notifier)
          .bump();
      final opening = container.read(hermesSessionOpeningProvider.notifier);
      opening.start('a', epoch);
      final token = opening.tokenFor(epoch)!;
      container.read(hermesMobileNavigationProvider.notifier).back();
      expect(container.read(hermesSessionOpeningProvider), isNull);
      expect(token.isCancelled, true);
      opening.start('b', epoch + 1);
      final b = opening.tokenFor(epoch + 1)!;
      opening.finish(epoch);
      expect(container.read(hermesSessionOpeningProvider)?.id, 'b');
      container
          .read(hermesMobileNavigationProvider.notifier)
          .select(HermesWorkArea.files);
      expect(container.read(hermesSessionOpeningProvider), isNull);
      expect(b.isCancelled, true);
    },
  );
}

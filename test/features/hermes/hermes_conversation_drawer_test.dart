import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/features/hermes/providers/hermes_messages.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/features/hermes/widgets/hermes_conversation_drawer.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Sessions extends HermesSessionsController {
  @override
  Future<List<HermesSessionSummary>> build() async => [
    HermesSessionSummary(
      id: 'website',
      title: 'Website redesign',
      preview: 'Keep the navigation clear.',
      updatedAt: DateTime(2026, 10, 16),
    ),
    const HermesSessionSummary(
      id: 'trip',
      title: 'Trip planning',
      preview: 'A weekend in the mountains',
    ),
    const HermesSessionSummary(
      id: 'archived',
      title: 'Archived conversation',
      archived: true,
    ),
    const HermesSessionSummary(
      id: 'cron_run',
      title: 'Scheduled work',
      source: 'cron',
    ),
  ];
}

class _Groups extends HermesGroupsController {
  @override
  Future<List<HermesBotGroup>> build() async => [];
}

const _bot = HermesBot(
  name: 'research',
  title: 'Research',
  preview: 'Your research assistant',
);

void main() {
  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'drawer remains integrated, selected and dismissible: dark=$dark scale=$scale',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final container = ProviderContainer(
            overrides: [
              hermesApiServiceProvider.overrideWithValue(null),
              hermesSessionsProvider.overrideWith(_Sessions.new),
              hermesMessagesBotsProvider.overrideWith((ref) async => [_bot]),
              hermesBotConversationsProvider.overrideWith(
                (ref) async => const HermesBotConversations([
                  HermesBotConversation(bot: _bot),
                ]),
              ),
              hermesBotGroupsProvider.overrideWith(_Groups.new),
            ],
          );
          addTearDown(container.dispose);
          container.read(hermesActiveSessionProvider.notifier).set('website');
          final boundary = GlobalKey();
          const renderFont = String.fromEnvironment('CONDUIT_RENDER_FONT');
          if (renderFont.isNotEmpty) {
            await tester.runAsync(() async {
              await (FontLoader('Roboto')..addFont(
                    Future.value(
                      ByteData.sublistView(
                        await File(renderFont).readAsBytes(),
                      ),
                    ),
                  ))
                  .load();
              await (FontLoader('HermesControls')..addFont(
                    rootBundle.load('assets/icons/hermes-controls.ttf'),
                  ))
                  .load();
            });
          }
          final theme = dark
              ? AppTheme.dark(TweakcnThemes.conduit)
              : AppTheme.light(TweakcnThemes.conduit);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: theme.copyWith(
                    textTheme: theme.textTheme.apply(
                      fontFamily: renderFont.isEmpty ? null : 'Roboto',
                    ),
                  ),
                  localizationsDelegates: conduitLocalizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(scale),
                      disableAnimations: scale == 2,
                    ),
                    child: child!,
                  ),
                  home: Consumer(
                    builder: (context, ref, _) => Scaffold(
                      body: Column(
                        children: [
                          TextButton(
                            onPressed: () =>
                                showHermesConversationDrawer(context, ref),
                            child: const Text('Open conversations'),
                          ),
                          const Expanded(
                            child: Center(child: Text('Current conversation')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          Future<void> open() async {
            await tester.tap(find.text('Open conversations'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }

          await open();
          expect(find.text('Website redesign'), findsOneWidget);
          expect(find.text('Archived conversation'), findsNothing);
          expect(find.text('Scheduled work'), findsNothing);
          expect(
            tester.getRect(find.byType(Drawer)).right,
            lessThanOrEqualTo(334),
          );
          final selected = tester.getSemantics(find.text('Website redesign'));
          expect(selected.flagsCollection.isSelected, ui.Tristate.isTrue);
          if (const bool.fromEnvironment('CONDUIT_CAPTURE_RENDER')) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 2);
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              Directory('build/mobile-preview').createSync(recursive: true);
              File(
                'build/mobile-preview/drawer-${dark ? 'dark' : 'light'}-$scale.png',
              ).writeAsBytesSync(data!.buffer.asUint8List());
              image.dispose();
            });
          }
          expect(find.byKey(const ValueKey('drawer-tab-bots')), findsNothing);
          await tester.tap(find.byTooltip('Search chats'));
          await tester.pumpAndSettle();
          expect(find.byType(Drawer), findsNothing);
          expect(container.read(hermesMessagesNavigationProvider), (
            tab: HermesMessagesTab.chats,
            search: true,
          ));
          await open();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(Drawer), findsNothing);
          await open();
          await tester.tapAt(const Offset(380, 350));
          await tester.pumpAndSettle();
          expect(find.byType(Drawer), findsNothing);
          await open();
          await tester.dragFrom(const Offset(250, 300), const Offset(-290, 0));
          await tester.pumpAndSettle();
          expect(find.byType(Drawer), findsNothing);
          expect(tester.takeException(), isNull);
          expect(container.read(hermesActiveSessionProvider), 'website');
          expect(
            container.read(hermesMobileNavigationProvider).conversation,
            isFalse,
          );
        },
      );
    }
  }
}

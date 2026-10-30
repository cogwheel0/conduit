import 'package:conduit/features/chat/providers/composer_draft_provider.dart';
import 'package:conduit/features/chat/widgets/composer_recordings.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_store.dart';
import 'package:conduit_core/features/chat/composer/composer_recording_store.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../../support/native_database.dart';

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _Store extends ComposerDraftStore {
  _Store(super.db) : _recordings = _Recordings(db);
  final _Recordings _recordings;
  @override
  _Recordings get recordings => _recordings;
}

class _Recordings extends ComposerRecordingStore {
  _Recordings(super.db);
  bool failDiscard = false;
  @override
  Future<void> discard(String id) {
    if (failDiscard) throw StateError('Synthetic deletion failure');
    return super.discard(id);
  }
}

void main() {
  const channel = MethodChannel('app.cogwheel.conduit/native_stt');
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'compact recording error, retry, and confirmed discard on $platform',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = platform;
        PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
        addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = AppDatabase(NativeDatabase.memory());
        final store = _Store(db);
        final ComposerDraftContext owner = (
          owner: (
            backend: 'example',
            account: 'example',
            principal: 'reader',
            session: null,
          ),
          scope: 'chat',
          chatId: 'paper',
          store: store,
          temporary: false,
        );
        final exports = <List<int>>[];
        final container = ProviderContainer(
          overrides: [
            composerDraftContextProvider.overrideWithValue(owner),
            appSettingsProvider.overrideWith(_Settings.new),
            recordingShareProvider.overrideWithValue((params) async {
              expect(params.fileNameOverrides, ['recording.wav']);
              expect(params.sharePositionOrigin!.isEmpty, isFalse);
              exports.add(await params.files!.single.readAsBytes());
              return const ShareResult('', ShareResultStatus.dismissed);
            }),
            serverSpeechProviderProvider.overrideWithValue(null),
          ],
        );
        var failTranscription = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'cancelRecordingTranscription') return null;
          if (failTranscription) {
            throw PlatformException(code: 'synthetic-unavailable');
          }
          return 'Add a blue paper star.';
        });
        Future<void> settle() async {
          for (var i = 0; i < 8; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 1)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpAndSettle();
        }

        Future<void> choose(String label) async {
          await tester.tap(find.byIcon(Icons.more_horiz));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label).last);
          await settle();
        }

        final inserted = <String>[];
        try {
          await pumpDatabaseOperation(tester, () async {
            await db
                .into(db.chats)
                .insert(
                  ChatsCompanion.insert(
                    id: 'paper',
                    title: 'Paper shapes',
                    createdAt: 1,
                    updatedAt: 1,
                  ),
                );
            final writer = await store.recordings.begin(
              id: 'blue-star',
              scope: 'chat',
              chatId: 'paper',
              onFailure: () => fail('Save failed'),
            );
            writer.add(Uint8List.fromList([1, 0, 2, 0]));
            await writer.close();
          });
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: ThemeData(platform: platform),
                localizationsDelegates: conduitLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: Scaffold(
                  body: ComposerRecordings(
                    owner: owner,
                    onInsert: inserted.add,
                  ),
                ),
              ),
            ),
          );
          await settle();
          await choose('Transcribe on device');
          expect(find.text('Error'), findsOneWidget);
          expect(
            find.text('Transcription failed. Recording saved.'),
            findsNothing,
          );
          expect(find.textContaining('synthetic-unavailable'), findsNothing);
          await tester.tap(find.byKey(const ValueKey('recording-error')));
          await tester.pumpAndSettle();
          expect(
            find.text('Transcription failed. Recording saved.'),
            findsOneWidget,
          );
          failTranscription = false;
          await tester.ensureVisible(find.text('Transcribe on device').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Transcribe on device').last);
          await settle();
          expect(inserted, ['Add a blue paper star.']);
          expect(find.text('Error'), findsNothing);
          expect(find.textContaining('Saved recording'), findsOneWidget);
          expect(find.byIcon(Icons.play_arrow), findsNothing);
          await choose('Export recording');
          expect(exports, hasLength(1));
          expect(exports.single.take(4), [82, 73, 70, 70]);
          expect(find.textContaining('Saved recording'), findsOneWidget);
          await choose('Discard recording');
          expect(
            find.text('Are you sure you want to discard this recording?'),
            findsOneWidget,
          );
          await tester.tap(find.text('Cancel').last);
          await settle();
          expect(find.textContaining('Saved recording'), findsOneWidget);
          store.recordings.failDiscard = true;
          await choose('Discard recording');
          await tester.tap(find.text('Discard recording').last);
          await settle();
          expect(find.text('Error'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('recording-error')));
          await tester.pumpAndSettle();
          expect(
            find.text('Could not discard this recording. Try again.'),
            findsOneWidget,
          );
          expect(find.text('Transcribe on device'), findsNothing);
          store.recordings.failDiscard = false;
          await tester.ensureVisible(find.text('Discard recording').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Discard recording').last);
          await settle();
          expect(
            find.text('Are you sure you want to discard this recording?'),
            findsOneWidget,
          );
          await tester.tap(find.text('Discard recording').last);
          await settle();
          expect(find.textContaining('Saved recording'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          await tester.pump();
          await pumpDatabaseOperation(tester, db.close);
          messenger.setMockMethodCallHandler(channel, null);
        }
      },
    );
  }
}

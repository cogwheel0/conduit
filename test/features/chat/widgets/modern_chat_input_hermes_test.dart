import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'dart:async';

import 'package:conduit/features/chat/services/voice_input_service.dart';

import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';

import 'dart:ui' show SemanticsAction;

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/features/chat/widgets/recording_contour.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixtureBackend extends Fake implements HermesBackendService {}

class _FixtureConnection extends Notifier<HermesBackendService?> {
  @override
  HermesBackendService? build() => null;
  void change(HermesBackendService? value) => state = value;
}

final _fixtureConnectionProvider =
    NotifierProvider<_FixtureConnection, HermesBackendService?>(
      _FixtureConnection.new,
    );

class _VoiceFixture extends Fake implements VoiceInputService {
  final texts = StreamController<String>.broadcast();
  final startGate = Completer<Stream<String>>();
  bool delayStart = false;
  int stops = 0;
  @override
  final transcribing = ValueNotifier(false);
  @override
  final recordingLevel = ValueNotifier<double>(0);
  Completer<void>? stopGate;
  @override
  Future<bool> initialize({bool forceLocalStt = false}) async => true;
  @override
  Future<Stream<String>> beginListening({
    bool iosAudioSessionManagedExternally = false,
    bool nativeAccumulateResults = true,
    bool holdServerRecorderForResponseWait = false,
  }) async => delayStart ? startGate.future : texts.stream;
  @override
  Future<void> stopListening() async {
    stops++;
    await stopGate?.future;
  }
}

class _ActiveCallFixture extends ChatVoiceModeController {
  @override
  ChatVoiceModeSnapshot build() => const ChatVoiceModeSnapshot(
    phase: ChatVoiceModePhase.listening, isCollapsed: true, intensity: 5,
  );
}

void main() {
  testWidgets('call waveform is passive; expansion belongs to the header', (tester) async {
    await _pumpComposer(tester, mobile: true, capabilities: const HermesCapabilities(), activeCall: true);
    final activity = find.byKey(const ValueKey('hermes-composer-call-activity'));
    expect(activity, findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(ModernChatInput)));
    await tester.tap(activity);
    await tester.pumpAndSettle();
    expect(container.read(chatVoiceModeControllerProvider).isCollapsed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Android composer actions have nonoverlapping 48 dp edge targets',
    (tester) async {
      final voice = _VoiceFixture();
      addTearDown(() async {
        await voice.texts.close();
        voice.transcribing.dispose();
        voice.recordingLevel.dispose();
      });
      await _pumpComposer(
        tester,
        mobile: true,
        capabilities: const HermesCapabilities(),
        voice: voice,
        onFileAttachment: () {},
      );
      final mic = find.byKey(const ValueKey('composer-dictation-start'));
      final plus = find.byKey(const ValueKey('hermes-attachment-menu'));
      final micRect = tester.getRect(mic);
      final plusRect = tester.getRect(plus);
      for (final rect in [micRect, plusRect]) {
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      expect(plusRect.overlaps(micRect), false);
      await tester.tapAt(micRect.topLeft + const Offset(1, 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      final stop = find.byKey(const ValueKey('composer-dictation-stop'));
      expect(stop, findsOneWidget);
      final stopRect = tester.getRect(stop);
      expect(stopRect.size, micRect.size);
      await tester.tapAt(stopRect.bottomRight - const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(voice.stops, 1);
      await tester.enterText(find.byType(TextField), 'Draft');
      await tester.pumpAndSettle();
      final send = tester.getRect(
        find.byKey(const ValueKey('primary-btn-send')),
      );
      expect(send.width, greaterThanOrEqualTo(48));
      expect(send.height, greaterThanOrEqualTo(48));
      expect(send.overlaps(tester.getRect(plus)), false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      'large-text recording has one stop in the original mic slot (mobile=$mobile)',
      (tester) async {
        final voice = _VoiceFixture();
        addTearDown(() async {
          await voice.texts.close();
          voice.transcribing.dispose();
          voice.recordingLevel.dispose();
        });
        await _pumpComposer(
          tester,
          mobile: mobile,
          textScale: 1.6,
          capabilities: const HermesCapabilities(),
          voice: voice,
        );
        final mic = find.byKey(const ValueKey('composer-dictation-start'));
        expect(mic, findsOneWidget);
        final position = tester.getCenter(mic);
        await tester.tap(mic);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        final stop = find.byKey(const ValueKey('composer-dictation-stop'));
        expect(stop, findsOneWidget);
        expect(tester.getCenter(stop), position);
        expect(find.byType(RecordingContourMeter), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(stop);
        await tester.pumpAndSettle();
        expect(voice.stops, 1);
      },
    );
  }

  testWidgets(
    'Contour keeps stop in the mic slot and preserves final dictation',
    (tester) async {
      final voice = _VoiceFixture();
      addTearDown(() async {
        await voice.texts.close();
        voice.transcribing.dispose();
        voice.recordingLevel.dispose();
      });
      await _pumpComposer(
        tester,
        mobile: true,
        capabilities: const HermesCapabilities(),
        voice: voice,
      );
      final mic = find.byKey(const ValueKey('composer-dictation-start'));
      final micPosition = tester.getCenter(mic);
      final editorState = tester.state(find.byType(EditableText));
      await tester.tap(mic);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      final stop = find.byKey(const ValueKey('composer-dictation-stop'));
      expect(tester.getCenter(stop), micPosition);
      expect(find.byKey(const ValueKey('primary-btn-send')), findsNothing);
      expect(find.byType(RecordingContourMeter), findsOneWidget);
      expect(tester.state(find.byType(EditableText)), same(editorState));
      voice.recordingLevel.value = 0.65;
      voice.texts.add(
        'A long recording that should stay in its original slot ' * 12,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getCenter(stop), micPosition);
      expect(
        find.byKey(const ValueKey('compact-composer-shell')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('primary-btn-send')), findsNothing);
      voice.stopGate = Completer<void>();
      await tester.tap(stop);
      await tester.pump();
      expect(voice.stops, 1);
      expect(find.byType(RecordingContourMeter), findsNothing);
      voice.texts.add('Final dictated text');
      await tester.pump();
      voice.stopGate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('composer-dictation-stop')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('primary-btn-send')), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Final dictated text',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final delayed in [false, true]) {
    testWidgets(
      'leaving the chat stops ${delayed ? "pending" : "active"} recording and rejects late text',
      (tester) async {
        final voice = _VoiceFixture()..delayStart = delayed;
        addTearDown(() async {
          voice.transcribing.dispose();
          await voice.texts.close();
        });
        await _pumpComposer(
          tester,
          mobile: true,
          capabilities: const HermesCapabilities(),
          voice: voice,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ModernChatInput)),
        );
        container
            .read(hermesMobileNavigationProvider.notifier)
            .showConversation();
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('composer-dictation-start')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        if (!delayed) {
          expect(
            find.byKey(const ValueKey('composer-dictation-stop')),
            findsOneWidget,
          );
        }
        container
            .read(hermesMobileNavigationProvider.notifier)
            .select(HermesWorkArea.files);
        await tester.pump();
        if (delayed) voice.startGate.complete(voice.texts.stream);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 200));
        expect(voice.stops, greaterThanOrEqualTo(1));
        voice.texts.add('Text from the old recording');
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(
          find.byKey(const ValueKey('composer-dictation-stop')),
          findsNothing,
        );
      },
    );
  }

  test('Hermes overflow follows local attachment availability', () {
    expect(
      shouldShowComposerOverflowButton(
        isHermesComposer: true,
        isDirectComposer: false,
        directSupportsImages: true,
      ),
      isFalse,
    );
    expect(
      shouldShowComposerOverflowButton(
        isHermesComposer: true,
        isDirectComposer: false,
        directSupportsImages: false,
        hermesHasLocalAttachmentActions: true,
      ),
      isTrue,
    );
  });

  testWidgets('Exact slash command ranks before prefix and substring matches', (
    tester,
  ) async {
    await _pumpComposer(
      tester,
      capabilities: const HermesCapabilities(skills: true),
      prompts: const [
        Prompt(command: '/model-info', title: 'AAA', content: '/model-info '),
        Prompt(
          command: '/change-model',
          title: 'BBB',
          content: '/change-model ',
        ),
        Prompt(command: '/model', title: 'ZZZ', content: '/model '),
      ],
    );
    await tester.enterText(find.byType(TextField), '/model');
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('ZZZ')).dy,
      lessThan(tester.getTopLeft(find.text('AAA')).dy),
    );
    expect(
      tester.getTopLeft(find.text('AAA')).dy,
      lessThan(tester.getTopLeft(find.text('BBB')).dy),
    );
  });

  testWidgets('Hermes image capability reveals only local attachment actions', (
    tester,
  ) async {
    var photoCalls = 0;

    await _pumpComposer(
      tester,
      capabilities: const HermesCapabilities(inputImages: true),
      onFileAttachment: () {},
      onImageAttachment: () => photoCalls++,
      onCameraCapture: () {},
      onServerFileAttachment: () {},
      onWebAttachment: () {},
    );

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.contentInsertionConfiguration, isNotNull);
    expect(find.byIcon(Icons.add), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    final sheet = tester.widget<ComposerAttachmentKeyboard>(
      find.byType(ComposerAttachmentKeyboard),
    );
    expect(sheet.localAttachmentsOnly, isTrue);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Files'), findsNothing);
    expect(find.text('Web Page'), findsNothing);
    expect(find.text('Tools'), findsNothing);

    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();
    expect(photoCalls, 1);
  });

  testWidgets('Hermes images fail closed when capability is absent', (
    tester,
  ) async {
    await _pumpComposer(
      tester,
      capabilities: const HermesCapabilities(),
      onImageAttachment: () {},
      onCameraCapture: () {},
    );

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.contentInsertionConfiguration, isNull);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets(
    'Hermes images fail closed while capabilities load but local files remain',
    (tester) async {
      final capabilities = Completer<HermesCapabilities>();

      await _pumpComposer(
        tester,
        pendingCapabilities: capabilities.future,
        onFileAttachment: () {},
        onImageAttachment: () {},
        onCameraCapture: () {},
      );

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.contentInsertionConfiguration, isNull);
      expect(find.byIcon(Icons.add), findsOneWidget);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('File'), findsOneWidget);
      expect(find.text('Photo'), findsNothing);
      expect(find.text('Camera'), findsNothing);

      capabilities.complete(const HermesCapabilities(inputImages: true));
    },
  );

  testWidgets(
    'Android Hermes has one trailing mic that becomes Send after typing',
    (tester) async {
      await _pumpComposer(
        tester,
        mobile: true,
        capabilities: const HermesCapabilities(),
        onFileAttachment: () {},
      );
      expect(
        find.byKey(const ValueKey('composer-dictation-start')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('primary-btn-send')), findsNothing);
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('composer-dictation-start')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('primary-btn-send')), findsOneWidget);
    },
  );

  testWidgets(
    'Android attachment menu opens vertically above Plus and honors capability gates',
    (tester) async {
      var photos = 0;
      await _pumpComposer(
        tester,
        mobile: true,
        capabilities: const HermesCapabilities(inputImages: true),
        onFileAttachment: () {},
        onImageAttachment: () => photos++,
        onCameraCapture: () {},
      );
      // Position the composer at the screen bottom, as in ChatPage.
      final plus = find.byKey(const ValueKey('hermes-attachment-menu'));
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);
      // No video ingest handler exists for Hermes; don't advertise a dead action.
      expect(find.text('Videos'), findsNothing);
      expect(find.text('Files'), findsOneWidget);
      await tester.tap(find.text('Photos'));
      await tester.pumpAndSettle();
      expect(photos, 1);
      expect(find.text('Photos'), findsNothing);
    },
  );

  testWidgets(
    'Android composer keeps separate unsent drafts when switching sessions',
    (tester) async {
      await _pumpComposer(
        tester,
        mobile: true,
        capabilities: const HermesCapabilities(),
        onFileAttachment: () {},
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ModernChatInput)),
      );
      container.read(hermesActiveSessionProvider.notifier).set('one');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'First draft');
      container.read(hermesActiveSessionProvider.notifier).set('two');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      await tester.enterText(find.byType(TextField), 'Second draft');
      container.read(hermesActiveSessionProvider.notifier).set('one');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'First draft',
      );
      container.read(hermesActiveSessionProvider.notifier).set('two');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Second draft',
      );
    },
  );

  testWidgets(
    'Group composer does not consume another chat draft or skill prefill',
    (tester) async {
      await _pumpComposer(
        tester,
        mobile: true,
        capabilities: const HermesCapabilities(),
        draftOwner: 'group:team',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ModernChatInput)),
      );
      await tester.enterText(find.byType(TextField), 'Group draft');
      container.read(hermesActiveSessionProvider.notifier).set('another-chat');
      container
          .read(prefilledInputTextProvider.notifier)
          .set('Pending skill prompt');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Group draft',
      );
      expect(
        container.read(prefilledInputTextProvider),
        'Pending skill prompt',
      );
      expect(
        container.read(hermesMobileDraftsProvider)['group:team'],
        'Group draft',
      );
    },
  );

  testWidgets(
    'Android drafts are cleared across a connection change with reused session ids',
    (tester) async {
      await _pumpComposer(
        tester,
        mobile: true,
        changingConnection: true,
        capabilities: const HermesCapabilities(),
        onFileAttachment: () {},
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ModernChatInput)),
      );
      container.read(hermesActiveSessionProvider.notifier).set('same-id');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Account A draft');
      container
          .read(_fixtureConnectionProvider.notifier)
          .change(_FixtureBackend());
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(
        container.read(hermesMobileDraftsProvider).values,
        isNot(contains('Account A draft')),
      );
      container.read(hermesActiveSessionProvider.notifier).set('other-id');
      await tester.pumpAndSettle();
      container.read(hermesActiveSessionProvider.notifier).set('same-id');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets('Hermes suppresses OpenWebUI context suggestions', (
    tester,
  ) async {
    await _pumpComposer(
      tester,
      capabilities: const HermesCapabilities(inputImages: true),
    );

    await tester.enterText(find.byType(TextField), '#document');
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('prompt-overlay')), findsNothing);
  });

  testWidgets('Desktop local streams keep Stop enabled without running state', (
    tester,
  ) async {
    await _pumpComposer(
      tester,
      capabilities: const HermesCapabilities(),
      desktopGateway: true,
      isStreaming: true,
    );

    final stop = find.byKey(const ValueKey('primary-btn-stop'));
    expect(stop, findsOneWidget);
    expect(
      tester
          .getSemantics(stop)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
  });
}

class _DesktopHermesConfigController extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    mode: HermesBackendMode.desktopGateway,
  );
}

Future<void> _pumpComposer(
  WidgetTester tester, {
  HermesCapabilities? capabilities,
  Future<HermesCapabilities>? pendingCapabilities,
  VoidCallback? onFileAttachment,
  VoidCallback? onServerFileAttachment,
  VoidCallback? onImageAttachment,
  VoidCallback? onCameraCapture,
  VoidCallback? onWebAttachment,
  VoiceInputService? voice,
  bool desktopGateway = false,
  bool mobile = false,
  bool activeCall = false,
  double textScale = 1,
  bool changingConnection = false,
  bool isStreaming = false,
  String? draftOwner,
  List<Prompt> prompts = const [],
}) async {
  assert((capabilities == null) != (pendingCapabilities == null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (activeCall) chatVoiceModeControllerProvider.overrideWith(_ActiveCallFixture.new),
        if (voice != null) voiceInputServiceProvider.overrideWithValue(voice),
        if (voice != null)
          voiceInputAvailableProvider.overrideWith((_) async => true),
        selectedModelProvider.overrideWithValue(hermesSyntheticModel()),
        hermesSkillPromptsProvider.overrideWith((_) async => prompts),
        hermesMobileLayoutProvider.overrideWithValue(mobile),
        if (mobile)
          changingConnection
              ? hermesApiServiceProvider.overrideWith(
                  (ref) => ref.watch(_fixtureConnectionProvider),
                )
              : hermesApiServiceProvider.overrideWithValue(null),
        if (desktopGateway) ...[
          hermesConfigProvider.overrideWith(_DesktopHermesConfigController.new),
          hermesDesktopTurnStateProvider.overrideWith(
            (_) => Stream.value(HermesDesktopTurnState.unsupportedGateway),
          ),
        ],
        isChatStreamingProvider.overrideWithValue(isStreaming),
        hermesCapabilitiesProvider.overrideWith(
          (ref) => pendingCapabilities ?? Future.value(capabilities!),
        ),
        apiServiceProvider.overrideWithValue(null),
        webSearchAvailableProvider.overrideWithValue(true),
        imageGenerationAvailableProvider.overrideWithValue(true),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ModernChatInput(
              draftOwner: draftOwner,
              onSendMessage: (_) {},
              onFileAttachment: onFileAttachment,
              onServerFileAttachment: onServerFileAttachment,
              onImageAttachment: onImageAttachment,
              onCameraCapture: onCameraCapture,
              onWebAttachment: onWebAttachment,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (pendingCapabilities == null) {
    await tester.pumpAndSettle();
  }
}

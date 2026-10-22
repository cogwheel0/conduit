import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/features/hermes/providers/hermes_media.dart';
import 'package:conduit/features/hermes/widgets/hermes_media_attachment.dart';
import 'package:conduit/platform/file_delivery_bridge.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/hermes/models/hermes_media.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_media_service.dart';
import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';

const media = HermesMediaReference(
  path: '/home/person/Conduit/zoey-demo.wav',
  name: 'zoey-demo.wav',
);

class _Audio extends Mock implements AudioPlayer {}

class _Downloads extends FileDeliveryBridge {
  final saved = <String>[];
  final opened = <String>[];
  Completer<String?>? completion;
  @override
  Future<void> openSaved(String uri, String mime) async {
    opened.add(uri);
  }

  List<int>? bytes;
  @override
  Future<String?> save(String path, String name, String mime) async {
    saved.add('$name|$mime');
    bytes = File(path).readAsBytesSync();
    return completion == null
        ? 'content://media/downloads/1'
        : completion!.future;
  }
}

class _Files implements HermesMediaService {
  int reads = 0;
  Completer<void>? wait;
  CancelToken? token;
  void Function(int, int)? reportProgress;
  @override
  Future<void> downloadMedia(
    HermesMediaReference media,
    String destination, {
    String? sessionId,
    String? profile,
    CancelToken? cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    reads++;
    reportProgress = onProgress;
    token = cancelToken;
    if (wait != null) await Future.any([wait!.future, cancelToken!.whenCancel]);
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    File(destination).writeAsBytesSync([82, 73, 70, 70]);
    onProgress?.call(4, 4);
  }
}

// Widget tests keep their fake clock independent of native filesystem events.
// The real lease and binary filesystem path have separate async tests.
class _TestLease extends HermesMediaLease {
  _TestLease(_Files service, Directory directory)
    : _directory = directory,
      super(service, Future.value(directory));
  final Directory _directory;
  Future<File>? _result;
  @override
  Future<File> load(
    HermesMediaReference media, {
    String? sessionId,
    String? profile,
    void Function(int, int)? onProgress,
  }) => _result ??= () async {
    final file = File('${_directory.path}/audio.wav');
    await service.downloadMedia(
      media,
      file.path,
      sessionId: sessionId,
      profile: profile,
      cancelToken: cancel,
      onProgress: onProgress,
    );
    return file;
  }();
  @override
  Future<void> close() async {
    cancel.cancel();
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  HermesMediaLeaseFactory factory,
  _Audio audio,
  _Downloads downloads, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool expanded = false,
  HermesMediaReference reference = media,
  FocusNode? composerFocus,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(null),
        hermesMediaLeaseFactoryProvider.overrideWithValue(factory),
        hermesAudioPlayerFactoryProvider.overrideWithValue(() => audio),
        fileDeliveryBridgeProvider.overrideWithValue(downloads),
      ],
      child: RepaintBoundary(
        key: const ValueKey('media-render'),
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark(TweakcnThemes.conduit)
              : AppTheme.light(TweakcnThemes.conduit),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (composerFocus != null)
                        TextField(focusNode: composerFocus),
                      HermesMediaAttachment(
                        key: const ValueKey('wav'),
                        media: reference,
                        sessionId: 'session-A',
                        expanded: expanded,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(HermesMediaAttachment)),
  );
}

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    registerFallbackValue(Duration.zero);
    const font = String.fromEnvironment('CONDUIT_RENDER_FONT');
    if (font.isNotEmpty) {
      await (FontLoader('Roboto')..addFont(
            Future.value(ByteData.sublistView(await File(font).readAsBytes())),
          ))
          .load();
      const icons = String.fromEnvironment('CONDUIT_RENDER_ICONS');
      if (icons.isNotEmpty) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(
                ByteData.sublistView(await File(icons).readAsBytes()),
              ),
            ))
            .load();
      }
    }
  });
  late Directory root;
  late _Audio audio;
  late _Downloads downloads;
  late _Files files;
  late StreamController<PlayerState> state;
  late StreamController<Duration> position;
  late StreamController<Duration?> duration;
  late HermesMediaLeaseFactory factory;
  final leases = <HermesMediaLease>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('media-widget-');
    audio = _Audio();
    downloads = _Downloads();
    files = _Files();
    state = StreamController.broadcast(sync: true);
    position = StreamController.broadcast(sync: true);
    duration = StreamController.broadcast(sync: true);
    when(() => audio.playerStateStream).thenAnswer((_) => state.stream);
    when(() => audio.positionStream).thenAnswer((_) => position.stream);
    when(() => audio.durationStream).thenAnswer((_) => duration.stream);
    when(() => audio.setFilePath(any()))
        .thenAnswer((_) async => const Duration(milliseconds: 10080));
    when(() => audio.play()).thenAnswer((_) async {
      state.add(PlayerState(true, ProcessingState.ready));
    });
    when(() => audio.pause()).thenAnswer((_) async {
      state.add(PlayerState(false, ProcessingState.ready));
    });
    when(() => audio.seek(any())).thenAnswer((_) async {});
    when(() => audio.dispose()).thenAnswer((_) async {});
    factory = () {
      final lease = _TestLease(files, root.createTempSync('lease-'));
      leases.add(lease);
      return lease;
    };
  });
  tearDown(() async {
    for (final lease in leases) {
      await lease.close();
    }
    leases.clear();
    await state.close();
    await position.close();
    await duration.close();
    await root.delete(recursive: true);
  });

  testWidgets(
    'inline audio is explicit play, seeks, pauses and downloads original once',
    (tester) async {
      await _pump(tester, factory, audio, downloads);
      expect(files.reads, 0);
      verifyNever(() => audio.play());
      await tester.tap(find.byTooltip('Play audio'));
      await _settleIo(tester);
      expect(files.reads, 1);
      verify(() => audio.play()).called(1);
      duration.add(const Duration(milliseconds: 10080));
      position.add(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('0:03'), findsOneWidget);
      expect(find.text('0:10'), findsOneWidget);
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(5000);
      verify(() => audio.seek(const Duration(seconds: 5))).called(1);
      await tester.tap(find.byTooltip('Pause audio'));
      await tester.pump();
      verify(() => audio.pause()).called(1);
      await tester.tap(find.byTooltip('Download zoey-demo.wav'));
      await _settleIo(tester);
      expect(downloads.saved, ['zoey-demo.wav|audio/wav']);
      expect(downloads.bytes, [82, 73, 70, 70]);
      expect(files.reads, 1);
      expect(find.byType(SnackBar), findsNothing);
      await tester.tap(find.byTooltip('Open zoey-demo.wav'));
      await _settleIo(tester);
      expect(downloads.opened, ['content://media/downloads/1']);
      expect(files.reads, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleIo(tester);
      verify(() => audio.dispose()).called(1);
    },
  );

  testWidgets(
    'download progress stays in its control until native save succeeds',
    (tester) async {
      files.wait = Completer<void>();
      downloads.completion = Completer<String?>();
      await _pump(tester, factory, audio, downloads);
      final before = tester.getRect(find.byTooltip('Download zoey-demo.wav'));
      await tester.tap(find.byTooltip('Download zoey-demo.wav'));
      await _settleIo(tester);
      files.reportProgress!(1, 4);
      await tester.pump();
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        .25,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.getRect(find.byTooltip('Cancel file transfer')), before);
      files.wait!.complete();
      await _settleIo(tester);
      expect(find.byTooltip('Open zoey-demo.wav'), findsNothing);
      expect(find.byTooltip('Cancel file transfer'), findsNothing);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        isNull,
      );
      downloads.completion!.complete('content://media/downloads/1');
      await _settleIo(tester);
      expect(tester.getRect(find.byTooltip('Open zoey-demo.wav')), before);
      expect(find.byType(SnackBar), findsNothing);
      await tester.tap(find.byTooltip('Open zoey-demo.wav'));
      await _settleIo(tester);
      expect(downloads.opened, ['content://media/downloads/1']);
      expect(files.reads, 1);
    },
  );

  testWidgets('cancelled transfer and cancelled native save remain retryable', (
    tester,
  ) async {
    files.wait = Completer<void>();
    await _pump(tester, factory, audio, downloads);
    await tester.tap(find.byTooltip('Download zoey-demo.wav'));
    await _settleIo(tester);
    files.reportProgress!(1, -1);
    await tester.pump();
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      isNull,
    );
    await tester.tap(find.byTooltip('Cancel file transfer'));
    await _settleIo(tester);
    expect(files.token!.isCancelled, isTrue);
    expect(find.byTooltip('Download zoey-demo.wav'), findsOneWidget);
    files.wait = null;
    downloads.completion = Completer<String?>();
    await tester.tap(find.byTooltip('Download zoey-demo.wav'));
    await _settleIo(tester);
    downloads.completion!.complete(null);
    await _settleIo(tester);
    expect(find.byTooltip('Download zoey-demo.wav'), findsOneWidget);
    expect(find.byTooltip('Open zoey-demo.wav'), findsNothing);
    expect(find.textContaining('Could not open'), findsNothing);
  });

  testWidgets(
    'failed native save offers download retry without false success',
    (tester) async {
      downloads.completion = Completer<String?>();
      await _pump(tester, factory, audio, downloads);
      await tester.tap(find.byTooltip('Download zoey-demo.wav'));
      await _settleIo(tester);
      downloads.completion!.completeError(StateError('Storage unavailable'));
      await _settleIo(tester);
      expect(find.byTooltip('Open zoey-demo.wav'), findsNothing);
      expect(find.byTooltip('Download zoey-demo.wav'), findsOneWidget);
      expect(
        find.text('Could not save this file. Try downloading it again.'),
        findsOneWidget,
      );
      downloads.completion = null;
      await tester.tap(find.byTooltip('Download zoey-demo.wav'));
      await _settleIo(tester);
      expect(find.byTooltip('Open zoey-demo.wav'), findsOneWidget);
      expect(files.reads, 1);
    },
  );

  testWidgets(
    'closing a file preview does not restore a dismissed composer keyboard',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await _pump(
        tester,
        factory,
        audio,
        downloads,
        reference: const HermesMediaReference(
          path: '/home/person/document.docx',
          name: 'document.docx',
        ),
        composerFocus: focus,
      );
      await tester.showKeyboard(find.byType(TextField));
      tester.testTextInput.hide();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.tap(find.text('document.docx'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Open with'))).pop();
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleIo(tester);
    },
  );

  testWidgets(
    'file title opens the shared preview without an icon-only target',
    (tester) async {
      await _pump(
        tester,
        factory,
        audio,
        downloads,
        reference: const HermesMediaReference(
          path: '/home/person/document.docx',
          name: 'document.docx',
        ),
      );
      await tester.tap(find.byTooltip('Download document.docx'));
      await _settleIo(tester);
      expect(downloads.saved, hasLength(1));
      expect(find.text('Open with'), findsNothing);
      await tester.tap(find.text('document.docx'));
      await tester.pumpAndSettle();
      expect(find.text('Open with'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(files.reads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleIo(tester);
    },
  );

  testWidgets(
    'expanded viewer changes the download control to Open without a saved row',
    (tester) async {
      await _pump(tester, factory, audio, downloads, expanded: true);
      await tester.tap(find.byTooltip('Download zoey-demo.wav'));
      await _settleIo(tester);
      expect(find.text('Saved to Downloads'), findsNothing);
      expect(find.byTooltip('Open zoey-demo.wav'), findsOneWidget);
      expect(find.text('Download again'), findsOneWidget);
      expect(find.text('Saved zoey-demo.wav'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleIo(tester);
    },
  );

  testWidgets(
    'cancel while downloading leaves no stale error and retry works',
    (tester) async {
      files.wait = Completer<void>();
      await _pump(tester, factory, audio, downloads);
      await tester.tap(find.byTooltip('Play audio'));
      await _settleIo(tester);
      await tester.tap(find.byTooltip('Cancel file transfer'));
      await _settleIo(tester);
      expect(files.token!.isCancelled, isTrue);
      expect(find.textContaining('Could not open'), findsNothing);
      files.wait = null;
      await tester.tap(find.byTooltip('Play audio'));
      await _settleIo(tester);
      verify(() => audio.play()).called(1);
      expect(files.reads, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleIo(tester);
    },
  );

  testWidgets(
    'closing attachment during load cancels transport without autoplay',
    (tester) async {
      files.wait = Completer<void>();
      await _pump(tester, factory, audio, downloads);
      await tester.tap(find.byTooltip('Play audio'));
      await _settleIo(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleIo(tester);
      expect(files.token!.isCancelled, isTrue);
      verifyNever(() => audio.play());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'connection changes cancel old bytes and cannot autoplay or save them',
    (tester) async {
      files.wait = Completer<void>();
      final container = await _pump(tester, factory, audio, downloads);
      await tester.tap(find.byTooltip('Play audio'));
      await _settleIo(tester);
      final oldToken = files.token!;
      container.updateOverrides([
        hermesApiServiceProvider.overrideWithValue(null),
        hermesMediaLeaseFactoryProvider.overrideWithValue(null),
        hermesAudioPlayerFactoryProvider.overrideWithValue(() => audio),
        fileDeliveryBridgeProvider.overrideWithValue(downloads),
      ]);
      await _settleIo(tester);
      expect(oldToken.isCancelled, isTrue);
      expect(find.text('Reconnect to open this file.'), findsOneWidget);
      expect(downloads.saved, isEmpty);
      verifyNever(() => audio.play());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleIo(tester);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'audio attachment renders at 200 percent text in ${brightness.name}',
      (tester) async {
        await _pump(
          tester,
          factory,
          audio,
          downloads,
          brightness: brightness,
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byTooltip('Play audio')).shortestSide,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.byTooltip('Download zoey-demo.wav')).shortestSide,
          greaterThanOrEqualTo(48),
        );
        await tester.runAsync(() async {
          final boundary =
              tester
                      .element(find.byKey(const ValueKey('media-render')))
                      .findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('output/media-implementation-20261022');
          directory.createSync(recursive: true);
          File('${directory.path}/audio-${brightness.name}-2x.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(files.reads, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await _settleIo(tester);
      },
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/video_attachment_cache.dart';
import 'package:conduit/features/chat/widgets/enhanced_video_attachment.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Records playback fetches and leaves each one loading until the test
/// completes it.
class _RecordingVideoCache extends VideoAttachmentCache {
  final List<String> fetches = <String>[];
  final List<Completer<File>> pending = <Completer<File>>[];

  @override
  Future<File> fetchForPlayback({
    required VideoDownloadClaim claim,
    required String url,
    required String cacheIdentity,
    required String extension,
    required VideoTransport Function(String url) transport,
    required bool Function() isCurrent,
  }) {
    fetches.add(url);
    final completer = Completer<File>();
    pending.add(completer);
    return completer.future;
  }
}

/// Players that load when the test says so and record what they play.
final class _FakeVideoPlayerPlatform extends VideoPlayerPlatform
    with MockPlatformInterfaceMixin {
  final List<int> played = <int>[];
  final Map<int, StreamController<VideoEvent>> _events = {};
  int _nextId = 0;

  void finishLoading(int playerId) {
    _events[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 5),
        size: const Size(16, 9),
      ),
    );
  }

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextId++;
    _events[playerId] = StreamController<VideoEvent>();
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> play(int playerId) async => played.add(playerId);

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();
}

Widget _harness(_RecordingVideoCache cache, Widget child) {
  return ProviderScope(
    overrides: [
      apiServiceProvider.overrideWithValue(null),
      videoAttachmentCacheProvider.overrideWithValue(cache),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  const clip = 'https://cdn.example.com/out/clip.mp4';

  testWidgets('a video waits for Play before it downloads', (tester) async {
    final cache = _RecordingVideoCache();
    await tester.pumpWidget(
      _harness(
        cache,
        const EnhancedVideoAttachment(
          attachmentId: clip,
          sizeBytes: 3 * 1024 * 1024,
        ),
      ),
    );
    await tester.pump();

    check(cache.fetches).isEmpty();
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.text('3.0 MB'), findsOneWidget);

    final semantics = tester.ensureSemantics();
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();

    check(cache.fetches).deepEquals([clip]);
    // Loading replaces the Play button; another tap starts nothing.
    expect(find.byTooltip('Play'), findsNothing);
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    semantics.dispose();
    await tester.tap(find.text('clip.mp4'));
    await tester.pump();
    check(cache.fetches).deepEquals([clip]);
  });

  testWidgets('tapping the card starts playback', (tester) async {
    final cache = _RecordingVideoCache();
    await tester.pumpWidget(
      _harness(
        cache,
        const EnhancedVideoAttachment(
          attachmentId: clip,
          filenameHint: 'Sunset',
        ),
      ),
    );
    await tester.pump();
    check(cache.fetches).isEmpty();

    await tester.tap(find.text('Sunset'));
    await tester.pump();
    check(cache.fetches).deepEquals([clip]);
  });

  group('once loaded', () {
    late _FakeVideoPlayerPlatform platform;

    setUp(() {
      final previous = VideoPlayerPlatform.instance;
      platform = _FakeVideoPlayerPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
    });

    Future<void> loadAfterTap(
      WidgetTester tester, {
      VoidCallback? whileLoading,
    }) async {
      final cache = _RecordingVideoCache();
      await tester.pumpWidget(
        _harness(cache, const EnhancedVideoAttachment(attachmentId: clip)),
      );
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      whileLoading?.call();
      cache.pending.single.complete(File('${Directory.systemTemp.path}/c.mp4'));
      await tester.pump();
      platform.finishLoading(0);
      await tester.pump();
      expect(find.byType(VideoPlayer), findsOneWidget);
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets('the video plays once it loads', (tester) async {
      await loadAfterTap(tester);
      check(platform.played).deepEquals([0]);
      await unmount(tester);
    });

    testWidgets('a video that loads while the app is inactive waits', (
      tester,
    ) async {
      await loadAfterTap(
        tester,
        whileLoading: () {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          addTearDown(
            () => tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            ),
          );
        },
      );
      check(platform.played).isEmpty();
      await unmount(tester);
    });
  });
}

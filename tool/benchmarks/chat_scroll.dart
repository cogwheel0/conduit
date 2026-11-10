// Run with: flutter run --profile -t tool/benchmarks/chat_scroll.dart
// Uses only synthetic content and never connects to a backend.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/chat/widgets/chat_timeline_viewport.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/platform/flutter_worker_port.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:conduit_core/database/models/chat_transcript_window.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  runApp(
    ProviderScope(
      overrides: [
        workerPortProvider.overrideWithValue(const FlutterWorkerPort()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.conduit),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _ScrollBenchmark(),
      ),
    ),
  );
}

class _ScrollBenchmark extends StatefulWidget {
  const _ScrollBenchmark();
  @override
  State<_ScrollBenchmark> createState() => _ScrollBenchmarkState();
}

class _ScrollBenchmarkState extends State<_ScrollBenchmark> {
  final _controller = ChatTimelineViewportController();
  final _viewportKey = GlobalKey();
  final _frames = <FrameTiming>[];
  List<String> _ids = [];
  List<String> _text = [];
  int _estimates = 0;
  int _rowsBuilt = 0;
  bool _recording = false;
  String _phase = 'Preparing synthetic history';

  static String _message(int i) => switch (i % 4) {
    0 => '### Message $i\n\nA blue square has four equal sides.',
    1 =>
      '### Message $i\n\n${List.generate(30, (j) => '- Synthetic item ${j + 1}: an orange triangle.').join('\n')}',
    2 =>
      '### Message $i\n\n```text\n${List.generate(20, (j) => 'sample[$j] = ${j * 3}').join('\n')}\n```',
    _ =>
      '### Message $i\n\n${List.filled(6, 'A green circle sits beside a purple rectangle. **Shapes** have different sizes.\n\n').join()}',
  };

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_record);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  void _record(List<FrameTiming> frames) {
    if (_recording) _frames.addAll(frames);
  }

  ScrollPosition get _position {
    ScrollPosition? result;
    void visit(Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        result ??= (element.state as ScrollableState).position;
      }
      element.visitChildren(visit);
    }

    (_viewportKey.currentContext! as Element).visitChildren(visit);
    return result!;
  }

  static Map<String, Object> _summary(List<double> values) {
    values.sort();
    if (values.isEmpty) return {'samples': 0};
    double p(double q) => values[(values.length * q).ceil() - 1];
    return {
      'samples': values.length,
      'p50': p(.5),
      'p95': p(.95),
      'p99': p(.99),
      'max': values.last,
    };
  }

  Future<void> _scroll() async {
    final position = _position;
    final start = position.pixels;
    await position.animateTo(
      start + position.viewportDimension * 20,
      duration: const Duration(seconds: 6),
      curve: Curves.linear,
    );
    await position.animateTo(
      start,
      duration: const Duration(seconds: 6),
      curve: Curves.linear,
    );
  }

  Future<void> _run() async {
    try {
      for (final count in [1000, 10000]) {
        setState(() {
          _ids = List.generate(count, (i) => 'synthetic-$count-$i');
          _text = List.generate(count, _message);
        });
        await Future<void>.delayed(const Duration(seconds: 2));
        for (final pass in ['cold', 'warm']) {
          setState(() => _phase = '$count messages · $pass scroll');
          await Future<void>.delayed(const Duration(milliseconds: 500));
          _frames.clear();
          _estimates = 0;
          _rowsBuilt = 0;
          _recording = true;
          await _scroll();
          // FrameTiming arrives in batches; drain the final batch before reporting.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          _recording = false;
          final report = {
            'phase': '$count-$pass',
            'buildMs': _summary(
              _frames
                  .map((f) => f.buildDuration.inMicroseconds / 1000)
                  .toList(),
            ),
            'rasterMs': _summary(
              _frames
                  .map((f) => f.rasterDuration.inMicroseconds / 1000)
                  .toList(),
            ),
            'over16ms': _frames
                .where(
                  (f) =>
                      f.buildDuration.inMicroseconds > 16667 ||
                      f.rasterDuration.inMicroseconds > 16667,
                )
                .length,
            'estimates': _estimates,
            'rowsBuilt': _rowsBuilt,
            'rssBytes': ProcessInfo.currentRss,
          };
          // Structured output consumed by the benchmark runner.
          // ignore: avoid_print
          print('CHAT_SCROLL_RESULT ${jsonEncode(report)}');
        }
      }
      setState(() => _phase = 'Synthetic chat · 10,000 messages');
      // ignore: avoid_print
      print('CHAT_SCROLL_DONE');
    } catch (error, stack) {
      // ignore: avoid_print
      print('CHAT_SCROLL_ERROR $error\n$stack');
      // A runner that only waits for the process must see the failure too.
      exit(1);
    }
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_record);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: AppBar(title: Text(_phase)),
      body: ChatTimelineViewport(
        key: _viewportKey,
        controller: _controller,
        ownerGeneration: _ids.length,
        messageIds: _ids,
        rowRebuildKeys: _ids,
        initialAnchor: _ids.isEmpty
            ? null
            : ChatScrollAnchor(
                messageId: _ids[_ids.length ~/ 2],
                offsetWithinMessage: 0,
              ),
        estimateRowExtent: (index) {
          _estimates++;
          return estimateChatRowExtent(
            text: _text[index],
            viewportWidth: viewportWidth,
          );
        },
        rowBuilder: (context, index) {
          _rowsBuilt++;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: StreamingMarkdownWidget(
              key: ValueKey(_ids[index]),
              stateScopeId: _ids[index],
              content: _text[index],
              isStreaming: false,
            ),
          );
        },
        topContentInset: 16,
        bottomPadding: 24,
        horizontalPadding: 16,
        cacheExtent: 600,
        physics: const ClampingScrollPhysics(),
        maintainVisibleAnchor: false,
        followLatest: false,
        pinAutomatic: false,
        onPointerDown: () {},
        onUserDragStart: () {},
        onUserDragEnd: () {},
        onMetricsChanged: (_) {},
        onPinEndSpaceChanged: (_) {},
        onTrailingRefresh: () async {},
        onNativeScrollToTop: () async {},
      ),
    );
  }
}

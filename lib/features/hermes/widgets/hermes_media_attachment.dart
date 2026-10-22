import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/hermes/models/hermes_media.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../platform/file_delivery_bridge.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart'
    show showCompactConfigurationSheet;
import '../providers/hermes_media.dart';
import '../providers/hermes_mobile_navigation.dart';

final hermesAudioPlayerFactoryProvider = Provider<AudioPlayer Function()>(
  (ref) => AudioPlayer.new,
);

Future<void> showHermesMedia(
  BuildContext context,
  HermesMediaReference media, {
  String? sessionId,
  String? profile,
  bool download = false,
}) {
  // A hidden IME can still leave the composer focused. Do not restore that
  // focus (and reopen its keyboard) when the media sheet is dismissed.
  FocusManager.instance.primaryFocus?.unfocus();
  FocusManager.instance.applyFocusChangesIfNeeded();
  return showCompactConfigurationSheet<void>(
    context,
    (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: HermesMediaAttachment(
        media: media,
        sessionId: sessionId,
        profile: profile,
        expanded: true,
        downloadOnOpen: download,
      ),
    ),
  );
}

/// This widget owns playback ticks and transfer progress. Neither publishes
/// updates into chat state or rebuilds the transcript on every playback tick.
class HermesMediaAttachment extends ConsumerStatefulWidget {
  const HermesMediaAttachment({
    super.key,
    required this.media,
    this.sessionId,
    this.profile,
    this.expanded = false,
    this.downloadOnOpen = false,
  });
  final HermesMediaReference media;
  final String? sessionId;
  final String? profile;
  final bool expanded;
  final bool downloadOnOpen;

  @override
  ConsumerState<HermesMediaAttachment> createState() =>
      _HermesMediaAttachmentState();
}

class _HermesMediaAttachmentState extends ConsumerState<HermesMediaAttachment>
    with WidgetsBindingObserver {
  late final HermesMediaLeaseFactory? _owner;
  HermesMediaLease? _lease;
  AudioPlayer? _audio;
  VideoPlayerController? _video;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  File? _file;
  String? _text;
  String? _error;
  String? _savedUri;
  bool _loading = false;
  bool _saving = false;
  bool _openingSaved = false;
  bool _playing = false;
  bool _completed = false;
  bool _valid = true;
  int _generation = 0;
  double? _progress;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  bool get _current =>
      mounted &&
      _valid &&
      identical(ref.read(hermesMediaLeaseFactoryProvider), _owner);

  @override
  void initState() {
    super.initState();
    _owner = ref.read(hermesMediaLeaseFactoryProvider);
    WidgetsBinding.instance.addObserver(this);
    if (widget.downloadOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_save());
      });
    } else if (widget.expanded &&
        const {
          HermesMediaKind.image,
          HermesMediaKind.pdf,
          HermesMediaKind.text,
          HermesMediaKind.video,
        }.contains(widget.media.kind)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_prepare());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _pause();
  }

  void _pause() {
    unawaited(_audio?.pause());
    unawaited(_video?.pause());
  }

  Future<File> _load() async {
    if (!_current || _owner == null) {
      throw StateError('Reconnect to Hermes to open this file.');
    }
    if (_file != null) return _file!;
    _lease ??= _owner();
    final lease = _lease!;
    final file = await lease.load(
      widget.media,
      sessionId: widget.sessionId,
      profile: widget.profile,
      onProgress: (received, total) {
        if (_current && identical(lease, _lease)) {
          setState(() => _progress = total > 0 ? received / total : null);
        }
      },
    );
    if (!_current || !identical(lease, _lease)) {
      throw StateError('The file connection changed.');
    }
    return _file = file;
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool saving = false,
  }) async {
    if (!_current || _loading || _saving) return;
    final generation = _generation;
    setState(() {
      _error = null;
      _progress = null;
      if (saving) {
        _saving = true;
      } else {
        _loading = true;
      }
    });
    try {
      await action();
    } catch (error) {
      if (_current && generation == _generation) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : saving
              ? 'Could not save this file. Try downloading it again.'
              : 'Could not open this file. Try again, or download it to use another app.',
        );
      }
    } finally {
      if (_current && generation == _generation) {
        setState(() {
          _loading = false;
          _saving = false;
        });
      }
    }
  }

  Future<void> _prepare() => _run(() async {
    final file = await _load();
    if (widget.media.kind == HermesMediaKind.text) {
      final handle = await file.open();
      try {
        _text = utf8.decode(await handle.read(100000), allowMalformed: true);
      } finally {
        await handle.close();
      }
    } else if (widget.media.kind == HermesMediaKind.video) {
      final video = VideoPlayerController.file(file);
      _video = video;
      await video.initialize();
      if (!_current) return;
      video.addListener(_videoChanged);
    }
  });

  void _videoChanged() {
    if (_current) setState(() {});
  }

  Future<void> _toggleAudio() async {
    if (_audio != null && !_completed) {
      if (_playing) {
        await _audio!.pause();
      } else {
        unawaited(_audio!.play());
      }
      return;
    }
    await _run(() async {
      final file = await _load();
      if (_audio == null) {
        final player = ref.read(hermesAudioPlayerFactoryProvider)();
        _audio = player;
        _subscriptions.add(
          player.playerStateStream.listen((value) {
            if (_current) {
              setState(() {
                _completed = value.processingState == ProcessingState.completed;
                _playing = value.playing && !_completed;
              });
            }
          }),
        );
        _subscriptions.add(
          player.positionStream.listen((value) {
            if (_current) setState(() => _position = value);
          }),
        );
        _subscriptions.add(
          player.durationStream.listen((value) {
            if (_current) setState(() => _duration = value ?? Duration.zero);
          }),
        );
        await player.setFilePath(file.path);
      }
      if (!_current) return;
      if (_completed) await _audio!.seek(Duration.zero);
      unawaited(
        _audio!.play().catchError((Object _) {
          if (_current) {
            setState(
              () => _error =
                  'Audio playback failed. Download to open it in another app.',
            );
          }
        }),
      );
    });
  }

  Future<void> _save() => _run(() async {
    final delivery = ref.read(fileDeliveryBridgeProvider);
    final file = await _load();
    if (!_current) return;
    // The network transfer is complete; publishing to Downloads is a separate
    // operation with no byte progress. Do not show success before it resolves.
    setState(() => _progress = null);
    final lease = _lease!;
    lease.retainForExport();
    final String? uri;
    try {
      uri = await delivery.save(
        file.path,
        widget.media.name,
        widget.media.mimeType,
      );
    } finally {
      lease.releaseExport();
    }
    if (_current && uri != null) {
      setState(() => _savedUri = uri);
    }
  }, saving: true);

  Future<void> _openSaved() async {
    if (_loading || _saving) return;
    _openingSaved = true;
    try {
      await _run(() async {
        try {
          await ref
              .read(fileDeliveryBridgeProvider)
              .openSaved(_savedUri!, widget.media.mimeType);
        } catch (_) {
          throw const FormatException(
            'Could not open the saved file. Try again, or choose Open with in its preview.',
          );
        }
      });
    } finally {
      _openingSaved = false;
    }
  }

  Future<void> _open() => _run(() async {
    final file = await _load();
    if (_current) {
      final lease = _lease!;
      lease.retainForExport();
      try {
        await ref
            .read(fileDeliveryBridgeProvider)
            .open(file.path, widget.media.mimeType, name: widget.media.name);
      } finally {
        lease.releaseExport();
      }
    }
  });

  Future<void> _share() => _run(() async {
    final file = await _load();
    if (_current) {
      final lease = _lease!;
      lease.retainForExport();
      try {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: widget.media.mimeType)],
            fileNameOverrides: [widget.media.name],
          ),
        );
      } finally {
        lease.releaseExport();
      }
    }
  });

  void _cancel() {
    _generation++;
    final lease = _lease;
    _lease = null;
    // Invalidate this operation before its cancellation completion can publish.
    if (lease != null) unawaited(lease.close());
    if (_current) {
      setState(() {
        _loading = false;
        _saving = false;
        _progress = null;
      });
    }
    // A cancelled transfer cannot be reused; retry creates a fresh lease.
  }

  @override
  void dispose() {
    _valid = false;
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    final audio = _audio;
    final video = _video;
    unawaited(() async {
      await audio?.dispose();
      video?.removeListener(_videoChanged);
      await video?.dispose();
      await _lease?.close();
    }());
    super.dispose();
  }

  String _time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _button(IconData icon, String label, VoidCallback? action) =>
      IconButton(
        tooltip: label,
        onPressed: action,
        icon: Icon(icon, size: 22),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      );

  Widget _downloadControl(bool busy) {
    if (!_saving) {
      return Semantics(
        liveRegion: true,
        child: _button(
          _savedUri == null ? Icons.download_outlined : Icons.open_in_new,
          '${_savedUri == null ? 'Download' : 'Open'} ${widget.media.name}',
          busy || _owner == null
              ? null
              : _savedUri == null
              ? _save
              : _openSaved,
        ),
      );
    }
    final cancellable = _file == null;
    final value = _progress?.clamp(0.0, 1.0);
    return Semantics(
      label: 'Saving ${widget.media.name} to Downloads',
      value: value == null ? null : '${(value * 100).round()}%',
      child: IconButton(
        tooltip: cancellable ? 'Cancel file transfer' : 'Saving to Downloads',
        onPressed: cancellable ? _cancel : null,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: SizedBox.square(
          dimension: 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CircularProgressIndicator(
                  value: value,
                  strokeWidth: 2,
                  color: Theme.of(context).colorScheme.primary,
                  backgroundColor: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              if (cancellable) const Icon(Icons.close, size: 13),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(hermesMediaLeaseFactoryProvider);
    ref.listen(hermesMobileNavigationProvider, (previous, next) {
      if (previous != null &&
          (previous.area != next.area ||
              previous.conversation != next.conversation)) {
        _pause();
      }
    });
    if (!identical(live, _owner)) {
      _valid = false;
      _pause();
      _cancel();
      return const Text('Reconnect to open this file.');
    }
    final audio = widget.media.kind == HermesMediaKind.audio;
    final busy = _loading || _saving;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (audio)
              _button(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                _playing ? 'Pause audio' : 'Play audio',
                busy || _owner == null ? null : _toggleAudio,
              )
            else
              const SizedBox(
                width: 48,
                height: 48,
                child: Icon(Icons.insert_drive_file_outlined, size: 22),
              ),
            Expanded(
              child: Text(
                widget.media.name,
                maxLines: widget.expanded ? 3 : 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            _downloadControl(busy),
          ],
        ),
        if (_loading && !_openingSaved)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(child: LinearProgressIndicator(value: _progress)),
                if (_file == null)
                  _button(Icons.close, 'Cancel file transfer', _cancel),
              ],
            ),
          ),
        if (audio)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              children: [
                Slider(
                  value: _position.inMilliseconds.toDouble().clamp(
                    0,
                    _duration.inMilliseconds.toDouble(),
                  ),
                  max: _duration.inMilliseconds > 0
                      ? _duration.inMilliseconds.toDouble()
                      : 1,
                  semanticFormatterCallback: (value) =>
                      _time(Duration(milliseconds: value.round())),
                  onChanged: _audio != null && _duration > Duration.zero
                      ? (value) =>
                            _audio!.seek(Duration(milliseconds: value.round()))
                      : null,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(_time(_position)), Text(_time(_duration))],
                ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        if (widget.expanded) ...[
          if (_file != null) _preview(),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: busy ? null : _open,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open with'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : _share,
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Share'),
                ),
                if (_savedUri != null)
                  TextButton.icon(
                    onPressed: busy ? null : _save,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Download again'),
                  ),
                if (_error != null)
                  TextButton(
                    onPressed: busy ? null : _prepare,
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
    final box = Container(
      constraints: BoxConstraints(
        maxWidth: widget.expanded ? double.infinity : 340,
      ),
      decoration: BoxDecoration(
        color: context.conduitTheme.cardBackground,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: content,
    );
    return widget.expanded
        ? SingleChildScrollView(padding: const EdgeInsets.all(16), child: box)
        : audio
        ? box
        : ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Material(
              color: context.conduitTheme.cardBackground,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _owner == null
                    ? null
                    : () => showHermesMedia(
                        context,
                        widget.media,
                        sessionId: widget.sessionId,
                        profile: widget.profile,
                      ),
                child: content,
              ),
            ),
          );
  }

  Widget _preview() {
    switch (widget.media.kind) {
      case HermesMediaKind.image:
        return SizedBox(
          height: 300,
          child: InteractiveViewer(
            child: Image.file(
              _file!,
              fit: BoxFit.contain,
              cacheWidth: 1440,
              errorBuilder: (_, _, _) => const Center(
                child: Text(
                  'Preview unavailable. Download or open with another app.',
                ),
              ),
            ),
          ),
        );
      case HermesMediaKind.pdf:
        return SizedBox(height: 420, child: PdfViewer.file(_file!.path));
      case HermesMediaKind.text:
        return Padding(
          padding: const EdgeInsets.all(12),
          child: const {'md', 'markdown'}.contains(widget.media.extension)
              ? StreamingMarkdownWidget(
                  content: _text ?? '',
                  isStreaming: false,
                  enableTextSelection: true,
                )
              : SelectableText(_text ?? ''),
        );
      case HermesMediaKind.video:
        final video = _video;
        if (video == null || !video.value.isInitialized) {
          return const SizedBox.shrink();
        }
        return Column(
          children: [
            AspectRatio(
              aspectRatio: video.value.aspectRatio,
              child: VideoPlayer(video),
            ),
            Row(
              children: [
                _button(
                  video.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  video.value.isPlaying ? 'Pause video' : 'Play video',
                  () => video.value.isPlaying ? video.pause() : video.play(),
                ),
                Expanded(
                  child: VideoProgressIndicator(
                    video,
                    allowScrubbing: true,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
              ],
            ),
          ],
        );
      case HermesMediaKind.audio:
      case HermesMediaKind.file:
        return const SizedBox.shrink();
    }
  }
}

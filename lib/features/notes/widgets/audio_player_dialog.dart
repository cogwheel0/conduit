import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/services/api_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/themed_dialogs.dart';

/// A dialog for playing audio files.
class AudioPlayerDialog extends StatefulWidget {
  /// The file ID for downloading.
  final String? fileId;

  /// The API service for authenticated requests.
  final ApiService? api;

  /// Durable local source. Unlike a downloaded [_tempFile], this is never
  /// deleted by the player dialog.
  final String? localFilePath;

  /// The file name to display.
  final String fileName;

  const AudioPlayerDialog({
    super.key,
    this.fileId,
    this.api,
    this.localFilePath,
    required this.fileName,
  }) : assert(
         localFilePath != null || (fileId != null && api != null),
         'A local path or a server file id and API service is required',
       );

  /// Shows the audio player dialog.
  static Future<void> show(
    BuildContext context, {
    required String fileId,
    required ApiService api,
    required String fileName,
  }) {
    return ThemedDialogs.showCustom<void>(
      context: context,
      builder: (context) =>
          AudioPlayerDialog(fileId: fileId, api: api, fileName: fileName),
    );
  }

  /// Plays a durable local recording without taking ownership of the file.
  static Future<void> showLocal(
    BuildContext context, {
    required String filePath,
    required String fileName,
  }) {
    return ThemedDialogs.showCustom<void>(
      context: context,
      builder: (context) =>
          AudioPlayerDialog(localFilePath: filePath, fileName: fileName),
    );
  }

  @override
  State<AudioPlayerDialog> createState() => _AudioPlayerDialogState();
}

class _AudioPlayerDialogState extends State<AudioPlayerDialog> {
  final AudioPlayer _player = AudioPlayer();

  bool _isPlaying = false;
  bool _isLoading = true;
  bool _hasError = false;
  bool _isDisposed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  File? _tempFile;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

  @override
  void initState() {
    super.initState();
    _setupPlayer();
  }

  Future<void> _setupPlayer() async {
    try {
      final playablePath = widget.localFilePath ?? await _downloadRemoteFile();
      if (_isDisposed) {
        await _deleteOwnedTempFile();
        return;
      }
      if (!await File(playablePath).exists()) {
        throw StateError('Audio file is missing');
      }
      if (_isDisposed) {
        await _deleteOwnedTempFile();
        return;
      }

      // Setup player state listeners
      _stateSub = _player.playerStateStream.listen((state) {
        if (!mounted) return;
        setState(() {
          _isPlaying = state.playing;
          if (state.processingState == ProcessingState.completed) {
            _isPlaying = false;
            _position = _duration;
          }
        });
      });

      _positionSub = _player.positionStream.listen((pos) {
        if (!mounted) return;
        setState(() => _position = pos);
      });

      _durationSub = _player.durationStream.listen((dur) {
        if (!mounted) return;
        if (dur != null) {
          setState(() {
            _duration = dur;
            _isLoading = false;
          });
        }
      });

      // Load and play the file
      await _player.setFilePath(playablePath);
      if (_isDisposed) return;

      if (mounted) {
        setState(() => _isLoading = false);
      }

      await _player.play();
    } catch (error, stackTrace) {
      await _deleteOwnedTempFile();
      if (_isDisposed) return;
      DebugLogger.error(
        'audio-load-failed',
        scope: 'notes/audio/player',
        error: error,
        stackTrace: stackTrace,
        data: {'local': widget.localFilePath != null},
      );
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
    }
  }

  Future<String> _downloadRemoteFile() async {
    final api = widget.api;
    final fileId = widget.fileId;
    if (api == null || fileId == null) {
      throw StateError('Server audio source is unavailable');
    }

    final fileInfo = await api.getFileInfo(fileId);
    if (_isDisposed) throw StateError('Audio player was disposed');
    final filename = fileInfo['filename'] as String? ?? 'audio.m4a';
    final extension = filename.contains('.')
        ? filename.substring(filename.lastIndexOf('.'))
        : '.m4a';

    final tempDir = await getTemporaryDirectory();
    if (_isDisposed) throw StateError('Audio player was disposed');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tempPath = '${tempDir.path}/audio_${fileId}_$timestamp$extension';
    final tempFile = File(tempPath);
    _tempFile = tempFile;

    final response = await api.dio.get(
      '/api/v1/files/$fileId/content',
      options: Options(responseType: ResponseType.bytes),
    );
    final responseData = response.data;
    if (responseData is! List<int>) {
      throw StateError(
        'Unexpected audio response type: ${responseData.runtimeType}',
      );
    }
    if (_isDisposed) {
      await _deleteTemporaryFile(tempFile);
      throw StateError('Audio player was disposed');
    }
    await tempFile.writeAsBytes(responseData, flush: true);
    if (_isDisposed) {
      await _deleteTemporaryFile(tempFile);
      throw StateError('Audio player was disposed');
    }
    DebugLogger.log(
      'audio-download-ready',
      scope: 'notes/audio/player',
      data: {'bytes': responseData.length},
    );
    return tempPath;
  }

  Future<void> _deleteOwnedTempFile() async {
    final tempFile = _tempFile;
    _tempFile = null;
    if (tempFile == null) return;
    await _deleteTemporaryFile(tempFile);
  }

  Future<void> _deleteTemporaryFile(File tempFile) async {
    try {
      if (await tempFile.exists()) await tempFile.delete();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'audio-temp-cleanup-failed',
        scope: 'notes/audio/player',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await _player.pause();
    } else {
      // If at end, restart from beginning
      if (_position >= _duration && _duration > Duration.zero) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  Future<void> _seekTo(double value) async {
    final position = Duration(
      milliseconds: (value * _duration.inMilliseconds).round(),
    );
    await _player.seek(position);
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _isDisposed = true;
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    // AudioPlayer.dispose() is async but Flutter's dispose() is sync.
    // Fire-and-forget is acceptable here as just_audio handles cleanup internally.
    unawaited(_player.dispose());
    // Only remote downloads are owned by this dialog. A durable local pending
    // recording remains available for playback, retry, and export.
    unawaited(_deleteOwnedTempFile());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Dialog(
      backgroundColor: theme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppBorderRadius.md),
                  ),
                  child: Icon(
                    Platform.isIOS
                        ? CupertinoIcons.waveform
                        : Icons.audio_file_rounded,
                    color: Colors.orange,
                    size: IconSize.lg,
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.fileName,
                        style: AppTypography.bodyMediumStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        l10n.audioAttachment,
                        style: AppTypography.captionStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                    color: theme.textSecondary,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),

            const SizedBox(height: Spacing.xl),

            // Error state
            if (_hasError)
              Column(
                children: [
                  Icon(
                    Platform.isIOS
                        ? CupertinoIcons.exclamationmark_circle
                        : Icons.error_outline,
                    color: theme.error,
                    size: 48,
                  ),
                  const SizedBox(height: Spacing.md),
                  Text(
                    l10n.failedToLoadAudio,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.error,
                    ),
                  ),
                ],
              )
            // Loading state
            else if (_isLoading)
              Column(
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation(theme.buttonPrimary),
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  Text(
                    l10n.loadingAudio,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
              )
            // Player controls
            else ...[
              // Progress slider
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  activeTrackColor: Colors.orange,
                  inactiveTrackColor: theme.surfaceContainerHighest,
                  thumbColor: Colors.orange,
                  overlayColor: Colors.orange.withValues(alpha: 0.2),
                ),
                child: AdaptiveSlider(value: progress, onChanged: _seekTo),
              ),

              // Time display
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(_position),
                      style: AppTypography.captionStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                    Text(
                      _formatDuration(_duration),
                      style: AppTypography.captionStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: Spacing.md),

              // Play/Pause button
              GestureDetector(
                onTap: _togglePlayPause,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.orange,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.orange.withValues(alpha: 0.3),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(
                    _isPlaying
                        ? (Platform.isIOS
                              ? CupertinoIcons.pause_fill
                              : Icons.pause_rounded)
                        : (Platform.isIOS
                              ? CupertinoIcons.play_fill
                              : Icons.play_arrow_rounded),
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

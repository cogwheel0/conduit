import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/services/api_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// A dialog for playing audio files.
class AudioPlayerDialog extends StatefulWidget {
  /// The file ID for downloading.
  final String fileId;

  /// The API service for authenticated requests.
  final ApiService api;

  /// The file name to display.
  final String fileName;

  const AudioPlayerDialog({
    super.key,
    required this.fileId,
    required this.api,
    required this.fileName,
  });

  /// Shows the audio player dialog.
  static Future<void> show(
    BuildContext context, {
    required String fileId,
    required ApiService api,
    required String fileName,
  }) {
    return showDialog(
      context: context,
      builder: (context) => AudioPlayerDialog(
        fileId: fileId,
        api: api,
        fileName: fileName,
      ),
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
      // Get file info first to determine the correct extension
      final fileInfo = await widget.api.getFileInfo(widget.fileId);
      final filename = fileInfo['filename'] as String? ?? 'audio.m4a';
      final contentType = (fileInfo['meta'] as Map<String, dynamic>?)?['content_type'] as String?;
      
      debugPrint('AudioPlayerDialog: filename=$filename, contentType=$contentType');
      debugPrint('AudioPlayerDialog: fileInfo=$fileInfo');
      
      // Extract extension from filename
      final extension = filename.contains('.') 
          ? filename.substring(filename.lastIndexOf('.'))
          : '.m4a';

      // Download the file (requires authentication)
      // Use timestamp suffix to prevent conflicts if same file opened multiple times
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempPath = '${tempDir.path}/audio_${widget.fileId}_$timestamp$extension';
      _tempFile = File(tempPath);

      // Fetch file content through API (authenticated)
      final response = await widget.api.dio.get(
        '/api/v1/files/${widget.fileId}/content',
        options: Options(responseType: ResponseType.bytes),
      );

      final responseData = response.data;
      if (responseData is! List<int>) {
        throw Exception('Unexpected response type: ${responseData.runtimeType}');
      }
      final bytes = responseData;
      debugPrint('AudioPlayerDialog: Downloaded ${bytes.length} bytes');
      debugPrint('AudioPlayerDialog: First 20 bytes: ${bytes.take(20).toList()}');
      debugPrint('AudioPlayerDialog: Response content-type: ${response.headers.value('content-type')}');
      
      await _tempFile!.writeAsBytes(bytes);
      debugPrint('AudioPlayerDialog: Saved to $tempPath');

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
      await _player.setFilePath(_tempFile!.path);
      
      if (mounted) {
        setState(() => _isLoading = false);
      }
      
      await _player.play();
    } catch (e) {
      debugPrint('AudioPlayerDialog: Error loading audio: $e');
      // Clean up temp file on error to avoid orphaned files
      _tempFile?.delete().then((_) {
        debugPrint('AudioPlayerDialog: Cleaned up temp file after error');
      }).catchError((e) {
        debugPrint('AudioPlayerDialog: Failed to clean up temp file after error: $e');
      });
      _tempFile = null;
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
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
    final position = Duration(milliseconds: (value * _duration.inMilliseconds).round());
    await _player.seek(position);
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    // AudioPlayer.dispose() is async but Flutter's dispose() is sync.
    // Fire-and-forget is acceptable here as just_audio handles cleanup internally.
    unawaited(_player.dispose());
    // Clean up temp file (fire and forget, log errors for debugging)
    _tempFile?.delete().then((_) {
      debugPrint('AudioPlayerDialog: Cleaned up temp file');
    }).catchError((e) {
      debugPrint('AudioPlayerDialog: Failed to clean up temp file: $e');
    });
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
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  activeTrackColor: Colors.orange,
                  inactiveTrackColor: theme.surfaceContainerHighest,
                  thumbColor: Colors.orange,
                  overlayColor: Colors.orange.withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: progress,
                  onChanged: _seekTo,
                ),
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

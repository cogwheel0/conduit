import 'dart:async';
import 'dart:io';
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:record/record.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../services/audio_recording_service.dart';

/// Full-screen overlay for audio recording in notes.
///
/// Shows recording visualization, duration, and controls to confirm or cancel.
/// The recorded audio is returned as a file for upload to the server.
class AudioRecordingOverlay extends StatefulWidget {
  /// Called when the user cancels recording.
  final VoidCallback onCancel;

  /// Called when the user confirms the recording with the audio file.
  final void Function(File audioFile) onConfirm;

  const AudioRecordingOverlay({
    super.key,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  State<AudioRecordingOverlay> createState() => _AudioRecordingOverlayState();
}

class _AudioRecordingOverlayState extends State<AudioRecordingOverlay>
    with SingleTickerProviderStateMixin {
  final AudioRecordingService _recordingService = AudioRecordingService();

  bool _isRecording = false;
  bool _isProcessing = false;
  bool _hasError = false;
  Duration _duration = Duration.zero;
  double _amplitude = 0.0;

  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Amplitude>? _amplitudeSub;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    // Pulse animation for the recording indicator
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);

    _startRecording();
  }

  Future<void> _startRecording() async {
    try {
      await _recordingService.startRecording();

      if (!mounted) return;
      setState(() => _isRecording = true);
      HapticFeedback.heavyImpact();

      // Set up stream listeners only if still mounted.
      // Each callback also checks mounted to handle rapid disposal.
      if (!mounted) return;

      _durationSub = _recordingService.durationStream.listen((duration) {
        if (mounted) setState(() => _duration = duration);
      });

      _amplitudeSub = _recordingService.amplitudeStream.listen((amp) {
        if (mounted) {
          // Normalize amplitude to 0-1 range
          // amp.current is in dBFS, typically -160 to 0
          // We normalize from -60 to 0 for a reasonable range
          final normalized = ((amp.current + 60) / 60).clamp(0.0, 1.0);
          setState(() => _amplitude = normalized);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _hasError = true);
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.microphonePermissionDenied),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      // Delay briefly to show the error message
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) widget.onCancel();
    }
  }

  Future<void> _confirmRecording() async {
    if (_isProcessing || !_isRecording || !mounted) return;

    setState(() => _isProcessing = true);
    HapticFeedback.mediumImpact();

    try {
      final file = await _recordingService.stopRecording();

      if (file != null && mounted) {
        widget.onConfirm(file);
      } else if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.recordingFailed),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        widget.onCancel();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 4),
          ),
        );
        widget.onCancel();
      }
    }
  }

  Future<void> _cancelRecording() async {
    HapticFeedback.lightImpact();
    await _recordingService.cancelRecording();
    if (mounted) widget.onCancel();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _amplitudeSub?.cancel();
    _pulseController.dispose();
    // Recording service dispose is async but Flutter's dispose() is sync.
    // Fire-and-forget is acceptable here as the service handles its own cleanup.
    unawaited(_recordingService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: Colors.black.withValues(alpha: 0.92),
      child: SafeArea(
        child: Stack(
          children: [
            // Background blur effect
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: const SizedBox(),
              ),
            ),
            // Content
            Column(
              children: [
                // Header with cancel button
                Padding(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: _cancelRecording,
                        icon: Icon(
                          Platform.isIOS
                              ? CupertinoIcons.xmark
                              : Icons.close_rounded,
                          color: Colors.white70,
                          size: IconSize.md,
                        ),
                        label: Text(
                          l10n.cancel,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: AppTypography.bodyMedium,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Recording visualization
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Animated recording indicator
                        AnimatedBuilder(
                          animation: _pulseAnimation,
                          builder: (context, child) {
                            final scale = _isRecording
                                ? _pulseAnimation.value + (_amplitude * 0.3)
                                : 1.0;
                            return Transform.scale(
                              scale: scale,
                              child: child,
                            );
                          },
                          child: Container(
                            width: 140,
                            height: 140,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  Colors.red.withValues(alpha: 0.4),
                                  Colors.red.withValues(alpha: 0.1),
                                  Colors.transparent,
                                ],
                                stops: const [0.3, 0.7, 1.0],
                              ),
                            ),
                            child: Center(
                              child: Container(
                                width: 100,
                                height: 100,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.red.withValues(alpha: 0.2),
                                  border: Border.all(
                                    color: Colors.red,
                                    width: 3,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.red.withValues(alpha: 0.4),
                                      blurRadius: 20,
                                      spreadRadius: 5,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  Platform.isIOS
                                      ? CupertinoIcons.mic_fill
                                      : Icons.mic_rounded,
                                  size: 48,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: Spacing.xxl),

                        // Duration display
                        Text(
                          _formatDuration(_duration),
                          style: theme.textTheme.displayMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w300,
                            letterSpacing: 4,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),

                        const SizedBox(height: Spacing.md),

                        // Status text
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Text(
                            _hasError
                                ? l10n.microphonePermissionDenied
                                : (_isRecording
                                    ? l10n.recordingAudio
                                    : l10n.preparingRecording),
                            key: ValueKey(_isRecording),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: Colors.white60,
                              letterSpacing: 1,
                            ),
                          ),
                        ),

                        const SizedBox(height: Spacing.sm),

                        // Hint text
                        if (_isRecording && !_hasError)
                          Text(
                            l10n.recordingHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white38,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                // Confirm button
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.xl,
                    Spacing.md,
                    Spacing.xl,
                    Spacing.xxl,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed:
                          _isProcessing || !_isRecording || _hasError
                              ? null
                              : _confirmRecording,
                      icon: _isProcessing
                          ? SizedBox(
                              width: IconSize.md,
                              height: IconSize.md,
                              child: const CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              Platform.isIOS
                                  ? CupertinoIcons.stop_fill
                                  : Icons.stop_rounded,
                              size: IconSize.lg,
                            ),
                      label: Text(
                        _isProcessing
                            ? l10n.processingRecording
                            : l10n.stopAndSaveRecording,
                        style: const TextStyle(
                          fontSize: AppTypography.bodyLarge,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.red.withValues(
                          alpha: 0.5,
                        ),
                        disabledForegroundColor: Colors.white54,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppBorderRadius.button,
                          ),
                        ),
                        elevation: 4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}


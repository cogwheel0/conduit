import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../voice_call/application/voice_call_controller.dart';
import '../voice_call/domain/voice_call_models.dart';

class VoiceCallPage extends ConsumerStatefulWidget {
  const VoiceCallPage({super.key, this.startNewConversation = false});

  final bool startNewConversation;

  @override
  ConsumerState<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends ConsumerState<VoiceCallPage>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _waveController;
  late final VoiceCallController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(voiceCallControllerProvider.notifier);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _controller.start(startNewConversation: widget.startNewConversation),
      );
    });
  }

  @override
  void dispose() {
    unawaited(_controller.stop());
    _pulseController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(voiceCallControllerProvider);
    final selectedModel = ref.watch(selectedModelProvider);
    final l10n = AppLocalizations.of(context)!;
    final conduit = context.conduitTheme;
    final primaryColor = conduit.buttonPrimary;
    final textColor = conduit.textPrimary;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        leading: FloatingAppBarIconButton(
          icon: Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
          onTap: () async {
            await _controller.stop();
            if (!mounted) return;
            Navigator.of(this.context).pop();
          },
        ),
        title: FloatingAppBarTitle(text: l10n.voiceCallTitle),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (snapshot.failure != null)
              _buildBanner(context, snapshot.failure!.message),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                        minWidth: constraints.maxWidth,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              selectedModel?.name ?? '',
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(
                                    color: textColor.withValues(alpha: 0.7),
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _formatElapsed(snapshot.elapsed),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: textColor.withValues(alpha: 0.6),
                                  ),
                            ),
                            const SizedBox(height: 40),
                            _buildStatusIndicator(
                              snapshot,
                              primaryColor,
                              textColor,
                            ),
                            const SizedBox(height: 40),
                            Text(
                              _phaseLabel(snapshot.phase, l10n),
                              style: Theme.of(context).textTheme.headlineMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 24),
                            _buildTextDisplay(snapshot, textColor),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: _buildControlButtons(context, snapshot, l10n),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBanner(BuildContext context, String text) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(
    VoiceCallSnapshot snapshot,
    Color primaryColor,
    Color textColor,
  ) {
    if (snapshot.phase == CallPhase.listening) {
      return SizedBox(
        height: 120,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(5, (index) {
            return AnimatedBuilder(
              animation: _waveController,
              builder: (context, child) {
                final offset = (index * 0.2) % 1.0;
                final animation = (_waveController.value + offset) % 1.0;
                final height =
                    20.0 +
                    (math.sin(animation * math.pi * 2) * 30.0).abs() +
                    (snapshot.intensity * 4.0);

                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: 8,
                  height: height,
                  decoration: BoxDecoration(
                    color: primaryColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              },
            );
          }),
        ),
      );
    }

    if (snapshot.phase == CallPhase.speaking) {
      return AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final scale = 1.0 + (_pulseController.value * 0.2);
          return Transform.scale(
            scale: scale,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primaryColor.withValues(alpha: 0.2),
                border: Border.all(color: primaryColor, width: 3),
              ),
              child: Center(
                child: Icon(
                  CupertinoIcons.speaker_2_fill,
                  size: 48,
                  color: primaryColor,
                ),
              ),
            ),
          );
        },
      );
    }

    if (snapshot.phase == CallPhase.connecting ||
        snapshot.phase == CallPhase.starting) {
      return SizedBox(
        width: 96,
        height: 96,
        child: Center(
          child: SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
            ),
          ),
        ),
      );
    }

    if (snapshot.phase == CallPhase.thinking) {
      return AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final alpha = 0.1 + (_pulseController.value * 0.14);
          return Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primaryColor.withValues(alpha: alpha),
              border: Border.all(
                color: primaryColor.withValues(alpha: 0.38),
                width: 1.5,
              ),
            ),
            child: Center(child: _buildThinkingDots(primaryColor)),
          );
        },
      );
    }

    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: textColor.withValues(alpha: 0.1),
      ),
      child: Icon(
        snapshot.isMuted
            ? CupertinoIcons.mic_slash_fill
            : CupertinoIcons.mic_fill,
        size: 48,
        color: textColor.withValues(alpha: 0.5),
      ),
    );
  }

  Widget _buildThinkingDots(Color color) {
    return AnimatedBuilder(
      animation: _waveController,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final phase = (_waveController.value + (index * 0.18)) % 1.0;
            final scale = 0.7 + (math.sin(phase * math.pi) * 0.5);
            final opacity = 0.45 + (math.sin(phase * math.pi) * 0.55);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: opacity.clamp(0.2, 1.0)),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _buildTextDisplay(VoiceCallSnapshot snapshot, Color textColor) {
    final showTranscript = snapshot.phase == CallPhase.listening;
    final text = showTranscript
        ? snapshot.transcript
        : ConduitMarkdownPreprocessor.toPlainText(snapshot.response);
    if (text.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppTypography.chatMessageStyle.copyWith(
            color: textColor.withValues(alpha: 0.82),
            height: 1.45,
          ),
        ),
      ),
    );
  }

  Widget _buildControlButtons(
    BuildContext context,
    VoiceCallSnapshot snapshot,
    AppLocalizations l10n,
  ) {
    final errorColor = Theme.of(context).colorScheme.error;
    final warningColor = Colors.orange;
    final successColor = Theme.of(context).colorScheme.secondary;

    final buttons = <Widget>[
      _CallActionButton(
        icon: snapshot.isMuted
            ? CupertinoIcons.mic_fill
            : CupertinoIcons.mic_slash_fill,
        label: snapshot.isMuted ? 'Unmute' : 'Mute',
        color: snapshot.isMuted ? successColor : warningColor,
        onPressed: () async {
          await _controller.toggleMute();
        },
      ),
    ];

    if (snapshot.canPause) {
      buttons.add(
        _CallActionButton(
          icon: CupertinoIcons.pause_fill,
          label: l10n.voiceCallPause,
          color: warningColor,
          onPressed: () async {
            await _controller.pause();
          },
        ),
      );
    } else if (snapshot.canResume) {
      buttons.add(
        _CallActionButton(
          icon: CupertinoIcons.play_fill,
          label: l10n.voiceCallResume,
          color: successColor,
          onPressed: () async {
            await _controller.resume();
          },
        ),
      );
    }

    if (snapshot.phase == CallPhase.speaking) {
      buttons.add(
        _CallActionButton(
          icon: CupertinoIcons.stop_fill,
          label: l10n.voiceCallStop,
          color: warningColor,
          onPressed: () async {
            await _controller.cancelAssistantSpeech();
          },
        ),
      );
    }

    buttons.add(
      _CallActionButton(
        icon: CupertinoIcons.phone_down_fill,
        label: l10n.voiceCallEnd,
        color: errorColor,
        onPressed: () async {
          await _controller.stop();
          if (!mounted) return;
          Navigator.of(this.context).pop();
        },
      ),
    );

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 20,
      runSpacing: 14,
      children: buttons,
    );
  }

  String _phaseLabel(CallPhase phase, AppLocalizations l10n) {
    switch (phase) {
      case CallPhase.idle:
      case CallPhase.starting:
        return l10n.voiceCallReady;
      case CallPhase.connecting:
        return l10n.voiceCallConnecting;
      case CallPhase.listening:
        return l10n.voiceCallListening;
      case CallPhase.paused:
      case CallPhase.muted:
        return l10n.voiceCallPaused;
      case CallPhase.thinking:
        return l10n.voiceCallProcessing;
      case CallPhase.speaking:
        return l10n.voiceCallSpeaking;
      case CallPhase.ending:
      case CallPhase.ended:
        return l10n.voiceCallDisconnected;
      case CallPhase.failed:
        return l10n.error;
    }
  }

  String _formatElapsed(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _CallActionButton extends StatelessWidget {
  const _CallActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AdaptiveButton.child(
          onPressed: onPressed,
          style: AdaptiveButtonStyle.filled,
          color: color,
          useSmoothRectangleBorder: true,
          borderRadius: BorderRadius.circular(100),
          size: AdaptiveButtonSize.large,
          minSize: const Size(62, 62),
          child: Icon(icon, color: Colors.white, size: 30),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style:
              textTheme.labelMedium?.copyWith(color: color) ??
              AppTypography.labelMediumStyle.copyWith(color: color),
        ),
      ],
    );
  }
}

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../providers/chat_providers.dart';
import '../services/voice_call_service.dart';

class VoiceCallPage extends ConsumerStatefulWidget {
  const VoiceCallPage({super.key, this.startNewConversation = false});

  final bool startNewConversation;

  @override
  ConsumerState<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends ConsumerState<VoiceCallPage>
    with TickerProviderStateMixin {
  VoiceCallService? _service;
  StreamSubscription<VoiceCallState>? _stateSubscription;
  StreamSubscription<String>? _transcriptSubscription;
  StreamSubscription<String>? _responseSubscription;
  StreamSubscription<int>? _intensitySubscription;

  VoiceCallState _currentState = VoiceCallState.idle;
  String _currentTranscript = '';
  String _currentResponse = '';
  int _currentIntensity = 0;

  late AnimationController _pulseController;
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCall();
    });
  }

  Future<void> _initializeCall() async {
    try {
      // Start a new conversation if requested
      if (widget.startNewConversation) {
        startNewChat(ref);
      }

      _service = ref.read(voiceCallServiceProvider);

      // Subscribe to service streams
      _stateSubscription = _service!.stateStream.listen((state) {
        if (mounted) {
          setState(() {
            _currentState = state;
          });
        }
      });

      _transcriptSubscription = _service!.transcriptStream.listen((text) {
        if (mounted) {
          setState(() {
            _currentTranscript = text;
          });
        }
      });

      _responseSubscription = _service!.responseStream.listen((text) {
        if (mounted) {
          setState(() {
            _currentResponse = text;
          });
        }
      });

      _intensitySubscription = _service!.intensityStream.listen((intensity) {
        if (mounted) {
          setState(() {
            _currentIntensity = intensity;
          });
        }
      });

      // Initialize and start the call
      await _service!.initialize();
      final activeConversation = ref.read(activeConversationProvider);
      await _service!.startCall(activeConversation?.id);
    } catch (e) {
      if (mounted) {
        _showErrorDialog(e.toString());
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) {
        final dialogL10n = AppLocalizations.of(ctx)!;
        return AlertDialog(
          title: Text(dialogL10n.error),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: Text(dialogL10n.ok),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    // Cancel subscriptions (fire and forget)
    _stateSubscription?.cancel();
    _transcriptSubscription?.cancel();
    _responseSubscription?.cancel();
    _intensitySubscription?.cancel();
    _service?.stopCall();
    _pulseController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel = ref.watch(selectedModelProvider);
    final primaryColor = Theme.of(context).colorScheme.primary;
    final backgroundColor = Theme.of(context).scaffoldBackgroundColor;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: backgroundColor,
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        leading: FloatingAppBarIconButton(
          icon: Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
          onTap: () async {
            await _service?.stopCall();
            if (!context.mounted) return;
            Navigator.of(context).pop();
          },
        ),
        title: FloatingAppBarTitle(text: l10n.voiceCallTitle),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Model name
                  Text(
                    selectedModel?.name ?? '',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: textColor.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Animated waveform/status indicator
                  _buildStatusIndicator(primaryColor, textColor),

                  const SizedBox(height: 48),

                  // State label
                  Text(
                    _getStateLabel(),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Transcript or response text
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: _buildTextDisplay(textColor),
                  ),

                  // Error state help text
                  if (_currentState == VoiceCallState.error)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                      child: Text(
                        l10n.voiceCallErrorHelp,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.error,
                          height: 1.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Control buttons
            Padding(
              padding: const EdgeInsets.all(32),
              child: _buildControlButtons(primaryColor, l10n),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(Color primaryColor, Color textColor) {
    if (_currentState == VoiceCallState.listening) {
      // Animated waveform bars
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
                    (_currentIntensity * 4.0);

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
    } else if (_currentState == VoiceCallState.speaking) {
      // Pulsing circle for speaking
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
    } else if (_currentState == VoiceCallState.processing) {
      // Spinning loader for processing
      return SizedBox(
        width: 120,
        height: 120,
        child: CircularProgressIndicator(
          strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
        ),
      );
    } else {
      // Default microphone icon
      return Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: textColor.withValues(alpha: 0.1),
        ),
        child: Icon(
          CupertinoIcons.mic_fill,
          size: 48,
          color: textColor.withValues(alpha: 0.5),
        ),
      );
    }
  }

  Widget _buildTextDisplay(Color textColor) {
    String displayText = '';

    if (_currentState == VoiceCallState.listening &&
        _currentTranscript.isNotEmpty) {
      displayText = _currentTranscript;
    } else if (_currentState == VoiceCallState.speaking &&
        _currentResponse.isNotEmpty) {
      // Convert markdown to clean text for display
      displayText = ConduitMarkdownPreprocessor.toPlainText(_currentResponse);
    }

    if (displayText.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      child: SingleChildScrollView(
        child: Text(
          displayText,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            color: textColor.withValues(alpha: 0.8),
            height: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildControlButtons(Color primaryColor, AppLocalizations l10n) {
    final errorColor = Theme.of(context).colorScheme.error;
    final warningColor = Colors.orange;
    final successColor = Theme.of(context).colorScheme.secondary;

    final buttons = <Widget>[];

    // Retry button (only show in error state)
    if (_currentState == VoiceCallState.error) {
      buttons.add(
        _buildActionButton(
          icon: CupertinoIcons.arrow_clockwise,
          label: l10n.retry,
          color: primaryColor,
          onPressed: () async {
            await _initializeCall();
          },
        ),
      );
    }

    final canPause = _currentState == VoiceCallState.listening;
    final canResume = _currentState == VoiceCallState.paused;

    if (canPause) {
      buttons.add(
        _buildActionButton(
          icon: CupertinoIcons.pause_fill,
          label: l10n.voiceCallPause,
          color: warningColor,
          onPressed: () async {
            await _service?.pauseListening();
          },
        ),
      );
    } else if (canResume) {
      buttons.add(
        _buildActionButton(
          icon: CupertinoIcons.play_fill,
          label: l10n.voiceCallResume,
          color: successColor,
          onPressed: () async {
            await _service?.resumeListening();
          },
        ),
      );
    }

    // Cancel speaking button (only show when speaking)
    if (_currentState == VoiceCallState.speaking) {
      buttons.add(
        _buildActionButton(
          icon: CupertinoIcons.stop_fill,
          label: l10n.voiceCallStop,
          color: warningColor,
          onPressed: () async {
            await _service?.cancelSpeaking();
          },
        ),
      );
    }

    // End call button
    buttons.add(
      _buildActionButton(
        icon: CupertinoIcons.phone_down_fill,
        label: l10n.voiceCallEnd,
        color: errorColor,
        onPressed: () async {
          await _service?.stopCall();
          if (mounted) {
            Navigator.of(context).pop();
          }
        },
      ),
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: buttons,
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onPressed,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }

  String _getStateLabel() {
    final l10n = AppLocalizations.of(context)!;
    switch (_currentState) {
      case VoiceCallState.idle:
        return l10n.voiceCallReady;
      case VoiceCallState.connecting:
        return l10n.voiceCallConnecting;
      case VoiceCallState.listening:
        return l10n.voiceCallListening;
      case VoiceCallState.paused:
        return l10n.voiceCallPaused;
      case VoiceCallState.processing:
        return l10n.voiceCallProcessing;
      case VoiceCallState.speaking:
        return l10n.voiceCallSpeaking;
      case VoiceCallState.error:
        return l10n.error;
      case VoiceCallState.disconnected:
        return l10n.voiceCallDisconnected;
    }
  }
}

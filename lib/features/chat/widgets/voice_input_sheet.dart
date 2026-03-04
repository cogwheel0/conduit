import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/platform_service.dart' as ps;
import '../../../core/services/settings_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../services/voice_input_service.dart';

/// Bottom sheet providing voice-to-text input via on-device STT.
class VoiceInputSheet extends ConsumerStatefulWidget {
  /// Callback invoked with the final recognised text when the user
  /// taps "Send".
  final Function(String) onTextReceived;

  const VoiceInputSheet({super.key, required this.onTextReceived});

  @override
  ConsumerState<VoiceInputSheet> createState() =>
      VoiceInputSheetState();
}

/// State for [VoiceInputSheet].
class VoiceInputSheetState extends ConsumerState<VoiceInputSheet> {
  bool _isListening = false;
  String _recognizedText = '';
  late VoiceInputService _voiceService;
  StreamSubscription<int>? _intensitySub;
  int _intensity = 0;
  StreamSubscription<String>? _textSub;
  int _elapsedSeconds = 0;
  Timer? _elapsedTimer;
  String _languageTag = 'en';
  bool _holdToTalk = false;
  bool _autoSendFinal = false;

  @override
  void initState() {
    super.initState();
    _voiceService = ref.read(voiceInputServiceProvider);
    try {
      final preset = _voiceService.selectedLocaleId;
      if (preset != null && preset.isNotEmpty) {
        _languageTag =
            preset.split(RegExp('[-_]')).first.toLowerCase();
      } else {
        _languageTag = WidgetsBinding
            .instance.platformDispatcher.locale
            .toLanguageTag()
            .split(RegExp('[-_]'))
            .first
            .toLowerCase();
      }
    } catch (_) {
      _languageTag = 'en';
    }
    final settings = ref.read(appSettingsProvider);
    _holdToTalk = settings.voiceHoldToTalk;
    _autoSendFinal = settings.voiceAutoSendFinal;
    if (settings.voiceLocaleId != null &&
        settings.voiceLocaleId!.isNotEmpty) {
      _voiceService.setLocale(settings.voiceLocaleId);
      _languageTag = settings.voiceLocaleId!
          .split(RegExp('[-_]'))
          .first
          .toLowerCase();
    }
  }

  void _startListening() async {
    setState(() {
      _isListening = true;
      _recognizedText = '';
      _elapsedSeconds = 0;
    });
    final hapticEnabled = ref.read(hapticEnabledProvider);
    ps.PlatformService.hapticFeedbackWithSettings(
      type: ps.HapticType.medium,
      hapticEnabled: hapticEnabled,
    );

    try {
      final ok = await _voiceService.initialize();
      if (!ok) {
        throw Exception('Voice service unavailable');
      }

      _elapsedTimer?.cancel();
      _elapsedTimer =
          Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted || !_isListening) {
          t.cancel();
          return;
        }
        setState(() => _elapsedSeconds += 1);
      });

      final stream = await _voiceService.beginListening();
      _intensitySub =
          _voiceService.intensityStream.listen((value) {
        if (!mounted) return;
        setState(() => _intensity = value);
      });
      _textSub = stream.listen(
        (text) {
          setState(() {
            _recognizedText = text;
          });
        },
        onDone: () {
          DebugLogger.log(
            'VoiceInputSheet stream done',
            scope: 'chat/page',
          );
          setState(() {
            _isListening = false;
          });
          _elapsedTimer?.cancel();
          if (_autoSendFinal &&
              _recognizedText.trim().isNotEmpty) {
            _sendText();
          }
        },
        onError: (error) {
          DebugLogger.log(
            'VoiceInputSheet stream error: $error',
            scope: 'chat/page',
          );
          setState(() {
            _isListening = false;
          });
          _elapsedTimer?.cancel();
          if (mounted) {
            final hapticEnabled =
                ref.read(hapticEnabledProvider);
            ps.PlatformService.hapticFeedbackWithSettings(
              type: ps.HapticType.warning,
              hapticEnabled: hapticEnabled,
            );
          }
        },
      );
    } catch (e) {
      setState(() {
        _isListening = false;
      });
    }
  }

  Future<void> _stopListening() async {
    _intensitySub?.cancel();
    _intensitySub = null;
    await _voiceService.stopListening();
    _elapsedTimer?.cancel();
    if (mounted) {
      setState(() {
        _isListening = false;
      });
    }
    final hapticEnabled = ref.read(hapticEnabledProvider);
    ps.PlatformService.hapticFeedbackWithSettings(
      type: ps.HapticType.selection,
      hapticEnabled: hapticEnabled,
    );
  }

  void _sendText() {
    if (_recognizedText.isNotEmpty) {
      final hapticEnabled = ref.read(hapticEnabledProvider);
      ps.PlatformService.hapticFeedbackWithSettings(
        type: ps.HapticType.success,
        hapticEnabled: hapticEnabled,
      );
      widget.onTextReceived(_recognizedText);
      Navigator.pop(context);
    }
  }

  String _formatSeconds(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(1, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _pickLanguage() async {
    if (!_voiceService.hasLocalStt) return;
    final locales = _voiceService.locales;
    if (locales.isEmpty) return;
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return Container(
          decoration: BoxDecoration(
            color: context.conduitTheme.surfaceBackground,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppBorderRadius.bottomSheet),
            ),
            border: Border.all(
              color: context.conduitTheme.dividerColor,
              width: BorderWidth.regular,
            ),
            boxShadow: ConduitShadows.modal(context),
          ),
          padding: const EdgeInsets.all(
            Spacing.bottomSheetPadding,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SheetHandle(),
                const SizedBox(height: Spacing.md),
                Text(
                  l10n.selectLanguage,
                  style: TextStyle(
                    fontSize: AppTypography.headlineSmall,
                    color: context.conduitTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: locales.length,
                    separatorBuilder: (_, sep) => Divider(
                      height: 1,
                      color: context.conduitTheme.dividerColor,
                    ),
                    itemBuilder: (ctx, i) {
                      final l = locales[i];
                      final isSelected = l.localeId ==
                          _voiceService.selectedLocaleId;
                      return AdaptiveListTile(
                        title: Text(
                          l.name,
                          style: TextStyle(
                            color:
                                context.conduitTheme.textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          l.localeId,
                          style: TextStyle(
                            color: context
                                .conduitTheme
                                .textSecondary,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(
                                Icons.check,
                                color: context
                                    .conduitTheme
                                    .buttonPrimary,
                              )
                            : null,
                        onTap: () =>
                            Navigator.pop(ctx, l.localeId),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (selected != null && mounted) {
      setState(() {
        _voiceService.setLocale(selected);
        _languageTag =
            selected.split(RegExp('[-_]')).first.toLowerCase();
      });
      await ref
          .read(appSettingsProvider.notifier)
          .setVoiceLocaleId(selected);
      if (_isListening) {
        await _voiceService.stopListening();
        _startListening();
      }
    }
  }

  Widget _buildThemedSwitch({
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = context.conduitTheme;
    return AdaptiveSwitch(
      value: value,
      onChanged: onChanged,
      activeColor: theme.buttonPrimary,
    );
  }

  @override
  void dispose() {
    _intensitySub?.cancel();
    _textSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isCompact = media.size.height < 680;
    final l10n = AppLocalizations.of(context)!;
    final statusText = _isListening
        ? (_voiceService.hasLocalStt
              ? l10n.voiceStatusListening
              : l10n.voiceStatusRecording)
        : l10n.voice;
    return Container(
      height: media.size.height * (isCompact ? 0.45 : 0.6),
      decoration: BoxDecoration(
        color: context.conduitTheme.surfaceBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.bottomSheet),
        ),
        border: Border.all(
          color: context.conduitTheme.dividerColor,
          width: 1,
        ),
        boxShadow: ConduitShadows.modal(context),
      ),
      child: SafeArea(
        top: false,
        bottom: true,
        child: Padding(
          padding: const EdgeInsets.all(
            Spacing.bottomSheetPadding,
          ),
          child: Column(
            children: [
              const SheetHandle(),
              Padding(
                padding: const EdgeInsets.only(
                  top: Spacing.md,
                  bottom: Spacing.md,
                ),
                child: Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: AppTypography.headlineMedium,
                        fontWeight: FontWeight.w600,
                        color: context.conduitTheme.textPrimary,
                      ),
                    ),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: _voiceService.hasLocalStt
                              ? _pickLanguage
                              : null,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Spacing.xs,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: context
                                  .conduitTheme
                                  .surfaceBackground
                                  .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(
                                AppBorderRadius.badge,
                              ),
                              border: Border.all(
                                color: context
                                    .conduitTheme
                                    .dividerColor,
                                width: BorderWidth.thin,
                              ),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  _languageTag.toUpperCase(),
                                  style: TextStyle(
                                    fontSize:
                                        AppTypography.labelSmall,
                                    color: context
                                        .conduitTheme
                                        .textSecondary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (_voiceService
                                    .hasLocalStt) ...[
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.arrow_drop_down,
                                    size: 16,
                                    color: context
                                        .conduitTheme
                                        .iconSecondary,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        AnimatedOpacity(
                          opacity: _isListening ? 1 : 0.6,
                          duration: AnimationDuration.fast,
                          child: Text(
                            _formatSeconds(_elapsedSeconds),
                            style: TextStyle(
                              color: context
                                  .conduitTheme
                                  .textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        ConduitIconButton(
                          icon: Platform.isIOS
                              ? CupertinoIcons.xmark
                              : Icons.close,
                          tooltip: AppLocalizations.of(
                            context,
                          )!.closeButtonSemantic,
                          isCompact: true,
                          onPressed: () =>
                              Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  bottom: Spacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildThemedSwitch(
                            value: _holdToTalk,
                            onChanged: (v) async {
                              setState(
                                () => _holdToTalk = v,
                              );
                              await ref
                                  .read(
                                    appSettingsProvider.notifier,
                                  )
                                  .setVoiceHoldToTalk(v);
                            },
                          ),
                          const SizedBox(width: Spacing.xs),
                          Text(
                            l10n.voiceHoldToTalk,
                            style: TextStyle(
                              color: context
                                  .conduitTheme
                                  .textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        mainAxisAlignment:
                            MainAxisAlignment.end,
                        children: [
                          _buildThemedSwitch(
                            value: _autoSendFinal,
                            onChanged: (v) async {
                              setState(
                                () => _autoSendFinal = v,
                              );
                              await ref
                                  .read(
                                    appSettingsProvider.notifier,
                                  )
                                  .setVoiceAutoSendFinal(v);
                            },
                          ),
                          const SizedBox(width: Spacing.xs),
                          Text(
                            l10n.voiceAutoSend,
                            style: TextStyle(
                              color: context
                                  .conduitTheme
                                  .textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, viewport) {
                    final isUltra = media.size.height < 560;
                    final double micSize = isUltra
                        ? 64
                        : (isCompact ? 80 : 100);
                    final double micIconSize = isUltra
                        ? 26
                        : (isCompact ? 32 : 40);
                    final double topPaddingForScale =
                        ((micSize * 1.2) - micSize) / 2 + 8;

                    final content = Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment:
                            MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: isUltra
                                ? Spacing.sm
                                : Spacing.md,
                          ),
                          GestureDetector(
                                onTapDown: _holdToTalk
                                    ? (_) {
                                        if (!_isListening) {
                                          _startListening();
                                        }
                                      }
                                    : null,
                                onTapUp: _holdToTalk
                                    ? (_) {
                                        if (_isListening) {
                                          _stopListening();
                                        }
                                      }
                                    : null,
                                onTapCancel: _holdToTalk
                                    ? () {
                                        if (_isListening) {
                                          _stopListening();
                                        }
                                      }
                                    : null,
                                onTap: () => _holdToTalk
                                    ? null
                                    : (_isListening
                                          ? _stopListening()
                                          : _startListening()),
                                child: Container(
                                  width: micSize,
                                  height: micSize,
                                  decoration: BoxDecoration(
                                    color: _isListening
                                        ? context
                                              .conduitTheme
                                              .error
                                              .withValues(
                                                alpha: 0.2,
                                              )
                                        : context
                                              .conduitTheme
                                              .surfaceBackground
                                              .withValues(
                                                alpha:
                                                    Alpha.subtle,
                                              ),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _isListening
                                          ? context
                                                .conduitTheme
                                                .error
                                                .withValues(
                                                  alpha: 0.5,
                                                )
                                          : context
                                                .conduitTheme
                                                .dividerColor,
                                      width: 2,
                                    ),
                                  ),
                                  child: Icon(
                                    _isListening
                                        ? (Platform.isIOS
                                              ? CupertinoIcons
                                                    .mic_fill
                                              : Icons.mic)
                                        : (Platform.isIOS
                                              ? CupertinoIcons
                                                    .mic_off
                                              : Icons.mic_off),
                                    size: micIconSize,
                                    color: _isListening
                                        ? context
                                              .conduitTheme
                                              .error
                                        : context
                                              .conduitTheme
                                              .iconSecondary,
                                  ),
                                ),
                              )
                              .animate(
                                onPlay: (controller) =>
                                    _isListening
                                        ? controller.repeat()
                                        : null,
                              )
                              .scale(
                                duration: const Duration(
                                  milliseconds: 1000,
                                ),
                                begin: const Offset(1, 1),
                                end: const Offset(1.2, 1.2),
                              )
                              .then()
                              .scale(
                                duration: const Duration(
                                  milliseconds: 1000,
                                ),
                                begin: const Offset(1.2, 1.2),
                                end: const Offset(1, 1),
                              ),
                          SizedBox(
                            height: isUltra
                                ? Spacing.xs
                                : (isCompact
                                      ? Spacing.sm
                                      : Spacing.md),
                          ),
                          SizedBox(
                            height: isUltra
                                ? 18
                                : (isCompact ? 24 : 32),
                            child: AnimatedSwitcher(
                              duration: const Duration(
                                milliseconds: 150,
                              ),
                              child: Row(
                                key: ValueKey<int>(_intensity),
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
                                children: List.generate(
                                    isUltra ? 10 : 12, (i) {
                                  final normalized =
                                      ((_intensity + i) % 10) /
                                          10.0;
                                  final base = isUltra
                                      ? 4
                                      : (isCompact ? 6 : 8);
                                  final range = isUltra
                                      ? 14
                                      : (isCompact ? 18 : 24);
                                  final barHeight = base +
                                      (normalized * range);
                                  return Container(
                                    width: isUltra
                                        ? 2.5
                                        : (isCompact ? 3 : 4),
                                    height: barHeight,
                                    margin:
                                        EdgeInsets.symmetric(
                                      horizontal: isUltra
                                          ? 1
                                          : (isCompact
                                                ? 1.5
                                                : 2),
                                    ),
                                    decoration: BoxDecoration(
                                      color: context
                                          .conduitTheme
                                          .buttonPrimary
                                          .withValues(
                                            alpha: 0.7,
                                          ),
                                      borderRadius:
                                          BorderRadius.circular(
                                            2,
                                          ),
                                    ),
                                  );
                                }),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: isUltra
                                ? Spacing.sm
                                : (isCompact
                                      ? Spacing.md
                                      : Spacing.xl),
                          ),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: media.size.height *
                                  (isUltra
                                      ? 0.13
                                      : (isCompact
                                            ? 0.16
                                            : 0.2)),
                              minHeight: isUltra
                                  ? 56
                                  : (isCompact ? 64 : 80),
                            ),
                            child: ConduitCard(
                              isCompact: isCompact,
                              padding: EdgeInsets.all(
                                isCompact
                                    ? Spacing.md
                                    : Spacing.md,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        l10n.voiceTranscript,
                                        style: TextStyle(
                                          fontSize: AppTypography
                                              .labelSmall,
                                          fontWeight:
                                              FontWeight.w600,
                                          color: context
                                              .conduitTheme
                                              .textSecondary,
                                        ),
                                      ),
                                      const Spacer(),
                                      ConduitIconButton(
                                        icon: Icons.close,
                                        isCompact: true,
                                        tooltip:
                                            AppLocalizations.of(
                                          context,
                                        )!.clear,
                                        onPressed:
                                            _recognizedText
                                                    .isNotEmpty
                                                ? () {
                                                    setState(
                                                      () =>
                                                          _recognizedText =
                                                              '',
                                                    );
                                                  }
                                                : null,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(
                                    height: Spacing.xs,
                                  ),
                                  Flexible(
                                    child:
                                        SingleChildScrollView(
                                      child: Text(
                                        _recognizedText.isEmpty
                                            ? (_isListening
                                                  ? (_voiceService
                                                            .hasLocalStt
                                                        ? l10n
                                                            .voicePromptSpeakNow
                                                        : l10n
                                                            .voiceStatusRecording)
                                                  : l10n
                                                      .voicePromptTapStart)
                                            : _recognizedText,
                                        style: TextStyle(
                                          fontSize: isUltra
                                              ? AppTypography
                                                    .bodySmall
                                              : (isCompact
                                                    ? AppTypography
                                                          .bodyMedium
                                                    : AppTypography
                                                          .bodyLarge),
                                          color: _recognizedText
                                                  .isEmpty
                                              ? context
                                                    .conduitTheme
                                                    .inputPlaceholder
                                              : context
                                                    .conduitTheme
                                                    .textPrimary,
                                          height: 1.4,
                                        ),
                                        textAlign:
                                            TextAlign.center,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );

                    return SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      padding: EdgeInsets.only(
                        top: topPaddingForScale,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: viewport.maxHeight,
                        ),
                        child: content,
                      ),
                    );
                  },
                ),
              ),
              Builder(
                builder: (context) {
                  final showStartStop = !_holdToTalk;
                  final showSend = !_autoSendFinal;
                  if (!showStartStop && !showSend) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: EdgeInsets.only(
                      top: isCompact ? Spacing.sm : Spacing.md,
                    ),
                    child: Row(
                      children: [
                        if (showStartStop) ...[
                          Expanded(
                            child: ConduitButton(
                              text: _isListening
                                  ? l10n.voiceActionStop
                                  : l10n.voiceActionStart,
                              isSecondary: true,
                              isCompact: isCompact,
                              onPressed: _isListening
                                  ? _stopListening
                                  : _startListening,
                            ),
                          ),
                        ],
                        if (showStartStop && showSend)
                          const SizedBox(width: Spacing.xs),
                        if (showSend) ...[
                          Expanded(
                            child: ConduitButton(
                              text: l10n.send,
                              isCompact: isCompact,
                              onPressed:
                                  _recognizedText.isNotEmpty
                                      ? _sendText
                                      : null,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

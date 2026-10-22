import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesApiServiceProvider;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../chat/voice_mode/chat_voice_mode_controller.dart';
import '../../chat/voice_mode/call_audio_routes.dart';
import '../../chat/voice_mode/voice_mode_error_text.dart';
import '../../chat/widgets/hermes_inline_activity.dart';
import '../../../l10n/app_localizations.dart';
import '../providers/hermes_mobile_work.dart';
import 'hermes_message_interactions.dart';
import 'hermes_message_icon.dart';

final hermesCallCaptionsProvider = NotifierProvider<CallCaptions, bool>(
  CallCaptions.new,
);

class CallCaptions extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(chatVoiceModeControllerProvider.select((s) => s.startedAt));
    return true;
  }

  void toggle() => state = !state;
}

class HermesCallOverlay extends ConsumerWidget {
  const HermesCallOverlay({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep route/disconnection observation alive in the default compact view.
    ref.watch(callAudioRoutesProvider);
    ref.listen(hermesApiServiceProvider, (previous, next) {
      if (previous != null &&
          !identical(previous, next) &&
          ref.read(chatVoiceModeControllerProvider).isActive) {
        ref.read(chatVoiceModeControllerProvider.notifier).stop();
      }
    });
    final expanded = ref.watch(
      chatVoiceModeControllerProvider.select(
        (s) => s.isActive && !s.isCollapsed,
      ),
    );
    ref.listen(chatVoiceModeControllerProvider.select((s) => s.noticeCount), (
      old,
      next,
    ) {
      final notice = ref.read(chatVoiceModeControllerProvider).notice;
      if (next > (old ?? 0) && notice != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              voiceModeNoticeText(AppLocalizations.of(context)!, notice),
            ),
          ),
        );
      }
    });
    ref.listen(chatVoiceModeControllerProvider.select((s) => s.phase), (
      previous,
      next,
    ) {
      if (next == ChatVoiceModePhase.error &&
          previous != ChatVoiceModePhase.starting &&
          previous != ChatVoiceModePhase.idle) {
        final call = ref.read(chatVoiceModeControllerProvider);
        final message = voiceModeErrorText(
          AppLocalizations.of(context)!,
          kind: call.errorKind,
          message: call.errorMessage,
        );
        if (message != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        }
      }
    });
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !expanded,
        child: AnimatedSwitcher(
          duration: context.motionDuration(const Duration(milliseconds: 220)),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: expanded
              ? const HermesExpandedCall()
              : const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// The same call in chat and in the expanded view. Presentation owns no audio.
class HermesCallHeaderActions extends ConsumerWidget {
  const HermesCallHeaderActions({super.key, required this.onStart});
  final VoidCallback onStart;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(chatVoiceModeControllerProvider);
    final controller = ref.read(chatVoiceModeControllerProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (call.isActive && call.isCollapsed) ...[
          CompactIconAction(
            key: const ValueKey('hermes-call-expand'),
            tooltip: 'Expand call',
            icon: const Icon(Icons.open_in_full_rounded, size: 20),
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              controller.expand();
            },
          ),
          CompactIconAction(
            key: const ValueKey('hermes-call-mute'),
            tooltip: call.isMuted ? 'Unmute microphone' : 'Mute microphone',
            icon: Semantics(
              toggled: call.isMuted,
              child: Icon(
                call.isMuted ? Icons.mic_off_outlined : Icons.mic_none_outlined,
              ),
            ),
            onPressed: controller.toggleMute,
          ),
        ],
        if (call.isActive && !call.isCollapsed)
          CompactPopupMenu<String>(
            tooltip: 'Call options',
            icon: const Icon(HermesMessageIcons.more),
            choices: [
              CompactMenuChoice(
                'pause',
                call.phase == ChatVoiceModePhase.paused
                    ? 'Resume call'
                    : 'Pause call',
              ),
            ],
            onSelected: (_) {
              if (call.phase == ChatVoiceModePhase.paused) {
                controller.resume();
              } else {
                controller.pause();
              }
            },
          )
        else
          CompactIconAction(
            key: const ValueKey('hermes-call-toggle'),
            tooltip: call.isActive ? 'End call' : 'Call Hermes',
            icon: call.phase == ChatVoiceModePhase.starting
                ? SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: context.conduitTheme.error,
                    ),
                  )
                : Icon(
                    call.isActive
                        ? Icons.call_end_outlined
                        : Icons.call_outlined,
                    color: call.isActive ? context.conduitTheme.error : null,
                  ),
            onPressed: call.isActive ? controller.stop : onStart,
          ),
      ],
    );
  }
}

/// Uses the recognizer's real level; no idle animation pretends to hear speech.
class HermesCallActivity extends ConsumerWidget {
  const HermesCallActivity({
    super.key,
    this.wide = false,
    this.microphoneOnly = false,
  });
  final bool wide;
  final bool microphoneOnly;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(
      chatVoiceModeControllerProvider.select(
        (s) => (
          s.phase,
          s.isMuted,
          s.intensity,
          s.isInputSuspended,
          s.isContinuousListening,
        ),
      ),
    );
    final icon = s.$2
        ? Icons.mic_off_outlined
        : s.$1 == ChatVoiceModePhase.paused || s.$4
        ? Icons.pause_rounded
        : microphoneOnly && s.$5 && s.$1 != ChatVoiceModePhase.starting
        ? null
        : s.$1 == ChatVoiceModePhase.speaking
        ? Icons.volume_up_outlined
        : s.$1 == ChatVoiceModePhase.sending
        ? Icons.more_horiz_rounded
        : s.$1 == ChatVoiceModePhase.starting
        ? Icons.more_horiz_rounded
        : null;
    final label = s.$2
        ? 'Microphone muted'
        : s.$4
        ? 'Microphone paused while editing'
        : s.$1 == ChatVoiceModePhase.paused
        ? 'Call paused'
        : microphoneOnly && s.$5 && s.$1 != ChatVoiceModePhase.starting
        ? 'Microphone active'
        : switch (s.$1) {
            ChatVoiceModePhase.listening => 'Listening',
            ChatVoiceModePhase.speaking => 'Hermes speaking',
            ChatVoiceModePhase.sending => 'Hermes working',
            ChatVoiceModePhase.paused => 'Call paused',
            _ => 'Call connecting',
          };
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: SizedBox(
          key: const ValueKey('hermes-call-activity'),
          width: wide ? 220 : 24,
          height: wide ? 36 : 24,
          child: icon != null
              ? Icon(
                  icon,
                  size: wide ? 28 : 22,
                  color: context.conduitTheme.textSecondary,
                )
              : TweenAnimationBuilder<double>(
                  // Visual gain only; microphone capture and recognition are unchanged.
                  tween: Tween(
                    end: (s.$3.clamp(0, 10) / 10 * 1.32).clamp(0.0, 1.0),
                  ),
                  duration: context.motionDuration(
                    const Duration(milliseconds: 120),
                  ),
                  builder: (context, level, _) => CustomPaint(
                    painter: _CallWave(
                      level,
                      context.conduitTheme.buttonPrimary,
                      wide,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _CallWave extends CustomPainter {
  const _CallWave(this.level, this.color, this.wide);
  final double level;
  final Color color;
  final bool wide;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = wide ? 1.5 : 2
      ..strokeCap = StrokeCap.round;
    if (wide) {
      final path = Path();
      for (var x = 0.0; x <= size.width; x += 2) {
        final y =
            size.height / 2 +
            math.sin(x * .14) * math.sin(math.pi * x / size.width) * level * 13;
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint..style = PaintingStyle.stroke);
    } else {
      for (var i = 0; i < 4; i++) {
        final h = 3 + level * (i == 1 || i == 2 ? 17 : 10);
        final x = (i + .5) * size.width / 4;
        canvas.drawLine(
          Offset(x, (size.height - h) / 2),
          Offset(x, (size.height + h) / 2),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CallWave old) =>
      old.level != level || old.color != color || old.wide != wide;
}

class HermesExpandedCall extends ConsumerStatefulWidget {
  const HermesExpandedCall({super.key});
  @override
  ConsumerState<HermesExpandedCall> createState() => _HermesExpandedCallState();
}

class _HermesExpandedCallState extends ConsumerState<HermesExpandedCall> {
  @override
  Widget build(BuildContext context) {
    final call = ref.watch(chatVoiceModeControllerProvider);
    final captions = ref.watch(hermesCallCaptionsProvider);
    final controller = ref.read(chatVoiceModeControllerProvider.notifier);
    final audio = ref.watch(callAudioRoutesProvider);
    final theme = context.conduitTheme;
    final messages = ref.watch(chatMessagesProvider);
    final request = findPendingHermesComposerPrompt(messages);
    final active = messages
        .where((m) => m.role == 'assistant' && m.isStreaming)
        .lastOrNull;
    final voiceName = Theme.of(context).platform == TargetPlatform.android
        ? 'Zoey'
        : ref.watch(appSettingsProvider.select((s) => s.ttsVoiceName));
    final route = audio.current;
    final routeIcon = switch (route?.kind) {
      'speaker' => Icons.volume_up_outlined,
      'bluetooth' => Icons.bluetooth_rounded,
      'wired' => Icons.headphones_outlined,
      _ => Icons.smartphone_outlined,
    };
    final caption = call.spokenResponse.trim();
    return Material(
      key: const ValueKey('hermes-expanded-call'),
      color: theme.surfaceBackground,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          MediaQueryData.fromView(View.of(context)).viewPadding.top + 48,
          20,
          math.max(12, MediaQuery.viewPaddingOf(context).bottom),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    if (voiceName?.isNotEmpty == true)
                      Expanded(
                        child: Text(
                          voiceName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.textSecondary,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    Text(
                      '${call.elapsed.inMinutes.toString().padLeft(2, '0')}:${(call.elapsed.inSeconds % 60).toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    CompactIconAction(
                      key: const ValueKey('hermes-call-skills'),
                      tooltip: 'Skills',
                      onPressed: () => showHermesCallSkills(context),
                      icon: const HermesSkillsIcon(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  key: const PageStorageKey('hermes-expanded-call-content'),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(
                        0,
                        constraints.maxHeight -
                            260 -
                            (request == null ? 0 : 180),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 28),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: Image.asset(
                            'assets/icons/hermes_agent.png',
                            width: 80,
                            height: 80,
                          ),
                        ),
                        const SizedBox(height: 32),
                        const HermesCallActivity(wide: true),
                        if (captions &&
                            caption.isNotEmpty &&
                            call.phase == ChatVoiceModePhase.speaking) ...[
                          const SizedBox(height: 24),
                          Text(
                            caption,
                            key: const ValueKey('hermes-call-caption'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 20,
                              height: 1.45,
                              color: theme.textPrimary,
                            ),
                          ),
                        ],
                        if (active != null &&
                            active.statusHistory.any(
                              isHermesActivityStatus,
                            )) ...[
                          const SizedBox(height: 24),
                          HermesInlineActivity(
                            updates: active.statusHistory,
                            isStreaming: active.isStreaming,
                            stateId: active.id,
                            hasReplyText: active.content.isNotEmpty,
                          ),
                        ],
                        if (call.phase == ChatVoiceModePhase.speaking) ...[
                          const SizedBox(height: 16),
                          IconButton(
                            tooltip: 'Interrupt and talk',
                            onPressed: controller.cancelSpeaking,
                            icon: const Icon(Icons.mic_none_outlined),
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                          ),
                        ],
                        if (call.phase == ChatVoiceModePhase.paused) ...[
                          const SizedBox(height: 16),
                          IconButton(
                            key: const ValueKey('hermes-call-resume'),
                            tooltip: 'Resume call',
                            onPressed: controller.resume,
                            icon: const Icon(Icons.play_arrow_rounded),
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                          ),
                        ],
                        if (call.errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              voiceModeErrorText(
                                    AppLocalizations.of(context)!,
                                    kind: call.errorKind,
                                    message: call.errorMessage,
                                  ) ??
                                  'Voice unavailable',
                              style: TextStyle(color: theme.error),
                            ),
                          ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
              if (request != null)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .45,
                  ),
                  child: SingleChildScrollView(
                    child: HermesComposerPromptOverlay(
                      key: ValueKey('call-request-${request.id}'),
                      message: request,
                      presentation: HermesPromptPresentation.callSurface,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Row(
                  children: [
                    Expanded(
                      child: _CallAction(
                        key: const ValueKey('hermes-expanded-mute'),
                        label: call.isMuted
                            ? 'Unmute microphone'
                            : 'Mute microphone',
                        selected: call.isMuted,
                        icon: call.isMuted
                            ? Icons.mic_off_outlined
                            : Icons.mic_none_outlined,
                        onPressed: controller.toggleMute,
                      ),
                    ),
                    Expanded(
                      child: _CallAction(
                        key: const ValueKey('hermes-call-audio'),
                        label: audio.next == null
                            ? 'Audio output: ${route?.name ?? "Phone"}'
                            : 'Audio output: ${route?.name ?? "Phone"}. Switch to ${audio.next!.name}',
                        icon: routeIcon,
                        onPressed: audio.changing || audio.next == null
                            ? null
                            : () async {
                                final applied = await ref
                                    .read(callAudioRoutesProvider.notifier)
                                    .cycle();
                                if (!applied && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Could not switch audio output. Try again.',
                                      ),
                                    ),
                                  );
                                }
                              },
                      ),
                    ),
                    Expanded(
                      child: _CallAction(
                        key: const ValueKey('hermes-call-captions'),
                        label: captions ? 'Hide captions' : 'Show captions',
                        selected: captions,
                        icon: Icons.closed_caption_outlined,
                        onPressed: ref
                            .read(hermesCallCaptionsProvider.notifier)
                            .toggle,
                      ),
                    ),
                    Expanded(
                      child: _CallAction(
                        key: const ValueKey('hermes-expanded-end'),
                        label: 'End call',
                        icon: Icons.call_end_outlined,
                        destructive: true,
                        onPressed: controller.stop,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: math.max(
                  20,
                  MediaQuery.textScalerOf(context).scale(11) * 1.4,
                ),
                child: Row(
                  children: [
                    const Expanded(child: SizedBox()),
                    Expanded(
                      flex: 3,
                      child: Text(
                        route?.kind == 'bluetooth' || route?.kind == 'wired'
                            ? route!.name
                            : '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.start,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('hermes-call-conversation'),
                tooltip: 'Open conversation',
                onPressed: controller.collapse,
                icon: const Icon(HermesMessageIcons.messages),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallAction extends StatelessWidget {
  const _CallAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.destructive = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected, destructive;
  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      toggled: selected,
      child: Center(
        child: IconButton.filledTonal(
          tooltip: label,
          style: IconButton.styleFrom(
            minimumSize: const Size(54, 54),
            backgroundColor: destructive
                ? theme.error
                : selected
                ? theme.selectionBackground
                : theme.surfaceContainerHighest,
            foregroundColor: destructive
                ? Theme.of(context).colorScheme.onError
                : selected
                ? theme.selectionForeground
                : theme.textPrimary,
          ),
          onPressed: onPressed == null
              ? null
              : () {
                  ConduitHaptics.selectionClick();
                  onPressed!();
                },
          icon: Icon(icon, size: 24),
        ),
      ),
    );
  }
}

Future<void> showHermesCallSkills(BuildContext context) =>
    showCompactConfigurationSheet<void>(context, (_) => const _CallSkills());

final hermesCallSkillDraftsProvider =
    NotifierProvider<CallSkillDrafts, Map<String, String>>(CallSkillDrafts.new);

class CallSkillDrafts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    ref.watch(chatVoiceModeControllerProvider.select((s) => s.startedAt));
    return const {};
  }

  void save(String name, String text) => state = {...state, name: text};
}

class _CallSkills extends ConsumerStatefulWidget {
  const _CallSkills();
  @override
  ConsumerState<_CallSkills> createState() => _CallSkillsState();
}

class _CallSkillsState extends ConsumerState<_CallSkills> {
  String _query = '';
  bool _search = false, _sending = false;
  Prompt? _selected;
  final _instructions = TextEditingController();

  late final _callOwner = ref.read(chatVoiceModeControllerProvider).startedAt;
  late final _chatOwner = ref.read(activeConversationProvider)?.id;
  @override
  void dispose() {
    _instructions.dispose();
    super.dispose();
  }

  String title(Prompt skill) => skill.command
      .replaceFirst('/', '')
      .replaceAll(RegExp('[-_]'), ' ')
      .split(' ')
      .where((s) => s.isNotEmpty)
      .map((s) => '${s[0].toUpperCase()}${s.substring(1)}')
      .join(' ');
  @override
  Widget build(BuildContext context) {
    final call = ref.watch(chatVoiceModeControllerProvider);
    final owner = ref.watch(activeConversationProvider)?.id;
    final skills = ref.watch(hermesCallSkillsProvider);
    final selected = _selected;
    final request = ref.watch(
      chatMessagesProvider.select(findPendingHermesComposerPrompt),
    );
    final canSend =
        call.isActive &&
        call.startedAt == _callOwner &&
        owner == _chatOwner &&
        (call.phase == ChatVoiceModePhase.listening ||
            call.phase == ChatVoiceModePhase.muted) &&
        request == null &&
        !_sending;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.max(
            120,
            math.min(
              MediaQuery.sizeOf(context).height * .7,
              MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).bottom -
                  140,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (selected != null)
                  IconButton(
                    tooltip: 'Back to skills',
                    onPressed: () {
                      ref
                          .read(hermesCallSkillDraftsProvider.notifier)
                          .save(selected.command, _instructions.text);
                      setState(() => _selected = null);
                    },
                    icon: const Icon(HermesMessageIcons.back),
                  ),
                Expanded(
                  child: Text(
                    selected == null ? 'Skills' : title(selected),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (selected == null)
                  IconButton(
                    tooltip: 'Search skills',
                    onPressed: () => setState(() => _search = !_search),
                    icon: const HermesSearchIcon(),
                  ),
                IconButton(
                  tooltip: 'Close skills',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(HermesMessageIcons.close),
                ),
              ],
            ),
            if (selected == null && _search)
              TextField(
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search skills'),
                onChanged: (v) => setState(() => _query = v),
              ),
            if (selected == null)
              Flexible(
                child: skills.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (_, _) => TextButton(
                    onPressed: () => ref.invalidate(hermesCallSkillsProvider),
                    child: const Text('Retry skills'),
                  ),
                  data: (items) {
                    final filtered = items
                        .where(
                          (s) => '${s.command} ${s.title}'
                              .toLowerCase()
                              .contains(_query.toLowerCase()),
                        )
                        .toList();
                    if (filtered.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _query.isEmpty
                              ? 'No skills available.'
                              : 'No matching skills.',
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      separatorBuilder: (context, _) => Divider(
                        height: 1,
                        color: context.conduitTheme.textSecondary.withValues(
                          alpha: .6,
                        ),
                      ),
                      itemBuilder: (context, i) {
                        final skill = filtered[i];
                        return InkWell(
                          onTap: () {
                            _instructions.text =
                                ref.read(
                                  hermesCallSkillDraftsProvider,
                                )[skill.command] ??
                                '';
                            setState(() => _selected = skill);
                          },
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  const HermesSkillsIcon(),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      title(skill),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color:
                                            context.conduitTheme.textSecondary,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.all(3),
                                      child: Icon(
                                        Icons.arrow_forward_rounded,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            if (selected != null) ...[
              if (selected.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(selected.title),
                ),
              TextField(
                controller: _instructions,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(hintText: 'Add instructions'),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.icon(
                  key: const ValueKey('hermes-call-skill-send'),
                  onPressed: !canSend
                      ? null
                      : () async {
                          setState(() => _sending = true);
                          final detail = _instructions.text.trim();
                          // Natural-language admission keeps the exact installed name and
                          // avoids collisions with server built-in slash commands.
                          final text =
                              'Use the installed skill "${selected.command.replaceFirst('/', '')}".${detail.isEmpty ? '' : '\n$detail'}';
                          final accepted = await ref
                              .read(chatVoiceModeControllerProvider.notifier)
                              .submitText(text);
                          if (!context.mounted) return;
                          if (accepted) {
                            Navigator.of(context).pop();
                          } else {
                            setState(() => _sending = false);
                          }
                        },
                  icon: const Icon(HermesMessageIcons.send, size: 20),
                  label: const Text('Send'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

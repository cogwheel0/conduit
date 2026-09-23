import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/voice_providers.dart';
import '../voice.dart';
import 'ui.dart';

/// "Read aloud" under an answer (M8). Revealed on hover like the other
/// actions, and kept in view while it reads, so it can be stopped.
class ReadAloudButton extends StatelessComponent {
  const ReadAloudButton({required this.id, required this.text, super.key});

  final String id;
  final String text;

  @override
  Component build(BuildContext context) {
    final reading = context.watch(speechPlayerProvider).id == id;
    final label = reading
        ? t.desktop.desktopStopReading
        : t.desktop.desktopReadAloud;
    return iconButton(
      glyph: reading ? LucideIcon.square : LucideIcon.volume2,
      label: label,
      pressed: reading,
      classes: reading
          ? 'text-foreground'
          : 'opacity-0 transition-opacity group-hover:opacity-100 '
                'group-focus-within:opacity-100',
      attributes: <String, String>{'data-read-aloud': id},
      onClick: () =>
          context.read(speechPlayerProvider.notifier).toggle(id, text),
    );
  }
}

/// A small meter of how loud the microphone is.
Component _meter(double level) => span(
  classes: 'inline-flex h-3 w-1 flex-col overflow-hidden rounded-lg bg-surface-hover',
  attributes: const <String, String>{'aria-hidden': 'true'},
  [
    span(
      classes: 'block w-full bg-foreground-subtle',
      styles: Styles(
        raw: <String, String>{
          'height': '${(level * 400).clamp(8, 100).round()}%',
          'margin-top': 'auto',
        },
      ),
      [],
    ),
  ],
);

/// The composer's microphone (WP-8.1): click to dictate until a pause, or
/// with hold-to-talk, hold it down.
class DictationButton extends StatelessComponent {
  const DictationButton({super.key});

  @override
  Component build(BuildContext context) {
    final state = context.watch(dictationProvider);
    final hold =
        context.watch(voiceSettingsProvider).value?.holdToTalk ?? false;
    final dictation = context.read(dictationProvider.notifier);
    final listening = state.phase == DictationPhase.listening;
    final transcribing = state.phase == DictationPhase.transcribing;
    final label = transcribing
        ? t.app.transcribingAudio
        : listening
        ? t.desktop.desktopStopDictation
        : t.app.startDictation;
    return button(
      [
        icon(
          transcribing ? LucideIcon.loaderCircle : LucideIcon.mic,
          classes: 'size-4 shrink-0${transcribing ? ' animate-spin' : ''}',
        ),
        if (listening) _meter(state.level),
      ],
      id: 'dictate',
      classes:
          'inline-flex h-8 min-w-8 shrink-0 items-center justify-center gap-1 '
          'rounded-lg px-2 transition-colors '
          '${listening ? 'bg-selected text-foreground' : 'text-foreground-subtle hover:bg-hover hover:text-foreground'}',
      type: ButtonType.button,
      disabled: transcribing,
      attributes: <String, String>{
        'aria-label': label,
        'aria-pressed': '$listening',
        ...tooltipAttributes(label, side: TooltipSide.top),
      },
      events: hold
          ? <String, EventCallback>{
              'pointerdown': (_) => unawaited(dictation.start(hold: true)),
              'pointerup': (_) => unawaited(dictation.finish()),
              'pointerleave': (_) => unawaited(dictation.finish()),
            }
          : null,
      onClick: hold ? null : () => unawaited(dictation.toggle()),
    );
  }
}

/// Why dictation stopped, if it did not work.
String? dictationProblemText(DictationProblem? problem) => switch (problem) {
  null => null,
  DictationProblem.unavailable => t.app.voiceInputUnavailable,
  DictationProblem.microphone => t.desktop.desktopMicrophoneUnavailable,
  DictationProblem.nothingHeard => t.desktop.desktopNothingHeard,
  DictationProblem.failed => t.desktop.desktopTranscriptionFailed,
};

/// Starts a voice call (WP-8.3).
class VoiceCallButton extends StatelessComponent {
  const VoiceCallButton({super.key});

  @override
  Component build(BuildContext context) {
    final label = t.app.androidAssistantVoiceCallOption;
    return iconButton(
      id: 'voice-call',
      glyph: LucideIcon.audioLines,
      label: label,
      size: ControlSize.md,
      tooltip: TooltipSide.top,
      onClick: () =>
          unawaited(context.read(voiceCallProvider.notifier).start()),
    );
  }
}

/// The call, over the composer while it runs (WP-8.3): what it is doing,
/// what it heard, and mute, pause and hang up.
class VoiceCallPanel extends StatelessComponent {
  const VoiceCallPanel({super.key});

  @override
  Component build(BuildContext context) {
    final call = context.watch(voiceCallProvider);
    final machine = context.read(voiceCallProvider.notifier);
    if (!call.active) {
      final problem = switch (call.problem) {
        null => null,
        CallProblem.unavailable => t.app.voiceInputUnavailable,
        CallProblem.microphone => t.desktop.desktopMicrophoneUnavailable,
        CallProblem.failed => t.app.couldNotConnectGeneric,
      };
      if (problem == null) return const Component.empty();
      return p(
        classes: 'mx-auto mb-2 max-w-3xl text-ui-sm text-destructive',
        attributes: const <String, String>{'role': 'alert'},
        [Component.text(problem)],
      );
    }
    final status = switch (call.phase) {
      CallPhase.listening when call.muted => t.app.voiceCallMuted,
      CallPhase.listening => t.app.voiceCallListening,
      CallPhase.transcribing => t.app.transcribingAudio,
      CallPhase.thinking => t.app.voiceCallProcessing,
      CallPhase.speaking => t.app.voiceCallSpeaking,
      CallPhase.paused => t.app.voiceCallPaused,
      CallPhase.off => '',
    };
    Component control(
      String text,
      void Function() onClick, {
      String? id,
      bool danger = false,
      bool? pressed,
    }) => button(
      [Component.text(text)],
      id: id,
      classes: buttonClasses(
        tone: danger
            ? ButtonTone.destructive
            : pressed ?? false
            ? ButtonTone.secondary
            : ButtonTone.outline,
        size: ControlSize.sm,
      ),
      type: ButtonType.button,
      attributes: <String, String>{'aria-pressed': ?pressed?.toString()},
      onClick: onClick,
    );

    return section(
      classes:
          'mx-auto mb-2 flex max-w-3xl items-center gap-2 rounded-xl border '
          'border-border bg-panel px-3.5 py-2.5 shadow-sm',
      attributes: <String, String>{
        'role': 'region',
        'aria-label': t.app.voiceCallTitle,
      },
      [
        div(classes: 'min-w-0 flex-1', [
          p(
            classes: 'flex items-center gap-2 text-ui-sm font-medium',
            attributes: const <String, String>{
              'role': 'status',
              'aria-live': 'polite',
            },
            [
              if (call.phase == CallPhase.listening && !call.muted)
                _meter(call.level),
              Component.text(status),
            ],
          ),
          if (call.heard case final heard?)
            p(classes: 'truncate text-ui-sm text-foreground-subtle', [
              Component.text(t.desktop.desktopVoiceCallHeard(text: heard)),
            ]),
          if (call.problem == CallProblem.failed)
            p(classes: 'text-ui-sm text-destructive', [
              Component.text(t.app.couldNotConnectGeneric),
            ]),
        ]),
        // One name, pressed or not, as a toggle button should be.
        control(
          t.app.mute,
          () => unawaited(machine.toggleMute()),
          id: 'call-mute',
          pressed: call.muted,
        ),
        if (call.phase == CallPhase.paused)
          control(
            t.app.voiceCallResume,
            () => unawaited(machine.resume()),
            id: 'call-pause',
          )
        else
          control(t.app.voiceCallPause, machine.pause, id: 'call-pause'),
        control(t.app.voiceCallEnd, machine.end, id: 'call-end', danger: true),
      ],
    );
  }
}

import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/voice_providers.dart';
import '../voice.dart';
import '../widgets/form_field.dart';
import 'workspace/workspace_common.dart' show actionButton, statusLine;

/// Settings → Audio (M8): dictation, and how answers are read aloud. Each
/// control saves as it changes, as the appearance tab's do.
class AudioSettingsTab extends StatelessComponent {
  const AudioSettingsTab({super.key});

  @override
  Component build(BuildContext context) {
    final settings = context.watch(voiceSettingsProvider);
    final value = settings.value;
    if (value == null) {
      return statusLine(
        settings.hasError ? t.app.couldNotConnectGeneric : t.app.loadingShort,
        error: settings.hasError,
      );
    }
    return div(classes: 'space-y-8', [_Dictation(value), _Speech(value)]);
  }
}

void _save(BuildContext context, VoiceSettingsEdit edit) =>
    unawaited(context.read(voiceActionsProvider).save(edit));

Component _section(String title, List<Component> children) => section(
  classes: 'space-y-4',
  attributes: <String, String>{'aria-label': title},
  [
    h3(classes: 'text-ui-base font-semibold text-foreground', [
      Component.text(title),
    ]),
    ...children,
  ],
);

Component _hint(String text) =>
    p(classes: 'text-ui-sm text-muted-foreground', [Component.text(text)]);

/// A slider that saves when it is let go.
Component _slider({
  required String id,
  required String text,
  required String shown,
  required num value,
  required num min,
  required num max,
  required num step,
  required void Function(double value) onChanged,
  bool disabled = false,
}) => div(classes: 'space-y-1.5', [
  div(classes: 'flex items-center justify-between text-ui-base', [
    label(htmlFor: id, classes: 'font-medium text-foreground', [
      Component.text(text),
    ]),
    span(classes: 'text-ui-sm text-muted-foreground', [Component.text(shown)]),
  ]),
  input<Object?>(
    id: id,
    type: InputType.range,
    classes: 'w-full accent-primary',
    value: '$value',
    disabled: disabled,
    attributes: <String, String>{'min': '$min', 'max': '$max', 'step': '$step'},
    onChange: (raw) {
      final parsed = double.tryParse(numberFieldText(raw));
      if (parsed != null) onChanged(parsed);
    },
  ),
]);

class _Dictation extends StatefulComponent {
  const _Dictation(this.settings);

  final VoiceSettings settings;

  @override
  State<_Dictation> createState() => _DictationState();
}

class _DictationState extends State<_Dictation> {
  late String _language = component.settings.sttLanguage ?? '';

  static final RegExp _code = RegExp(r'^[a-zA-Z]{2,3}$');

  bool get _languageValid =>
      _language.trim().isEmpty || _code.hasMatch(_language.trim());

  @override
  Component build(BuildContext context) {
    final settings = component.settings;
    final local = settings.sttEngine == 'local';
    return _section(t.app.sttSettings, [
      if (settings.localStt) ...[
        fieldset(classes: 'space-y-2 border-0 p-0', [
          legend(classes: 'text-ui-base font-medium text-foreground', [
            Component.text(t.app.sttEngineLabel),
          ]),
          for (final (engine, text, description, enabled)
              in <(String, String, String, bool)>[
                (
                  'server',
                  t.app.sttEngineServer,
                  settings.serverStt
                      ? t.app.sttEngineServerDescription
                      : t.app.sttServerUnavailableWarning,
                  settings.serverStt,
                ),
                (
                  'local',
                  t.desktop.desktopSttEngineLocal,
                  t.desktop.desktopSttEngineLocalDescription,
                  true,
                ),
              ])
            div(classes: 'flex items-start gap-2', [
              input<bool>(
                id: 'stt-engine-$engine',
                type: InputType.radio,
                name: 'stt-engine',
                classes: 'mt-1',
                checked: settings.sttEngine == engine,
                disabled: !enabled,
                onChange: (_) =>
                    _save(context, VoiceSettingsEdit(sttEngine: engine)),
              ),
              div([
                label(htmlFor: 'stt-engine-$engine', classes: 'text-ui-base', [
                  Component.text(text),
                ]),
                _hint(description),
              ]),
            ]),
        ]),
        if (local) _LocalModels(settings),
      ] else if (!settings.serverStt)
        statusLine(t.app.sttServerUnavailableWarning),
      div(classes: 'space-y-1', [
        textField(
          id: 'voice-language',
          labelText: t.app.sttTranscriptionLanguage,
          placeholder: t.app.sttTranscriptionLanguagePlaceholder,
          value: _language,
          error: _languageValid ? null : t.app.sttTranscriptionLanguageInvalid,
          onInput: (value) {
            setState(() => _language = value);
            final code = value.trim().toLowerCase();
            if (code.isEmpty) {
              _save(context, const VoiceSettingsEdit(clearSttLanguage: true));
            } else if (_code.hasMatch(code)) {
              _save(context, VoiceSettingsEdit(sttLanguage: code));
            }
          },
        ),
        _hint(t.app.sttTranscriptionLanguageDescription),
      ]),
      _slider(
        id: 'voice-silence',
        text: t.app.sttSilenceDuration,
        shown: t.desktop.desktopMilliseconds(ms: settings.silenceMs),
        value: settings.silenceMs,
        min: 300,
        max: 5000,
        step: 100,
        onChanged: (value) =>
            _save(context, VoiceSettingsEdit(silenceMs: value.round())),
      ),
      checkboxField(
        id: 'voice-hold',
        text: t.app.voiceHoldToTalk,
        checked: settings.holdToTalk,
        onChanged: ({required value}) =>
            _save(context, VoiceSettingsEdit(holdToTalk: value)),
      ),
      checkboxField(
        id: 'voice-auto-send',
        text: t.app.voiceAutoSend,
        checked: settings.autoSend,
        onChanged: ({required value}) =>
            _save(context, VoiceSettingsEdit(autoSend: value)),
      ),
      div(classes: 'space-y-1', [
        checkboxField(
          id: 'voice-barge-in',
          text: t.app.voiceBargeIn,
          checked: settings.bargeIn,
          onChanged: ({required value}) =>
              _save(context, VoiceSettingsEdit(bargeIn: value)),
        ),
        div(classes: 'pl-6', [_hint(t.app.voiceBargeInDescription)]),
      ]),
    ]);
  }
}

class _Speech extends StatelessComponent {
  const _Speech(this.settings);

  final VoiceSettings settings;

  @override
  Component build(BuildContext context) {
    final server = settings.ttsEngine == 'server' && settings.serverTts;
    final previewing = context.watch(speechPlayerProvider).id == 'preview';
    return _section(t.app.ttsSettings, [
      fieldset(classes: 'space-y-2 border-0 p-0', [
        legend(classes: 'text-ui-base font-medium text-foreground', [
          Component.text(t.app.ttsEngineLabel),
        ]),
        for (final (engine, text, description, enabled)
            in <(String, String, String, bool)>[
              (
                'device',
                t.app.ttsEngineDevice,
                t.app.ttsEngineDeviceDescription,
                true,
              ),
              (
                'server',
                t.app.ttsEngineServer,
                settings.serverTts
                    ? t.app.ttsEngineServerDescription
                    : t.app.ttsServerUnavailableWarning,
                settings.serverTts,
              ),
            ])
          div(classes: 'flex items-start gap-2', [
            input<bool>(
              id: 'tts-engine-$engine',
              type: InputType.radio,
              name: 'tts-engine',
              classes: 'mt-1',
              checked: (engine == 'server') == server,
              disabled: !enabled,
              onChange: (_) =>
                  _save(context, VoiceSettingsEdit(ttsEngine: engine)),
            ),
            div([
              label(htmlFor: 'tts-engine-$engine', classes: 'text-ui-base', [
                Component.text(text),
              ]),
              _hint(description),
            ]),
          ]),
      ]),
      if (server) _serverVoices(context) else _deviceVoices(context),
      _slider(
        id: 'tts-rate',
        text: t.app.ttsSpeechRate,
        shown: '${(settings.rate * 2).toStringAsFixed(1)}×',
        value: settings.rate,
        min: 0.1,
        max: 1,
        step: 0.05,
        onChanged: (value) => _save(context, VoiceSettingsEdit(rate: value)),
      ),
      _slider(
        id: 'tts-pitch',
        text: t.app.ttsPitch,
        shown: settings.pitch.toStringAsFixed(1),
        value: settings.pitch,
        min: 0.5,
        max: 2,
        step: 0.1,
        disabled: server,
        onChanged: (value) => _save(context, VoiceSettingsEdit(pitch: value)),
      ),
      _slider(
        id: 'tts-volume',
        text: t.app.ttsVolume,
        shown: '${(settings.volume * 100).round()}%',
        value: settings.volume,
        min: 0,
        max: 1,
        step: 0.05,
        onChanged: (value) => _save(context, VoiceSettingsEdit(volume: value)),
      ),
      actionButton(
        previewing ? t.app.ttsStop : t.app.ttsPreview,
        id: 'tts-preview',
        onClick: () => context
            .read(speechPlayerProvider.notifier)
            .toggle('preview', t.app.ttsPreviewText),
      ),
    ]);
  }

  Component _voiceSelect({
    required List<(String, String)> choices,
    required String? selected,
    required String defaultText,
    required void Function(String? id) onChanged,
  }) => div(classes: 'space-y-1.5', [
    label(htmlFor: 'tts-voice', classes: 'block text-ui-base font-medium', [
      Component.text(t.app.ttsVoice),
    ]),
    select(
      [
        option(value: '', selected: selected == null, [
          Component.text(defaultText),
        ]),
        for (final (id, name) in choices)
          option(value: id, selected: selected == id, [Component.text(name)]),
      ],
      id: 'tts-voice',
      classes: 'w-full rounded border border-border bg-background px-3 py-2 text-ui-base',
      onChange: (values) {
        final id = values.isEmpty ? '' : values.first;
        onChanged(id.isEmpty ? null : id);
      },
    ),
  ]);

  Component _deviceVoices(BuildContext context) {
    final voices = context.watch(deviceVoicesProvider).value;
    if (voices != null && voices.isEmpty) {
      return statusLine(t.app.ttsNoVoicesAvailable);
    }
    return _voiceSelect(
      choices: <(String, String)>[
        for (final voice in voices ?? const [])
          (
            voice.name,
            voice.language.isEmpty
                ? voice.name
                : '${voice.name} (${voice.language})',
          ),
      ],
      selected: settings.deviceVoice,
      defaultText: t.app.ttsSystemDefault,
      onChanged: (id) => _save(
        context,
        id == null
            ? const VoiceSettingsEdit(clearDeviceVoice: true)
            : VoiceSettingsEdit(deviceVoice: id),
      ),
    );
  }

  Component _serverVoices(BuildContext context) {
    final voices = context.watch(serverVoicesProvider).value;
    return _voiceSelect(
      choices: <(String, String)>[
        for (final voice in voices?.voices ?? const <VoiceOption>[])
          (voice.id, voice.name.isEmpty ? voice.id : voice.name),
      ],
      selected: settings.serverVoice,
      defaultText: voices?.defaultVoice == null
          ? t.app.ttsSystemDefault
          : '${t.app.ttsSystemDefault} (${voices!.defaultVoice})',
      onChanged: (id) => _save(
        context,
        id == null
            ? const VoiceSettingsEdit(clearServerVoice: true)
            : VoiceSettingsEdit(serverVoice: id),
      ),
    );
  }
}

String _megabytes(int bytes) => '${(bytes / 1e6).round()} MB';

/// The whisper models to download, use and delete (M11).
class _LocalModels extends StatelessComponent {
  const _LocalModels(this.settings);

  final VoiceSettings settings;

  @override
  Component build(BuildContext context) {
    final models = context.watch(voiceModelsProvider).value;
    final actions = context.read(voiceActionsProvider);
    Component small(String text, void Function() onClick, {String? id}) =>
        button(
          [Component.text(text)],
          id: id,
          classes:
              'rounded border border-border px-2 py-0.5 text-ui-sm '
              'hover:bg-accent',
          type: ButtonType.button,
          onClick: onClick,
        );
    return section(
      classes: 'space-y-3 rounded border border-border p-3',
      attributes: <String, String>{
        'aria-label': t.desktop.desktopSttModelsTitle,
      },
      [
        h4(classes: 'text-ui-base font-medium', [
          Component.text(t.desktop.desktopSttModelsTitle),
        ]),
        _hint(t.desktop.desktopSttModelsDescription),
        if (!settings.localReady)
          statusLine(t.desktop.desktopSttLocalNeedsModel),
        if (models?.failure case final failure?)
          statusLine(
            failure == 'checksum'
                ? t.desktop.desktopSttModelFailedChecksum
                : t.desktop.desktopSttModelFailedNetwork,
            error: true,
          ),
        if (models == null)
          statusLine(t.app.loadingShort)
        else
          ul(classes: 'divide-y divide-border', [
            for (final model in models.models)
              li(
                classes: 'flex items-center gap-2 py-2 text-ui-base',
                attributes: <String, String>{'data-model': model.id},
                [
                  span(classes: 'min-w-0 flex-1', [
                    Component.text(model.name),
                    if (model.englishOnly)
                      span(classes: 'ml-2 text-ui-sm text-muted-foreground', [
                        Component.text(t.desktop.desktopSttModelEnglishOnly),
                      ]),
                  ]),
                  if (model.receivedBytes case final received?)
                    span(
                      classes: 'text-ui-sm text-muted-foreground',
                      attributes: const <String, String>{'role': 'status'},
                      [
                        Component.text(
                          t.desktop.desktopSttModelDownloading(
                            percent: model.sizeBytes == 0
                                ? '0'
                                : '${(received * 100 / model.sizeBytes).floor()}',
                          ),
                        ),
                      ],
                    )
                  else if (model.downloaded) ...[
                    if (settings.localModel == model.id)
                      span(classes: 'text-ui-sm text-primary', [
                        Component.text(t.desktop.desktopSttModelInUse),
                      ])
                    else
                      small(
                        t.desktop.desktopSttModelUse,
                        () => _save(
                          context,
                          VoiceSettingsEdit(localModel: model.id),
                        ),
                      ),
                    small(
                      t.desktop.desktopSttModelDelete,
                      () => unawaited(actions.deleteModel(model.id)),
                    ),
                  ] else
                    small(
                      t.desktop.desktopSttModelDownload(
                        size: _megabytes(model.sizeBytes),
                      ),
                      () {
                        unawaited(actions.downloadModel(model.id));
                        // The first one downloaded is the one used.
                        if (settings.localModel == null) {
                          _save(
                            context,
                            VoiceSettingsEdit(localModel: model.id),
                          );
                        }
                      },
                      id: 'download-${model.id}',
                    ),
                ],
              ),
          ]),
      ],
    );
  }
}

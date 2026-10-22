import 'package:conduit_core/features/hermes/models/hermes_agent_settings.dart';
import 'package:conduit_core/features/hermes/models/hermes_setting_guidance.dart';
import 'package:intl/intl.dart';

import '../../../l10n/app_localizations.dart';

String settingExplanation(AppLocalizations l, HermesSettingField f) =>
    switch (f.path) {
      'memory.memory_char_limit' => l.mobileAgentMemoryBudgetHint,
      'memory.user_char_limit' => l.mobileAgentProfileBudgetHint,
      'compression.threshold' => l.mobileAgentThresholdHint,
      'compression.target_ratio' => l.mobileAgentCompressionTargetHint,
      'compression.protect_last_n' => l.mobileAgentRecentMessagesHint,
      'auxiliary.compression.timeout' => l.mobileAgentCompressionTimeoutHint,
      'approvals.timeout' => l.mobileAgentApprovalTimeoutHint,
      'checkpoints.max_snapshots' => l.mobileAgentCheckpointLimitHint,
      'file_read_max_chars' => l.mobileAgentFileReadLimitHint,
      'tool_output.max_bytes' => l.mobileAgentToolOutputLimitHint,
      'tool_output.max_lines' => l.mobileAgentOutputLinesHint,
      'tool_output.max_line_length' => l.mobileAgentLineLengthHint,
      'terminal.timeout' => l.mobileAgentCommandTimeoutHint,
      'agent.api_max_retries' => l.mobileAgentRetriesHint,
      'agent.max_turns' ||
      'delegation.max_iterations' => l.mobileAgentTurnsHint,
      'delegation.max_concurrent_children' => l.mobileAgentParallelHint,
      'delegation.child_timeout_seconds' => l.mobileAgentChildTimeoutHint,
      'model_context_length' => l.mobileAgentContextOverrideHint,
      'tts.xai.speed' => l.mobileAgentSpeechSpeedHint,
      'tts.xai.optimize_streaming_latency' => l.mobileAgentSpeechLatencyHint,
      'tts.xai.sample_rate' => l.mobileAgentSampleRateHint,
      'tts.xai.bit_rate' => l.mobileAgentBitRateHint,
      'tts.xai.auto_speech_tags' => l.mobileAgentSpeechTagsHint,
      'tts.provider' => l.mobileAgentSpeechProviderHint,
      'tts.openai.voice' ||
      'tts.xai.voice_id' ||
      'tts.gemini.voice' ||
      'tts.edge.voice' => l.mobileAgentVoiceCatalogHint,
      'tts.elevenlabs.voice_id' ||
      'tts.minimax.voice_id' ||
      'tts.mistral.voice_id' => l.mobileAgentAccountVoiceHint,
      'tts.piper.voice' ||
      'tts.kittentts.voice' ||
      'tts.deepinfra.voice' ||
      'tts.neutts.model' => l.mobileAgentLocalVoiceHint,
      _ => f.description,
    };

String settingNumberLabel(
  String path,
  num value,
  AppLocalizations l, {
  bool describeSpecial = true,
}) {
  if (describeSpecial &&
      path == 'agent.max_turns' &&
      (value == 0 || value == -1)) {
    return l.mobileAgentUnlimited;
  }
  if (describeSpecial && path == 'model_context_length' && value == 0) {
    return l.mobileAgentAutomatic;
  }
  if (describeSpecial &&
      path == 'delegation.child_timeout_seconds' &&
      value == 0) {
    return l.mobileAgentNoIdleTimeout;
  }
  if (path == 'tts.xai.optimize_streaming_latency') {
    return switch (value) {
      0 => l.mobileAgentLatencyQuality,
      1 => l.mobileAgentLatencyFaster,
      2 => l.mobileAgentLatencyAggressive,
      _ => value.toString(),
    };
  }
  final unit = hermesNumericGuidance[path]?.unit;
  final n = NumberFormat.decimalPattern(l.localeName);
  final number = n.format(value);
  return switch (unit) {
    HermesSettingUnit.characters => '$number ${l.mobileAgentUnitsCharacters}',
    HermesSettingUnit.seconds => '$number ${l.mobileAgentUnitsSeconds}',
    HermesSettingUnit.messages => '$number ${l.mobileAgentUnitsMessages}',
    HermesSettingUnit.lines => '$number ${l.mobileAgentUnitsLines}',
    HermesSettingUnit.turns => '$number ${l.mobileAgentUnitsTurns}',
    HermesSettingUnit.retries => '$number ${l.mobileAgentUnitsRetries}',
    HermesSettingUnit.subagents => '$number ${l.mobileAgentUnitsSubagents}',
    HermesSettingUnit.snapshots => '$number ${l.mobileAgentUnitsSnapshots}',
    HermesSettingUnit.tokens => '$number ${l.mobileAgentUnitsTokens}',
    HermesSettingUnit.percent => '${n.format(value * 100)}%',
    HermesSettingUnit.speed => '$number×',
    HermesSettingUnit.hertz => '${n.format(value / 1000)} kHz',
    HermesSettingUnit.bitsPerSecond => '${n.format(value / 1000)} kbps',
    _ => number,
  };
}

/// Built-in provider IDs only. Account/custom voices remain an explicit editor.
/// Keep OpenAI's legacy models on their documented nine-voice catalog.
List<String> settingVoiceChoices(
  HermesSettingField field,
  HermesAgentSettings settings,
) {
  final values = switch (field.path) {
    'tts.openai.voice' => [
      'alloy',
      'ash',
      'coral',
      'sage',
      'echo',
      'fable',
      'onyx',
      'nova',
      'shimmer',
      if (hermesSettingValue(settings.config, 'tts.openai.model') ==
          'gpt-4o-mini-tts') ...[
        'ballad',
        'verse',
        'marin',
        'cedar',
      ],
    ],
    'tts.xai.voice_id' => [
      'eve',
      'ara',
      'rex',
      'sal',
      'leo',
      'carina',
      'zagan',
      'helix',
      'orion',
      'luna',
      'iris',
      'altair',
      'zenith',
      'perseus',
      'helios',
      'lux',
      'kepler',
      'rigel',
      'cosmo',
      'celeste',
      'ursa',
      'sirius',
      'lumen',
      'castor',
      'naksh',
      'atlas',
      'aurora',
      'liora',
    ],
    'tts.gemini.voice' => [
      'Zephyr',
      'Puck',
      'Charon',
      'Kore',
      'Fenrir',
      'Leda',
      'Orus',
      'Aoede',
      'Callirrhoe',
      'Autonoe',
      'Enceladus',
      'Iapetus',
      'Umbriel',
      'Algieba',
      'Despina',
      'Erinome',
      'Algenib',
      'Rasalgethi',
      'Laomedeia',
      'Achernar',
      'Alnilam',
      'Schedar',
      'Gacrux',
      'Pulcherrima',
      'Achird',
      'Zubenelgenubi',
      'Vindemiatrix',
      'Sadachbia',
      'Sadaltager',
      'Sulafat',
    ],
    _ => <String>[],
  };
  return field.type == 'select'
      ? values.where(field.options.contains).toList()
      : values;
}

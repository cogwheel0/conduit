/// Source-checked units/defaults and editorial starting points. These are not
/// population statistics. See docs/settings-input-guidance.md for provenance.
enum HermesSettingUnit {
  characters,
  seconds,
  messages,
  lines,
  turns,
  retries,
  subagents,
  snapshots,
  tokens,
  percent,
  speed,
  hertz,
  bitsPerSecond,
  mode,
}

class HermesNumericGuidance {
  const HermesNumericGuidance(
    this.unit,
    this.presets, {
    this.defaultValue,
    this.minimum = 0,
    this.maximum,
    this.integerOnly = true,
    this.allowedValues,
  });
  final HermesSettingUnit unit;
  final List<num> presets;
  final num? defaultValue;
  final num minimum;
  final num? maximum;
  final bool integerOnly;
  final List<num>? allowedValues;

  bool accepts(num value) =>
      value.isFinite &&
      value >= minimum &&
      (maximum == null || value <= maximum!) &&
      (!integerOnly || value == value.roundToDouble()) &&
      (allowedValues == null || allowedValues!.contains(value));
}

const hermesNumericGuidance = <String, HermesNumericGuidance>{
  'model_context_length': HermesNumericGuidance(HermesSettingUnit.tokens, [
    0,
  ], defaultValue: 0),
  'memory.memory_char_limit': HermesNumericGuidance(
    HermesSettingUnit.characters,
    [1100, 2200, 4400],
    defaultValue: 2200,
    minimum: 0,
  ),
  'memory.user_char_limit': HermesNumericGuidance(
    HermesSettingUnit.characters,
    [700, 1375, 2750],
    defaultValue: 1375,
    minimum: 0,
  ),
  'compression.threshold': HermesNumericGuidance(
    HermesSettingUnit.percent,
    [.5, .75, .85],
    defaultValue: .5,
    maximum: 1,
    integerOnly: false,
  ),
  'compression.target_ratio': HermesNumericGuidance(
    HermesSettingUnit.percent,
    [.1, .2, .4],
    defaultValue: .2,
    minimum: .1,
    maximum: .8,
    integerOnly: false,
  ),
  'compression.protect_last_n': HermesNumericGuidance(
    HermesSettingUnit.messages,
    [8, 20, 40],
    defaultValue: 20,
  ),
  'auxiliary.compression.timeout': HermesNumericGuidance(
    HermesSettingUnit.seconds,
    [60, 120, 300],
    defaultValue: 120,
    minimum: 1,
    integerOnly: false,
  ),
  'approvals.timeout': HermesNumericGuidance(
    HermesSettingUnit.seconds,
    [60, 300, 600],
    defaultValue: 300,
    minimum: 0,
    integerOnly: true,
  ),
  'checkpoints.max_snapshots': HermesNumericGuidance(
    HermesSettingUnit.snapshots,
    [5, 20, 50],
    defaultValue: 20,
    minimum: 1,
  ),
  'file_read_max_chars': HermesNumericGuidance(
    HermesSettingUnit.characters,
    [30000, 100000, 200000],
    defaultValue: 100000,
    minimum: 1,
  ),
  // Hermes slices a Python string with this historical "bytes" setting.
  'tool_output.max_bytes': HermesNumericGuidance(
    HermesSettingUnit.characters,
    [25000, 50000, 100000],
    defaultValue: 50000,
    minimum: 1,
  ),
  'tool_output.max_lines': HermesNumericGuidance(
    HermesSettingUnit.lines,
    [500, 2000, 4000],
    defaultValue: 2000,
    minimum: 1,
  ),
  'tool_output.max_line_length': HermesNumericGuidance(
    HermesSettingUnit.characters,
    [500, 2000, 4000],
    defaultValue: 2000,
    minimum: 1,
  ),
  'terminal.timeout': HermesNumericGuidance(
    HermesSettingUnit.seconds,
    [60, 180, 600],
    defaultValue: 180,
    minimum: 1,
    integerOnly: true,
  ),
  'agent.api_max_retries': HermesNumericGuidance(
    HermesSettingUnit.retries,
    [1, 3, 5],
    defaultValue: 3,
    minimum: 1,
  ),
  'agent.max_turns': HermesNumericGuidance(HermesSettingUnit.turns, [
    0,
    50,
    250,
  ], minimum: -1),
  'delegation.max_iterations': HermesNumericGuidance(
    HermesSettingUnit.turns,
    [50, 250, 500],
    defaultValue: 250,
    minimum: 1,
  ),
  'delegation.max_concurrent_children': HermesNumericGuidance(
    HermesSettingUnit.subagents,
    [1, 5, 10],
    defaultValue: 10,
    minimum: 1,
  ),
  'delegation.child_timeout_seconds': HermesNumericGuidance(
    HermesSettingUnit.seconds,
    [0, 300, 1800],
    defaultValue: 0,
    integerOnly: false,
  ),
  'tts.xai.speed': HermesNumericGuidance(
    HermesSettingUnit.speed,
    [.8, 1, 1.2],
    defaultValue: 1,
    minimum: .7,
    maximum: 1.5,
    integerOnly: false,
  ),
  // Guide and REST reference disagree on mode 2. Offer only common modes.
  'tts.xai.optimize_streaming_latency': HermesNumericGuidance(
    HermesSettingUnit.mode,
    [0, 1],
    defaultValue: 0,
    allowedValues: [0, 1, 2],
  ),
  'tts.xai.sample_rate': HermesNumericGuidance(
    HermesSettingUnit.hertz,
    [24000, 44100, 48000],
    defaultValue: 24000,
    allowedValues: [8000, 16000, 22050, 24000, 44100, 48000],
  ),
  'tts.xai.bit_rate': HermesNumericGuidance(
    HermesSettingUnit.bitsPerSecond,
    [64000, 128000, 192000],
    defaultValue: 128000,
    allowedValues: [32000, 64000, 96000, 128000, 192000],
  ),
};

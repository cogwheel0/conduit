import 'dart:convert';

import 'hermes_setting_guidance.dart';

/// The curated server settings shown by the desktop app, with desktop-only
/// preferences omitted. A field must also exist in the connected gateway.
class HermesSettingGroup {
  const HermesSettingGroup(this.title, this.description, this.fields);
  final String title;
  final String description;
  final Map<String, String> fields;
}

const hermesMobileSettingGroups = <HermesSettingGroup>[
  HermesSettingGroup("Models", "Defaults for new conversations.", {
    "model_context_length": "Context window override",
    "agent.reasoning_effort": "Default reasoning effort",
    "agent.service_tier": "Speed mode",
  }),
  HermesSettingGroup("Chat", "Assistant style, time zone, and attachments.", {
    "display.personality": "Personality",
    "timezone": "Time zone",
    "display.show_reasoning": "Show reasoning",
    "agent.image_input_mode": "Image attachments",
  }),
  HermesSettingGroup("Memory", "What Hermes keeps between conversations.", {
    "memory.memory_enabled": "Persistent memory",
    "memory.user_profile_enabled": "User profile",
    "memory.memory_char_limit": "Memory budget",
    "memory.user_char_limit": "Profile budget",
    "memory.provider": "Memory provider",
  }),
  HermesSettingGroup("Context", "How long conversations are compressed.", {
    "context.engine": "Context engine",
    "compression.enabled": "Compress long conversations",
    "compression.threshold": "Compression threshold",
    "compression.codex_gpt55_autoraise": "Adapt compression to model",
    "compression.target_ratio": "Compression target",
    "compression.protect_last_n": "Keep recent messages",
    "auxiliary.compression.timeout": "Compression timeout",
  }),
  HermesSettingGroup("Safety", "Approvals, privacy, and checkpoints.", {
    "approvals.mode": "Approval mode",
    "approvals.timeout": "Approval timeout",
    "approvals.mcp_reload_confirm": "Confirm integration reloads",
    "command_allowlist": "Command allowlist",
    "security.redact_secrets": "Hide secrets",
    "security.allow_private_urls": "Allow private network URLs",
    "privacy.redact_pii": "Hide personal information",
    "checkpoints.enabled": "File checkpoints",
    "checkpoints.max_snapshots": "Checkpoint limit",
  }),
  HermesSettingGroup("Browser", "The browser Hermes uses on its server.", {
    "browser.use_real_profile": "Use server browser profile",
    "browser.allow_private_urls": "Allow private network URLs",
    "browser.auto_local_for_private_urls":
        "Use server browser for private URLs",
  }),
  HermesSettingGroup(
    "Workspace",
    "Files and shell access on the Hermes server.",
    {
      "terminal.cwd": "Working folder",
      "code_execution.mode": "Code execution mode",
      "terminal.persistent_shell": "Persistent shell",
      "terminal.env_passthrough": "Environment passthrough",
      "file_read_max_chars": "File read limit",
    },
  ),
  HermesSettingGroup(
    "Execution",
    "Tool limits and the server execution environment.",
    {
      "terminal.backend": "Execution backend",
      "terminal.timeout": "Command timeout",
      "terminal.docker_image": "Docker image",
      "terminal.singularity_image": "Singularity image",
      "terminal.modal_image": "Modal image",
      "terminal.daytona_image": "Daytona image",
      "tool_output.max_bytes": "Max bytes",
      "tool_output.max_lines": "Max lines",
      "tool_output.max_line_length": "Max line length",
      "agent.max_turns": "Agent turn limit",
      "agent.api_max_retries": "API retries",
      "agent.tool_use_enforcement": "Tool use enforcement",
    },
  ),
  HermesSettingGroup(
    "Delegation",
    "Defaults for work Hermes delegates to subagents.",
    {
      "delegation.model": "Subagent model",
      "delegation.provider": "Subagent provider",
      "delegation.max_iterations": "Subagent turn limit",
      "delegation.max_concurrent_children": "Parallel subagents",
      "delegation.child_timeout_seconds": "Subagent timeout",
      "delegation.reasoning_effort": "Subagent reasoning effort",
    },
  ),
  HermesSettingGroup(
    "Speech output",
    "Voice providers configured on Hermes. Phone playback is in App settings.",
    {
      "tts.provider": "Speech provider",
      "tts.edge.voice": "Voice",
      "tts.openai.model": "Model",
      "tts.openai.voice": "Voice",
      "tts.elevenlabs.voice_id": "Voice id",
      "tts.elevenlabs.model_id": "Model id",
      "tts.xai.voice_id": "Voice id",
      "tts.xai.language": "Language",
      "tts.xai.speed": "Speed",
      "tts.xai.auto_speech_tags": "Auto speech tags",
      "tts.xai.optimize_streaming_latency": "Optimize streaming latency",
      "tts.xai.sample_rate": "Sample rate",
      "tts.xai.bit_rate": "Bit rate",
      "tts.minimax.model": "Model",
      "tts.minimax.voice_id": "Voice id",
      "tts.mistral.model": "Model",
      "tts.mistral.voice_id": "Voice id",
      "tts.gemini.model": "Model",
      "tts.gemini.voice": "Voice",
      "tts.neutts.model": "Model",
      "tts.neutts.device": "Device",
      "tts.kittentts.model": "Model",
      "tts.kittentts.voice": "Voice",
      "tts.piper.voice": "Voice",
      "tts.deepinfra.model": "Model",
      "tts.deepinfra.voice": "Voice",
    },
  ),
  HermesSettingGroup(
    "Speech input",
    "Transcription providers configured on Hermes. Phone dictation is in App settings.",
    {
      "stt.enabled": "Transcription",
      "stt.echo_transcripts": "Show transcripts",
      "stt.provider": "Transcription provider",
      "stt.streaming": "Stream transcription",
      "stt.language": "Language",
      "stt.local.model": "Model",
      "stt.local.language": "Language",
      "stt.openai.model": "Model",
      "stt.openai.streaming_model": "Streaming model",
      "stt.groq.model": "Model",
      "stt.mistral.model": "Model",
      "stt.xai.model": "Model",
      "stt.deepinfra.model": "Model",
      "stt.elevenlabs.model_id": "Model id",
      "stt.elevenlabs.language_code": "Language code",
      "stt.elevenlabs.tag_audio_events": "Tag audio events",
      "stt.elevenlabs.diarize": "Diarize",
    },
  ),
];

Object? hermesSettingValue(Map<String, dynamic> config, String path) {
  Object? value = config;
  for (final part in path.split('.')) {
    if (value is! Map) return null;
    value = value[part];
  }
  return value;
}

Map<String, dynamic> hermesSettingPatch(String path, Object? value) {
  final parts = path.split('.');
  if (parts.any((part) => !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(part)) ||
      parts.any(
        (part) =>
            const {'constructor', 'prototype', '__proto__'}.contains(part),
      )) {
    throw const FormatException('Invalid setting path.');
  }
  Map<String, dynamic> result = {parts.last: value};
  for (final part in parts.reversed.skip(1)) {
    result = {part: result};
  }
  return result;
}

class HermesSettingField {
  const HermesSettingField(
    this.path,
    this.label,
    this.type,
    this.value,
    this.options,
    this.description, {
    this.minimum,
    this.maximum,
  });
  final String path;
  final String label;
  final String type;
  final Object? value;
  final List<String> options;
  final String description;
  final num? minimum;
  final num? maximum;

  void validate(Object? next) {
    final valid = switch (type) {
      'boolean' => next is bool,
      'number' =>
        next is num &&
            next.isFinite &&
            (hermesNumericGuidance[path]?.accepts(next) ?? true) &&
            (path != 'compression.threshold' || (next > 0 && next < 1)) &&
            (path != 'delegation.child_timeout_seconds' ||
                next == 0 ||
                next >= 30) &&
            (minimum == null || next >= minimum!) &&
            (maximum == null || next <= maximum!),
      'select' => next is String && options.contains(next),
      'list' =>
        next is List<String> &&
            next.length <= 256 &&
            next.every((item) => item.length <= 4096),
      'string' => next is String && next.length <= 16384,
      _ => false,
    };
    if (!valid) throw const FormatException('Invalid setting value.');
  }
}

class HermesAgentSettings {
  const HermesAgentSettings({
    required this.config,
    required this.schema,
    this.model = const {},
    this.auxiliary = const [],
    this.ensembles = const {},
    this.supportsGlobalModel = false,
  });
  final Map<String, dynamic> config;
  final Map<String, dynamic> schema;
  final Map<String, dynamic> model;
  final List<Map<String, dynamic>> auxiliary;
  final Map<String, dynamic> ensembles;
  final bool supportsGlobalModel;

  HermesSettingField? field(String path, String label) {
    final value = hermesSettingValue(config, path);
    final raw = schema[path];
    if (raw is! Map && value == null) return null;
    final spec = raw is Map ? raw : const {};
    var type =
        spec['type']?.toString() ??
        switch (value) {
          bool() => 'boolean',
          num() => 'number',
          List() => 'list',
          _ => 'string',
        };
    // The generic gateway schema reports nullable max_turns as a string.
    // Hermes accepts integer caps and 0 as Unlimited; retain the original
    // value for optimistic-concurrency checks while editing as a number.
    if (path == 'agent.max_turns' && type == 'string') type = 'number';
    if (!const {
      'boolean',
      'number',
      'string',
      'select',
      'list',
    }.contains(type)) {
      return null;
    }
    if (type == 'list' &&
        value is List &&
        value.any((item) => item is! String)) {
      return null;
    }
    final options =
        (spec['options'] as List?)?.whereType<String>().take(256).toList() ??
        const <String>[];
    if (type == 'select' && options.isEmpty) return null;
    return HermesSettingField(
      path,
      label,
      type,
      value,
      options,
      spec['description']?.toString() ?? '',
      minimum: spec['min'] is num ? spec['min'] as num : null,
      maximum: spec['max'] is num ? spec['max'] as num : null,
    );
  }

  List<HermesSettingField> fields(HermesSettingGroup group) => [
    for (final entry in group.fields.entries)
      if (_visible(entry.key)) ?field(entry.key, entry.value),
  ];

  bool _visible(String path) {
    final parts = path.split('.');
    if (parts.length < 3 || !const {'tts', 'stt'}.contains(parts.first)) {
      return true;
    }
    final provider =
        hermesSettingValue(config, '${parts.first}.provider')?.toString() ??
        (parts.first == 'tts' ? 'edge' : 'local');
    return parts[1] == provider;
  }

  bool sameValue(String path, Object? expected) =>
      jsonEncode(hermesSettingValue(config, path)) == jsonEncode(expected);
}

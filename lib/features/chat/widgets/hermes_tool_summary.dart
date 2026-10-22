import 'dart:convert';

import 'package:conduit_core/models/chat_message.dart';

enum HermesToolKind {
  terminal,
  code,
  search,
  web,
  skill,
  read,
  write,
  image,
  tool,
}

/// A bounded display summary of already-sanitized tool metadata. Raw details
/// remain on the status update; this never executes or fetches tool content.
class HermesToolSummary {
  const HermesToolSummary({
    required this.kind,
    required this.title,
    required this.toolName,
    required this.failed,
    this.preview,
  });

  final HermesToolKind kind;
  final String title;
  final String toolName;
  final String? preview;
  final bool failed;

  factory HermesToolSummary.fromUpdate(ChatStatusUpdate update) {
    final actionName = (update.action ?? '').replaceFirst('hermes_tool_', '');
    final description = update.description?.trim() ?? '';
    final name = actionName.startsWith('opaque')
        ? description.split(RegExp(r'\s·\s| failed')).first
        : actionName;
    final lower = name.toLowerCase();
    final details = update.items.where(
      (item) => item.presentation == ChatStatusItemPresentation.detail,
    );
    Map<String, dynamic> args = const {};
    for (final item in details) {
      if (item.title?.toLowerCase() != 'arguments') continue;
      try {
        final decoded = jsonDecode(item.snippet ?? '');
        if (decoded is Map<String, dynamic>) args = decoded;
      } on FormatException {
        // Persisted arguments may be truncated. Keep the raw value in Details.
      }
      break;
    }
    String? value(List<String> keys) {
      for (final key in keys) {
        final value = args[key];
        if (value is String && value.trim().isNotEmpty) return value;
      }
      return null;
    }

    late HermesToolKind kind;
    late String title;
    String? preview;
    if (lower == 'terminal' ||
        lower.contains('shell') ||
        lower == 'exec_command') {
      kind = HermesToolKind.terminal;
      title = 'Run command';
      preview = value(['command', 'cmd']);
    } else if (lower == 'execute_code' ||
        lower == 'python' ||
        lower == 'run_code') {
      kind = HermesToolKind.code;
      title = 'Run code';
      preview = value(['code', 'script']);
    } else if (lower.contains('skill')) {
      kind = HermesToolKind.skill;
      final operation = value(['action', 'operation'])?.toLowerCase();
      final skill = value(['name', 'skill_name', 'skill']);
      title = lower.contains('list') || operation == 'list'
          ? 'List skills'
          : lower.contains('read') ||
                lower.contains('view') ||
                operation == 'view' ||
                operation == 'read'
          ? 'Read skill'
          : 'Use skill';
      preview = skill;
    } else if (lower.contains('search')) {
      kind = HermesToolKind.search;
      title = lower.contains('tool')
          ? 'Search tools'
          : lower.contains('web')
          ? 'Search the web'
          : 'Search';
      preview = value(['query', 'q', 'pattern']);
    } else if (lower.contains('browser')) {
      kind = HermesToolKind.web;
      title = lower.contains('navigate')
          ? 'Open page'
          : lower.contains('screenshot')
          ? 'Capture page'
          : 'Use browser';
      preview = value(['url', 'uri', 'selector']);
    } else if (lower.contains('web') ||
        lower.contains('fetch') ||
        lower.contains('browse')) {
      kind = HermesToolKind.web;
      title = 'Read page';
      preview = value(['url', 'uri']);
    } else if (lower.contains('image')) {
      kind = HermesToolKind.image;
      title = 'Work with image';
      preview = value(['prompt', 'path']);
    } else if (lower.contains('read') || lower.contains('file_view')) {
      kind = HermesToolKind.read;
      preview = value(['path', 'file_path', 'filename']);
      title = preview != null ? 'Read file' : 'Read content';
      final url = value(['url', 'uri']);
      if (preview == null && url != null) {
        kind = HermesToolKind.web;
        title = 'Read page';
        preview = url;
      }
    } else if (lower.contains('write') ||
        lower.contains('edit') ||
        lower.contains('patch')) {
      kind = HermesToolKind.write;
      preview = value(['path', 'file_path', 'filename']);
      title = preview != null ? 'Update file' : 'Update content';
    } else {
      kind = HermesToolKind.tool;
      title = name.isEmpty ? 'Use tool' : name.replaceAll('_', ' ');
    }
    if (preview == null && description.startsWith('$name · ')) {
      preview = description.substring(name.length + 3);
    }
    final failed =
        details.any((item) => item.title?.toLowerCase() == 'error') ||
        description.startsWith('$name failed');
    return HermesToolSummary(
      kind: kind,
      title: title,
      toolName: name,
      failed: failed,
      preview: preview == null
          ? null
          : String.fromCharCodes(
              preview.trim().replaceAll(RegExp(r'\s+'), ' ').runes.take(180),
            ),
    );
  }
}

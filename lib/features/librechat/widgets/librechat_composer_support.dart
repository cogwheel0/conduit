import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/librechat/models/librechat_prompts.dart';
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/utils/prompt_variable_parser.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../../shared/utils/external_link_launcher.dart';
import '../../prompts/widgets/prompt_variable_dialog.dart';

/// The composer's tool rows for a LibreChat model: the server's own tools,
/// then the user's MCP servers. Their ids map to the turn's
/// `ephemeralAgent` when it is sent.
List<Tool> libreChatComposerTools(
  AppLocalizations l10n,
  LibreChatComposerOptions options,
) => [
  if (options.webSearch)
    Tool(
      id: kLibreChatWebSearchToolId,
      name: l10n.webSearch,
      meta: const {'source': 'librechat'},
    ),
  if (options.codeInterpreter)
    Tool(
      id: kLibreChatCodeToolId,
      name: l10n.codeInterpreter,
      meta: const {'source': 'librechat'},
    ),
  if (options.fileSearch)
    Tool(
      id: kLibreChatFileSearchToolId,
      name: l10n.libreChatFileSearch,
      // Its own: the composer's guess by name reads "search" as the web.
      meta: {
        'source': 'librechat',
        'description': l10n.libreChatFileSearchDescription,
      },
    ),
  for (final server in options.mcpServers)
    Tool(
      id: server.toolId,
      name: server.name,
      meta: {
        'source': 'librechat_mcp',
        'description': server.needsConnection
            ? l10n.libreChatMcpConnect
            : l10n.directMcpContentServer,
        if (server.needsConnection) 'libreChatNeedsConnection': true,
      },
    ),
];

/// When [toolId] is a LibreChat MCP server that still needs signing in to,
/// opens the LibreChat web app, where that happens, and returns true: the
/// server cannot be used until then, so it is not switched on.
bool openLibreChatConnectionIfNeeded(WidgetRef ref, String toolId) {
  if (!toolId.startsWith(kLibreChatMcpToolIdPrefix)) return false;
  final options = ref.read(libreChatComposerOptionsProvider).asData?.value;
  final server = options?.mcpServers
      .where((server) => server.toolId == toolId)
      .firstOrNull;
  if (server == null || !server.needsConnection) return false;
  final baseUrl = ref.read(libreChatFileBaseUrlProvider);
  if (baseUrl != null) {
    // The system browser, where the user is signed in to LibreChat.
    unawaited(
      launchExternalLink(
        baseUrl,
        scope: 'librechat/mcp',
        mode: LaunchMode.externalApplication,
      ),
    );
  }
  return true;
}

/// Asks for the blanks in a LibreChat [prompt] and returns its text filled
/// in, LibreChat's way; null when the user cancels.
///
/// The form is the app's prompt-variable dialog, fed variables read with
/// LibreChat's grammar: `{{name}}` is a text field, `{{name:a|b}}` a choice.
/// Open WebUI's parser never reads a LibreChat prompt.
Future<String?> fillLibreChatPromptInteractively(
  BuildContext context,
  Prompt prompt, {
  String? userName,
}) async {
  final variables = libreChatPromptVariables(prompt.content);
  if (variables.isEmpty) {
    return fillLibreChatPrompt(prompt.content, userName: userName);
  }
  final names = <String>{};
  final fields = <PromptVariable>[];
  for (final variable in variables) {
    var name = variable.name.isEmpty ? 'value' : variable.name;
    for (var suffix = 2; !names.add(name); suffix++) {
      name = '${variable.name} $suffix';
    }
    // LibreChat's choices are suggestions: any answer may be typed. The
    // field is text, prefilled with the first choice, with the choices
    // offered under it. The dialog reads them as a list split at commas, so
    // a choice with a comma or quote in it is named in the hint instead.
    final options = variable.options
        .where((option) => option.isNotEmpty)
        .toList(growable: false);
    final suggestible =
        options.isNotEmpty &&
        options.every((option) => !option.contains(RegExp('[,"]')));
    fields.add(
      PromptVariable(
        fullMatch: '{{${variable.token}}}',
        name: name,
        type: PromptVariableType.text,
        // Optional, as on LibreChat: a blank left unanswered stays in the
        // prompt, to fill in before sending.
        properties: {
          if (suggestible)
            'options': '[${options.map((option) => '"$option"').join(',')}]',
          if (options.isNotEmpty) 'default': options.first,
          if (options.isNotEmpty) 'placeholder': options.join(' | '),
        },
        start: 0,
        end: 0,
      ),
    );
  }
  final answers = await PromptVariableDialog.show(
    context,
    variables: fields,
    promptTitle: prompt.title,
  );
  if (answers == null) return null;
  return fillLibreChatPrompt(
    prompt.content,
    values: {
      for (var index = 0; index < variables.length; index++)
        if (answers[fields[index].name]?.isNotEmpty ?? false)
          variables[index].token: answers[fields[index].name]!,
    },
    userName: userName,
  );
}

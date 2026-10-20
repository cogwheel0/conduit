import 'package:conduit/l10n/app_localizations.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/features/web_search/services/direct_web_search_mode.dart';
import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';

class ComposerOverflowActionIds {
  const ComposerOverflowActionIds._();

  static const file = 'file';
  static const serverFile = 'serverFile';
  static const photo = 'photo';
  static const camera = 'camera';
  static const web = 'web';
  static const mcpContent = 'mcpContent';
  static const webSearch = 'webSearch';
  static const imageGeneration = 'imageGeneration';
  static const codeInterpreter = 'codeInterpreter';
  static const toolSettings = 'toolSettings';
  static const compareModels = 'compareModels';
  static const _filterPrefix = 'filter:';
  static const _toolPrefix = 'tool:';
  static const _terminalPrefix = 'terminal:';

  static String filter(String filterId) => '$_filterPrefix$filterId';

  static String tool(String toolId) => '$_toolPrefix$toolId';

  /// A terminal row. The id carries a digest of the terminal's selection id,
  /// never the id itself: a direct terminal is selected by its URL, which can
  /// hold credentials.
  static String terminal(TerminalServerInfo server) =>
      '$_terminalPrefix${composerTerminalToken(server)}';

  static String? terminalTokenFrom(String actionId) {
    if (!actionId.startsWith(_terminalPrefix)) {
      return null;
    }

    final token = actionId.substring(_terminalPrefix.length);
    return token.isEmpty ? null : token;
  }

  static String? filterIdFrom(String actionId) {
    if (!actionId.startsWith(_filterPrefix)) {
      return null;
    }

    final filterId = actionId.substring(_filterPrefix.length);
    return filterId.isEmpty ? null : filterId;
  }

  static String? toolIdFrom(String actionId) {
    if (!actionId.startsWith(_toolPrefix)) {
      return null;
    }

    final toolId = actionId.substring(_toolPrefix.length);
    return toolId.isEmpty ? null : toolId;
  }
}

/// [action] rows run a command (such as opening a sheet) and never carry a
/// selected state.
enum ComposerOverflowItemKind { attachment, toggle, action }

enum ComposerOverflowSection {
  attachments('attachments'),
  features('features'),
  tools('tools'),
  filters('filters');

  const ComposerOverflowSection(this.nativeValue);

  final String nativeValue;

  /// The heading shown above the section, or null for the sections that lead
  /// the panel without one (the attach strip and the feature toggles).
  String? titleFor(AppLocalizations l10n) => switch (this) {
    ComposerOverflowSection.attachments => null,
    ComposerOverflowSection.features => null,
    ComposerOverflowSection.tools => l10n.tools,
    ComposerOverflowSection.filters => l10n.filters,
  };
}

/// Why the code interpreter cannot run, in the user's words.
String codeInterpreterBlockReason(
  AppLocalizations l10n,
  CodeInterpreterBlock block,
) => switch (block) {
  CodeInterpreterBlock.unsupportedEngine => l10n.codeInterpreterBrowserEngine,
  _ => l10n.codeInterpreterUnavailable,
};

class ComposerOverflowAttachmentAvailability {
  const ComposerOverflowAttachmentAvailability({
    this.file = false,
    this.serverFile = false,
    this.photo = false,
    this.camera = false,
    this.web = false,
    this.mcpContent = false,
  });

  final bool file;
  final bool serverFile;
  final bool photo;
  final bool camera;
  final bool web;
  final bool mcpContent;
}

class ComposerOverflowItem {
  const ComposerOverflowItem({
    required this.id,
    required this.kind,
    required this.section,
    required this.label,
    required this.cupertinoIcon,
    required this.materialIcon,
    required this.sfSymbol,
    this.subtitle,
    this.enabled = true,
    this.selected = false,
    this.dismissesKeyboard = true,
  });

  final String id;
  final ComposerOverflowItemKind kind;
  final ComposerOverflowSection section;
  final String label;
  final String? subtitle;
  final bool enabled;
  final bool selected;
  final bool dismissesKeyboard;
  final IconData cupertinoIcon;
  final IconData materialIcon;
  final String sfSymbol;

  IconData iconFor({required bool useCupertino}) {
    return useCupertino ? cupertinoIcon : materialIcon;
  }
}

List<ComposerOverflowItem> buildComposerOverflowItems({
  required AppLocalizations l10n,
  required ComposerOverflowAttachmentAvailability attachmentAvailability,
  required bool webSearchAvailable,
  required bool webSearchEnabled,
  required bool imageGenerationAvailable,
  required bool imageGenerationEnabled,
  required List<Tool> availableTools,
  required List<String> selectedToolIds,
  required List<ToggleFilter> availableFilters,
  required List<String> selectedFilterIds,
  ComposerPersonalConnections connections = ComposerPersonalConnections.none,
  bool toolSettingsAvailable = false,
  bool compareModelsAvailable = false,
  bool hasMessage = true,
  CodeInterpreterOffer? codeInterpreter,
}) {
  return <ComposerOverflowItem>[
    ...buildComposerOverflowAttachmentItems(
      l10n: l10n,
      attachmentAvailability: attachmentAvailability,
    ),
    ...buildComposerOverflowFeatureItems(
      l10n: l10n,
      webSearchAvailable: webSearchAvailable,
      webSearchEnabled: webSearchEnabled,
      imageGenerationAvailable: imageGenerationAvailable,
      imageGenerationEnabled: imageGenerationEnabled,
      codeInterpreter: codeInterpreter,
    ),
    ...buildComposerOverflowComparisonItems(
      l10n: l10n,
      available: compareModelsAvailable,
      hasMessage: hasMessage,
    ),
    ...buildComposerOverflowToolItems(
      availableTools: availableTools,
      selectedToolIds: selectedToolIds,
    ),
    ...buildComposerOverflowConnectionItems(
      l10n: l10n,
      connections: connections,
      selectedToolIds: selectedToolIds,
    ),
    ...buildComposerOverflowToolSettingsItems(
      l10n: l10n,
      available: toolSettingsAvailable,
    ),
    ...buildComposerOverflowFilterItems(
      availableFilters: availableFilters,
      selectedFilterIds: selectedFilterIds,
    ),
  ];
}

List<ComposerOverflowItem> buildComposerOverflowAttachmentItems({
  required AppLocalizations l10n,
  required ComposerOverflowAttachmentAvailability attachmentAvailability,
}) {
  return <ComposerOverflowItem>[
    ComposerOverflowItem(
      id: ComposerOverflowActionIds.file,
      kind: ComposerOverflowItemKind.attachment,
      section: ComposerOverflowSection.attachments,
      label: l10n.file,
      cupertinoIcon: CupertinoIcons.doc,
      materialIcon: Icons.attach_file,
      sfSymbol: 'doc',
      enabled: attachmentAvailability.file,
    ),
    ComposerOverflowItem(
      id: ComposerOverflowActionIds.serverFile,
      kind: ComposerOverflowItemKind.attachment,
      section: ComposerOverflowSection.attachments,
      label: l10n.files,
      cupertinoIcon: CupertinoIcons.folder,
      materialIcon: Icons.folder_rounded,
      sfSymbol: 'folder',
      enabled: attachmentAvailability.serverFile,
    ),
    ComposerOverflowItem(
      id: ComposerOverflowActionIds.photo,
      kind: ComposerOverflowItemKind.attachment,
      section: ComposerOverflowSection.attachments,
      label: l10n.photo,
      cupertinoIcon: CupertinoIcons.photo,
      materialIcon: Icons.image,
      sfSymbol: 'photo',
      enabled: attachmentAvailability.photo,
    ),
    ComposerOverflowItem(
      id: ComposerOverflowActionIds.camera,
      kind: ComposerOverflowItemKind.attachment,
      section: ComposerOverflowSection.attachments,
      label: l10n.camera,
      cupertinoIcon: CupertinoIcons.camera,
      materialIcon: Icons.camera_alt,
      sfSymbol: 'camera',
      enabled: attachmentAvailability.camera,
    ),
    ComposerOverflowItem(
      id: ComposerOverflowActionIds.web,
      kind: ComposerOverflowItemKind.attachment,
      section: ComposerOverflowSection.attachments,
      label: l10n.webPage,
      cupertinoIcon: CupertinoIcons.globe,
      materialIcon: Icons.public,
      sfSymbol: 'globe',
      enabled: attachmentAvailability.web,
    ),
    if (attachmentAvailability.mcpContent)
      ComposerOverflowItem(
        id: ComposerOverflowActionIds.mcpContent,
        kind: ComposerOverflowItemKind.attachment,
        section: ComposerOverflowSection.attachments,
        label: l10n.directMcpContentAction,
        cupertinoIcon: CupertinoIcons.text_quote,
        materialIcon: Icons.text_snippet_outlined,
        sfSymbol: 'text.quote',
      ),
  ];
}

List<ComposerOverflowItem> buildComposerOverflowFeatureItems({
  required AppLocalizations l10n,
  required bool webSearchAvailable,
  required bool webSearchEnabled,
  required bool imageGenerationAvailable,
  required bool imageGenerationEnabled,
  CodeInterpreterOffer? codeInterpreter,
}) {
  final items = <ComposerOverflowItem>[];

  if (webSearchAvailable) {
    items.add(
      ComposerOverflowItem(
        id: ComposerOverflowActionIds.webSearch,
        kind: ComposerOverflowItemKind.toggle,
        section: ComposerOverflowSection.features,
        label: l10n.webSearch,
        subtitle: l10n.webSearchDescription,
        cupertinoIcon: CupertinoIcons.search,
        materialIcon: Icons.search,
        sfSymbol: 'magnifyingglass',
        selected: webSearchEnabled,
        dismissesKeyboard: false,
      ),
    );
  }

  if (imageGenerationAvailable) {
    items.add(
      ComposerOverflowItem(
        id: ComposerOverflowActionIds.imageGeneration,
        kind: ComposerOverflowItemKind.toggle,
        section: ComposerOverflowSection.features,
        label: l10n.imageGeneration,
        subtitle: l10n.imageGenerationDescription,
        cupertinoIcon: CupertinoIcons.photo,
        materialIcon: Icons.image,
        sfSymbol: 'sparkles',
        selected: imageGenerationEnabled,
        dismissesKeyboard: false,
      ),
    );
  }

  if (codeInterpreter != null) {
    final block = codeInterpreter.block;
    items.add(
      ComposerOverflowItem(
        id: ComposerOverflowActionIds.codeInterpreter,
        kind: ComposerOverflowItemKind.toggle,
        section: ComposerOverflowSection.features,
        label: l10n.codeInterpreter,
        subtitle: block == null
            ? l10n.codeInterpreterDescription
            : codeInterpreterBlockReason(l10n, block),
        cupertinoIcon: CupertinoIcons.chevron_left_slash_chevron_right,
        materialIcon: Icons.code,
        sfSymbol: 'curlybraces',
        // An explanation row is not tappable, but a choice already made can
        // always be turned off.
        enabled: block == null || codeInterpreter.selected,
        selected: codeInterpreter.selected,
        dismissesKeyboard: false,
      ),
    );
  }

  return items;
}

List<ComposerOverflowItem> buildComposerOverflowToolItems({
  required List<Tool> availableTools,
  required List<String> selectedToolIds,
}) {
  final selectedToolIdSet = selectedToolIds.toSet();

  return <ComposerOverflowItem>[
    for (final tool in availableTools)
      ComposerOverflowItem(
        id: ComposerOverflowActionIds.tool(tool.id),
        kind: ComposerOverflowItemKind.toggle,
        section: ComposerOverflowSection.tools,
        label: tool.name,
        subtitle: composerOverflowToolDescription(tool),
        cupertinoIcon: composerOverflowToolCupertinoIcon(tool),
        materialIcon: composerOverflowToolMaterialIcon(tool),
        sfSymbol: composerOverflowToolSFSymbol(tool),
        selected: selectedToolIdSet.contains(tool.id),
        dismissesKeyboard: false,
      ),
  ];
}

/// Reads a provider; both `ref.watch` and `ref.read` fit, so the build-time
/// and the post-frame callers share one reader of the connections.
typedef ComposerRead = T Function<T>(ProviderListenable<T> provider);

/// The account a set of connection rows was built for.
///
/// Native panel taps arrive after the row was drawn, so one can land once
/// another account is signed in. The personal session and the terminal service
/// are each rebuilt when the account, server or token changes, so holding the
/// two tells the accounts apart even when both own a connection with the same
/// name or key.
@immutable
class ComposerConnectionsOwner {
  const ComposerConnectionsOwner({this.session, this.terminalService});

  final PersonalConnectionsSession? session;
  final TerminalService? terminalService;

  bool isCurrent(ComposerRead read) =>
      identical(read(personalConnectionsSessionProvider), session) &&
      identical(read(terminalServiceProvider), terminalService) &&
      (session?.isCurrent() ?? true);
}

/// The personal tool servers and terminals the signed-in account can choose
/// in the composer, with the owner they were read for.
@immutable
class ComposerPersonalConnections {
  const ComposerPersonalConnections({
    required this.owner,
    this.toolServers = const <PersonalConnectionEntry>[],
    this.terminals = const <TerminalServerInfo>[],
    this.selectedTerminalId,
  });

  static const none = ComposerPersonalConnections(
    owner: ComposerConnectionsOwner(),
  );

  final ComposerConnectionsOwner owner;

  /// Enabled tool servers only.
  final List<PersonalConnectionEntry> toolServers;
  final List<TerminalServerInfo> terminals;
  final String? selectedTerminalId;
}

/// Reads the connections of the account that is signed in now.
///
/// Settings and terminals count only once they have resolved for this account.
/// `asData` is null while a provider reloads after an account change, so the
/// value it kept from the previous account is never offered.
ComposerPersonalConnections readComposerPersonalConnections(ComposerRead read) {
  final session = read(personalConnectionsSessionProvider);
  final snapshot = session == null
      ? null
      : read(personalConnectionsProvider).asData?.value;
  return ComposerPersonalConnections(
    owner: ComposerConnectionsOwner(
      session: session,
      terminalService: read(terminalServiceProvider),
    ),
    toolServers: snapshot != null && identical(snapshot.session, session)
        ? <PersonalConnectionEntry>[
            for (final entry in snapshot.toolServers)
              if (entry.enabled) entry,
          ]
        : const <PersonalConnectionEntry>[],
    terminals:
        read(terminalAvailableServersProvider).asData?.value ??
        const <TerminalServerInfo>[],
    selectedTerminalId: read(selectedTerminalIdProvider),
  );
}

/// Digest that stands for [server] in a native action id. It only has to tell
/// the account's terminals apart, and keeps the URL out of the id.
String composerTerminalToken(TerminalServerInfo server) =>
    personalToolServerFingerprint(<String, dynamic>{'url': server.selectionId});

/// Indices, in the list the tool servers were read from, of the servers that
/// [selectedToolIds] name.
Set<int> _selectedToolServerIndices(
  List<PersonalConnectionEntry> servers,
  List<String> selectedToolIds,
) {
  if (servers.isEmpty) return const <int>{};
  return resolvePersonalToolSelections(
    servers.first.list,
    selectedToolIds,
  ).matchedIndices.toSet();
}

/// Personal tool servers and terminals, in the tools section like the ordinary
/// tools, so the native panel renders them without a new section.
List<ComposerOverflowItem> buildComposerOverflowConnectionItems({
  required AppLocalizations l10n,
  required ComposerPersonalConnections connections,
  required List<String> selectedToolIds,
}) {
  final selectedServers = _selectedToolServerIndices(
    connections.toolServers,
    selectedToolIds,
  );

  return <ComposerOverflowItem>[
    for (final entry in connections.toolServers)
      ComposerOverflowItem(
        id: ComposerOverflowActionIds.tool(
          personalToolServerSelectionId(entry.list, entry.index),
        ),
        kind: ComposerOverflowItemKind.toggle,
        section: ComposerOverflowSection.tools,
        label: entry.displayName.isEmpty ? l10n.toolServer : entry.displayName,
        subtitle: _toolServerSubtitle(entry),
        cupertinoIcon: CupertinoIcons.square_stack_3d_down_right,
        materialIcon: Icons.hub_outlined,
        sfSymbol: 'square.stack.3d.down.right',
        selected: selectedServers.contains(entry.index),
        dismissesKeyboard: false,
      ),
    for (final server in connections.terminals)
      ComposerOverflowItem(
        id: ComposerOverflowActionIds.terminal(server),
        kind: ComposerOverflowItemKind.toggle,
        section: ComposerOverflowSection.tools,
        label: server.displayName,
        subtitle: server.subtitle,
        cupertinoIcon: CupertinoIcons.chevron_left_slash_chevron_right,
        materialIcon: Icons.terminal_rounded,
        sfSymbol: 'terminal',
        selected: connections.selectedTerminalId == server.selectionId,
        dismissesKeyboard: false,
      ),
  ];
}

/// The entry's description, else its host. The full URL can carry a token.
String? _toolServerSubtitle(PersonalConnectionEntry entry) {
  final info = personalConnectionMap(entry.raw['info']);
  for (final candidate in <Object?>[
    entry.raw['description'],
    info?['description'],
  ]) {
    final text = candidate?.toString().trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  final host = Uri.tryParse(entry.url)?.host.trim() ?? '';
  return host.isEmpty ? null : host;
}

/// Whether [actionId] names a personal tool server or a terminal, whose
/// selection is validated against the signed-in account before it applies.
bool isComposerConnectionAction(String actionId) {
  final toolId = ComposerOverflowActionIds.toolIdFrom(actionId);
  return (toolId?.startsWith(kDirectServerSelectionPrefix) ?? false) ||
      ComposerOverflowActionIds.terminalTokenFrom(actionId) != null;
}

/// Applies a personal connection choice made in the native panel.
///
/// A tap is dropped unless the panel was built for the account that is signed
/// in now ([opened]) and the connection it names is still one of that
/// account's enabled, usable connections. The tool server is looked up by the
/// stored identity, so a keyless entry that was removed, reordered into
/// another's place or reconfigured never selects a different server.
Future<void> toggleComposerConnectionSelection(
  WidgetRef ref,
  String actionId, {
  required ComposerConnectionsOwner? opened,
}) async {
  if (opened == null || !opened.isCurrent(ref.read)) return;
  final connections = readComposerPersonalConnections(ref.read);

  final toolId = ComposerOverflowActionIds.toolIdFrom(actionId);
  if (toolId != null) {
    _toggleToolServer(ref, connections.toolServers, toolId);
    return;
  }

  final token = ComposerOverflowActionIds.terminalTokenFrom(actionId);
  if (token == null) return;
  final matches = connections.terminals
      .where((server) => composerTerminalToken(server) == token)
      .toList(growable: false);
  // Two terminals sharing a digest cannot be told apart, so neither is chosen.
  if (matches.length != 1) return;
  await ref.read(terminalSelectionControllerProvider).toggle(matches.single);
}

void _toggleToolServer(
  WidgetRef ref,
  List<PersonalConnectionEntry> servers,
  String toolId,
) {
  if (!toolId.startsWith(kDirectServerSelectionPrefix) || servers.isEmpty) {
    return;
  }
  final list = servers.first.list;
  final index = resolvePersonalToolServerToken(
    list,
    toolId.substring(kDirectServerSelectionPrefix.length),
  );
  if (index == null || !servers.any((entry) => entry.index == index)) return;

  final current = ref.read(selectedToolIdsProvider);
  final selected = <String>[];
  var wasSelected = false;
  for (final id in current) {
    final selectedIndex = id.startsWith(kDirectServerSelectionPrefix)
        ? resolvePersonalToolServerToken(
            list,
            id.substring(kDirectServerSelectionPrefix.length),
          )
        : null;
    if (selectedIndex == index) {
      wasSelected = true;
    } else {
      selected.add(id);
    }
  }
  if (!wasSelected) {
    selected.add(personalToolServerSelectionId(list, index));
  }
  ref.read(selectedToolIdsProvider.notifier).set(selected);
}

/// The advanced "Compare models" command. It sits in the features section so
/// the native iOS panel, which groups rows by section, renders it without a new
/// native section; the id reaches Flutter through the same action callback as
/// every other row, so setup is one code path on both.
///
/// It compares the message being written, so it stays visible but off, and
/// says why, until there is one ([hasMessage]).
List<ComposerOverflowItem> buildComposerOverflowComparisonItems({
  required AppLocalizations l10n,
  required bool available,
  bool hasMessage = true,
}) {
  if (!available) return const <ComposerOverflowItem>[];
  return <ComposerOverflowItem>[
    ComposerOverflowItem(
      id: ComposerOverflowActionIds.compareModels,
      kind: ComposerOverflowItemKind.action,
      section: ComposerOverflowSection.features,
      label: l10n.chatCompareModelsAction,
      subtitle: hasMessage
          ? l10n.chatCompareModelsDescription
          : l10n.chatCompareNeedsMessage,
      enabled: hasMessage,
      cupertinoIcon: CupertinoIcons.square_split_2x1,
      materialIcon: Icons.vertical_split_outlined,
      sfSymbol: 'rectangle.split.2x1',
    ),
  ];
}

/// The advanced "Tool settings" command. It lives in the tools section so the
/// native iOS panel, which groups rows by section, renders it without a new
/// native section; the id reaches Flutter through the same action callback.
List<ComposerOverflowItem> buildComposerOverflowToolSettingsItems({
  required AppLocalizations l10n,
  required bool available,
}) {
  if (!available) return const <ComposerOverflowItem>[];
  return <ComposerOverflowItem>[
    ComposerOverflowItem(
      id: ComposerOverflowActionIds.toolSettings,
      kind: ComposerOverflowItemKind.action,
      section: ComposerOverflowSection.tools,
      label: l10n.personalToolSettings,
      subtitle: l10n.personalToolSettingsDescription,
      cupertinoIcon: CupertinoIcons.wrench,
      materialIcon: Icons.build_outlined,
      sfSymbol: 'wrench.and.screwdriver',
    ),
  ];
}

List<ComposerOverflowItem> buildComposerOverflowFilterItems({
  required List<ToggleFilter> availableFilters,
  required List<String> selectedFilterIds,
}) {
  final selectedFilterIdSet = selectedFilterIds.toSet();

  return <ComposerOverflowItem>[
    for (final filter in availableFilters)
      ComposerOverflowItem(
        id: ComposerOverflowActionIds.filter(filter.id),
        kind: ComposerOverflowItemKind.toggle,
        section: ComposerOverflowSection.filters,
        label: filter.name,
        subtitle: filter.description,
        cupertinoIcon: CupertinoIcons.sparkles,
        materialIcon: Icons.auto_awesome,
        sfSymbol: 'sparkles',
        selected: selectedFilterIdSet.contains(filter.id),
        dismissesKeyboard: false,
      ),
  ];
}

void setComposerOverflowSelection(
  WidgetRef ref, {
  required String actionId,
  required bool selected,
}) {
  switch (actionId) {
    case ComposerOverflowActionIds.webSearch:
      ref.read(webSearchEnabledProvider.notifier).set(selected);
      if (selected && !_webSearchCoexistsWithLocalTools(ref)) {
        _clearLocalMcpTools(ref);
      }
      return;
    case ComposerOverflowActionIds.imageGeneration:
      ref.read(imageGenerationEnabledProvider.notifier).set(selected);
      if (selected) _clearLocalMcpTools(ref);
      return;
    case ComposerOverflowActionIds.codeInterpreter:
      // The notifier refuses a choice the server, account or model cannot
      // honor, so a Python-in-the-browser server never gets browser execution.
      ref.read(codeInterpreterEnabledProvider.notifier).set(selected);
      return;
  }

  final filterId = ComposerOverflowActionIds.filterIdFrom(actionId);
  if (filterId != null) {
    final current = List<String>.from(ref.read(selectedFilterIdsProvider));
    final alreadySelected = current.contains(filterId);

    if (selected) {
      if (!alreadySelected) {
        current.add(filterId);
      }
    } else if (alreadySelected) {
      current.remove(filterId);
    }

    ref.read(selectedFilterIdsProvider.notifier).set(current);
    return;
  }

  final toolId = ComposerOverflowActionIds.toolIdFrom(actionId);
  if (toolId == null) {
    return;
  }

  final current = List<String>.from(ref.read(selectedToolIdsProvider));
  final alreadySelected = current.contains(toolId);

  if (selected) {
    if (!alreadySelected) {
      current.add(toolId);
    }
    if (toolId.startsWith(kDirectMcpToolIdPrefix)) {
      ref.read(imageGenerationEnabledProvider.notifier).set(false);
      if (!_webSearchCoexistsWithLocalTools(ref)) {
        ref.read(webSearchEnabledProvider.notifier).set(false);
      }
    }
  } else if (alreadySelected) {
    current.remove(toolId);
  }

  ref.read(selectedToolIdsProvider.notifier).set(current);
}

/// On-device web search is just another local tool, so it can run beside
/// MCP tools; a provider-hosted search tool can't share their request.
bool _webSearchCoexistsWithLocalTools(WidgetRef ref) =>
    ref.read(selectedDirectWebSearchModeProvider) ==
    DirectWebSearchMode.onDevice;

void _clearLocalMcpTools(WidgetRef ref) {
  final tools = ref.read(selectedToolIdsProvider);
  ref
      .read(selectedToolIdsProvider.notifier)
      .set(
        tools.where((id) => !id.startsWith(kDirectMcpToolIdPrefix)).toList(),
      );
}

void toggleComposerOverflowSelection(WidgetRef ref, String actionId) {
  final currentSelection = composerOverflowSelectionState(ref, actionId);
  if (currentSelection == null) {
    return;
  }

  setComposerOverflowSelection(
    ref,
    actionId: actionId,
    selected: !currentSelection,
  );
}

bool? composerOverflowSelectionState(WidgetRef ref, String actionId) {
  switch (actionId) {
    case ComposerOverflowActionIds.webSearch:
      return ref.read(webSearchEnabledProvider);
    case ComposerOverflowActionIds.imageGeneration:
      return ref.read(imageGenerationEnabledProvider);
    case ComposerOverflowActionIds.codeInterpreter:
      return ref.read(codeInterpreterEnabledProvider);
  }

  final filterId = ComposerOverflowActionIds.filterIdFrom(actionId);
  if (filterId != null) {
    return ref.read(selectedFilterIdsProvider).contains(filterId);
  }

  final toolId = ComposerOverflowActionIds.toolIdFrom(actionId);
  if (toolId == null) {
    return null;
  }

  return ref.read(selectedToolIdsProvider).contains(toolId);
}

String composerOverflowToolDescription(Tool tool) {
  final meta = tool.meta;
  if (meta != null) {
    final value = meta['description'];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
  }

  final customDescription = tool.description?.trim();
  if (customDescription != null && customDescription.isNotEmpty) {
    return customDescription;
  }

  final name = tool.name.toLowerCase();
  if (name.contains('search') || name.contains('browse')) {
    return 'Search the web for fresh context to improve answers.';
  }
  if (name.contains('image') || name.contains('vision')) {
    return 'Understand or generate imagery alongside your conversation.';
  }
  if (name.contains('code') || name.contains('python')) {
    return 'Execute code snippets and return computed results inline.';
  }
  if (name.contains('calc') || name.contains('math')) {
    return 'Perform precise math and calculations on demand.';
  }
  if (name.contains('file') || name.contains('document')) {
    return 'Access and summarize your uploaded files during chat.';
  }
  if (name.contains('api') || name.contains('request')) {
    return 'Trigger API requests and bring external data into the chat.';
  }
  return 'Enhance responses with specialized capabilities from this tool.';
}

IconData composerOverflowToolCupertinoIcon(Tool tool) {
  return _composerOverflowToolIcons(tool).cupertinoIcon;
}

IconData composerOverflowToolMaterialIcon(Tool tool) {
  return _composerOverflowToolIcons(tool).materialIcon;
}

String composerOverflowToolSFSymbol(Tool tool) {
  return _composerOverflowToolIcons(tool).sfSymbol;
}

_ComposerOverflowToolIcons _composerOverflowToolIcons(Tool tool) {
  final name = tool.name.toLowerCase();
  if (name.contains('image') || name.contains('vision')) {
    return const _ComposerOverflowToolIcons(
      cupertinoIcon: CupertinoIcons.photo,
      materialIcon: Icons.image,
      sfSymbol: 'photo',
    );
  }
  if (name.contains('code') || name.contains('python')) {
    return const _ComposerOverflowToolIcons(
      cupertinoIcon: CupertinoIcons.chevron_left_slash_chevron_right,
      materialIcon: Icons.code,
      sfSymbol: 'chevron.left.forwardslash.chevron.right',
    );
  }
  if (name.contains('calculator') || name.contains('math')) {
    return const _ComposerOverflowToolIcons(
      cupertinoIcon: Icons.calculate,
      materialIcon: Icons.calculate,
      sfSymbol: 'function',
    );
  }
  if (name.contains('file') || name.contains('document')) {
    return const _ComposerOverflowToolIcons(
      cupertinoIcon: CupertinoIcons.doc,
      materialIcon: Icons.description,
      sfSymbol: 'doc',
    );
  }
  if (name.contains('api') || name.contains('request')) {
    return const _ComposerOverflowToolIcons(
      cupertinoIcon: CupertinoIcons.cloud,
      materialIcon: Icons.cloud,
      sfSymbol: 'cloud',
    );
  }
  if (name.contains('search')) {
    return const _ComposerOverflowToolIcons(
      cupertinoIcon: CupertinoIcons.search,
      materialIcon: Icons.search,
      sfSymbol: 'magnifyingglass',
    );
  }
  return const _ComposerOverflowToolIcons(
    cupertinoIcon: CupertinoIcons.square_grid_2x2,
    materialIcon: Icons.extension,
    sfSymbol: 'square.grid.2x2',
  );
}

class _ComposerOverflowToolIcons {
  const _ComposerOverflowToolIcons({
    required this.cupertinoIcon,
    required this.materialIcon,
    required this.sfSymbol,
  });

  final IconData cupertinoIcon;
  final IconData materialIcon;
  final String sfSymbol;
}

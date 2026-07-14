import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/toggle_filter.dart';
import '../../../core/models/tool.dart';
import '../../tools/providers/tools_providers.dart';
import '../providers/chat_providers.dart';

class ComposerOverflowActionIds {
  const ComposerOverflowActionIds._();

  static const file = 'file';
  static const serverFile = 'serverFile';
  static const photo = 'photo';
  static const camera = 'camera';
  static const web = 'web';
  static const webSearch = 'webSearch';
  static const imageGeneration = 'imageGeneration';
  static const _filterPrefix = 'filter:';
  static const _toolPrefix = 'tool:';

  static String filter(String filterId) => '$_filterPrefix$filterId';

  static String tool(String toolId) => '$_toolPrefix$toolId';

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

enum ComposerOverflowItemKind { attachment, toggle }

enum ComposerOverflowSection {
  attachments('attachments'),
  features('features'),
  tools('tools'),
  filters('filters');

  const ComposerOverflowSection(this.nativeValue);

  final String nativeValue;
}

class ComposerOverflowAttachmentAvailability {
  const ComposerOverflowAttachmentAvailability({
    this.file = false,
    this.serverFile = false,
    this.photo = false,
    this.camera = false,
    this.web = false,
  });

  final bool file;
  final bool serverFile;
  final bool photo;
  final bool camera;
  final bool web;
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
    ),
    ...buildComposerOverflowToolItems(
      availableTools: availableTools,
      selectedToolIds: selectedToolIds,
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
  ];
}

List<ComposerOverflowItem> buildComposerOverflowFeatureItems({
  required AppLocalizations l10n,
  required bool webSearchAvailable,
  required bool webSearchEnabled,
  required bool imageGenerationAvailable,
  required bool imageGenerationEnabled,
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
      return;
    case ComposerOverflowActionIds.imageGeneration:
      ref.read(imageGenerationEnabledProvider.notifier).set(selected);
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
  } else if (alreadySelected) {
    current.remove(toolId);
  }

  ref.read(selectedToolIdsProvider.notifier).set(current);
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

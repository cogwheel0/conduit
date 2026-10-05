import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/features/chat/composer/ask_conduit.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';

import '../../l10n/app_localizations.dart';

bool get _canShowAskConduitSelectionAction =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

String? selectedTextFromEditableTextState(EditableTextState editableTextState) {
  final value = editableTextState.textEditingValue;
  final selection = value.selection;
  if (!selection.isValid ||
      selection.isCollapsed ||
      selection.end > value.text.length) {
    return null;
  }
  return selection.textInside(value.text);
}

List<ContextMenuButtonItem> withAskConduitContextMenuItem({
  required List<ContextMenuButtonItem> items,
  required WidgetRef ref,
  required String? selectedText,
  required String? composerTargetId,
  required VoidCallback hideToolbar,
  required String label,
}) {
  final text = askConduitInsertionText(
    selectedText: selectedText,
    composerTargetId: composerTargetId,
  );
  if (!_canShowAskConduitSelectionAction || text == null) {
    return items;
  }

  return [
    ...items,
    ContextMenuButtonItem(
      label: label,
      onPressed: () {
        hideToolbar();
        ref
            .read(composerTextInsertionProvider.notifier)
            .insert(targetId: composerTargetId!, text: text);
      },
    ),
  ];
}

Widget buildAskConduitSelectionAreaContextMenu({
  required SelectableRegionState selectableRegionState,
  required WidgetRef ref,
  required String? selectedText,
  required String? composerTargetId,
}) {
  final defaultItems = selectableRegionState.contextMenuButtonItems;
  final items = withAskConduitContextMenuItem(
    items: defaultItems,
    ref: ref,
    selectedText: selectedText,
    composerTargetId: composerTargetId,
    hideToolbar: () => selectableRegionState.hideToolbar(false),
    label: AppLocalizations.of(selectableRegionState.context)!.askConduitAction,
  );

  if (identical(items, defaultItems)) {
    return AdaptiveTextSelectionToolbar.selectableRegion(
      selectableRegionState: selectableRegionState,
    );
  }

  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: selectableRegionState.contextMenuAnchors,
    buttonItems: items,
  );
}

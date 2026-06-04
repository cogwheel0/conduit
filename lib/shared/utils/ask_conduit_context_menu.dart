import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/providers/chat_providers.dart';

const String _askConduitLabel = 'Ask Conduit';

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
}) {
  final text = selectedText;
  if (!_canShowAskConduitSelectionAction ||
      composerTargetId == null ||
      composerTargetId.isEmpty ||
      text == null ||
      text.trim().isEmpty) {
    return items;
  }

  return [
    ...items,
    ContextMenuButtonItem(
      label: _askConduitLabel,
      onPressed: () {
        hideToolbar();
        ref
            .read(composerTextInsertionProvider.notifier)
            .insert(targetId: composerTargetId, text: text);
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

import 'dart:math' as math;

import 'package:fleather/fleather.dart' as fleather;
import 'package:flutter/material.dart'
    as legacy
    show AdaptiveTextSelectionToolbar;
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import 'adaptive_text_selection_menu.dart';
import 'platform_ui_capabilities.dart';

/// Selection menus for document widgets that expose their own selection state.
abstract final class AdaptiveDocumentSelectionMenu {
  /// Keeps Fleather's editing menu and adapts its read-only iOS menu.
  static Widget richText(BuildContext context, fleather.EditorState state) {
    if (!PlatformUiCapabilities.isIOS ||
        !state.widget.readOnly ||
        !SystemContextMenu.isSupported(context)) {
      return fleather.defaultContextMenuBuilder(context, state);
    }
    final renderEditor = state.renderEditor;
    final selection = state.textEditingValue.selection;
    final height = math.min(
      renderEditor.preferredLineHeight(selection.base),
      renderEditor.preferredLineHeight(selection.extent),
    );
    return AdaptiveTextSelectionMenu(
      selectionRect: TextSelectionToolbarAnchors.getSelectionRect(
        renderEditor,
        height,
        height,
        [
          for (final endpoint in renderEditor.getEndpointsForSelection(
            selection,
          ))
            TextSelectionPoint(
              endpoint.point + renderEditor.paintOffset,
              endpoint.direction,
            ),
        ],
      ),
      anchors: state.contextMenuAnchors,
      buttonItems: state.contextMenuButtonItems,
      onDismiss: () => state.hideToolbar(false),
    );
  }

  /// Preserves PDF copy permissions, actions and local fallback coordinates.
  static Widget? pdf(
    BuildContext context,
    PdfViewerContextMenuBuilderParams params,
  ) {
    final selection = params.textSelectionDelegate;
    final items = [
      if (params.isTextSelectionEnabled &&
          selection.isCopyAllowed &&
          selection.hasSelectedText)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () => selection.copyTextSelection(),
        ),
      if (params.isTextSelectionEnabled && !selection.isSelectingAllText)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () => selection.selectAllText(),
        ),
    ];
    if (items.isEmpty) return null;
    final anchors = TextSelectionToolbarAnchors(
      primaryAnchor: params.anchorA,
      secondaryAnchor: params.anchorB,
    );
    Widget menu = legacy.AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: items,
    );
    final box = context.findRenderObject();
    if (PlatformUiCapabilities.isIOS &&
        SystemContextMenu.isSupported(context) &&
        box is RenderBox &&
        box.attached &&
        box.hasSize) {
      final rect = Rect.fromPoints(
        box.localToGlobal(params.anchorA),
        box.localToGlobal(params.anchorB ?? params.anchorA),
      );
      menu = AdaptiveTextSelectionMenu(
        // An unselected background has a point anchor, rather than a range.
        selectionRect: rect.isEmpty ? rect.inflate(1) : rect,
        anchors: anchors,
        buttonItems: items,
        onDismiss: params.dismissContextMenu,
      );
    }
    return Align(alignment: Alignment.topLeft, child: menu);
  }
}

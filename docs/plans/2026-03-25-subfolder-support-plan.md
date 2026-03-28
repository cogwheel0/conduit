# Plan: Subfolder Support in Drawer (Issue #413)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add nested subfolder support to the folder sidebar. The backend API and data model (`Folder.parentId`) already support hierarchy — this is purely a UI/state presentation change. Replace flat folder rendering with a recursive tree, add "Create Subfolder" and "Move to Folder" context menu actions, and update the create dialog to optionally accept a parent.

**Architecture:** A `FolderTreeNode` helper converts the flat `List<Folder>` into a recursive tree structure, exposed via a derived `folderTreeProvider`. The drawer iterates this tree recursively, indenting subfolders by depth. Folder CRUD operations continue to use the flat `foldersProvider` as source of truth — the tree is a read-only projection.

**Tech Stack:** Flutter, Riverpod 3.0 (codegen), Freezed (models), ARB (localization)

## Decisions
- **Unlimited nesting depth** (matching OpenWebUI behavior)
- **Context menu only** for reparenting folders (no folder drag-drop to avoid accidental moves)
- **Both** context menu "Create Subfolder" AND parent picker dropdown in the create dialog
- Chat drag-drop into subfolders continues to work as-is (folders already accept drops)
- Scope: Android + iOS (requested platforms), but implementation is cross-platform Flutter

---

### Task 1: Create `FolderTreeNode` helper

**Files:**
- Create: `lib/core/models/folder_tree.dart`

Define a simple immutable class for the recursive tree:

```dart
class FolderTreeNode {
  const FolderTreeNode({required this.folder, this.children = const []});
  final Folder folder;
  final List<FolderTreeNode> children;
}
```

Add a static factory that converts a flat folder list into a tree:

```dart
static List<FolderTreeNode> buildTree(List<Folder> folders) {
  // Group folders by parentId
  // Return root nodes (parentId == null) with recursively built children
  // Sort children alphabetically (case-insensitive) at each level
}
```

Add a utility to collect all descendant folder IDs (needed for circular-reference prevention in move dialog):

```dart
static Set<String> getDescendantIds(String folderId, List<Folder> folders) {
  // Recursively collect all folder IDs where parentId chains back to folderId
}
```

---

### Task 2: Create derived `folderTreeProvider`

**Files:**
- Modify: `lib/core/providers/app_providers.dart`

Add a `@riverpod` function that watches `foldersProvider` and returns the tree:

```dart
@riverpod
List<FolderTreeNode> folderTree(FolderTreeRef ref) {
  final folders = ref.watch(foldersProvider).valueOrNull ?? const [];
  return FolderTreeNode.buildTree(folders);
}
```

This avoids modifying the existing `Folders` notifier — the flat list remains the source of truth. Run `dart run build_runner build --delete-conflicting-outputs` after adding.

---

### Task 3: Add localization keys

**Files:**
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_*.arb` (other locales — use English as placeholder)

New keys:

```json
"createSubfolder": "Create Subfolder",
"@createSubfolder": { "description": "Action to create a new subfolder inside a folder." },
"newSubfolder": "New Subfolder",
"@newSubfolder": { "description": "Dialog title when creating a subfolder." },
"moveToFolder": "Move to Folder",
"@moveToFolder": { "description": "Action to move a folder into another folder." },
"topLevel": "None (top level)",
"@topLevel": { "description": "Option to place a folder at the top level with no parent." },
"failedToMoveFolder": "Failed to move folder",
"@failedToMoveFolder": { "description": "Error notice when moving a folder fails." },
"deleteFolderWithSubfoldersMessage": "This folder, its subfolders, and their assignment references will be removed.",
"@deleteFolderWithSubfoldersMessage": { "description": "Warning that deleting a folder with subfolders will remove all of them." },
"parentFolder": "Parent folder",
"@parentFolder": { "description": "Label for selecting a parent folder." }
```

---

### Task 4: Update `_buildFolderHeader()` for depth-aware indentation

**Files:**
- Modify: `lib/features/navigation/widgets/chats_drawer.dart` (~line 885)

**Step 1:** Add `int depth = 0` parameter to `_buildFolderHeader()`.

**Step 2:** Apply left padding to the header row: `EdgeInsets.only(left: 16.0 * depth)`.

**Step 3:** Optionally use a subfolder icon variant (e.g., `Icons.folder_outlined`) at `depth > 0`.

No changes needed to `expandedFoldersProvider` — it already keys by folder ID, so expand/collapse works at all depths. Subfolders should default to collapsed.

---

### Task 5: Refactor flat folder loop to recursive tree rendering

**Files:**
- Modify: `lib/features/navigation/widgets/chats_drawer.dart`

**Step 1:** Replace the flat `for (final folder in folders)` loop (around line 360) with iteration over `folderTreeProvider`:

```dart
final folderTree = ref.watch(folderTreeProvider);
```

**Step 2:** Create a private `_buildFolderTree(FolderTreeNode node, int depth)` method that:
- Calls `_buildFolderHeader(node.folder.id, node.folder.name, convCount, depth: depth)`
- When expanded: renders child conversations, then recurses into `node.children` with `depth + 1`

**Step 3:** Root iteration:
```dart
for (final rootNode in folderTree) {
  slivers.addAll(_buildFolderTree(rootNode, 0));
}
```

The `_resolveFolderConversations()` continues to work per-folder — no changes needed there.

---

### Task 6: Update `CreateFolderDialog` to support subfolders

**Files:**
- Modify: `lib/features/navigation/widgets/create_folder_dialog.dart`

**Step 1:** Add `String? parentId` parameter to `show()`:

```dart
static Future<void> show(
  BuildContext context,
  WidgetRef ref, {
  String? parentId,
  required Future<void> Function(String message) onError,
})
```

**Step 2:** When `parentId != null` (from context menu "Create Subfolder"):
- Dialog title: `l10n.newSubfolder` instead of `l10n.newFolder`
- Pass `parentId` to `api.createFolder(name: name, parentId: parentId)`

**Step 3:** When `parentId == null` (from section header "+" button):
- Show an optional parent folder dropdown below the name field
- Populate from `foldersProvider` flat list, default: "None (top-level)"
- If user selects a parent, pass that ID to `api.createFolder()`

The `api.createFolder()` already accepts `parentId` — no API changes needed.

---

### Task 7: Add "Create Subfolder" context menu action

**Files:**
- Modify: `lib/features/navigation/widgets/chats_drawer.dart` (~line 1196, in `_buildFolderActions()`)

Add a new `ConduitContextMenuAction` between Rename and Delete:

```dart
ConduitContextMenuAction(
  cupertinoIcon: CupertinoIcons.folder_badge_plus,
  materialIcon: Icons.create_new_folder_rounded,
  label: l10n.createSubfolder,
  onBeforeClose: () => ConduitHaptics.selectionClick(),
  onSelected: () async {
    await CreateFolderDialog.show(
      context, ref,
      parentId: folderId,
      onError: _showDrawerError,
    );
  },
),
```

---

### Task 8: Create `MoveFolderDialog`

**Files:**
- Create: `lib/features/navigation/widgets/move_folder_dialog.dart`

A dialog that shows a list of all folders as selectable targets, EXCLUDING:
- The folder itself
- All its descendants (use `FolderTreeNode.getDescendantIds()` from Task 1)

Include a "None (top-level)" option to unset parent (move to root).

On selection:
```dart
await api.updateFolder(folderId, parentId: selectedParentId);
ref.read(foldersProvider.notifier).updateFolder(
  folderId,
  (f) => f.copyWith(parentId: selectedParentId, updatedAt: DateTime.now()),
);
refreshConversationsCache(ref, includeFolders: true);
```

Pattern follows `_renameFolder()` closely: API call → provider update → cache refresh → error handling.

---

### Task 9: Add "Move to Folder" context menu action

**Files:**
- Modify: `lib/features/navigation/widgets/chats_drawer.dart` (in `_buildFolderActions()`)

Add a `ConduitContextMenuAction` after "Create Subfolder":

```dart
ConduitContextMenuAction(
  cupertinoIcon: CupertinoIcons.folder,
  materialIcon: Icons.drive_file_move_rounded,
  label: l10n.moveToFolder,
  onBeforeClose: () => ConduitHaptics.selectionClick(),
  onSelected: () async {
    await _moveFolder(context, folderId);
  },
),
```

Add `_moveFolder()` method that shows the `MoveFolderDialog`.

---

### Task 10: Enhanced delete confirmation for folders with children

**Files:**
- Modify: `lib/features/navigation/widgets/chats_drawer.dart` (in `_confirmAndDeleteFolder()`)

**Step 1:** Before showing the confirmation dialog, check if the folder has children:

```dart
final allFolders = ref.read(foldersProvider).valueOrNull ?? [];
final hasChildren = allFolders.any((f) => f.parentId == folderId);
```

**Step 2:** If `hasChildren`, use `l10n.deleteFolderWithSubfoldersMessage` instead of `l10n.deleteFolderMessage`.

**Step 3:** After deletion, also remove orphaned child folders from provider (or rely on server-side cascade — verify behavior first).

---

## Relevant Files

| File | Status | Purpose |
|------|--------|---------|
| `lib/core/models/folder.dart` | No changes | Existing `Folder` model with `parentId` field |
| `lib/core/models/folder_tree.dart` | **New** | `FolderTreeNode` + `buildTree()` + `getDescendantIds()` |
| `lib/core/services/api_service.dart` | No changes | Already supports `parentId` in `createFolder()` and `updateFolder()` |
| `lib/core/providers/app_providers.dart` | Modify | Add `folderTreeProvider` derived provider |
| `lib/features/navigation/widgets/chats_drawer.dart` | Modify | Recursive tree rendering, new context menu items, depth-aware headers |
| `lib/features/navigation/widgets/create_folder_dialog.dart` | Modify | Add `parentId` parameter and optional parent picker |
| `lib/features/navigation/widgets/move_folder_dialog.dart` | **New** | Folder picker for reparenting |
| `lib/features/navigation/widgets/drawer_section_notifiers.dart` | No changes | `expandedFoldersProvider` already keys by ID |
| `lib/l10n/app_en.arb` | Modify | New localization strings |
| `lib/l10n/app_*.arb` | Modify | Corresponding translations |

## Verification

1. **Unit test `FolderTreeNode.buildTree()`**: Verify tree construction from flat folder list with various parent-child relationships, orphans, and deep nesting
2. **Unit test `getDescendantIds()`**: Verify correct descendant collection for circular-reference prevention
3. **Widget test**: Verify subfolder indentation renders at the correct depth
4. **Widget test**: Verify "Create Subfolder" context menu item appears and passes correct `parentId`
5. **Manual test**: Create folder → create subfolder → verify hierarchy displays correctly in drawer
6. **Manual test**: Move folder to different parent → verify tree updates
7. **Manual test**: Delete folder with subfolders → verify warning and clean removal
8. **Manual test**: Drag chat into subfolder → verify it lands in correct folder
9. **Manual test**: Test on iOS and Android (requested platforms)
10. **Run `dart run build_runner build --delete-conflicting-outputs`** after adding the new Riverpod provider
11. **Run `flutter test`** to verify no regressions
12. **Run `dart run custom_lint`** for Riverpod lint checks

## Excluded from Scope
- Folder drag-drop reparenting (context menu only, per user decision)
- Breadcrumb navigation within folders
- Folder search/filter
- Folder-level inherited settings (prompts/attachments) — mentioned in the issue as a future desire, but is a separate feature

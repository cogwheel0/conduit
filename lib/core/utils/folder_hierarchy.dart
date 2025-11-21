import '../models/folder.dart';

/// Represents a folder node in the hierarchy tree
class FolderNode {
  FolderNode({
    required this.folder,
    this.children = const [],
    this.depth = 0,
  });

  final Folder folder;
  final List<FolderNode> children;
  final int depth;

  FolderNode copyWith({
    Folder? folder,
    List<FolderNode>? children,
    int? depth,
  }) {
    return FolderNode(
      folder: folder ?? this.folder,
      children: children ?? this.children,
      depth: depth ?? this.depth,
    );
  }
}

/// Builds a hierarchical tree structure from a flat list of folders
class FolderHierarchy {
  FolderHierarchy(List<Folder> folders) {
    _buildHierarchy(folders);
  }

  final List<FolderNode> _rootNodes = [];
  final Map<String, FolderNode> _nodeMap = {};

  /// Get root-level folders (folders with no parent)
  List<FolderNode> get rootNodes => _rootNodes;

  /// Get all folders in a flattened list with depth information
  List<FolderNode> get flattenedNodes {
    final result = <FolderNode>[];
    void addNodesRecursively(List<FolderNode> nodes) {
      for (final node in nodes) {
        result.add(node);
        addNodesRecursively(node.children);
      }
    }

    addNodesRecursively(_rootNodes);
    return result;
  }

  /// Find a folder node by ID
  FolderNode? findNode(String folderId) {
    return _nodeMap[folderId];
  }

  /// Build the hierarchy from a flat list
  void _buildHierarchy(List<Folder> folders) {
    _rootNodes.clear();
    _nodeMap.clear();

    // First pass: Create nodes for all folders
    for (final folder in folders) {
      _nodeMap[folder.id] = FolderNode(folder: folder);
    }

    // Second pass: Build parent-child relationships
    final childrenMap = <String, List<FolderNode>>{};

    for (final folder in folders) {
      final node = _nodeMap[folder.id]!;
      if (folder.parentId == null || folder.parentId!.isEmpty) {
        // Root level folder
        _rootNodes.add(node);
      } else {
        // Child folder - add to parent's children list
        childrenMap.putIfAbsent(folder.parentId!, () => []).add(node);
      }
    }

    // Third pass: Update children and depths recursively
    void updateDepthsRecursively(FolderNode node, int depth) {
      final updatedNode = node.copyWith(
        depth: depth,
        children: childrenMap[node.folder.id] ?? const [],
      );
      _nodeMap[node.folder.id] = updatedNode;

      for (final child in updatedNode.children) {
        updateDepthsRecursively(child, depth + 1);
      }
    }

    // Start with root nodes at depth 0
    final updatedRoots = <FolderNode>[];
    for (final root in _rootNodes) {
      updateDepthsRecursively(root, 0);
      updatedRoots.add(_nodeMap[root.folder.id]!);
    }
    _rootNodes
      ..clear()
      ..addAll(updatedRoots);
  }

  /// Check if a folder has any children
  bool hasChildren(String folderId) {
    final node = _nodeMap[folderId];
    return node != null && node.children.isNotEmpty;
  }

  /// Get all child folder IDs recursively
  List<String> getDescendantIds(String folderId) {
    final node = _nodeMap[folderId];
    if (node == null) return [];

    final result = <String>[];
    void collectIds(FolderNode n) {
      for (final child in n.children) {
        result.add(child.folder.id);
        collectIds(child);
      }
    }

    collectIds(node);
    return result;
  }
}

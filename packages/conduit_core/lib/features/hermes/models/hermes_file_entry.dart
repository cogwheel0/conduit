import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

String? hermesFilePath(Object? value) {
  final path = validateHermesBoundedString(
    value,
    maxCharacters: 4096,
    trim: false,
  );
  return path == null || path.contains(RegExp(r'[\x00-\x1f]')) ? null : path;
}

bool hermesFileNameIsValid(String name) =>
    name.isNotEmpty &&
    name.trim() == name &&
    name != '.' &&
    name != '..' &&
    name.length <= 255 &&
    !name.contains(RegExp(r'[/\\\x00-\x1f]'));

final class HermesFileEntry {
  const HermesFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
    this.mimeType,
  });

  factory HermesFileEntry.fromJson(Map<String, dynamic> json) {
    final name = validateHermesBoundedString(json['name'], maxCharacters: 255);
    final path = hermesFilePath(json['path']);
    final directory = json['is_directory'];
    if (name == null || path == null || directory is! bool) {
      throw const FormatException('Invalid file entry');
    }
    final mtime = json['mtime'];
    return HermesFileEntry(
      name: name,
      path: path,
      isDirectory: directory,
      size: json['size'] is int ? json['size'] as int : null,
      modifiedAt: mtime is num && mtime.isFinite && mtime.abs() < 8640000000000
          ? DateTime.fromMillisecondsSinceEpoch((mtime * 1000).round())
          : null,
      mimeType: validateHermesBoundedString(
        json['mime_type'],
        maxCharacters: 255,
      ),
    );
  }

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;
  final String? mimeType;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'is_directory': isDirectory,
  };
}

final class HermesDirectory {
  const HermesDirectory({
    required this.path,
    required this.entries,
    this.parent,
    this.root,
    this.canChangePath = true,
  });

  factory HermesDirectory.fromJson(Map<String, dynamic> json) {
    final path = hermesFilePath(json['path']);
    final entries = json['entries'];
    if (path == null || entries is! List) {
      throw const FormatException('Invalid directory response');
    }
    return HermesDirectory(
      path: path,
      parent: hermesFilePath(json['parent']),
      root: hermesFilePath(json['locked_root'] ?? json['root']),
      canChangePath: json['can_change_path'] != false,
      entries: List.unmodifiable([
        for (final entry in entries)
          if (entry is Map)
            HermesFileEntry.fromJson(Map<String, dynamic>.from(entry)),
      ]),
    );
  }

  final String path;
  final String? parent;
  final String? root;
  final bool canChangePath;
  final List<HermesFileEntry> entries;
}

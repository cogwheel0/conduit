import 'hermes_file_entry.dart';

enum HermesMediaKind { audio, video, image, pdf, text, file }

/// A reference only. File bytes never belong in the transcript database.
final class HermesMediaReference {
  const HermesMediaReference({
    required this.path,
    required this.name,
    this.size,
  });
  final String path;
  final String name;
  final int? size;

  String get extension => name.split('.').last.toLowerCase();
  HermesMediaKind get kind => switch (extension) {
    'wav' ||
    'mp3' ||
    'm4a' ||
    'aac' ||
    'ogg' ||
    'opus' ||
    'flac' => HermesMediaKind.audio,
    'mp4' || 'mov' || 'webm' || 'mkv' => HermesMediaKind.video,
    'png' ||
    'jpg' ||
    'jpeg' ||
    'webp' ||
    'gif' ||
    'bmp' => HermesMediaKind.image,
    'pdf' => HermesMediaKind.pdf,
    'txt' ||
    'md' ||
    'markdown' ||
    'csv' ||
    'json' ||
    'yaml' ||
    'yml' ||
    'log' => HermesMediaKind.text,
    _ => HermesMediaKind.file,
  };
  String get mimeType => switch (extension) {
    'wav' => 'audio/wav',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'ogg' || 'opus' => 'audio/ogg',
    'flac' => 'audio/flac',
    'mp4' || 'm4v' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'mkv' => 'video/x-matroska',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'bmp' => 'image/bmp',
    'pdf' => 'application/pdf',
    'json' => 'application/json',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'txt' ||
    'md' ||
    'markdown' ||
    'csv' ||
    'yaml' ||
    'yml' ||
    'log' => 'text/plain',
    _ => 'application/octet-stream',
  };

  static HermesMediaReference? fromPath(
    Object? value, {
    String? name,
    int? size,
  }) {
    if (value is! String || value.length > 4096) return null;
    var path = value.trim();
    if (path.startsWith('MEDIA:')) path = path.substring(6).trim();
    if (path.length > 1 &&
        ((path.startsWith('`') && path.endsWith('`')) ||
            (path.startsWith('"') && path.endsWith('"')) ||
            (path.startsWith("'") && path.endsWith("'")))) {
      path = path.substring(1, path.length - 1);
    }
    final uri = Uri.tryParse(path);
    if (uri == null ||
        uri.host.isNotEmpty ||
        (uri.hasScheme && uri.scheme != 'file')) {
      return null;
    }
    if (uri.scheme == 'file') {
      try {
        path = Uri.decodeComponent(uri.path);
      } on FormatException {
        return null;
      }
    }
    if (!(path.startsWith('/') ||
            path.startsWith('~/') ||
            path.startsWith('./')) ||
        path.startsWith('//') ||
        hermesFilePath(path) == null) {
      return null;
    }
    final filename = name ?? path.split('/').last;
    if (!hermesFileNameIsValid(filename)) return null;
    return HermesMediaReference(path: path, name: filename, size: size);
  }

  static HermesMediaReference? fromDescriptor(Map<dynamic, dynamic> file) {
    final direct = file['hermes_server_path'] ?? file['path'];
    final url = file['url'];
    // App-relative API URLs identify a different transport, not server files.
    final candidate =
        direct ?? (url is String && !url.startsWith('/api/') ? url : null);
    return fromPath(
      candidate,
      name: (file['name'] ?? file['filename']) is String
          ? (file['name'] ?? file['filename']) as String
          : null,
      size: file['size'] is int ? file['size'] as int : null,
    );
  }
}

final _mediaExtension = RegExp(
  r'\.(wav|mp3|m4a|aac|ogg|opus|flac|mp4|mov|webm|mkv|png|jpe?g|webp|gif|bmp|pdf|docx?|xlsx?|pptx?|txt|md|markdown|csv|json|zip)$',
  caseSensitive: false,
);
final _mediaTags = RegExp(
  r'''MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|[^\s<>]+)''',
);
final _mediaLinks = RegExp(r'!?\[[^\]\n]*\]\(([^)\n]+)\)');
final _mediaCode = RegExp(r'`((?:/|~/|\./)[^`\n]+)`');

/// Only assistant output is admitted by callers. Recognition does not authorize
/// a read: the owning gateway still enforces roots, account and session access.
List<HermesMediaReference> hermesMediaReferences(
  String content, {
  Iterable<Map> files = const [],
}) {
  final found = <String, HermesMediaReference>{};
  void add(HermesMediaReference? ref) {
    if (ref != null && found.length < 32) {
      found.putIfAbsent(ref.path, () => ref);
    }
  }

  for (final file in files.take(32)) {
    add(HermesMediaReference.fromDescriptor(file));
  }
  final text = content.length > 512 * 1024
      ? content.substring(0, 512 * 1024)
      : content;
  for (final match in _mediaTags.allMatches(text).take(32)) {
    add(HermesMediaReference.fromPath(match.group(1)));
  }
  for (final pattern in [_mediaLinks, _mediaCode]) {
    for (final match in pattern.allMatches(text).take(100)) {
      final ref = HermesMediaReference.fromPath(match.group(1));
      if (ref != null && _mediaExtension.hasMatch(ref.name)) add(ref);
    }
  }
  return List.unmodifiable(found.values);
}

/// MEDIA is transport markup, not prose. Ordinary code/path mentions remain
/// intact; legacy replies receive a card without rewriting the stored answer.
String hermesVisibleMediaText(String content) => content
    .replaceAllMapped(
      _mediaTags,
      (match) => HermesMediaReference.fromPath(match.group(1)) == null
          ? match.group(0)!
          : '',
    )
    .trim();

/// How a note's `data` is shaped on Open WebUI 0.12.5 and later, where a note
/// holds one or more pages and its attachments sit inside a page's content.
///
/// Since 0.12.5 the server returns `data.pages` for every note (a note saved
/// earlier gets a single `main` page when it is read), with `content` as a
/// view built from the pages, plus `pages_revision` and `search_text`. It
/// refuses an update whose `data` carries `pages`, `pages_revision` or
/// `files`, and a content save without `page_id` on a note with several pages.
/// Files are attached by linking them from the page content as
/// `[name](/api/v1/files/{id}/content)`, which is also what the server turns a
/// note's old `files` list into.
///
/// Pure Dart: shared by the sync layer, the attachments controller and the
/// editor.
library;

import 'dart:convert';

/// The id of the page every note has, the one first in its list.
const String kNoteMainPageId = 'main';

/// Local-only key in a stored paged note's `data`: the ids of the pages whose
/// content was edited on this device and not yet sent. Never sent.
const String kNoteDirtyPagesKey = 'conduit_dirty_pages';

/// Keys a create never sends: what the server derives from a note's pages,
/// which it refuses, and [kNoteDirtyPagesKey].
const Set<String> kNoteDataKeysNotSentOnCreate = <String>{
  'pages',
  'pages_revision',
  'search_text',
  kNoteDirtyPagesKey,
};

/// A content edit names no page of a note with several pages, so it belongs
/// to none of them.
class NotePageRequiredException implements Exception {
  const NotePageRequiredException();

  @override
  String toString() => 'NotePageRequiredException: the note has several pages';
}

/// A content edit names a page the note no longer has.
class NotePageMissingException implements Exception {
  const NotePageMissingException(this.pageId);

  final String pageId;

  @override
  String toString() => 'NotePageMissingException: no page $pageId';
}

/// The pages in a note's [data], or an empty list for a note from a server
/// older than 0.12.5 (or one stored before the server was upgraded).
List<Map<String, dynamic>> notePagesOf(Map<String, dynamic> data) {
  final Object? raw = data['pages'];
  if (raw is! List) return const <Map<String, dynamic>>[];
  return <Map<String, dynamic>>[
    for (final Object? page in raw)
      if (page is Map && page['id'] is String)
        Map<String, dynamic>.from(page),
  ];
}

/// Whether [data] is in the paged shape 0.12.5 servers return.
bool noteDataHasPages(Map<String, dynamic> data) =>
    notePagesOf(data).isNotEmpty;

/// Whether [data] holds more than one page, so its `content` is a read-only
/// view of every page rather than one page's text.
bool noteDataIsMultiPage(Map<String, dynamic> data) =>
    notePagesOf(data).length > 1;

/// The page a content edit of [data] that names none goes to: the only page
/// of a paged note, or [kNoteMainPageId] for a note in the older shape (whose
/// content becomes the main page once the server reads it). Null when [data]
/// has several pages.
String? noteSinglePageId(Map<String, dynamic> data) {
  final pages = notePagesOf(data);
  if (pages.isEmpty) return kNoteMainPageId;
  if (pages.length > 1) return null;
  return pages.first['id'] as String;
}

/// The pages of [data] edited on this device and not yet sent, in page order.
List<String> noteDirtyPageIds(Map<String, dynamic> data) {
  final Object? raw = data[kNoteDirtyPagesKey];
  if (raw is! List) return const <String>[];
  final dirty = <String>{
    for (final Object? id in raw)
      if (id is String) id,
  };
  return <String>[
    for (final page in notePagesOf(data))
      if (dirty.contains(page['id'])) page['id'] as String,
  ];
}

/// The content of page [pageId] in [data]. A note in the older shape, or with
/// one page, has its `content`: that is the page's text as the server sends
/// it, and what builds before page-aware edits wrote, leaving the page's own
/// copy behind. Null when the note has no such page.
Map<String, dynamic>? notePageContent(
  Map<String, dynamic> data,
  String pageId,
) {
  final pages = notePagesOf(data);
  final Object? content = data['content'];
  if (pages.isEmpty || (pages.length == 1 && pages.first['id'] == pageId)) {
    if (content is Map) return Map<String, dynamic>.from(content);
    if (pages.isEmpty) return null;
  }
  for (final page in pages) {
    if (page['id'] != pageId) continue;
    final Object? content = page['content'];
    return content is Map
        ? Map<String, dynamic>.from(content)
        : <String, dynamic>{'json': null, 'html': '', 'md': ''};
  }
  return null;
}

/// The markdown of page [pageId] in [data], empty when it has none.
String notePageMarkdown(Map<String, dynamic> data, String pageId) {
  final Object? md = notePageContent(data, pageId)?['md'];
  return md is String ? md : '';
}

/// [existing] note data with [patch] applied, the patch's `content` going to
/// page [pageId].
///
/// For a note in the older shape the patch merges over the data, as the
/// servers before 0.12.5 merge it. For a paged note the content replaces that
/// page's content (and the note's `content` too while it has one page), and
/// the page is marked edited ([kNoteDirtyPagesKey]) so the next sync sends it
/// there. Without [pageId] the content goes to the note's only page; a note
/// with several pages then throws [NotePageRequiredException], and a page it
/// lacks throws [NotePageMissingException].
Map<String, dynamic> applyNoteContentEdit(
  Map<String, dynamic> existing,
  Map<String, dynamic> patch, {
  String? pageId,
}) {
  if (!noteDataHasPages(existing)) {
    return <String, dynamic>{...existing, ...patch};
  }
  final Map<String, dynamic> rest = <String, dynamic>{
    for (final MapEntry<String, dynamic> entry in patch.entries)
      if (entry.key != 'content' &&
          !kNoteDataKeysNotSentOnCreate.contains(entry.key))
        entry.key: entry.value,
  };
  final Object? content = patch['content'];
  if (content is! Map) return <String, dynamic>{...existing, ...rest};

  final String? target = pageId ?? noteSinglePageId(existing);
  if (target == null) throw const NotePageRequiredException();
  final pages = notePagesOf(existing);
  final int index = pages.indexWhere((page) => page['id'] == target);
  if (index < 0) throw NotePageMissingException(target);
  final Map<String, dynamic> pageContent = Map<String, dynamic>.from(content);
  // The combined view of a note with several pages follows its pages, unless
  // an earlier build edited it as a whole: that edit is kept for the sync to
  // find ([noteCombinedContentEdited]).
  final bool followsPages =
      pages.length > 1 && !noteCombinedContentEdited(existing);
  pages[index] = <String, dynamic>{...pages[index], 'content': pageContent};
  return <String, dynamic>{
    ...existing,
    ...rest,
    'pages': pages,
    if (pages.length == 1) 'content': pageContent,
    if (followsPages)
      'content': noteContentWithMarkdown(
        existing['content'] is Map
            ? Map<String, dynamic>.from(existing['content'] as Map)
            : null,
        noteCombinedMarkdown(pages),
      ),
    kNoteDirtyPagesKey: <String>{
      ...noteDirtyPageIds(existing),
      target,
    }.toList(),
  };
}

/// The combined markdown a 0.12.5 server makes a note with several pages
/// show as its `content`: each page under a heading naming its path.
String noteCombinedMarkdown(List<Map<String, dynamic>> pages) {
  final Map<String, String> paths = <String, String>{};
  final List<String> parts = <String>[];
  for (final page in pages) {
    final Object? rawTitle = page['title'];
    final String title = rawTitle is String ? rawTitle : '';
    final String? parent = paths[page['parent_id']];
    final String path = parent == null ? title : '$parent / $title';
    paths[page['id'] as String] = path;
    final Object? content = page['content'];
    final Object? md = content is Map ? content['md'] : null;
    parts.add('## $path\n\n${md is String ? md : ''}');
  }
  return parts.join('\n\n');
}

/// Whether the `content` of [data], a note with several pages, differs from
/// the combined view of its pages: it was edited as a whole, as builds before
/// page-aware edits did, and belongs to no page.
bool noteCombinedContentEdited(Map<String, dynamic> data) {
  final Object? content = data['content'];
  final Object? md = content is Map ? content['md'] : null;
  return md is String && md != noteCombinedMarkdown(notePagesOf(data));
}

/// The data of a conflict copy of a note: a note of its own, in the older
/// shape, holding the text edited here. For a paged note that is the edited
/// page, the edited pages each under its title, or for one page or content
/// edited as a whole, its `content`.
Map<String, dynamic> noteDataForConflictCopy(Map<String, dynamic> data) {
  if (!noteDataHasPages(data)) return data;
  final List<String> dirty = noteDirtyPageIds(data);
  Object? content = data['content'];
  if (noteDataIsMultiPage(data) && dirty.isNotEmpty) {
    if (dirty.length == 1) {
      content = notePageContent(data, dirty.single);
    } else {
      final pages = <Map<String, dynamic>>[
        for (final page in notePagesOf(data))
          if (dirty.contains(page['id'])) page,
      ];
      content = noteContentWithMarkdown(null, noteCombinedMarkdown(pages));
    }
  }
  return <String, dynamic>{
    ...noteDataForCreate(data),
    'content': content is Map
        ? Map<String, dynamic>.from(content)
        : noteContentWithMarkdown(null, ''),
  };
}

/// The page of [data] named [pageId], or the main page when it has no such
/// page (it was removed meanwhile) or [pageId] is null.
String notePageIdIn(Map<String, dynamic> data, String? pageId) {
  if (pageId == null) return kNoteMainPageId;
  final pages = notePagesOf(data);
  if (pages.isEmpty) return kNoteMainPageId;
  return pages.any((page) => page['id'] == pageId) ? pageId : kNoteMainPageId;
}

/// The data patch that detaches file [fileId] from [data]: out of the file
/// list of a note in the older shape, and its link out of the content of
/// page [pageId] (by default the main page). Empty when neither holds it.
Map<String, dynamic> noteDataWithoutFile(
  Map<String, dynamic> data,
  String fileId, {
  String pageId = kNoteMainPageId,
}) {
  final Map<String, dynamic> patch = <String, dynamic>{};
  final Object? files = data['files'];
  if (!noteDataHasPages(data) && files is List) {
    final kept = <Object?>[
      for (final Object? file in files)
        if (file is! Map || file['id']?.toString() != fileId) file,
    ];
    if (kept.length != files.length) patch['files'] = kept;
  }
  final String md = notePageMarkdown(data, pageId);
  final Map<String, dynamic> content =
      notePageContent(data, pageId) ?? <String, dynamic>{'md': md};
  final Object? html = content['html'];
  final Object? json = content['json'];
  // The server reads the editor JSON, then the HTML, before the markdown: a
  // file any of them links is attached.
  if (noteFileLinksInMarkdown(md).any((link) => link.id == fileId) ||
      (html is String && _htmlFileLinkIds(html).contains(fileId)) ||
      (json is Map &&
          _jsonFileAttachmentIds(
            Map<String, dynamic>.from(json),
          ).contains(fileId))) {
    patch['content'] = noteContentWithoutFile(content, fileId);
  }
  return patch;
}

/// [content] without file [fileId]: its links taken out of the markdown, its
/// attachment nodes and linked text out of the editor JSON, and its links
/// (with the block [noteContentWithLinkedFiles] puts them in) out of the
/// HTML, so the rich text the web editor saved is kept. A form that still
/// links the file after that, in a shape not known here, is cleared, as the
/// server and the web editor read JSON, then HTML, before the markdown, and
/// would otherwise keep the file.
Map<String, dynamic> noteContentWithoutFile(
  Map<String, dynamic> content,
  String fileId,
) {
  final Object? rawMd = content['md'];
  final Object? rawHtml = content['html'];
  final Object? rawJson = content['json'];
  var html = rawHtml is String ? rawHtml : '';
  if (html.isNotEmpty) {
    // The markup is matched in any case, as HTML is; the file id exactly.
    String ofFile(Match match) => match[1] == fileId ? '' : match[0]!;
    // A block goes whole when it names the file and holds no link but the
    // file's own.
    String ofFileBlock(Match match) =>
        match[1] == fileId && (match[2] == null || match[2] == fileId)
        ? ''
        : match[0]!;
    html = html
        .replaceAllMapped(_htmlFileBlockPattern, ofFileBlock)
        .replaceAllMapped(_htmlFileAnchorPattern, ofFile)
        // A block of the file that holds more keeps the rest, and its other
        // attributes, but no longer names the file: the editor would read
        // it back as the file.
        .replaceAllMapped(
          _htmlFileBlockOpenPattern,
          (Match match) => match[1] == fileId
              ? match[0]!.replaceAll(_htmlFileBlockAttributePattern, '')
              : match[0]!,
        );
    if (_htmlFileLinkIds(html).contains(fileId)) html = '';
  }
  Map<String, dynamic>? json = rawJson is Map
      ? _jsonWithoutFile(Map<String, dynamic>.from(rawJson), fileId)
      : null;
  if (json != null && _jsonFileAttachmentIds(json).contains(fileId)) {
    json = null;
  }
  return <String, dynamic>{
    ...content,
    'md': removeNoteFileLinks(rawMd is String ? rawMd : '', fileId),
    'html': html,
    'json': json,
  };
}

/// A block holding only a file link, as [noteContentWithLinkedFiles] and
/// Open WebUI's editor write it, with the id it names and the id its link
/// names. A block holding more is not taken whole: its other content stays.
final RegExp _htmlFileBlockPattern = RegExp(
  r'''<div\b[^>]*\sdata-file-id\s*=\s*["']([^"']*)["'][^>]*>\s*'''
  r'''(?:<a\b[^>]*?\shref\s*=\s*["']/api/v1/files/([\w-]+)/content["'][^>]*>'''
  r'''(?:(?!</?(?:a|div)\b)[\s\S])*</a>)?\s*</div>''',
  caseSensitive: false,
);

/// The opening tag of a block that names a file, with the id it names.
final RegExp _htmlFileBlockOpenPattern = RegExp(
  r'''<div\b[^>]*\sdata-file-id\s*=\s*["']([^"']*)["'][^>]*>''',
  caseSensitive: false,
);

/// The attributes by which a block names a file.
final RegExp _htmlFileBlockAttributePattern = RegExp(
  r'''\sdata-file-(?:id|size)\s*=\s*(?:"[^"]*"|'[^']*')''',
  caseSensitive: false,
);

/// A whole anchor element linking a file's content, with the file's id.
final RegExp _htmlFileAnchorPattern = RegExp(
  r'''<a\b[^>]*?\shref\s*=\s*["']/api/v1/files/([\w-]+)/content["'][^>]*>.*?</a>''',
  caseSensitive: false,
  dotAll: true,
);

/// Editor JSON [node] without the attachment nodes of file [fileId], and
/// without the text that links to it.
Map<String, dynamic> _jsonWithoutFile(Map<String, dynamic> node, String fileId) {
  final Object? children = node['content'];
  if (children is! List) return node;
  final String href = '/api/v1/files/$fileId/content';
  bool isOfFile(Object? child) {
    if (child is! Map) return false;
    if (child['type'] == 'fileAttachment') {
      final Object? attrs = child['attrs'];
      return attrs is Map && attrs['id'] == fileId;
    }
    final Object? marks = child['marks'];
    return child['type'] == 'text' &&
        marks is List &&
        marks.any(
          (Object? mark) =>
              mark is Map &&
              mark['type'] == 'link' &&
              mark['attrs'] is Map &&
              (mark['attrs'] as Map)['href'] == href,
        );
  }

  return <String, dynamic>{
    ...node,
    'content': <Object?>[
      for (final Object? child in children)
        if (!isOfFile(child))
          child is Map
              ? _jsonWithoutFile(Map<String, dynamic>.from(child), fileId)
              : child,
    ],
  };
}

/// [data] without the keys a create never sends.
Map<String, dynamic> noteDataForCreate(Map<String, dynamic> data) =>
    <String, dynamic>{
      for (final MapEntry<String, dynamic> entry in data.entries)
        if (!kNoteDataKeysNotSentOnCreate.contains(entry.key))
          entry.key: entry.value,
    };

/// [content] with its markdown set to [md] and its rich-text forms cleared,
/// so the server and the web editor read the markdown: they prefer `json`,
/// then `html`, which would still hold the text from before.
Map<String, dynamic> noteContentWithMarkdown(
  Map<String, dynamic>? content,
  String md,
) => <String, dynamic>{...?content, 'json': null, 'html': '', 'md': md};

/// The body of a content save of [content] to note page [pageId].
///
/// [files] is the file list of a note in the older shape, which servers
/// before 0.12.5 keep attachments in; null leaves it out. `page_id` names the
/// page for 0.12.5 servers; older ones ignore it.
Map<String, dynamic> noteContentUpdateBody(
  Map<String, dynamic>? content, {
  required String pageId,
  List<Object?>? files,
}) => <String, dynamic>{
  'data': <String, dynamic>{'content': ?content, 'files': ?files},
  'page_id': pageId,
};

/// [content] with [files] written into it the way a 0.12.5 server moves a
/// note's old file list into its first page (`migrate_page_files`): each
/// image's `data://` reference replaced by its URL, and each file the content
/// does not attach yet added to every form it holds, as a link in the
/// markdown, a block in the HTML and a `fileAttachment` node in the editor
/// JSON, so the rich text a web editor saved is kept, not replaced by the
/// markdown. Empty HTML stays empty, for the server to derive from the
/// markdown. Returns [content] itself when nothing changes.
Map<String, dynamic> noteContentWithLinkedFiles(
  Map<String, dynamic> content,
  List<Object?> files,
) {
  final Object? rawMd = content['md'];
  var md = rawMd is String ? rawMd : '';
  final Object? rawHtml = content['html'];
  var html = rawHtml is String ? rawHtml : '';
  final Object? rawJson = content['json'];
  Map<String, dynamic>? json = rawJson is Map
      ? Map<String, dynamic>.from(rawJson)
      : null;
  var changed = false;

  final List<Map<String, dynamic>> attachments = <Map<String, dynamic>>[];
  for (final Object? file in files) {
    if (file is! Map) continue;
    final Map<String, dynamic> entry = Map<String, dynamic>.from(file);
    if (entry['type'] != 'image') {
      attachments.add(entry);
      continue;
    }
    final Object? id = entry['id'];
    final Object? url = entry['url'];
    if (id is! String || url is! String || url.isEmpty) continue;
    final String reference = 'data://$id';
    if (md.contains(reference)) md = md.replaceAll(reference, url);
    if (html.contains(reference)) html = html.replaceAll(reference, url);
    final String? encoded = json == null ? null : jsonEncode(json);
    if (encoded != null && encoded.contains(reference)) {
      final String quoted = jsonEncode(url);
      json = Map<String, dynamic>.from(
        jsonDecode(
              encoded.replaceAll(
                reference,
                quoted.substring(1, quoted.length - 1),
              ),
            )
            as Map,
      );
    }
    changed = true;
  }

  // What the content attaches already, as the server reads it: the editor
  // JSON's attachment nodes when it has JSON, else the links of its html, or
  // of its markdown when the html is empty. A file linked only in a form the
  // server does not read is added; each form gets it once.
  final Set<String> attached = json != null
      ? _jsonFileAttachmentIds(json)
      : html.isNotEmpty
      ? _htmlFileLinkIds(html)
      : <String>{
          for (final NoteFileLink link in noteFileLinksInMarkdown(md)) link.id,
        };
  final List<Map<String, dynamic>> added = <Map<String, dynamic>>[
    for (final Map<String, dynamic> file in attachments)
      if (file['id'] case final String id
          when _fileIdPattern.hasMatch(id) && attached.add(id))
        file,
  ];
  if (added.isNotEmpty) {
    md = appendNoteFileLinks(md, added);
    for (final Map<String, dynamic> file in added) {
      final String id = file['id'] as String;
      final Object? rawName = file['name'];
      final String name = rawName is String && rawName.isNotEmpty
          ? rawName
          : id;
      if (html.isNotEmpty && !_htmlFileLinkIds(html).contains(id)) {
        const attribute = HtmlEscape(HtmlEscapeMode.attribute);
        const text = HtmlEscape(HtmlEscapeMode.element);
        html +=
            '<div data-file-id="${attribute.convert(id)}">'
            '<a href="${attribute.convert('/api/v1/files/$id/content')}">'
            '${text.convert(name)}</a></div>';
      }
      if (json != null) {
        final Object? nodes = json['content'];
        json['content'] = <Object?>[
          if (nodes is List) ...nodes,
          <String, dynamic>{
            'type': 'fileAttachment',
            'attrs': <String, dynamic>{
              'id': id,
              'name': name,
              'size': file['size'] ?? 0,
            },
          },
        ];
      }
    }
    changed = true;
  }
  if (!changed) return content;
  return <String, dynamic>{
    ...content,
    'md': md,
    'html': html,
    'json': json,
  };
}

/// An anchor element linking a file's content in html, as the server's
/// parser finds them.
final RegExp _htmlFileLinkPattern = RegExp(
  r'''<a\b[^>]*?\shref\s*=\s*["']/api/v1/files/([\w-]+)/content["']''',
  caseSensitive: false,
);

/// The ids of the files [html] links.
Set<String> _htmlFileLinkIds(String html) => <String>{
  for (final Match match in _htmlFileLinkPattern.allMatches(html))
    match.group(1)!,
};

/// The ids of the `fileAttachment` nodes in editor JSON [json].
Set<String> _jsonFileAttachmentIds(Map<String, dynamic>? json) {
  final Set<String> ids = <String>{};
  final List<Object?> stack = <Object?>[json];
  while (stack.isNotEmpty) {
    final Object? node = stack.removeLast();
    if (node is! Map) continue;
    if (node['type'] == 'fileAttachment') {
      final Object? attrs = node['attrs'];
      final Object? id = attrs is Map ? attrs['id'] : null;
      if (id is String) ids.add(id);
    }
    final Object? children = node['content'];
    if (children is List) stack.addAll(children);
  }
  return ids;
}

/// A file attached to a note page through a link in its markdown.
class NoteFileLink {
  const NoteFileLink({required this.id, required this.name});

  final String id;
  final String name;

  /// The attachment as an entry of a note's file list, the shape the editor's
  /// attachment list shows.
  Map<String, dynamic> toAttachment() => <String, dynamic>{
    'type': 'file',
    'id': id,
    'name': name,
  };

  @override
  bool operator ==(Object other) =>
      other is NoteFileLink && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'NoteFileLink($id, $name)';
}

/// The server's pattern for a file id (`[\w-]+`).
final RegExp _fileIdPattern = RegExp(r'^[\w-]+$');

/// A markdown link (not an image) to a file's content,
/// `[name](/api/v1/files/{id}/content)`.
final RegExp _fileLinkPattern = RegExp(
  r'(?<!!)\[([^\]\n]*)\]\(/api/v1/files/([\w-]+)/content\)',
);


/// The markdown that links file [id] as an attachment, as the server writes
/// it (brackets are taken out of the name so the link stays whole).
String noteFileLinkMarkdown({required String id, required String name}) {
  final String label = name.replaceAll('[', '').replaceAll(']', '');
  return '[${label.isEmpty ? id : label}](/api/v1/files/$id/content)';
}

/// A line that may open or close a fenced code block: up to three spaces, a
/// run of three or more backticks or tildes, then the rest of the line.
final RegExp _fencePattern = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// [markdown]'s lines, each with whether it lies in a fenced code block, and
/// the fence of a block left open at its end. As in CommonMark, a block
/// closes only on a run of its own character at least as long as the one
/// that opened it, with nothing after; a backtick run with a backtick after
/// it opens none.
({List<(String, bool)> lines, String? open}) _scanFences(String markdown) {
  final List<(String, bool)> lines = <(String, bool)>[];
  String? open;
  for (final String line in markdown.split('\n')) {
    // The carriage return of a CRLF line ending is no part of the line.
    final RegExpMatch? fence = _fencePattern.firstMatch(
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
    );
    if (fence == null) {
      lines.add((line, open != null));
      continue;
    }
    final String run = fence.group(1)!;
    final String rest = fence.group(2)!;
    if (open == null) {
      if (run.startsWith('`') && rest.contains('`')) {
        lines.add((line, false));
        continue;
      }
      open = run;
    } else if (run[0] == open[0] &&
        run.length >= open.length &&
        rest.trim().isEmpty) {
      open = null;
    }
    lines.add((line, true));
  }
  return (lines: lines, open: open);
}

/// [markdown]'s lines, each with whether it lies in a fenced code block.
List<(String, bool)> _linesWithFences(String markdown) =>
    _scanFences(markdown).lines;

/// The files [markdown] attaches, in order, each id once. Images, code spans
/// and fenced code are left out, as the server reads them.
List<NoteFileLink> noteFileLinksInMarkdown(String markdown) {
  final Set<String> seen = <String>{};
  final List<NoteFileLink> links = <NoteFileLink>[];
  for (final RegExpMatch match in _fileLinkPattern.allMatches(
    _withoutCode(markdown),
  )) {
    final String id = match.group(2)!;
    if (!seen.add(id)) continue;
    // The name as written: code it holds is hidden in the text matched.
    final int nameStart = match.start + 1;
    final String name = markdown
        .substring(nameStart, nameStart + match.group(1)!.length)
        .trim();
    links.add(NoteFileLink(id: id, name: name.isEmpty ? id : name));
  }
  return links;
}

/// [markdown] with a link to each of [files] it does not link yet, appended
/// as its own paragraph, the way the server migrates a note's file list.
/// Images are left out: the server keeps those as images, not attachments.
String appendNoteFileLinks(
  String markdown,
  List<Map<String, dynamic>> files,
) {
  final Set<String> linked = <String>{
    for (final NoteFileLink link in noteFileLinksInMarkdown(markdown)) link.id,
  };
  final StringBuffer out = StringBuffer(markdown);
  // A link written inside an unclosed code block would be code, not an
  // attachment: the block is closed first.
  var fence = _openFence(markdown);
  for (final Map<String, dynamic> file in files) {
    if (file['type'] == 'image') continue;
    final Object? id = file['id'];
    if (id is! String || !_fileIdPattern.hasMatch(id)) continue;
    if (!linked.add(id)) continue;
    if (fence != null) {
      out
        ..write('\n')
        ..write(fence);
      fence = null;
    }
    final Object? name = file['name'];
    out
      ..write('\n\n')
      ..write(noteFileLinkMarkdown(id: id, name: name is String ? name : id));
  }
  return out.toString();
}

/// The fence of a code block [markdown] leaves open at its end, which also
/// closes it, or null when it ends outside one.
String? _openFence(String markdown) => _scanFences(markdown).open;

/// The character code hidden text is replaced with, which no link holds.
const int _hidden = 0x01;

/// [markdown] with its code hidden, so a file link is found only where it is
/// one: every character of a fenced code block or of a code span, line
/// breaks aside, replaced with [_hidden]. A code span, as in CommonMark,
/// opens on a run of backticks and closes on the next run of as many within
/// its paragraph. A link whose name holds code is still a link; one inside
/// code, or whose address code breaks, is none.
String _withoutCode(String markdown) {
  final List<int> text = <int>[];
  var first = true;
  for (final (String line, bool fenced) in _linesWithFences(markdown)) {
    if (!first) text.add(0x0A);
    first = false;
    text.addAll(fenced ? List<int>.filled(line.length, _hidden) : line.codeUnits);
  }
  var i = 0;
  while (i < text.length) {
    if (text[i] != 0x60) {
      i++;
      continue;
    }
    final int opened = i;
    while (i < text.length && text[i] == 0x60) {
      i++;
    }
    final int run = i - opened;
    int? closed;
    var j = i;
    while (j < text.length) {
      if (text[j] == 0x0A && _blankLineAfter(text, j)) break;
      if (text[j] != 0x60) {
        j++;
        continue;
      }
      final int start = j;
      while (j < text.length && text[j] == 0x60) {
        j++;
      }
      if (j - start == run) {
        closed = j;
        break;
      }
    }
    if (closed == null) continue;
    for (var k = opened; k < closed; k++) {
      if (text[k] != 0x0A) text[k] = _hidden;
    }
    i = closed;
  }
  return String.fromCharCodes(text);
}

/// Whether the line after the line break at [index] of [text] is blank,
/// which ends a paragraph.
bool _blankLineAfter(List<int> text, int index) {
  for (var k = index + 1; k < text.length && text[k] != 0x0A; k++) {
    if (text[k] != 0x20 && text[k] != 0x09 && text[k] != 0x0D) return false;
  }
  return true;
}

/// [mine] with the file links [stored] gained since [base], the stored
/// markdown [mine] was edited from: a recording attached, or files a sync
/// moved into the content, while the editor held its own copy. Links [mine]
/// dropped since [base] stay dropped.
String mergeNoteFileLinks({
  required String base,
  required String stored,
  required String mine,
}) {
  final Set<String> known = <String>{
    for (final NoteFileLink link in noteFileLinksInMarkdown(base)) link.id,
  };
  final List<Map<String, dynamic>> gained = <Map<String, dynamic>>[
    for (final NoteFileLink link in noteFileLinksInMarkdown(stored))
      if (!known.contains(link.id)) link.toAttachment(),
  ];
  return gained.isEmpty ? mine : appendNoteFileLinks(mine, gained);
}

/// [markdown] without the links to file [id]. A line that held only such a
/// link goes, with the blank line that set it apart; other text stays as it
/// was.
String removeNoteFileLinks(String markdown, String id) {
  final List<(String, bool)> lines = _linesWithFences(markdown);
  // The links go from the text as written; a link never spans lines, so the
  // lines stay as many.
  final StringBuffer out = StringBuffer();
  var start = 0;
  for (final RegExpMatch match in _fileLinkPattern.allMatches(
    _withoutCode(markdown),
  )) {
    if (match.group(2) != id) continue;
    out.write(markdown.substring(start, match.start));
    start = match.end;
  }
  out.write(markdown.substring(start));
  final List<String> strippedLines = out.toString().split('\n');
  final List<String> kept = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final (String line, bool fenced) = lines[i];
    if (fenced) {
      kept.add(line);
      continue;
    }
    final String stripped = strippedLines[i];
    if (stripped.trim().isNotEmpty || line.trim().isEmpty) {
      kept.add(stripped);
      continue;
    }
    // The line held only the link. Its paragraph break goes with it when
    // blank lines would otherwise meet, or the note would end in one.
    final bool nextBlank =
        i + 1 >= lines.length || lines[i + 1].$1.trim().isEmpty;
    if (nextBlank && kept.isNotEmpty && kept.last.trim().isEmpty) {
      kept.removeLast();
    }
  }
  return kept.join('\n');
}

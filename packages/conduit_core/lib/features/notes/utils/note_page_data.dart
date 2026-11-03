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

/// The data patch that detaches file [fileId] from [data]: out of the file
/// list of a note in the older shape, and its link out of the main page's
/// content, the page Conduit edits. Empty when neither holds it.
Map<String, dynamic> noteDataWithoutFile(
  Map<String, dynamic> data,
  String fileId,
) {
  final Map<String, dynamic> patch = <String, dynamic>{};
  final Object? files = data['files'];
  if (!noteDataHasPages(data) && files is List) {
    final kept = <Object?>[
      for (final Object? file in files)
        if (file is! Map || file['id']?.toString() != fileId) file,
    ];
    if (kept.length != files.length) patch['files'] = kept;
  }
  final String md = notePageMarkdown(data, kNoteMainPageId);
  if (noteFileLinksInMarkdown(md).any((link) => link.id == fileId)) {
    patch['content'] = noteContentWithMarkdown(
      notePageContent(data, kNoteMainPageId),
      removeNoteFileLinks(md, fileId),
    );
  }
  return patch;
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
/// note's old file list into its first page: a link to each file the
/// markdown does not link yet, and each image's `data://` reference replaced
/// by its URL. Returns [content] itself when nothing changes.
Map<String, dynamic> noteContentWithLinkedFiles(
  Map<String, dynamic> content,
  List<Object?> files,
) {
  final Object? rawMd = content['md'];
  final String original = rawMd is String ? rawMd : '';
  var md = original;
  final List<Map<String, dynamic>> attachments = <Map<String, dynamic>>[];
  for (final Object? file in files) {
    if (file is! Map) continue;
    final Map<String, dynamic> entry = Map<String, dynamic>.from(file);
    if (entry['type'] == 'image') {
      final Object? id = entry['id'];
      final Object? url = entry['url'];
      if (id is String && url is String && url.isNotEmpty) {
        md = md.replaceAll('data://$id', url);
      }
    } else {
      attachments.add(entry);
    }
  }
  md = appendNoteFileLinks(md, attachments);
  return md == original ? content : noteContentWithMarkdown(content, md);
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

/// Inline code spans, whose text is no link.
final RegExp _inlineCodePattern = RegExp(r'`[^`\n]*`');

/// The markdown that links file [id] as an attachment, as the server writes
/// it (brackets are taken out of the name so the link stays whole).
String noteFileLinkMarkdown({required String id, required String name}) {
  final String label = name.replaceAll('[', '').replaceAll(']', '');
  return '[${label.isEmpty ? id : label}](/api/v1/files/$id/content)';
}

/// A line that may open or close a fenced code block: a run of three or more
/// backticks or tildes, then the rest of the line, a carriage return of a
/// CRLF line ending included.
final RegExp _fencePattern = RegExp(r'^\s*(`{3,}|~{3,})(.*)$', dotAll: true);

/// [markdown]'s lines, each with whether it lies in a fenced code block, and
/// the fence of a block left open at its end. As in CommonMark, a block
/// closes only on a run of its own character at least as long as the one
/// that opened it, with nothing after; a backtick run with a backtick after
/// it opens none.
({List<(String, bool)> lines, String? open}) _scanFences(String markdown) {
  final List<(String, bool)> lines = <(String, bool)>[];
  String? open;
  for (final String line in markdown.split('\n')) {
    final RegExpMatch? fence = _fencePattern.firstMatch(line);
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
  for (final (String line, bool fenced) in _linesWithFences(markdown)) {
    if (fenced) continue;
    final String text = line.replaceAll(_inlineCodePattern, '');
    for (final RegExpMatch match in _fileLinkPattern.allMatches(text)) {
      final String id = match.group(2)!;
      if (!seen.add(id)) continue;
      final String name = match.group(1)!.trim();
      links.add(NoteFileLink(id: id, name: name.isEmpty ? id : name));
    }
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

/// [line] with [replace] applied to the text outside its inline code spans,
/// whose text is no link and stays as written.
String _outsideInlineCode(String line, String Function(String) replace) {
  final StringBuffer out = StringBuffer();
  var start = 0;
  for (final Match code in _inlineCodePattern.allMatches(line)) {
    out
      ..write(replace(line.substring(start, code.start)))
      ..write(code.group(0));
    start = code.end;
  }
  out.write(replace(line.substring(start)));
  return out.toString();
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
  final List<String> kept = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final (String line, bool fenced) = lines[i];
    if (fenced) {
      kept.add(line);
      continue;
    }
    final String stripped = _outsideInlineCode(
      line,
      (String text) => text.replaceAllMapped(
        _fileLinkPattern,
        (Match match) => match.group(2) == id ? '' : match.group(0)!,
      ),
    );
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

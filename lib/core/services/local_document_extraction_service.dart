import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart'
    show XmlEndElementEvent, XmlStartElementEvent, parseEvents;

const int kLocalDocumentDefaultMaxFiles = 4;
const int kLocalDocumentDefaultMaxSourceBytes = 8 * 1024 * 1024;
const int kLocalDocumentDefaultMaxAggregateSourceBytes = 16 * 1024 * 1024;
const int kLocalDocumentDefaultMaxPdfPages = 50;
const int kLocalDocumentDefaultMaxCharacters = 120000;
const int kLocalDocumentDefaultMaxExpandedBytes = 8 * 1024 * 1024;
const int kLocalDocumentDefaultMaxXmlNodes = 250000;
const int kLocalDocumentDefaultMaxXmlDepth = 256;
const int kLocalDocumentDefaultMaxZipEntries = 512;
const int kLocalDocumentDefaultMaxCentralDirectoryBytes = 1024 * 1024;

/// Extensions supported by the bounded local-document extraction pipeline.
///
/// PDF is intentionally absent: the current PDF engine cannot enforce a hard
/// text-expansion bound before materializing each page. The injected extractor
/// below remains a test seam for the bounded contract.
const List<String> kLocalDocumentPickerExtensions = <String>[
  'cfg',
  'conf',
  'css',
  'csv',
  'dart',
  'dockerignore',
  'docx',
  'editorconfig',
  'env',
  'gitignore',
  'go',
  'h',
  'hpp',
  'htm',
  'html',
  'ini',
  'java',
  'js',
  'json',
  'jsonl',
  'kt',
  'log',
  'markdown',
  'md',
  'npmrc',
  'php',
  'properties',
  'py',
  'rb',
  'rs',
  'sh',
  'sql',
  'swift',
  'toml',
  'ts',
  'tsv',
  'txt',
  'xml',
  'yaml',
  'yml',
];

bool isLocalDocumentFileNameSupported(String name) {
  final basename = _portableBasename(name).toLowerCase();
  if (basename == 'dockerfile' ||
      basename == 'makefile' ||
      basename == 'license' ||
      basename == 'readme') {
    return true;
  }
  final dot = basename.lastIndexOf('.');
  if (dot < 0 || dot == basename.length - 1) return false;
  return kLocalDocumentPickerExtensions.contains(basename.substring(dot + 1));
}

/// Resource limits for local-only document extraction.
///
/// Source files never leave the device; only bounded extracted text is
/// returned to the caller.
final class LocalDocumentExtractionLimits {
  const LocalDocumentExtractionLimits({
    this.maxFiles = kLocalDocumentDefaultMaxFiles,
    this.maxSourceBytes = kLocalDocumentDefaultMaxSourceBytes,
    this.maxAggregateSourceBytes = kLocalDocumentDefaultMaxAggregateSourceBytes,
    this.maxPdfPages = kLocalDocumentDefaultMaxPdfPages,
    this.maxAggregateCharacters = kLocalDocumentDefaultMaxCharacters,
    this.maxExpandedDocumentBytes = kLocalDocumentDefaultMaxExpandedBytes,
    this.maxDocxXmlNodes = kLocalDocumentDefaultMaxXmlNodes,
    this.maxDocxXmlDepth = kLocalDocumentDefaultMaxXmlDepth,
    this.maxDocxZipEntries = kLocalDocumentDefaultMaxZipEntries,
    this.maxDocxCentralDirectoryBytes =
        kLocalDocumentDefaultMaxCentralDirectoryBytes,
  }) : assert(maxFiles > 0),
       assert(maxSourceBytes > 0),
       assert(maxAggregateSourceBytes > 0),
       assert(maxPdfPages > 0),
       assert(maxAggregateCharacters > 0),
       assert(maxExpandedDocumentBytes > 0),
       assert(maxDocxXmlNodes > 0),
       assert(maxDocxXmlDepth > 0),
       assert(maxDocxZipEntries > 0),
       assert(maxDocxCentralDirectoryBytes > 0);

  final int maxFiles;
  final int maxSourceBytes;
  final int maxAggregateSourceBytes;
  final int maxPdfPages;
  final int maxAggregateCharacters;

  /// Maximum expanded size of the XML part read from a container document.
  /// This is independent from the compressed source-byte limit and prevents
  /// small archive bombs from being accepted as DOCX files.
  final int maxExpandedDocumentBytes;

  /// Maximum XML nodes visited while extracting the DOCX main document.
  final int maxDocxXmlNodes;

  /// Maximum element nesting accepted before constructing a DOCX XML tree.
  final int maxDocxXmlDepth;

  /// Maximum number of central-directory records accepted in a DOCX archive.
  final int maxDocxZipEntries;

  /// Maximum encoded size of the DOCX ZIP central directory.
  final int maxDocxCentralDirectoryBytes;
}

/// A local source whose bytes can be read without exposing its filesystem path
/// to the prepared document or prompt renderer.
final class LocalDocumentSource {
  LocalDocumentSource._({
    required this.name,
    required this.mimeType,
    required this.declaredSize,
    required Future<Uint8List> Function(int maxBytes) readBytes,
  }) : _readBytes = readBytes;

  /// Creates an in-memory source. The supplied bytes are copied so later
  /// caller mutations cannot change the prepared document or its stable ID.
  factory LocalDocumentSource.fromBytes({
    required String name,
    required List<int> bytes,
    String? mimeType,
  }) {
    final ownedBytes = Uint8List.fromList(bytes);
    return LocalDocumentSource._(
      name: name,
      mimeType: mimeType,
      declaredSize: ownedBytes.length,
      readBytes: (_) async => ownedBytes,
    );
  }

  /// Creates a lazily read source for a local file. Only a sanitized basename
  /// is retained; the path remains private to the byte-reader closure.
  static Future<LocalDocumentSource> fromFile(
    File file, {
    String? displayName,
    String? mimeType,
  }) async {
    final requestedName = displayName == null || displayName.trim().isEmpty
        ? _portableBasename(file.path)
        : displayName;
    final name = sanitizeLocalDocumentFilename(requestedName);
    late final int declaredSize;
    try {
      declaredSize = await file.length();
    } catch (_) {
      throw _documentFailure(
        LocalDocumentExtractionError.readFailed,
        name,
        '$name could not be read.',
      );
    }
    return LocalDocumentSource._(
      name: name,
      mimeType: mimeType,
      declaredSize: declaredSize,
      readBytes: (maxBytes) async {
        final output = BytesBuilder(copy: false);
        await for (final chunk in file.openRead(0, maxBytes + 1)) {
          output.add(chunk);
        }
        return output.takeBytes();
      },
    );
  }

  final String name;
  final String? mimeType;
  final int declaredSize;
  final Future<Uint8List> Function(int maxBytes) _readBytes;
}

enum LocalDocumentExtractionError {
  tooManyFiles,
  sourceTooLarge,
  aggregateSourceTooLarge,
  aggregateCharacterLimit,
  unsupportedType,
  invalidTextEncoding,
  binaryContent,
  encryptedDocument,
  emptyDocument,
  tooManyPages,
  malformedDocument,
  readFailed,
}

/// A safe, user-presentable preparation failure.
///
/// [documentName] is always sanitized and never contains a local path.
final class LocalDocumentExtractionException implements Exception {
  const LocalDocumentExtractionException({
    required this.code,
    required this.message,
    this.documentName,
  });

  final LocalDocumentExtractionError code;
  final String message;
  final String? documentName;

  @override
  String toString() => message;
}

/// Text extracted from a PDF by the injected PDF implementation.
final class LocalPdfExtraction {
  const LocalPdfExtraction({
    required this.text,
    required this.pageCount,
    this.isEncrypted = false,
  });

  final String text;
  final int pageCount;
  final bool isEncrypted;
}

typedef LocalPdfExtractor =
    Future<LocalPdfExtraction> Function(
      Uint8List bytes, {
      required int maxPages,
      required int maxCharacters,
    });

/// A bounded local document extracted without backend-specific formatting.
final class ExtractedLocalDocument {
  const ExtractedLocalDocument({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.extractedText,
    required this.truncated,
  });

  /// Stable, opaque identifier derived from the sanitized name and contents.
  final String id;
  final String name;
  final String mimeType;
  final int size;
  final String extractedText;
  final bool truncated;

  int get characterCount => extractedText.runes.length;
}

final class ExtractedLocalDocumentBatch {
  const ExtractedLocalDocumentBatch({
    required this.documents,
    required this.totalSourceBytes,
    required this.totalCharacters,
  });

  final List<ExtractedLocalDocument> documents;
  final int totalSourceBytes;
  final int totalCharacters;

  bool get wasTruncated => documents.any((document) => document.truncated);
}

/// Extracts bounded document text locally without applying backend semantics.
///
/// This service performs no network requests and does not retain source paths
/// or bytes after preparation completes.
final class LocalDocumentExtractionService {
  LocalDocumentExtractionService({
    this.limits = const LocalDocumentExtractionLimits(),
    this.documentIdPrefix = 'ldoc_',
    LocalPdfExtractor? pdfExtractor,
  }) : assert(documentIdPrefix.isNotEmpty),
       assert(documentIdPrefix.length <= 32),
       _pdfExtractor = pdfExtractor;

  final LocalDocumentExtractionLimits limits;
  final String documentIdPrefix;
  final LocalPdfExtractor? _pdfExtractor;

  Future<ExtractedLocalDocument> prepare(LocalDocumentSource source) async {
    final batch = await prepareAll([source]);
    return batch.documents.single;
  }

  Future<ExtractedLocalDocumentBatch> prepareAll(
    Iterable<LocalDocumentSource> inputSources,
  ) async {
    final sources = List<LocalDocumentSource>.unmodifiable(inputSources);
    if (sources.length > limits.maxFiles) {
      throw LocalDocumentExtractionException(
        code: LocalDocumentExtractionError.tooManyFiles,
        message: 'Select no more than ${limits.maxFiles} documents.',
      );
    }
    if (sources.isEmpty) {
      return const ExtractedLocalDocumentBatch(
        documents: [],
        totalSourceBytes: 0,
        totalCharacters: 0,
      );
    }

    var declaredTotal = 0;
    for (final source in sources) {
      final safeName = sanitizeLocalDocumentFilename(source.name);
      if (source.declaredSize > limits.maxSourceBytes) {
        throw _documentFailure(
          LocalDocumentExtractionError.sourceTooLarge,
          safeName,
          '$safeName exceeds the ${limits.maxSourceBytes}-byte document limit.',
        );
      }
      declaredTotal += source.declaredSize;
      if (declaredTotal > limits.maxAggregateSourceBytes) {
        throw LocalDocumentExtractionException(
          code: LocalDocumentExtractionError.aggregateSourceTooLarge,
          message:
              'The selected documents exceed the '
              '${limits.maxAggregateSourceBytes}-byte combined limit.',
        );
      }
    }

    final prepared = <ExtractedLocalDocument>[];
    var actualTotalBytes = 0;
    var totalCharacters = 0;

    for (final source in sources) {
      final safeName = sanitizeLocalDocumentFilename(source.name);
      late final Uint8List bytes;
      try {
        bytes = await source._readBytes(limits.maxSourceBytes);
      } catch (_) {
        throw _documentFailure(
          LocalDocumentExtractionError.readFailed,
          safeName,
          '$safeName could not be read.',
        );
      }

      if (bytes.length > limits.maxSourceBytes) {
        throw _documentFailure(
          LocalDocumentExtractionError.sourceTooLarge,
          safeName,
          '$safeName exceeds the ${limits.maxSourceBytes}-byte document limit.',
        );
      }
      actualTotalBytes += bytes.length;
      if (actualTotalBytes > limits.maxAggregateSourceBytes) {
        throw LocalDocumentExtractionException(
          code: LocalDocumentExtractionError.aggregateSourceTooLarge,
          message:
              'The selected documents exceed the '
              '${limits.maxAggregateSourceBytes}-byte combined limit.',
        );
      }

      final remainingCharacters =
          limits.maxAggregateCharacters - totalCharacters;
      if (remainingCharacters <= 0) {
        throw LocalDocumentExtractionException(
          code: LocalDocumentExtractionError.aggregateCharacterLimit,
          message:
              'The selected documents exceed the '
              '${limits.maxAggregateCharacters}-character text limit.',
        );
      }
      final extracted = await _extract(
        bytes: bytes,
        name: safeName,
        declaredMimeType: source.mimeType,
        maxCharacters: remainingCharacters,
      );
      final normalizedText = _normalizeExtractedText(extracted.text);
      if (normalizedText.isEmpty) {
        throw _documentFailure(
          LocalDocumentExtractionError.emptyDocument,
          safeName,
          '$safeName contains no extractable text.',
        );
      }

      final sourceCharacterCount = normalizedText.runes.length;
      final truncated = sourceCharacterCount > remainingCharacters;
      final boundedText = truncated
          ? _takeRunes(normalizedText, remainingCharacters)
          : normalizedText;
      totalCharacters += boundedText.runes.length;

      prepared.add(
        ExtractedLocalDocument(
          id: _stableDocumentId(safeName, bytes, prefix: documentIdPrefix),
          name: safeName,
          mimeType: extracted.mimeType,
          size: bytes.length,
          extractedText: boundedText,
          truncated: truncated,
        ),
      );
    }

    return ExtractedLocalDocumentBatch(
      documents: List.unmodifiable(prepared),
      totalSourceBytes: actualTotalBytes,
      totalCharacters: totalCharacters,
    );
  }

  Future<_ExtractedDocument> _extract({
    required Uint8List bytes,
    required String name,
    required String? declaredMimeType,
    required int maxCharacters,
  }) async {
    if (bytes.isEmpty) {
      throw _documentFailure(
        LocalDocumentExtractionError.emptyDocument,
        name,
        '$name is empty.',
      );
    }

    final extension = _extensionOf(name);
    final mimeType = _normalizeMimeType(declaredMimeType);
    final hasPdfSignature = _startsWith(bytes, const [0x25, 0x50, 0x44, 0x46]);
    final expectsPdf = extension == '.pdf' || mimeType == 'application/pdf';
    if ((expectsPdf || hasPdfSignature) && _pdfExtractor == null) {
      throw _documentFailure(
        LocalDocumentExtractionError.unsupportedType,
        name,
        '$name is not a supported local document.',
      );
    }
    if (expectsPdf && !hasPdfSignature) {
      throw _documentFailure(
        LocalDocumentExtractionError.malformedDocument,
        name,
        '$name is not a valid PDF document.',
      );
    }
    if (hasPdfSignature) {
      return _extractPdf(bytes, name, maxCharacters);
    }

    final expectsDocx = extension == '.docx' || mimeType == _docxMimeType;
    if (expectsDocx && _hasOleCompoundFileSignature(bytes)) {
      throw _documentFailure(
        LocalDocumentExtractionError.encryptedDocument,
        name,
        '$name is encrypted or password protected.',
      );
    }
    final hasZipSignature = _hasZipSignature(bytes);
    if (expectsDocx && !hasZipSignature) {
      throw _documentFailure(
        LocalDocumentExtractionError.malformedDocument,
        name,
        '$name is not a valid DOCX document.',
      );
    }
    if (hasZipSignature) {
      if (!expectsDocx) {
        throw _documentFailure(
          LocalDocumentExtractionError.unsupportedType,
          name,
          '$name is an unsupported archive.',
        );
      }
      return _extractDocx(bytes, name);
    }

    if (!_isSupportedTextSource(extension, name, mimeType)) {
      throw _documentFailure(
        LocalDocumentExtractionError.unsupportedType,
        name,
        '$name is not a supported UTF-8 text or DOCX document.',
      );
    }

    return _ExtractedDocument(
      text: _decodeUtf8Text(bytes, name),
      mimeType: _textMimeType(extension, mimeType),
    );
  }

  Future<_ExtractedDocument> _extractPdf(
    Uint8List bytes,
    String name,
    int maxCharacters,
  ) async {
    final pdfExtractor = _pdfExtractor;
    if (pdfExtractor == null) {
      // pdfrx exposes only whole-page text objects. A compressed page can
      // expand without a character bound before Conduit sees the result, and
      // a Dart isolate cannot impose a process memory ceiling. Fail closed
      // until the engine offers an incremental or hard-bounded text API.
      throw _documentFailure(
        LocalDocumentExtractionError.unsupportedType,
        name,
        '$name is not a supported local document.',
      );
    }
    late final LocalPdfExtraction extraction;
    try {
      extraction = await pdfExtractor(
        bytes,
        maxPages: limits.maxPdfPages,
        maxCharacters: maxCharacters,
      );
    } on PdfPasswordException {
      throw _documentFailure(
        LocalDocumentExtractionError.encryptedDocument,
        name,
        '$name is encrypted or password protected.',
      );
    } on LocalDocumentExtractionException {
      rethrow;
    } catch (_) {
      throw _documentFailure(
        LocalDocumentExtractionError.malformedDocument,
        name,
        '$name could not be decoded as a PDF document.',
      );
    }
    if (extraction.isEncrypted) {
      throw _documentFailure(
        LocalDocumentExtractionError.encryptedDocument,
        name,
        '$name is encrypted or password protected.',
      );
    }
    if (extraction.pageCount > limits.maxPdfPages) {
      throw _documentFailure(
        LocalDocumentExtractionError.tooManyPages,
        name,
        '$name exceeds the ${limits.maxPdfPages}-page PDF limit.',
      );
    }
    return _ExtractedDocument(
      text: extraction.text,
      mimeType: 'application/pdf',
    );
  }

  _ExtractedDocument _extractDocx(Uint8List bytes, String name) {
    ZipDirectory? directory;
    try {
      final zipPreflight = _validateDocxZipCentralDirectory(
        bytes,
        maxEntries: limits.maxDocxZipEntries,
        maxCentralDirectoryBytes: limits.maxDocxCentralDirectoryBytes,
      );
      // Parse metadata and retain compressed entry streams, but do not build
      // an Archive with ZipDecoder. ZipDecoder eagerly expands Unix symlink
      // entries while determining their target, before callers can enforce an
      // expansion limit. DOCX does not need links, so reject them from the
      // central directory and expand only the main XML part below.
      directory = ZipDirectory()..read(InputMemoryStream(bytes));
      final headers = directory.fileHeaders;
      if (headers.length != zipPreflight.entryCount) {
        throw const FormatException('Mismatched ZIP entry count');
      }
      if (headers.any(_zipEntryIsEncrypted)) {
        throw _documentFailure(
          LocalDocumentExtractionError.encryptedDocument,
          name,
          '$name is encrypted or password protected.',
        );
      }
      if (headers.any(_zipEntryIsUnixSymlink)) {
        throw const FormatException('DOCX links are not allowed');
      }
      if (headers.any(
        (header) =>
            header.file == null || header.file!.filename != header.filename,
      )) {
        throw const FormatException('Mismatched ZIP entry names');
      }

      final contentTypes = headers
          .where((header) => header.filename == '[Content_Types].xml')
          .toList();
      final documentParts = headers
          .where((header) => header.filename == 'word/document.xml')
          .toList();
      if (contentTypes.length != 1 || documentParts.length != 1) {
        throw const FormatException('Missing DOCX main document part');
      }
      final documentPart = documentParts.single;
      if (documentPart.uncompressedSize > limits.maxExpandedDocumentBytes) {
        throw _documentFailure(
          LocalDocumentExtractionError.sourceTooLarge,
          name,
          '$name expands beyond the '
          '${limits.maxExpandedDocumentBytes}-byte document limit.',
        );
      }

      final documentOutput = _BoundedOutputMemoryStream(
        limits.maxExpandedDocumentBytes,
      );
      try {
        documentPart.file!.decompress(documentOutput);
      } on _ExpandedDocumentLimitException {
        throw _documentFailure(
          LocalDocumentExtractionError.sourceTooLarge,
          name,
          '$name expands beyond the '
          '${limits.maxExpandedDocumentBytes}-byte document limit.',
        );
      }
      final documentBytes = documentOutput.getBytes();
      if (documentBytes.isEmpty) {
        throw const FormatException('Empty DOCX main document part');
      }
      if (documentBytes.length > limits.maxExpandedDocumentBytes) {
        throw _documentFailure(
          LocalDocumentExtractionError.sourceTooLarge,
          name,
          '$name expands beyond the '
          '${limits.maxExpandedDocumentBytes}-byte document limit.',
        );
      }
      final xmlSource = utf8.decode(documentBytes, allowMalformed: false);
      if (RegExp(
        r'<!\s*(DOCTYPE|ENTITY)',
        caseSensitive: false,
      ).hasMatch(xmlSource)) {
        throw const FormatException('DOCX declarations are not allowed');
      }
      _validateDocxXmlComplexity(
        xmlSource,
        maxNodes: limits.maxDocxXmlNodes,
        maxDepth: limits.maxDocxXmlDepth,
      );
      final document = XmlDocument.parse(xmlSource);
      final buffer = StringBuffer();
      _appendDocxText(
        document.rootElement,
        buffer,
        maxNodes: limits.maxDocxXmlNodes,
      );
      return _ExtractedDocument(
        text: buffer.toString(),
        mimeType: _docxMimeType,
      );
    } on LocalDocumentExtractionException {
      rethrow;
    } catch (_) {
      throw _documentFailure(
        LocalDocumentExtractionError.malformedDocument,
        name,
        '$name could not be decoded as a DOCX document.',
      );
    } finally {
      for (final header in directory?.fileHeaders ?? const <ZipFileHeader>[]) {
        header.file?.closeSync();
      }
    }
  }
}

final class _ExtractedDocument {
  const _ExtractedDocument({required this.text, required this.mimeType});

  final String text;
  final String mimeType;
}

final class _ExpandedDocumentLimitException implements Exception {
  const _ExpandedDocumentLimitException();
}

final class _BoundedOutputMemoryStream extends OutputMemoryStream {
  _BoundedOutputMemoryStream(this.maxBytes)
    : super(size: maxBytes < 0x8000 ? maxBytes : 0x8000);

  final int maxBytes;

  void _ensureCapacity(int additionalBytes) {
    if (additionalBytes < 0 || length + additionalBytes > maxBytes) {
      throw const _ExpandedDocumentLimitException();
    }
  }

  @override
  void writeByte(int value) {
    _ensureCapacity(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final writeLength = length ?? bytes.length;
    _ensureCapacity(writeLength);
    super.writeBytes(bytes, length: writeLength);
  }

  @override
  void writeStream(InputStream stream) {
    _ensureCapacity(stream.length);
    super.writeStream(stream);
  }
}

const _docxMimeType =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

final _textExtensions = <String>{
  for (final extension in kLocalDocumentPickerExtensions)
    if (extension != 'docx') '.$extension',
};

const _textMimeTypes = <String>{
  'application/javascript',
  'application/json',
  'application/ld+json',
  'application/sql',
  'application/toml',
  'application/x-httpd-php',
  'application/x-ndjson',
  'application/x-sh',
  'application/x-yaml',
  'application/xml',
  'application/yaml',
};

const _extensionMimeTypes = <String, String>{
  '.csv': 'text/csv',
  '.htm': 'text/html',
  '.html': 'text/html',
  '.json': 'application/json',
  '.jsonl': 'application/x-ndjson',
  '.markdown': 'text/markdown',
  '.md': 'text/markdown',
  '.toml': 'application/toml',
  '.tsv': 'text/tab-separated-values',
  '.xml': 'application/xml',
  '.yaml': 'application/yaml',
  '.yml': 'application/yaml',
};

String _decodeUtf8Text(Uint8List bytes, String name) {
  var start = 0;
  if (_startsWith(bytes, const [0xef, 0xbb, 0xbf])) {
    start = 3;
  }
  late final String decoded;
  try {
    decoded = utf8.decode(bytes.sublist(start), allowMalformed: false);
  } on FormatException {
    throw _documentFailure(
      LocalDocumentExtractionError.invalidTextEncoding,
      name,
      '$name is not valid UTF-8 text.',
    );
  }

  var suspiciousControls = 0;
  for (final rune in decoded.runes) {
    if (rune == 0) {
      throw _documentFailure(
        LocalDocumentExtractionError.binaryContent,
        name,
        '$name appears to contain binary data.',
      );
    }
    if ((rune < 0x20 &&
            rune != 0x09 &&
            rune != 0x0a &&
            rune != 0x0c &&
            rune != 0x0d) ||
        rune == 0x7f) {
      suspiciousControls++;
    }
  }
  if (suspiciousControls > 0) {
    throw _documentFailure(
      LocalDocumentExtractionError.binaryContent,
      name,
      '$name appears to contain binary data.',
    );
  }
  return decoded;
}

void _validateDocxXmlComplexity(
  String source, {
  required int maxNodes,
  required int maxDepth,
}) {
  var nodes = 0;
  var depth = 0;
  for (final event in parseEvents(
    source,
    validateNesting: true,
    validateDocument: true,
  )) {
    if (event is XmlStartElementEvent) {
      nodes += 1 + event.attributes.length;
      if (!event.isSelfClosing) {
        depth++;
        if (depth > maxDepth) {
          throw const FormatException('DOCX XML depth limit exceeded');
        }
      }
    } else if (event is XmlEndElementEvent) {
      depth--;
    } else {
      nodes++;
    }
    if (nodes > maxNodes) {
      throw const FormatException('DOCX XML node limit exceeded');
    }
  }
  if (depth != 0) {
    throw const FormatException('DOCX XML nesting is incomplete');
  }
}

void _appendDocxText(
  XmlNode root,
  StringBuffer buffer, {
  required int maxNodes,
}) {
  final pending = <({XmlNode node, bool exiting})>[
    (node: root, exiting: false),
  ];
  var visitedNodes = 0;

  void countVisit() {
    visitedNodes++;
    if (visitedNodes > maxNodes) {
      throw const FormatException('DOCX XML node limit exceeded');
    }
  }

  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    final node = current.node;
    if (current.exiting) {
      final localName = (node as XmlElement).name.local.toLowerCase();
      if (localName == 'p' || localName == 'tr') {
        buffer.write('\n');
      } else if (localName == 'tc') {
        buffer.write('\t');
      }
      continue;
    }

    countVisit();
    if (node is! XmlElement) {
      for (var index = node.children.length - 1; index >= 0; index--) {
        pending.add((node: node.children[index], exiting: false));
      }
      continue;
    }

    final localName = node.name.local.toLowerCase();
    if (localName == 'del' || localName == 'movefrom') continue;
    if (localName == 't') {
      // XmlElement.innerText uses an iterative descendant walk. Repeat it here
      // so descendants count toward the same explicit work budget.
      for (final descendant in node.descendants) {
        countVisit();
        if (descendant is XmlText) {
          buffer.write(descendant.value);
        } else if (descendant is XmlCDATA) {
          buffer.write(descendant.value);
        }
      }
      continue;
    }
    if (localName == 'tab') {
      buffer.write('\t');
      continue;
    }
    if (localName == 'br' || localName == 'cr') {
      buffer.write('\n');
      continue;
    }

    pending.add((node: node, exiting: true));
    for (var index = node.children.length - 1; index >= 0; index--) {
      pending.add((node: node.children[index], exiting: false));
    }
  }
}

String _normalizeExtractedText(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll(RegExp(r'[ \t]+\n'), '\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

bool _isSupportedTextSource(String extension, String name, String? mimeType) {
  if (_textExtensions.contains(extension)) return true;
  if (mimeType != null &&
      (mimeType.startsWith('text/') || _textMimeTypes.contains(mimeType))) {
    return true;
  }
  final lowerName = name.toLowerCase();
  return lowerName == 'dockerfile' ||
      lowerName == 'makefile' ||
      lowerName == 'license' ||
      lowerName == 'readme';
}

String _textMimeType(String extension, String? declaredMimeType) {
  if (declaredMimeType != null &&
      (declaredMimeType.startsWith('text/') ||
          _textMimeTypes.contains(declaredMimeType))) {
    return declaredMimeType;
  }
  return _extensionMimeTypes[extension] ?? 'text/plain';
}

String? _normalizeMimeType(String? mimeType) {
  if (mimeType == null) return null;
  final normalized = mimeType.split(';').first.trim().toLowerCase();
  return normalized.isEmpty ? null : normalized;
}

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return '';
  if (dot == 0) return name.toLowerCase();
  return name.substring(dot).toLowerCase();
}

bool _startsWith(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return false;
  }
  return true;
}

bool _hasZipSignature(Uint8List bytes) =>
    _startsWith(bytes, const [0x50, 0x4b, 0x03, 0x04]) ||
    _startsWith(bytes, const [0x50, 0x4b, 0x05, 0x06]) ||
    _startsWith(bytes, const [0x50, 0x4b, 0x07, 0x08]);

final class _DocxZipPreflight {
  const _DocxZipPreflight({required this.entryCount});

  final int entryCount;
}

_DocxZipPreflight _validateDocxZipCentralDirectory(
  Uint8List bytes, {
  required int maxEntries,
  required int maxCentralDirectoryBytes,
}) {
  const endOfCentralDirectorySignature = 0x06054b50;
  const zip64EndOfCentralDirectorySignature = 0x06064b50;
  const zip64LocatorSignature = 0x07064b50;
  const centralDirectoryHeaderSignature = 0x02014b50;
  const localFileHeaderSignature = 0x04034b50;
  const endOfCentralDirectoryBytes = 22;
  const zip64LocatorBytes = 20;
  const zip64EndOfCentralDirectoryMinimumBytes = 56;
  const centralDirectoryHeaderBytes = 46;

  if (bytes.length < endOfCentralDirectoryBytes) {
    throw const FormatException('Missing ZIP end record');
  }

  // The EOCD signature may occur inside the archive comment. Accept only a
  // candidate whose declared comment consumes the exact remaining bytes.
  final searchFloor = bytes.length > endOfCentralDirectoryBytes + 0xffff
      ? bytes.length - endOfCentralDirectoryBytes - 0xffff
      : 0;
  var eocdOffset = -1;
  for (
    var offset = bytes.length - endOfCentralDirectoryBytes;
    offset >= searchFloor;
    offset--
  ) {
    if (_zipUint32At(bytes, offset) != endOfCentralDirectorySignature) {
      continue;
    }
    final commentLength = _zipUint16At(bytes, offset + 20);
    if (offset + endOfCentralDirectoryBytes + commentLength == bytes.length) {
      eocdOffset = offset;
      break;
    }
  }
  if (eocdOffset < 0) {
    throw const FormatException('Missing ZIP end record');
  }
  // archive 4.0.9 searches backward in non-overlapping 1024-byte chunks. It can
  // both select an incomplete signature in the selected EOCD's comment and
  // miss a real EOCD that straddles a chunk boundary, falling back to an older
  // attacker-controlled signature. Require the selected exact record to be the
  // archive's only raw EOCD signature before invoking ZipDirectory.
  for (var offset = 0; offset <= bytes.length - 4; offset++) {
    if (offset != eocdOffset &&
        _zipUint32At(bytes, offset) == endOfCentralDirectorySignature) {
      throw const FormatException('Ambiguous ZIP end record');
    }
  }

  final diskNumber = _zipUint16At(bytes, eocdOffset + 4);
  final centralDirectoryDisk = _zipUint16At(bytes, eocdOffset + 6);
  if (diskNumber != 0 || centralDirectoryDisk != 0) {
    throw const FormatException('Multi-disk DOCX archives are not allowed');
  }
  final classicEntriesOnDisk = _zipUint16At(bytes, eocdOffset + 8);
  final classicEntryCount = _zipUint16At(bytes, eocdOffset + 10);
  final classicCentralDirectorySize = _zipUint32At(bytes, eocdOffset + 12);
  final classicCentralDirectoryOffset = _zipUint32At(bytes, eocdOffset + 16);
  final needsZip64 =
      classicEntriesOnDisk == 0xffff ||
      classicEntryCount == 0xffff ||
      classicCentralDirectorySize == 0xffffffff ||
      classicCentralDirectoryOffset == 0xffffffff;
  final zip64LocatorOffset = eocdOffset - zip64LocatorBytes;
  final hasZip64Locator =
      zip64LocatorOffset >= 0 &&
      _zipUint32At(bytes, zip64LocatorOffset) == zip64LocatorSignature;
  // ZipDirectory honors an adjacent ZIP64 locator even when every classic
  // field is non-sentinel. Treat that mixed representation as ambiguous rather
  // than validating the classic directory while the dependency parses ZIP64.
  if (hasZip64Locator && !needsZip64) {
    throw const FormatException('Unexpected ZIP64 locator');
  }

  var entryCount = classicEntryCount;
  var centralDirectorySize = classicCentralDirectorySize;
  var centralDirectoryOffset = classicCentralDirectoryOffset;
  var expectedCentralDirectoryEnd = eocdOffset;
  if (needsZip64) {
    final locatorOffset = zip64LocatorOffset;
    if (!hasZip64Locator) {
      throw const FormatException('Missing ZIP64 locator');
    }
    if (_zipUint32At(bytes, locatorOffset + 4) != 0 ||
        _zipUint32At(bytes, locatorOffset + 16) != 1) {
      throw const FormatException('Multi-disk ZIP64 archives are not allowed');
    }
    final zip64Offset = _zipUint64BoundedAt(
      bytes,
      locatorOffset + 8,
      maxValue: locatorOffset,
    );
    if (zip64Offset > locatorOffset - zip64EndOfCentralDirectoryMinimumBytes ||
        _zipUint32At(bytes, zip64Offset) !=
            zip64EndOfCentralDirectorySignature) {
      throw const FormatException('Invalid ZIP64 end record');
    }
    final maximumRecordBody = locatorOffset - zip64Offset - 12;
    final recordBodySize = _zipUint64BoundedAt(
      bytes,
      zip64Offset + 4,
      maxValue: maximumRecordBody,
    );
    if (recordBodySize < 44 ||
        zip64Offset + 12 + recordBodySize != locatorOffset) {
      throw const FormatException('Inconsistent ZIP64 end record');
    }
    if (_zipUint32At(bytes, zip64Offset + 16) != 0 ||
        _zipUint32At(bytes, zip64Offset + 20) != 0) {
      throw const FormatException('Multi-disk ZIP64 archives are not allowed');
    }
    final zip64EntriesOnDisk = _zipUint64BoundedAt(
      bytes,
      zip64Offset + 24,
      maxValue: maxEntries,
    );
    entryCount = _zipUint64BoundedAt(
      bytes,
      zip64Offset + 32,
      maxValue: maxEntries,
    );
    if (zip64EntriesOnDisk != entryCount) {
      throw const FormatException('Inconsistent ZIP64 entry count');
    }
    centralDirectorySize = _zipUint64BoundedAt(
      bytes,
      zip64Offset + 40,
      maxValue: maxCentralDirectoryBytes,
    );
    centralDirectoryOffset = _zipUint64BoundedAt(
      bytes,
      zip64Offset + 48,
      maxValue: bytes.length,
    );
    if ((classicEntriesOnDisk != 0xffff &&
            classicEntriesOnDisk != zip64EntriesOnDisk) ||
        (classicEntryCount != 0xffff && classicEntryCount != entryCount) ||
        (classicCentralDirectorySize != 0xffffffff &&
            classicCentralDirectorySize != centralDirectorySize) ||
        (classicCentralDirectoryOffset != 0xffffffff &&
            classicCentralDirectoryOffset != centralDirectoryOffset)) {
      throw const FormatException('Inconsistent ZIP64 fallback fields');
    }
    expectedCentralDirectoryEnd = zip64Offset;
  } else {
    if (classicEntriesOnDisk != entryCount) {
      throw const FormatException('Inconsistent ZIP entry count');
    }
    if (entryCount > maxEntries) {
      throw const FormatException('DOCX ZIP entry limit exceeded');
    }
    if (centralDirectorySize > maxCentralDirectoryBytes) {
      throw const FormatException('DOCX central directory limit exceeded');
    }
  }

  if (centralDirectoryOffset > expectedCentralDirectoryEnd ||
      centralDirectorySize >
          expectedCentralDirectoryEnd - centralDirectoryOffset ||
      centralDirectoryOffset + centralDirectorySize !=
          expectedCentralDirectoryEnd) {
    throw const FormatException('Inconsistent ZIP central directory range');
  }

  var cursor = centralDirectoryOffset;
  var walkedEntries = 0;
  while (cursor < expectedCentralDirectoryEnd) {
    if (walkedEntries >= maxEntries) {
      throw const FormatException('DOCX ZIP entry limit exceeded');
    }
    if (expectedCentralDirectoryEnd - cursor < centralDirectoryHeaderBytes ||
        _zipUint32At(bytes, cursor) != centralDirectoryHeaderSignature) {
      throw const FormatException('Invalid ZIP central directory record');
    }
    final nameLength = _zipUint16At(bytes, cursor + 28);
    final extraLength = _zipUint16At(bytes, cursor + 30);
    final commentLength = _zipUint16At(bytes, cursor + 32);
    if (_zipUint16At(bytes, cursor + 34) != 0) {
      throw const FormatException('Multi-disk DOCX entries are not allowed');
    }
    final localHeaderOffset = _zipUint32At(bytes, cursor + 42);
    if (localHeaderOffset != 0xffffffff &&
        (localHeaderOffset > centralDirectoryOffset - 30 ||
            _zipUint32At(bytes, localHeaderOffset) !=
                localFileHeaderSignature)) {
      throw const FormatException('Invalid ZIP local-header offset');
    }
    final variableLength = nameLength + extraLength + commentLength;
    if (variableLength >
        expectedCentralDirectoryEnd - cursor - centralDirectoryHeaderBytes) {
      throw const FormatException('Truncated ZIP central directory record');
    }
    cursor += centralDirectoryHeaderBytes + variableLength;
    walkedEntries++;
  }
  if (cursor != expectedCentralDirectoryEnd || walkedEntries != entryCount) {
    throw const FormatException('Mismatched ZIP entry count');
  }
  return _DocxZipPreflight(entryCount: walkedEntries);
}

int _zipUint16At(Uint8List bytes, int offset) {
  if (offset < 0 || offset > bytes.length - 2) {
    throw const FormatException('Truncated ZIP metadata');
  }
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _zipUint32At(Uint8List bytes, int offset) {
  if (offset < 0 || offset > bytes.length - 4) {
    throw const FormatException('Truncated ZIP metadata');
  }
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

int _zipUint64BoundedAt(Uint8List bytes, int offset, {required int maxValue}) {
  if (maxValue < 0 || offset < 0 || offset > bytes.length - 8) {
    throw const FormatException('Truncated ZIP64 metadata');
  }
  final low = _zipUint32At(bytes, offset);
  final high = _zipUint32At(bytes, offset + 4);
  if (high != 0 || low > maxValue) {
    throw const FormatException('ZIP64 metadata exceeds document limits');
  }
  return low;
}

bool _hasOleCompoundFileSignature(Uint8List bytes) =>
    _startsWith(bytes, const [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]);

bool _zipEntryIsEncrypted(ZipFileHeader header) =>
    (header.generalPurposeBitFlag & 0x1) != 0 ||
    ((header.file?.flags ?? 0) & 0x1) != 0;

bool _zipEntryIsUnixSymlink(ZipFileHeader header) {
  final madeByUnix = header.versionMadeBy >> 8 == 3;
  final unixFileType = (header.externalFileAttributes >> 16) & 0xf000;
  return madeByUnix && unixFileType == 0xa000;
}

String _stableDocumentId(
  String name,
  Uint8List bytes, {
  required String prefix,
}) {
  final contentDigest = sha256.convert(bytes).bytes;
  final identityBytes = <int>[...contentDigest, 0, ...utf8.encode(name)];
  final identity = sha256.convert(identityBytes).toString();
  return '$prefix${identity.substring(0, 24)}';
}

String _takeRunes(String value, int count) =>
    String.fromCharCodes(value.runes.take(count));

/// Produces a display-only filename with no path components or control text.
String sanitizeLocalDocumentFilename(String input) {
  var name = _portableBasename(input).trim();
  name = name.replaceAll(
    RegExp(r'[\u0000-\u001F\u007F\u202A-\u202E\u2066-\u2069<>:"/\\|?*]'),
    '_',
  );
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  while (name.startsWith('..')) {
    name = name.substring(1);
  }
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.') name = 'document';
  if (name.runes.length > 120) name = _takeRunes(name, 120);
  return name;
}

String _portableBasename(String value) {
  final normalized = value.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

LocalDocumentExtractionException _documentFailure(
  LocalDocumentExtractionError code,
  String name,
  String message,
) => LocalDocumentExtractionException(
  code: code,
  documentName: name,
  message: message,
);

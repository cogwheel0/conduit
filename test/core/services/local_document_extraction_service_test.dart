import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/local_document_extraction_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalDocumentExtractionService', () {
    test('exposes backend-neutral picker and filename helpers', () {
      check(kLocalDocumentPickerExtensions).contains('txt');
      check(kLocalDocumentPickerExtensions).contains('docx');
      check(isLocalDocumentFileNameSupported('README')).isTrue();
      check(isLocalDocumentFileNameSupported('archive.pdf')).isFalse();
      check(
        sanitizeLocalDocumentFilename('../private/bad\nnotes.txt'),
      ).equals('bad_notes.txt');
    });

    test('extracts text with neutral stable identifiers', () async {
      final service = LocalDocumentExtractionService();
      final source = LocalDocumentSource.fromBytes(
        name: 'notes.txt',
        bytes: utf8.encode('Local content'),
      );

      final first = await service.prepare(source);
      final second = await service.prepare(source);

      check(first.id).equals(second.id);
      check(first.id).startsWith('ldoc_');
      check(first.name).equals('notes.txt');
      check(first.mimeType).equals('text/plain');
      check(first.extractedText).equals('Local content');
      check(first.truncated).isFalse();
    });

    test('supports consumer-specific stable identifier namespaces', () async {
      final document =
          await LocalDocumentExtractionService(
            documentIdPrefix: 'consumer_',
          ).prepare(
            LocalDocumentSource.fromBytes(
              name: 'notes.txt',
              bytes: utf8.encode('Local content'),
            ),
          );

      check(document.id).startsWith('consumer_');
    });

    test('returns backend-neutral typed failures', () async {
      final service = LocalDocumentExtractionService(
        limits: const LocalDocumentExtractionLimits(maxSourceBytes: 2),
      );

      try {
        await service.prepare(
          LocalDocumentSource.fromBytes(
            name: 'notes.txt',
            bytes: utf8.encode('too large'),
          ),
        );
        fail('Expected LocalDocumentExtractionException');
      } on LocalDocumentExtractionException catch (error) {
        check(error.code).equals(LocalDocumentExtractionError.sourceTooLarge);
        check(error.documentName).equals('notes.txt');
      }
    });
  });
}

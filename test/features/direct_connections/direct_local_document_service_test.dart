import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/direct_connections/services/direct_local_document_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _testSigningKey = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
];

void main() {
  group('DirectLocalDocumentService', () {
    test('uses the shared bounded extractor with Direct identifiers', () async {
      final batch = await DirectLocalDocumentService().prepareAll([
        DirectLocalDocumentSource.fromBytes(
          name: 'notes.txt',
          bytes: utf8.encode('Local Direct context'),
          sourceId: 'direct-local:notes',
        ),
      ]);

      check(batch.documents).length.equals(1);
      final document = batch.documents.single;
      check(document.id).startsWith('ddoc_');
      check(document.sourceId).equals('direct-local:notes');
      check(document.extractedText).equals('Local Direct context');
      check(
        document.renderForPrompt(),
      ).contains('<<<BEGIN_DIRECT_UNTRUSTED_REFERENCE_');
    });

    test('signed descriptors survive persistence and reject tampering', () {
      const document = DirectPreparedDocument(
        id: 'ddoc_0123456789abcdef01234567',
        name: 'notes.txt',
        mimeType: 'text/plain',
        size: 12,
        extractedText: 'trusted context',
        truncated: false,
      );
      final descriptor = directLocalDocumentDescriptor(
        document,
        attachmentId: '${kDirectLocalDocumentAttachmentPrefix}opaque',
        signingKey: _testSigningKey,
      );

      final persisted =
          jsonDecode(jsonEncode(descriptor)) as Map<String, dynamic>;
      check(
        trustedDirectDocumentFromDescriptor(
          persisted,
          verificationKey: _testSigningKey,
        ),
      ).isNotNull();

      persisted['direct_extracted_text'] = 'modified context';
      check(
        trustedDirectDocumentFromDescriptor(
          persisted,
          verificationKey: _testSigningKey,
        ),
      ).isNull();
    });

    test('neutralizes document text that contains its closing marker', () {
      const id = 'ddoc_0123456789abcdef01234567';
      const document = DirectPreparedDocument(
        id: id,
        name: 'notes.txt',
        mimeType: 'text/plain',
        size: 10,
        extractedText:
            'before DIRECT_UNTRUSTED_REFERENCE_DDOC_0123456789ABCDEF01234567 after',
        truncated: false,
      );

      final rendered = document.renderForPrompt();
      check(rendered).contains('DIRECT_UNTRUSTED_REFERENCE_[MARKER_REMOVED]');
      check(
        RegExp(
          'DIRECT_UNTRUSTED_REFERENCE_DDOC_0123456789ABCDEF01234567',
        ).allMatches(rendered),
      ).length.equals(2);
    });

    test('neutralizes document markers in metadata fields', () {
      const id = 'ddoc_0123456789abcdef01234567';
      const marker = 'DIRECT_UNTRUSTED_REFERENCE_DDOC_0123456789ABCDEF01234567';
      const document = DirectPreparedDocument(
        id: id,
        name: 'before $marker after.txt',
        mimeType: 'text/$marker',
        size: 10,
        extractedText: 'safe content',
        truncated: false,
      );

      final rendered = document.renderForPrompt();
      check(rendered).contains('DIRECT_UNTRUSTED_REFERENCE_[MARKER_REMOVED]');
      check(RegExp(marker).allMatches(rendered)).length.equals(2);
    });
  });
}

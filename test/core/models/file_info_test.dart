import 'package:checks/checks.dart';
import 'package:conduit/core/models/file_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileInfo.fromJson', () {
    test('parses OpenWebUI file payloads with nested meta fields', () {
      final file = FileInfo.fromJson({
        'id': 'file-1',
        'user_id': 'user-1',
        'filename': 'quarterly-report.pdf',
        'hash': 'abc123',
        'meta': {
          'name': 'Quarterly Report.pdf',
          'content_type': 'application/pdf',
          'size': 4096,
        },
        'created_at': 1713786305,
        'updated_at': 1713789905,
      });

      check(file.id).equals('file-1');
      check(file.userId).equals('user-1');
      check(file.filename).equals('quarterly-report.pdf');
      check(file.originalFilename).equals('Quarterly Report.pdf');
      check(file.displayName).equals('Quarterly Report.pdf');
      check(file.mimeType).equals('application/pdf');
      check(file.size).equals(4096);
      check(file.hash).equals('abc123');
      check(file.metadata).isNotNull();
      check(file.createdAt.year).equals(2024);
      check(file.updatedAt.isAfter(file.createdAt)).isTrue();
    });

    test('supports camelCase fallbacks and millisecond timestamps', () {
      final file = FileInfo.fromJson({
        'id': 'img-1',
        'filename': 'image.png',
        'originalFilename': 'image.png',
        'mimeType': 'image/png',
        'size': 512,
        'createdAt': 1713786305000,
        'updatedAt': 1713786305000,
      });

      check(file.displayName).equals('image.png');
      check(file.isImage).isTrue();
      check(file.extension).equals('.png');
      check(file.createdAt.year).equals(2024);
    });

    test('preserves microsecond timestamps from OpenWebUI payloads', () {
      final file = FileInfo.fromJson({
        'id': 'file-2',
        'filename': 'draft.md',
        'original_filename': 'draft.md',
        'content_type': 'text/markdown',
        'size': 128,
        'created_at': 1713786305123456,
        'updated_at': 1713786305987654,
      });

      check(
        file.createdAt,
      ).equals(DateTime.fromMicrosecondsSinceEpoch(1713786305123456));
      check(
        file.updatedAt,
      ).equals(DateTime.fromMicrosecondsSinceEpoch(1713786305987654));
    });
  });
}

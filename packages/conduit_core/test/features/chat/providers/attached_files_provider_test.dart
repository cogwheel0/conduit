import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/attached_files_provider.dart';
import 'package:test/test.dart';

FileUploadState _upload(FileUploadStatus status, {String? fileId}) =>
    FileUploadState(
      file: File('/synthetic/tray/sketch.png'),
      fileName: 'sketch.png',
      fileSize: 10,
      progress: status == FileUploadStatus.completed ? 1 : 0,
      status: status,
      fileId: fileId,
      isImage: true,
    );

void main() {
  group('draftHasSendableContent', () {
    test('words alone are enough', () {
      check(draftHasSendableContent(' Hello ', const [])).isTrue();
      check(draftHasSendableContent('   ', const [])).isFalse();
    });

    test('a finished upload is enough without words', () {
      check(
        draftHasSendableContent('', [
          _upload(FileUploadStatus.completed, fileId: 'file-1'),
        ]),
      ).isTrue();
    });

    test('an upload that has not finished is not', () {
      for (final status in [
        FileUploadStatus.pending,
        FileUploadStatus.uploading,
        FileUploadStatus.failed,
      ]) {
        check(
          draftHasSendableContent(' ', [_upload(status, fileId: 'file-1')]),
        ).isFalse();
      }
      check(
        draftHasSendableContent('', [_upload(FileUploadStatus.completed)]),
      ).isFalse();
    });
  });
}

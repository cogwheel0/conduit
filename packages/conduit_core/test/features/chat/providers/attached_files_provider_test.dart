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

  group('image upload encoding', () {
    const large = 2 * 1024 * 1024;

    test('a PNG, GIF or WebP goes as picked, however large', () {
      for (final name in ['screenshot.png', 'loop.GIF', 'sticker.webp']) {
        check(convertsImageForUpload(name, large)).isFalse();
      }
    });

    // The composer drops a picked image over 20 MB, and a PNG is no longer
    // re-encoded by the picker to fit under it.
    test('a PNG over the size an attached image may be is converted', () {
      check(convertsImageForUpload('screenshot.png', kAttachedImageMaxBytes))
          .isFalse();
      check(
        convertsImageForUpload('screenshot.png', kAttachedImageMaxBytes + 1),
      ).isTrue();
    });

    test('a large JPEG is compressed, a small one is not', () {
      check(convertsImageForUpload('photo.jpg', large)).isTrue();
      check(convertsImageForUpload('photo.JPEG', large)).isTrue();
      check(convertsImageForUpload('photo.jpg', 100 * 1024)).isFalse();
    });

    test('a format models cannot read is always converted', () {
      check(convertsImageForUpload('photo.heic', 10)).isTrue();
      check(convertsImageForUpload('scan.bmp', 10)).isTrue();
    });

    test('a compressed JPEG is kept only when it is smaller', () {
      check(
        keepsConvertedImage(
          'photo.jpg',
          originalBytes: 900,
          convertedBytes: 600,
        ),
      ).isTrue();
      check(
        keepsConvertedImage(
          'photo.jpg',
          originalBytes: 600,
          convertedBytes: 900,
        ),
      ).isFalse();
      check(
        keepsConvertedImage(
          'photo.jpg',
          originalBytes: 600,
          convertedBytes: 600,
        ),
      ).isFalse();
    });

    test('a converted HEIC is kept even when it is larger', () {
      check(
        keepsConvertedImage(
          'photo.heic',
          originalBytes: 600,
          convertedBytes: 900,
        ),
      ).isTrue();
    });
  });
}

import 'dart:async';
import 'dart:io';

import 'package:conduit/features/hermes/providers/hermes_media.dart';
import 'package:conduit_core/features/hermes/models/hermes_media.dart';
import 'package:conduit_core/features/hermes/services/hermes_media_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Files implements HermesMediaService {
  int requests = 0;
  @override
  Future<void> downloadMedia(
    HermesMediaReference media,
    String destination, {
    String? sessionId,
    String? profile,
    CancelToken? cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    requests++;
    await File(destination).writeAsBytes([1, 2, 3, 4]);
  }
}

const media = HermesMediaReference(
  path: '/workspace/test.wav',
  name: 'test.wav',
);
void main() {
  test('one open attachment reuses its original, then removes only private cached bytes', () async {
    final root = await Directory.systemTemp.createTemp('lease-cache-');
    final service = _Files();
    final lease = HermesMediaLease(service, Future.value(root));
    final file = await lease.load(media);
    expect(await lease.load(media), same(file));
    expect(service.requests, 1);
    await lease.close();
    expect(lease.cancel.isCancelled, isTrue);
    expect(await root.exists(), isFalse);
    await expectLater(lease.load(media), throwsStateError);
  });
  test('closing during native export cancels admission but keeps bytes until export completes', () async {
    final root = await Directory.systemTemp.createTemp('lease-export-');
    final lease = HermesMediaLease(_Files(), Future.value(root));
    final file = await lease.load(media);
    lease.retainForExport();
    var closed = false;
    final closing = lease.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(lease.cancel.isCancelled, isTrue);
    expect(closed, isFalse);
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    lease.releaseExport();
    await closing;
    expect(await root.exists(), isFalse);
  });
}

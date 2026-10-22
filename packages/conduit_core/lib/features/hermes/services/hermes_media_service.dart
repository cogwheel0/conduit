import 'package:dio/dio.dart';

import '../models/hermes_media.dart';

const kMaxHermesMediaDownloadBytes = 256 * 1024 * 1024;

/// Authenticated binary transport. A caller owns its private temporary target
/// and must not publish it until this method completes successfully.
abstract interface class HermesMediaService {
  Future<void> downloadMedia(
    HermesMediaReference media,
    String destination, {
    String? sessionId,
    String? profile,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  });
}

import 'package:dio/dio.dart';

import '../models/hermes_file_entry.dart';

/// The server's managed-files surface; never reads the phone's filesystem.
abstract interface class HermesFileBrowserService {
  Future<HermesDirectory> browseFiles({String? path, CancelToken? cancelToken});
  Future<void> createFile({
    required String directory,
    required String name,
    required String content,
  });
  Future<void> createDirectory({
    required String directory,
    required String name,
  });
  Future<String> readFileDataUrl(String path, {CancelToken? cancelToken});
}

part of 'hermes_desktop_api_service.dart';

extension _HermesDesktopFiles on HermesDesktopApiService {
  Future<HermesDirectory> _filesList(String? path, CancelToken? cancel) async {
    if (path != null && hermesFilePath(path) == null) {
      throw ArgumentError('Invalid directory path');
    }
    return HermesDirectory.fromJson(
      _object(
        await _requestJson(
          'GET',
          '/api/files',
          query: {'path': ?path},
          cancelToken: cancel,
        ),
      ),
    );
  }

  Future<HermesDirectory> _filesBrowse({
    String? path,
    CancelToken? cancelToken,
  }) async {
    if (path != null) return _filesList(path, cancelToken);
    final initial = await _filesList(null, cancelToken);
    // Hosted gateways advertise their own boundary. On a desktop, discover
    // Hermes home from server metadata or the home listing, never phone paths.
    if (!initial.canChangePath) return initial;
    var home = hermesFilePath(_status?['hermes_home']);
    if (home == null) {
      // Authenticated status probes omit deployment paths. Profile metadata
      // still identifies Hermes home, including nonstandard HERMES_HOME roots.
      try {
        final profiles = _objects(
          _object(
            await _requestJson(
              'GET',
              '/api/profiles',
              cancelToken: cancelToken,
            ),
          )['profiles'],
        );
        final defaults = profiles.where(
          (profile) =>
              profile['is_default'] == true || profile['name'] == 'default',
        );
        if (defaults.isNotEmpty) home = hermesFilePath(defaults.first['path']);
      } on DioException catch (error) {
        if (error.response?.statusCode != 404 &&
            error.response?.statusCode != 405) {
          rethrow;
        }
      }
    }
    final homes = initial.entries.where(
      (entry) => entry.isDirectory && entry.name == '.hermes',
    );
    final start = home ?? (homes.isEmpty ? null : homes.first.path);
    return start == null || start == initial.path
        ? initial
        : _filesList(start, cancelToken);
  }

  String _filesChildPath(String directory, String name) {
    if (hermesFilePath(directory) == null || !hermesFileNameIsValid(name)) {
      throw ArgumentError('Invalid file name or directory');
    }
    final separator = directory.contains('\\') && !directory.contains('/')
        ? '\\'
        : '/';
    return '${directory.endsWith(separator) ? directory : '$directory$separator'}$name';
  }

  Future<void> _filesCreate({
    required String directory,
    required String name,
    required String content,
  }) async {
    final path = _filesChildPath(directory, name);
    final bytes = utf8.encode(content);
    if (bytes.length > 1024 * 1024) {
      throw ArgumentError('File content too large');
    }
    await _requestJson(
      'POST',
      '/api/files/upload',
      body: {
        'path': path,
        'data_url':
            'data:text/plain;charset=utf-8;base64,${base64Encode(bytes)}',
        'overwrite': false,
      },
    );
  }

  Future<void> _filesCreateDirectory({
    required String directory,
    required String name,
  }) async {
    await _requestJson(
      'POST',
      '/api/files/mkdir',
      body: {'path': _filesChildPath(directory, name)},
    );
  }

  Future<String> _filesRead(String path, {CancelToken? cancelToken}) async {
    if (hermesFilePath(path) == null) throw ArgumentError('Invalid file path');
    final data = _object(
      await _requestJson(
        'GET',
        '/api/files/read',
        query: {'path': path},
        cancelToken: cancelToken,
        maximumResponseBytes: 2 * 1024 * 1024,
      ),
    )['data_url'];
    if (data is! String || !data.startsWith('data:')) {
      throw const FormatException('Invalid file response');
    }
    return data;
  }
}

import 'dart:io';

final String? runtimeDefaultUserAgent = _readRuntimeDefaultUserAgent();

String? _readRuntimeDefaultUserAgent() {
  final client = HttpClient();
  try {
    return client.userAgent;
  } finally {
    client.close(force: true);
  }
}

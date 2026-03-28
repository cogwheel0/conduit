import 'dart:async';
import 'qonduit_router_api_client.dart';

class QonduitRouterLogStreamService {
  final QonduitRouterApiClient apiClient;

  QonduitRouterLogStreamService(this.apiClient);

  Stream<List<String>> streamLogLines() async* {
    final buffer = StringBuffer();
    final lines = <String>[];

    await for (final chunk in apiClient.streamRouterLogs()) {
      buffer.write(chunk);
      final parts = buffer.toString().split('\n');

      buffer.clear();
      if (parts.isNotEmpty) {
        buffer.write(parts.removeLast());
      }

      for (final line in parts) {
        final trimmed = line.trimRight();
        if (trimmed.isEmpty) continue;
        lines.add(trimmed);
      }

      if (lines.length > 300) {
        lines.removeRange(0, lines.length - 300);
      }

      yield List<String>.from(lines.reversed);
    }
  }
}
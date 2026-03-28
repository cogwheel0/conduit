import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/qonduit_memory_gateway_api_client.dart';

final qonduitMemoryGatewayApiClientProvider =
Provider<QonduitMemoryGatewayApiClient>((ref) {
  return QonduitMemoryGatewayApiClient();
});
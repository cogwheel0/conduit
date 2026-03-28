import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/qonduit_router_api_client.dart';
import '../models/qonduit_router_status.dart';

final qonduitRouterApiClientProvider = Provider<QonduitRouterApiClient>((ref) {
  return QonduitRouterApiClient();
});

final qonduitRouterModelsProvider = FutureProvider<List<String>>((ref) async {
  return ref.read(qonduitRouterApiClientProvider).fetchModels();
});

final qonduitRouterSuggestedContextProvider = FutureProvider<int>((ref) async {
  return ref.read(qonduitRouterApiClientProvider).fetchSuggestedContext();
});

final qonduitRouterStatusProvider = FutureProvider<QonduitRouterStatus>((ref) async {
  return ref.read(qonduitRouterApiClientProvider).fetchStatus();
});
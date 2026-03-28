import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';

final ragCollectionsProvider = FutureProvider<List<String>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return <String>[];
  return api.getRagCollections();
});

class SelectedRagCollectionNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setCollection(String? value) {
    state = value;
  }
}

final selectedRagCollectionProvider =
NotifierProvider<SelectedRagCollectionNotifier, String?>(
  SelectedRagCollectionNotifier.new,
);
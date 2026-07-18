import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/persistence/persistence_keys.dart';
import '../../core/persistence/preferences_store.dart';
import 'models/release_note.dart';

class ReleaseNotesBannerData {
  const ReleaseNotesBannerData({
    required this.currentVersion,
    required this.previousVersion,
    required this.notes,
  });

  final String currentVersion;
  final String previousVersion;
  final List<ReleaseNote> notes;
}

final releaseNotesBannerProvider =
    NotifierProvider<ReleaseNotesBannerController, ReleaseNotesBannerData?>(
      ReleaseNotesBannerController.new,
    );

class ReleaseNotesBannerController extends Notifier<ReleaseNotesBannerData?> {
  @override
  ReleaseNotesBannerData? build() => null;

  void show(ReleaseNotesBannerData data) {
    state = data;
  }

  void clear() {
    state = null;
  }

  Future<void> dismiss() async {
    state = null;
    await PreferencesStore.remove(
      PreferenceKeys.releaseNotesBannerPreviousVersion,
    );
  }
}

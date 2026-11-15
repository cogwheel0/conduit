import 'package:conduit_core/features/release_notes/data/release_notes_catalog.dart';
import 'package:conduit_core/features/release_notes/models/release_note.dart';
import 'package:conduit_core/features/release_notes/release_notes_banner_controller.dart';
import 'package:conduit_core/features/release_notes/release_notes_coordination.dart';
import 'package:conduit_core/features/release_notes/services/release_notes_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

/// `releaseNotes.*`: core's release-notes decision and its stored state
/// (the last version seen, the banner's) over the catalog the app ships.
///
/// The notes describe the app that shows them, so the window sends its own
/// catalog with each call; core reads it as it reads the phone's bundled
/// assets, locale fallback included.
final class ReleaseNotesRpcService {
  ReleaseNotesRpcService(this._container);

  final ProviderContainer _container;

  /// [version] without a pre-release or build suffix: core compares
  /// `major.minor.patch` only (`0.9.0-beta.2` is 0.9.0).
  static String coreVersion(String version) =>
      version.trim().split(RegExp('[-+]')).first;

  Future<List<ReleaseNote>> _notes(ReleaseNotesQuery query) async {
    final catalog = ReleaseNotesCatalog(
      loadAsset: (path) async {
        final name = path.split('/').last;
        final locale = name.endsWith('.json')
            ? name.substring(0, name.length - '.json'.length)
            : name;
        return query.catalogs[locale];
      },
    );
    try {
      return await catalog.load(
        languageCode: query.languageCode,
        scriptCode: query.scriptCode,
        countryCode: query.countryCode,
      );
    } on FormatException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'release notes catalog: ${error.message}',
      );
    }
  }

  /// At launch: decides with core whether the after-update banner shows,
  /// records the version as seen, and answers with the banner's notes.
  Future<ReleaseNotesState> check(ReleaseNotesQuery query) async {
    final version = coreVersion(query.currentVersion);
    final notes = await _notes(query);
    final banner = _container.read(releaseNotesBannerProvider.notifier);
    ReleaseNotesBannerData? shown;
    await applyReleaseNotesDecision(
      currentVersion: version,
      lastSeenVersion: readReleaseNotesLastSeenVersion(),
      notes: notes,
      isActive: () => true,
      showBanner: (data) {
        shown = data;
        banner.show(data);
      },
      clearBanner: () {
        shown = null;
        banner.clear();
      },
    );
    return ReleaseNotesState(
      currentVersion: version,
      banner: shown != null,
      notes: <ReleaseNoteDto>[...?shown?.notes.map(noteDto)],
    );
  }

  /// About › Release Notes: the newest note at or before this version.
  Future<ReleaseNotesState> latest(ReleaseNotesQuery query) async {
    final version = coreVersion(query.currentVersion);
    final notes = latestBundledReleaseNotesForVersion(
      currentVersion: version,
      notes: await _notes(query),
    );
    return ReleaseNotesState(
      currentVersion: version,
      notes: <ReleaseNoteDto>[...notes.map(noteDto)],
    );
  }

  /// The banner's close button: it stays gone until the next update.
  Future<OkResult> dismiss() async {
    await _container.read(releaseNotesBannerProvider.notifier).dismiss();
    return const OkResult(ok: true);
  }

  static ReleaseNoteDto noteDto(ReleaseNote note) => ReleaseNoteDto(
    version: note.version,
    title: note.title,
    intro: note.intro,
    bullets: <ReleaseNoteBullet>[
      for (var i = 0; i < note.bullets.length; i++)
        ReleaseNoteBullet(
          text: note.bullets[i],
          icon: note.iconNameForBullet(i),
        ),
    ],
  );
}

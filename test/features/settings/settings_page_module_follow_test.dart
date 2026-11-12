import 'package:checks/checks.dart';
import 'package:conduit/features/settings/settings_controller.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

final class _Count extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final _countProvider = NotifierProvider<_Count, int>(_Count.new);

/// Follows a provider derived from [_countProvider], as a module follows
/// the providers its pages show.
final _followedProvider = Provider<int>((ref) => ref.watch(_countProvider));

final class _Following extends SettingsPageModule {
  _Following(this._ref);

  final Ref _ref;
  final heard = <int>[];

  @override
  bool ownsPage(String detailId) => detailId == 'following';

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _ref.listen(_followedProvider, (_, next) => heard.add(next));
  }

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async => false;
}

/// The app root as far as Settings needs it: it attaches the controller.
final class _App extends ConsumerStatefulWidget {
  const _App();

  @override
  ConsumerState<_App> createState() => _AppState();
}

final class _AppState extends ConsumerState<_App> {
  @override
  void initState() {
    super.initState();
    ref.read(settingsControllerProvider).attach(ref);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('a module hears what it follows after the modules are read '
      'again, as every row change reads them', (tester) async {
    final container = ProviderContainer(
      overrides: [
        settingsPageModulesProvider.overrideWith((ref) => [_Following(ref)]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const _App()),
    );
    final module =
        container.read(settingsPageModulesProvider).single as _Following;
    await module.hydrate('following', _l10n);

    container.read(settingsPageModulesProvider);
    container.read(_countProvider.notifier).bump();
    await tester.pump();

    check(module.heard).deepEquals([1]);
  });
}

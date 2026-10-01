import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_cookie_registry.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:test/test.dart';

/// `WebViewCookieHelper.cookieIdentityParts` in the app.
String identity(String name, {String domain = '', String path = '/'}) =>
    '$name\u0000$domain\u0000$path';

void main() {
  setUp(() {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    HermesDashboardCookieRegistry.debugReset();
  });
  tearDown(() {
    HermesDashboardCookieRegistry.debugReset();
    PreferencesStore.debugReset();
  });

  test('the delta keeps new cookies and refreshed session cookies', () {
    final hermes = identity('__Host-hermes_session_at');
    final openWebUi = identity('token');
    final fresh = identity('dashboard_pref');

    check(
      hermesDashboardCookieIdentityDelta(
        current: {hermes, openWebUi, fresh},
        baseline: {hermes, openWebUi},
        retainedNames: kHermesDashboardRetainedCookieNames,
      ),
    ).deepEquals({hermes, fresh});
    check(
      hermesDashboardCookieIdentityDelta(
        current: {hermes, openWebUi},
        baseline: {hermes, openWebUi},
      ),
    ).isEmpty();
  });

  test('origin keys fill in the default port and ignore case', () {
    check(hermesDashboardCookieOriginKey('HTTPS://Hermes.Example/agent'))
        .equals('https://hermes.example:443');
    check(hermesDashboardCookieOriginKey('http://hermes.example'))
        .equals('http://hermes.example:80');
    check(hermesDashboardCookieOriginKey('http://127.0.0.1:18171/v1'))
        .equals('http://127.0.0.1:18171');
    check(hermesDashboardCookieOriginKey('not a url')).isNull();
    check(hermesDashboardCookieOriginKey('')).isNull();
  });

  test('the merge caps at the newest identities, session cookies last', () {
    final existing = [for (var i = 0; i < 63; i++) identity('old$i')];
    final merged = mergeHermesDashboardCookieIdentities(
      existing: existing,
      identities: {identity('hermes_session_at'), identity('fresh')},
      retainedNames: kHermesDashboardRetainedCookieNames,
    );
    check(merged).length.equals(64);
    check(merged.first).equals(identity('old1'));
    check(merged.last).equals(identity('hermes_session_at'));
    check(merged[62]).equals(identity('fresh'));
  });

  test('records per origin and forgets after a clear', () async {
    const origin = 'https://hermes.example';
    final generation = HermesDashboardCookieRegistry.begin(origin);
    check(
      HermesDashboardCookieRegistry.isCurrent(
        'HTTPS://hermes.example:443/x',
        generation,
      ),
    ).isTrue();

    await HermesDashboardCookieRegistry.record(
      origin,
      identities: {identity('a'), identity('b')},
    );
    await HermesDashboardCookieRegistry.record(
      'https://other.example',
      identities: {identity('c')},
    );
    check(HermesDashboardCookieRegistry.identitiesFor(origin))
        .deepEquals({identity('a'), identity('b')});

    final stored = jsonDecode(
      PreferencesStore.getString(
        PreferenceKeys.hermesDashboardCookieIdentities,
      )!,
    ) as Map;
    check(
      stored.keys.toSet(),
    ).deepEquals({'https://hermes.example:443', 'https://other.example:443'});

    check(HermesDashboardCookieRegistry.invalidate(origin)).isTrue();
    check(HermesDashboardCookieRegistry.isCurrent(origin, generation))
        .isFalse();
    await HermesDashboardCookieRegistry.forget(origin);
    check(HermesDashboardCookieRegistry.identitiesFor(origin)).isEmpty();
    check(HermesDashboardCookieRegistry.identitiesFor('https://other.example'))
        .deepEquals({identity('c')});

    await HermesDashboardCookieRegistry.forget('https://other.example');
    check(
      PreferencesStore.getString(
        PreferenceKeys.hermesDashboardCookieIdentities,
      ),
    ).isNull();
  });

  test('a later sign-in supersedes an earlier generation', () {
    const origin = 'https://hermes.example';
    final first = HermesDashboardCookieRegistry.begin(origin);
    final second = HermesDashboardCookieRegistry.begin(origin);
    check(HermesDashboardCookieRegistry.isCurrent(origin, first)).isFalse();
    check(HermesDashboardCookieRegistry.isCurrent(origin, second)).isTrue();
    check(HermesDashboardCookieRegistry.begin('nope')).equals(0);
    check(HermesDashboardCookieRegistry.isCurrent('nope', 0)).isFalse();
    check(HermesDashboardCookieRegistry.invalidate('nope')).isFalse();
  });

  test('a corrupt registry reads as empty', () async {
    await PreferencesStore.putChecked(
      PreferenceKeys.hermesDashboardCookieIdentities,
      '{not json',
    );
    check(HermesDashboardCookieRegistry.identitiesFor('https://hermes.example'))
        .isEmpty();
    await PreferencesStore.putChecked(
      PreferenceKeys.hermesDashboardCookieIdentities,
      jsonEncode({
        'https://hermes.example:443': [identity('a'), 7, null],
        'broken': 'value',
      }),
    );
    check(HermesDashboardCookieRegistry.identitiesFor('https://hermes.example'))
        .deepEquals({identity('a')});
  });
}

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('a catalog entry', () {
    test('from the dashboard, says what it asks for', () {
      final entry = HermesMcpCatalogEntry.fromJson({
        'name': 'tide-tables',
        'required_env': [
          {
            'name': 'TIDE_API_KEY',
            'prompt': 'Tide tables API key',
            'required': true,
          },
          {'name': 'TIDE_REGION', 'prompt': 'Coast region', 'required': false},
          // Not a variable name, or asked for twice: left out.
          {'name': 'TIDE KEY', 'prompt': 'Spaced'},
          {'name': 'TIDE_API_KEY', 'prompt': 'Again'},
          'TIDE_STRAY',
        ],
      }, fromDashboard: true);

      check(entry.credentials.map((it) => (it.name, it.prompt, it.required)))
          .deepEquals([
            ('TIDE_API_KEY', 'Tide tables API key', true),
            ('TIDE_REGION', 'Coast region', false),
          ]);
      check(entry.canAdd).isTrue();
    });

    test('from the dashboard, says how Hermes signs in to it', () {
      HermesMcpCatalogEntry entry(Object? authType) =>
          HermesMcpCatalogEntry.fromJson({
            'name': 'tide-calendar',
            'auth_type': authType,
          }, fromDashboard: true);

      check(entry('oauth'))
        ..has((it) => it.authType, 'authType').equals('oauth')
        ..has((it) => it.usesOAuth, 'usesOAuth').isTrue();
      check(entry('api_key').usesOAuth).isFalse();
      check(entry(null).authType).isNull();
    });

    // Sixteen specs were read before their names were checked, so names
    // that were not variables could push real ones out.
    test('keeps every valid value past ones that are not', () {
      final entry = HermesMcpCatalogEntry.fromJson({
        'name': 'tide-tables',
        'required_env': [
          for (var i = 0; i < 20; i++) {'name': 'NOT A NAME $i'},
          {'name': 'TIDE_API_KEY'},
        ],
      }, fromDashboard: true);

      check(entry.credentials.map((it) => it.name))
          .deepEquals(['TIDE_API_KEY']);
      check(entry.canAdd).isTrue();
    });

    test('asking for more than the app asks for, is not offered', () {
      final entry = HermesMcpCatalogEntry.fromJson({
        'name': 'tide-tables',
        'required_env': [
          for (var i = 0; i < 33; i++) {'name': 'TIDE_VALUE_$i'},
        ],
      }, fromDashboard: true);

      check(entry.credentialsComplete).isFalse();
      check(entry.canAdd).isFalse();
    });

    test('from the gateway, names them only and cannot send them', () {
      final needs = HermesMcpCatalogEntry.fromJson({
        'name': 'tide-tables',
        'requires': ['TIDE_API_KEY'],
      });
      final asksNothing = HermesMcpCatalogEntry.fromJson({
        'name': 'tide-notes',
        'requires': <String>[],
      });

      check(needs.credentials.map((it) => (it.name, it.prompt, it.required)))
          .deepEquals([('TIDE_API_KEY', null, true)]);
      check(needs.canAdd).isFalse();
      check(asksNothing.canAdd).isTrue();
    });
  });

  group('the values sent with an add', () {
    final entry = HermesMcpCatalogEntry.fromJson({
      'name': 'tide-tables',
      'required_env': [
        {'name': 'TIDE_API_KEY', 'required': true},
        {'name': 'TIDE_REGION', 'required': false},
      ],
    }, fromDashboard: true);

    test('are trimmed, without empty or undeclared ones', () {
      check(
        hermesMcpCatalogCredentialValues(entry, {
          'TIDE_API_KEY': '  synthetic-tide-key ',
          'TIDE_REGION': ' ',
          'TIDE_STRAY': 'not asked for',
        }),
      ).isNotNull().deepEquals({'TIDE_API_KEY': 'synthetic-tide-key'});
    });

    test('are none while a required one is missing', () {
      check(hermesMcpCatalogCredentialValues(entry, {'TIDE_REGION': 'north'}))
          .isNull();
    });
  });
}

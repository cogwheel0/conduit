import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';

void main() {
  test('parses section, import/export, sharing, public, and user grants', () {
    final capabilities = WorkspaceCapabilities.fromPermissions({
      'workspace': {
        'models': true,
        'models_import': true,
        'models_export': false,
        'tools': true,
      },
      'sharing': {
        'models': true,
        'public_models': false,
        'tools': false,
        'public_tools': true,
      },
      'access_grants': {'allow_users': true},
    });

    check(capabilities.models.manage).isTrue();
    check(capabilities.models.importItems).isTrue();
    check(capabilities.models.exportItems).isFalse();
    check(capabilities.models.share).isTrue();
    check(capabilities.models.sharePublicly).isFalse();
    check(capabilities.tools.manage).isTrue();
    check(capabilities.tools.share).isFalse();
    check(capabilities.tools.sharePublicly).isTrue();
    check(capabilities.prompts.manage).isFalse();
    check(capabilities.allowUserGrants).isTrue();
  });

  test('admin is all-capable without an ApiService', () async {
    final container = ProviderContainer(
      overrides: [
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'admin-1',
            username: 'admin',
            email: 'admin@example.com',
            role: 'admin',
          ),
        ),
        apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    final capabilities = await container.read(
      workspaceCapabilitiesProvider.future,
    );

    for (final section in [
      capabilities.models,
      capabilities.knowledge,
      capabilities.prompts,
      capabilities.skills,
      capabilities.tools,
    ]) {
      _checkSection(section, expected: true);
    }
    check(capabilities.allowUserGrants).isTrue();
  });

  test('non-admin without an ApiService fails closed', () async {
    final container = ProviderContainer(
      overrides: [
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'user-1',
            username: 'user',
            email: 'user@example.com',
            role: 'user',
          ),
        ),
        apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    final capabilities = await container.read(
      workspaceCapabilitiesProvider.future,
    );

    for (final section in [
      capabilities.models,
      capabilities.knowledge,
      capabilities.prompts,
      capabilities.skills,
      capabilities.tools,
    ]) {
      _checkSection(section, expected: false);
    }
    check(capabilities.allowUserGrants).isFalse();
  });
}

void _checkSection(
  WorkspaceSectionCapabilities section, {
  required bool expected,
}) {
  check(section.manage).equals(expected);
  check(section.importItems).equals(expected);
  check(section.exportItems).equals(expected);
  check(section.share).equals(expected);
  check(section.sharePublicly).equals(expected);
}

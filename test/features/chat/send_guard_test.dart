import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stand-in for a non-null [ApiService] (we only care about non-null identity).
class _FakeApiService extends Fake implements ApiService {}

const _owuiModel = Model(id: 'gpt-4', name: 'GPT-4');
final _hermesModel = hermesSyntheticModel();

/// Unit tests for the extracted send/regenerate guard. The Hermes-only
/// relaxation lets a Hermes model send with no OpenWebUI [api].
void main() {
  group('isSendBlocked', () {
    test('blocks when no model is selected', () {
      check(
        isSendBlocked(reviewerMode: false, api: null, selectedModel: null),
      ).isTrue();
      // ...even with an api present.
      check(
        isSendBlocked(
          reviewerMode: false,
          api: _FakeApiService(),
          selectedModel: null,
        ),
      ).isTrue();
    });

    test('blocks an OWUI model when the api is null and not reviewer', () {
      check(
        isSendBlocked(
          reviewerMode: false,
          api: null,
          selectedModel: _owuiModel,
        ),
      ).isTrue();
    });

    test('allows an OWUI model when the api is present', () {
      check(
        isSendBlocked(
          reviewerMode: false,
          api: _FakeApiService(),
          selectedModel: _owuiModel,
        ),
      ).isFalse();
    });

    test('allows any model in reviewer mode even with a null api', () {
      check(
        isSendBlocked(reviewerMode: true, api: null, selectedModel: _owuiModel),
      ).isFalse();
    });

    test('allows a Hermes model with a null api (the relaxation)', () {
      check(
        isSendBlocked(
          reviewerMode: false,
          api: null,
          selectedModel: _hermesModel,
        ),
      ).isFalse();
    });
  });
}

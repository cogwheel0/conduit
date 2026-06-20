import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CaptureInterceptor extends Interceptor {
  _CaptureInterceptor(this.responseData);
  final Object? responseData;
  final List<RequestOptions> requests = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.resolve(
      Response<dynamic>(
        requestOptions: options,
        data: responseData,
        statusCode: 200,
      ),
    );
  }
}

void main() {
  test('listSkills hits /v1/skills and unwraps a bare array', () async {
    final capture = _CaptureInterceptor([
      {'name': 'gif-search', 'description': 'Find GIFs', 'category': 'media'},
    ]);
    final dio = Dio()..interceptors.add(capture);
    final service = HermesApiService(
      config: const HermesConfig(
        enabled: true,
        baseUrl: 'http://host:8642/v1',
        apiKey: 'k',
      ),
      dio: dio,
    );

    final skills = await service.listSkills();
    check(capture.requests.single.path).equals('http://host:8642/v1/skills');
    check(skills.single['name']).equals('gif-search');
  });

  test('hermesSkillPromptsProvider maps skills to slash-command prompts', () async {
    final capture = _CaptureInterceptor({
      'skills': [
        {'name': 'gif-search', 'description': 'Find GIFs'},
        {'name': 'plan', 'description': 'Plan a rollout'},
        {'description': 'no name — skipped'},
      ],
    });
    final dio = Dio()..interceptors.add(capture);
    final service = HermesApiService(
      config: const HermesConfig(
        enabled: true,
        baseUrl: 'http://host:8642',
        apiKey: 'k',
      ),
      dio: dio,
    );

    final container = ProviderContainer(
      overrides: [hermesApiServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    final prompts = await container.read(hermesSkillPromptsProvider.future);
    check(prompts).has((p) => p.length, 'length').equals(2);
    check(prompts.first.command).equals('/gif-search');
    check(prompts.first.title).equals('Find GIFs');
    check(prompts.first.content).equals('/gif-search ');
  });
}

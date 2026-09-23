import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Filling a prompt in (WP-3.3). The parsing is the core's and tested
/// there; what is tested here is the exchange: ask once per field, answer
/// with what was given, and let the window supply the clipboard.
void main() {
  late ProviderContainer container;
  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  PromptsService serviceWith(List<Prompt> prompts) =>
      PromptsService(container, fetch: () async => prompts);

  const plain = Prompt(command: '/hello', title: 'Hello', content: 'Hi there');
  const withInputs = Prompt(
    command: '/standup',
    title: 'Stand-up',
    content:
        'Team {{team | select:options=["Platform","Mobile"]:required=true}}, '
        'blockers: {{blockers | textarea:placeholder=None}}. '
        'Again, {{team}}.',
  );
  const withClipboard = Prompt(
    command: '/explain',
    title: 'Explain',
    content: 'Explain this: {{CLIPBOARD}}',
  );

  test('lists commands, and says which ones read the clipboard', () async {
    final list = await serviceWith(<Prompt>[plain, withClipboard]).list();
    expect(list.prompts.map((p) => p.command), <String>['/hello', '/explain']);
    expect(list.prompts.map((p) => p.usesClipboard), <bool>[false, true]);
  });

  test('a prompt without variables is final at once', () async {
    final rendered = await serviceWith(<Prompt>[plain])
        .render(const RenderPrompt(command: '/hello'));
    expect(rendered.content, 'Hi there');
    expect(rendered.inputs, isEmpty);
  });

  test('asks for each field once, then fills every use of it', () async {
    final service = serviceWith(<Prompt>[withInputs]);
    final asked = await service.render(const RenderPrompt(command: '/standup'));
    expect(asked.inputs.map((i) => i.name), <String>['team', 'blockers']);
    final team = asked.inputs.first;
    expect(team.type, 'select');
    expect(team.options, <String>['Platform', 'Mobile']);
    expect(team.required, isTrue);
    expect(asked.inputs.last.placeholder, 'None');

    final answered = await service.render(
      const RenderPrompt(
        command: '/standup',
        values: <String, String>{'team': 'Mobile', 'blockers': 'none'},
      ),
    );
    expect(answered.inputs, isEmpty);
    expect(answered.content, 'Team Mobile, blockers: none. Again, Mobile.');
  });

  test('the clipboard is what the window sent', () async {
    final rendered = await serviceWith(<Prompt>[withClipboard])
        .render(const RenderPrompt(command: '/explain', clipboard: 'x = 1'));
    expect(rendered.content, 'Explain this: x = 1');
  });

  test('an unknown command is not found', () async {
    expect(
      serviceWith(<Prompt>[plain]).render(const RenderPrompt(command: '/nope')),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
  });
}

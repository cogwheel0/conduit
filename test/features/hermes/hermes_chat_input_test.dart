import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_chat_input.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openai_dart/openai_dart.dart' as openai;

void main() {
  test('text input preserves the legacy scalar wire shape', () {
    final input = HermesChatInput.text('  hello  ');

    check(input.toJson()).equals('  hello  ');
    check(input.toResponsesJson()).equals('  hello  ');
    check(input.toResponseInput())
        .isA<openai.ResponseInputText>()
        .has((value) => value.text, 'text')
        .equals('  hello  ');
  });

  test('multimodal input uses Responses-style content parts', () {
    final input = HermesChatInput.multimodal([
      HermesInputTextPart('What is this?'),
      HermesInputImagePart('data:image/png;base64,aGVsbG8=', detail: 'high'),
    ]);

    check(input.toJson() as List).deepEquals([
      {'type': 'input_text', 'text': 'What is this?'},
      {
        'type': 'input_image',
        'image_url': 'data:image/png;base64,aGVsbG8=',
        'detail': 'high',
      },
    ]);
    check(input.toResponsesJson() as List).deepEquals([
      {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': 'What is this?'},
          {
            'type': 'input_image',
            'image_url': 'data:image/png;base64,aGVsbG8=',
            'detail': 'high',
          },
        ],
      },
    ]);
    final sdkInput = check(
      input.toResponseInput(),
    ).isA<openai.ResponseInputItems>();
    sdkInput.has((value) => value.items, 'items').length.equals(1);
    check(
      input.toResponseInput().toJson() as List<Object?>,
    ).deepEquals(input.toResponsesJson() as List<Object?>);
  });

  test('rejects empty turns and unsupported image references', () {
    check(() => HermesChatInput.text('  ')).throws<ArgumentError>();
    check(() => HermesChatInput.multimodal(const [])).throws<ArgumentError>();
    check(
      () => HermesInputImagePart('/private/device/photo.jpg'),
    ).throws<ArgumentError>();
    check(
      () => HermesInputImagePart(
        'https://example.com/image.png',
        detail: 'extreme',
      ),
    ).throws<ArgumentError>();
  });
}

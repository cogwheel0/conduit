import 'package:conduit_core/utils/model_system_prompt.dart';
import 'package:test/test.dart';

void main() {
  test('reads params.system, trimmed, and nothing when blank', () {
    expect(
      modelSystemPromptOf({
        'params': {'system': '  Answer in haiku. '},
      }),
      'Answer in haiku.',
    );
    expect(
      modelSystemPromptOf({
        'params': {'system': '   '},
      }),
      isNull,
    );
    expect(modelSystemPromptOf({'params': null}), isNull);
    expect(modelSystemPromptOf(const {}), isNull);
  });

  test('a record is writable only when the server says so', () {
    expect(modelRecordWritable({'write_access': true}), isTrue);
    expect(modelRecordWritable({'write_access': 'true'}), isFalse);
    expect(modelRecordWritable(const {}), isFalse);
  });
}

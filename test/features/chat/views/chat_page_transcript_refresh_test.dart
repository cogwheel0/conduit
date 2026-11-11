import 'package:checks/checks.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  HermesTranscriptRefreshStep step({
    bool shownChanged = false,
    bool streaming = false,
    bool retried = false,
    int shownCount = 4,
    int readCount = 4,
    bool shortened = false,
    List<String>? used,
  }) => hermesTranscriptRefreshStep(
    shownChanged: shownChanged,
    streaming: streaming,
    retried: retried,
    shownCount: shownCount,
    readCount: readCount,
    shortened: () {
      used?.add('taken');
      return shortened;
    },
  );

  // A prompt sent while the transcript was read is not in that read: it
  // replaced the chat, and the prompt was gone though its turn ran.
  test('a chat that changed during the read is not replaced by it', () {
    check(
      step(shownChanged: true, streaming: true),
    ).equals(HermesTranscriptRefreshStep.afterReply);
    check(
      step(shownChanged: true),
    ).equals(HermesTranscriptRefreshStep.retry);
    check(
      step(shownChanged: true, retried: true),
    ).equals(HermesTranscriptRefreshStep.keep);
  });

  test('a shorter read is shown only after a change that shortened it', () {
    check(step(readCount: 2)).equals(HermesTranscriptRefreshStep.keep);
    check(
      step(readCount: 2, shortened: true),
    ).equals(HermesTranscriptRefreshStep.apply);
    check(step(readCount: 6)).equals(HermesTranscriptRefreshStep.apply);
  });

  // Left after a read that was not shorter, the allowance let a later,
  // incomplete read shorten the chat.
  test('a compared read uses up the shortening allowance', () {
    final used = <String>[];
    step(readCount: 6, shortened: true, used: used);
    check(used).deepEquals(['taken']);

    final unused = <String>[];
    step(shownChanged: true, used: unused);
    check(unused).isEmpty();
  });
}

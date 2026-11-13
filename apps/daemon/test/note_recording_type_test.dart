import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

void main() {
  test("a waiting recording's type follows its name", () {
    expect(NotesService.audioTypeOf('Recording 1.m4a'), 'audio/mp4');
    expect(NotesService.audioTypeOf('memo.WAV'), 'audio/wav');
    expect(NotesService.audioTypeOf('memo.mp3'), 'audio/mpeg');
    expect(NotesService.audioTypeOf('memo.caf'), 'audio/x-caf');
    expect(NotesService.audioTypeOf('memo.webm'), 'audio/webm');
    expect(NotesService.audioTypeOf('memo'), 'application/octet-stream');
    expect(NotesService.audioTypeOf('memo.exe'), 'application/octet-stream');
  });
}

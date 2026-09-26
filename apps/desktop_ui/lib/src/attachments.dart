/// A file the user chose, still held by the browser.
///
/// Deliberately not the bytes. [handle] names a `File` the browser keeps;
/// the upload streams it straight to the daemon, so a 200 MB attachment
/// never exists as a Dart list or a JSON string. `FilePickerPort` says the
/// same thing from the other side: it is text-only on purpose, and this is
/// the different port with different concerns it points at.
class PickedAttachment {
  const PickedAttachment({
    required this.handle,
    required this.name,
    required this.size,
    required this.contentType,
  });

  /// Identifies the browser-held file to [AttachmentPort.upload].
  final String handle;
  final String name;
  final int size;
  final String contentType;
}

/// A terminal handle and a folder on its machine, for an upload.
typedef TerminalUploadTarget = ({String handle, String directory});

/// Picking and uploading attachments.
abstract interface class AttachmentPort {
  /// Opens the OS picker. Empty when the user cancels.
  ///
  /// [accept] is an HTML accept list. A filter, never a guarantee.
  Future<List<PickedAttachment>> pick({String accept = ''});

  /// Sends [handle] to the daemon, which forwards it to the server.
  ///
  /// Returns the id the server assigned, which is what a turn refers to.
  /// [onProgress] reports a fraction between 0 and 1.
  ///
  /// With [terminal], the file goes into that folder of a terminal's
  /// machine instead, and the answer is its path there.
  Future<String> upload(
    String handle, {
    void Function(double fraction)? onProgress,
    TerminalUploadTarget? terminal,
  });

  /// Forgets [handle] without uploading it.
  void discard(String handle);

  /// Whether a drag over the composer carries files, and if it does,
  /// claims it so it can be dropped there.
  ///
  /// A drag of text is left alone, so dropping a selection into the field
  /// still inserts it. [event] is the DOM event, typed loosely so this
  /// interface stays compilable on the VM.
  bool claimDrag(Object event);

  /// The files a drop or a paste carries, each held like a picked one.
  ///
  /// When there are any, the event is claimed: otherwise Electron would
  /// also navigate to a dropped file, and a pasted screenshot would also
  /// paste its file name into the field. Empty for text, which proceeds as
  /// the browser would.
  List<PickedAttachment> takeFiles(Object event);

  /// Starts recording from the microphone. False when there is no
  /// microphone or it was refused -- which is the user's answer, not an
  /// error to report as one.
  Future<bool> startRecording();

  /// Stops recording and holds the result like a picked file, ready for
  /// [upload]. Null when nothing was recorded.
  Future<PickedAttachment?> stopRecording();
}

/// Records what it was asked to do. The default outside a browser.
final class RecordingAttachments implements AttachmentPort {
  RecordingAttachments({this.picks = const <PickedAttachment>[]});

  /// What the next [pick] returns.
  List<PickedAttachment> picks;

  final List<String> uploaded = <String>[];
  final List<String> discarded = <String>[];

  /// Fails the next upload with this, if set.
  Object? failWith;

  @override
  Future<List<PickedAttachment>> pick({String accept = ''}) async => picks;

  @override
  Future<String> upload(
    String handle, {
    void Function(double fraction)? onProgress,
    TerminalUploadTarget? terminal,
  }) async {
    if (failWith case final error?) throw error;
    onProgress?.call(1);
    uploaded.add(handle);
    if (terminal != null) {
      uploadedTo.add(terminal);
      return '${terminal.directory}$handle';
    }
    return 'server-$handle';
  }

  /// Where terminal uploads went, in order.
  final List<TerminalUploadTarget> uploadedTo = <TerminalUploadTarget>[];

  @override
  void discard(String handle) => discarded.add(handle);

  /// What the next drop or paste carries.
  List<PickedAttachment> transfer = const <PickedAttachment>[];

  @override
  bool claimDrag(Object event) => transfer.isNotEmpty;

  @override
  List<PickedAttachment> takeFiles(Object event) {
    final files = transfer;
    transfer = const <PickedAttachment>[];
    return files;
  }

  /// Whether [startRecording] finds a microphone.
  bool microphone = true;

  /// What [stopRecording] hands back.
  PickedAttachment recording = const PickedAttachment(
    handle: 'rec',
    name: 'Recording.webm',
    size: 1024,
    contentType: 'audio/webm',
  );
  bool recordingNow = false;

  @override
  Future<bool> startRecording() async => recordingNow = microphone;

  @override
  Future<PickedAttachment?> stopRecording() async {
    if (!recordingNow) return null;
    recordingNow = false;
    return recording;
  }
}

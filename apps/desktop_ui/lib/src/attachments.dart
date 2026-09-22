/// A file the user chose, still held by the browser (WP-3.3).
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
  Future<String> upload(
    String handle, {
    void Function(double fraction)? onProgress,
  });

  /// Forgets [handle] without uploading it.
  void discard(String handle);
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
  }) async {
    if (failWith case final error?) throw error;
    onProgress?.call(1);
    uploaded.add(handle);
    return 'server-$handle';
  }

  @override
  void discard(String handle) => discarded.add(handle);
}

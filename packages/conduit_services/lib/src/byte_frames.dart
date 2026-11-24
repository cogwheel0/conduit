import 'dart:typed_data';

/// What a [ByteFrame] says. The wire value is the index, so the order is
/// part of the format.
enum ByteFrameKind {
  /// From the client: a request, its JSON (`method`, `path`, `query`,
  /// `headers`) as the payload.
  open,

  /// A piece of a body, either way: at most [ByteFrame.maxChunk] bytes.
  chunk,

  /// The body is complete, either way.
  end,

  /// From the client: the request is abandoned, and nothing more of its
  /// answer is wanted. From the host: the answer is given, so the rest of
  /// the request's body is not.
  cancel,

  /// From the host: the answer's status and headers, as JSON.
  responseHead,

  /// From the host: the stream failed, with what went wrong as text.
  error,
}

/// One frame of the byte routes over a message transport: a 12-byte
/// header, then the payload.
///
/// The header, big-endian: the stream (u32), [kind] (u8), [flags] (u8),
/// two reserved bytes, and the payload's length (u32). Each request is a
/// stream the client numbers; its frames, and its answer's, carry that
/// number.
final class ByteFrame {
  ByteFrame(this.stream, this.kind, {Uint8List? payload, this.flags = 0})
    : payload = payload ?? Uint8List(0);

  static const int headerLength = 12;

  /// The most a body chunk carries.
  static const int maxChunk = 64 * 1024;

  final int stream;
  final ByteFrameKind kind;
  final int flags;
  final Uint8List payload;

  /// A new buffer, which the receiver may keep.
  Uint8List encode() {
    final bytes = Uint8List(headerLength + payload.length);
    ByteData.sublistView(bytes)
      ..setUint32(0, stream)
      ..setUint8(4, kind.index)
      ..setUint8(5, flags)
      ..setUint32(8, payload.length);
    bytes.setRange(headerLength, bytes.length, payload);
    return bytes;
  }

  /// [bytes] as a frame whose payload is a view of [bytes], not a copy.
  /// Throws a [FormatException] for a frame that is short, of an unknown
  /// kind, or whose length is not what follows the header.
  static ByteFrame decode(Uint8List bytes) {
    if (bytes.length < headerLength) {
      throw const FormatException('a byte frame is shorter than its header');
    }
    final header = ByteData.sublistView(bytes, 0, headerLength);
    final kind = header.getUint8(4);
    if (kind >= ByteFrameKind.values.length) {
      throw FormatException('unknown byte frame kind $kind');
    }
    final length = header.getUint32(8);
    if (length != bytes.length - headerLength) {
      throw const FormatException('a byte frame says another length');
    }
    return ByteFrame(
      header.getUint32(0),
      ByteFrameKind.values[kind],
      flags: header.getUint8(5),
      payload: Uint8List.sublistView(bytes, headerLength),
    );
  }
}

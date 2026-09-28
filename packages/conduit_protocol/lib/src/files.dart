import 'package:freezed_annotation/freezed_annotation.dart';

part 'files.freezed.dart';
part 'files.g.dart';

/// The daemon's answer to `POST /upload`.
///
/// An HTTP route rather than an RPC method, and the reason is in the body:
/// the file is sent as raw bytes and streamed to the server, so a 200 MB
/// attachment never becomes a base64 string inside a JSON-RPC frame. The
/// *answer* is small and typed, so it travels as a protocol DTO like
/// everything else.
@freezed
abstract class UploadedFile with _$UploadedFile {
  const factory UploadedFile({
    /// The id Open WebUI assigned. This is what a turn refers to.
    required String id,
    required String name,
    required int size,
    String? contentType,
  }) = _UploadedFile;

  factory UploadedFile.fromJson(Map<String, dynamic> json) =>
      _$UploadedFileFromJson(json);
}

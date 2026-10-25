/// The slowest upload speed, in bytes per second, an upload is given time
/// for before it counts as stalled.
const int _uploadBytesPerSecondFloor = 128 * 1024;
const Duration _minimumUploadTimeout = Duration(minutes: 5);

/// How long sending [bytes] may take: the time at 128 KiB/s plus two
/// minutes, and never less than five minutes.
Duration uploadTimeoutForBytes(int bytes) {
  final estimatedUploadSeconds =
      (bytes / _uploadBytesPerSecondFloor).ceil() + 120;
  final timeout = Duration(seconds: estimatedUploadSeconds);
  return timeout < _minimumUploadTimeout ? _minimumUploadTimeout : timeout;
}

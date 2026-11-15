/// Error codes and fail-closed result union shared across Bridge, Storage,
/// Domain (L4), and Presentation (L5).
library;

/// Canonical fail-closed error codes across all Dart layers.
enum MuseErrorCode {
  // Audio HAL & Engine (L1–L3)
  audioDeviceInitFailed,
  microphonePermissionDenied,
  webAudioUserGestureRequired,
  soundFontLoadFailed,
  soundFontTooLargeForWeb,
  soundFontPresetBufferTooSmall,
  webSoundFontLoadWhilePlaying,
  captureBufferOverflow,
  takeLoadFailed,
  takePlaybackBufferUnderrun,
  eventQueueOverflow,
  eventQueueUnderrun,
  missingSoundFontForPart,

  // Storage, SQLite & CAS
  sqliteJournalModeMismatch,
  sqliteConstraintViolation,
  insufficientStorageQuota,
  casPromotionFailed,
  casBlobMissing,
  entityNotFound,
  revisionConflict,

  // Domain & Codec (L4)
  invalidMusicXmlFormat,
  invalidSoundFontFormat,
  invalidTickRange,
  invalidMidiChannelOrPitch,
  protectedInitialMapEvent,
}

/// Structured error payload returned inside [Err].
final class MuseError {
  final MuseErrorCode code;
  final String message;
  final Object? cause;

  const MuseError(this.code, this.message, {this.cause});

  @override
  String toString() => cause == null
      ? 'MuseError(${code.name}: $message)'
      : 'MuseError(${code.name}: $message, cause: $cause)';
}

/// Zero-exception discriminated union for fail-closed error propagation.
sealed class Result<T> {
  const Result();

  bool get isOk => this is Ok<T>;
  bool get isErr => this is Err<T>;
}

/// Successful [Result] carrying [value].
final class Ok<T> extends Result<T> {
  final T value;

  const Ok(this.value);
}

/// Failed [Result] carrying [error].
final class Err<T> extends Result<T> {
  final MuseError error;

  const Err(this.error);
}

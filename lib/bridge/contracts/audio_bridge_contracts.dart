/// Segregated Pure Dart Middle Bridge contracts and POD transfer models
/// decoupling L4 Domain and L5 Presentation from Native FFI and Web AudioWorklet.
library;

import 'engine_constants.dart';
import 'ids_and_units.dart';
import 'result.dart';

/// Pure-Dart storage-to-bridge resolver implemented by `lib/storage/{native,web}/`
/// and injected into platform audio bridges by `lib/app/` so `lib/bridge/`
/// never hardcodes filesystem paths or opens OPFS directly.
abstract interface class IInternalStorageLocator {
  /// Native: returns internal POSIX path `ApplicationSupportDirectory/cas/<aa>/<sha256>.<ext>`.
  /// Web: returns `null` exclusively because OPFS blobs lack POSIX paths
  /// (Web bridges must call [readCasBlobBytes], which fails closed with
  /// [MuseErrorCode.casBlobMissing] if the blob is absent).
  String? resolveNativeCasPosixPath(Sha256Digest sha256, {required String ext});

  /// Native: returns `ApplicationSupportDirectory/staging/rec_<take_id>.wav.part`.
  /// Web: returns OPFS-relative staging path `/staging/rec_<take_id>.wav.part`.
  String resolveRecordingStagingPath(TakeId takeId);

  /// Reads an immutable CAS asset as bytes (used on Web to transfer `.sf2`/`.wav`
  /// into Worker/Worklet and during WAV export).
  Future<Result<List<int>>> readCasBlobBytes(
    Sha256Digest sha256, {
    required String ext,
  });
}

/// Hardware device configuration latched during audio engine initialization.
final class AudioHardwareInfo {
  final int sampleRate;
  final int inputChannels;
  final int outputChannels;
  final int inputBufferFrames;
  final int outputBufferFrames;
  final String deviceFingerprint;

  const AudioHardwareInfo({
    required this.sampleRate,
    required this.inputChannels,
    required this.outputChannels,
    required this.inputBufferFrames,
    required this.outputBufferFrames,
    required this.deviceFingerprint,
  });
}

/// Extracted SoundFont preset entry (Bank, Program, Name).
final class SoundFontPresetInfo {
  final int bankNum;
  final int programNum;
  final String presetName;

  const SoundFontPresetInfo({
    required this.bankNum,
    required this.programNum,
    required this.presetName,
  });
}

/// Runtime SoundFont descriptor returned when loading an `.sf2` into FluidSynth.
final class LoadedSoundFontDescriptor {
  final SoundFontHandle handle;
  final List<SoundFontPresetInfo> presets;

  const LoadedSoundFontDescriptor({
    required this.handle,
    required this.presets,
  });
}

/// Lifecycle and SoundFont loading bridge for L1–L3.
abstract interface class IAudioLifecycleBridge {
  /// On Web, must be invoked inside a user gesture (resumes `AudioContext`).
  Future<Result<AudioHardwareInfo>> initialize();

  /// Returns the hardware configuration latched by [initialize].
  /// Must fail closed by throwing [StateError] if accessed before [initialize]
  /// succeeds (never synthesize fallback hardware parameters).
  AudioHardwareInfo get currentHardwareInfo;

  Future<Result<LoadedSoundFontDescriptor>> loadSoundFontFromCas({
    required Sha256Digest sha256,
  });

  Future<Result<void>> unloadSoundFont(SoundFontHandle handle);

  Future<void> dispose();
}

/// Audible recorded WAV take region synchronized to L3 playback streaming.
final class ActiveTakePlaybackRegion {
  final TakeId takeId;
  final PartId partId;
  final Sha256Digest wavSha256;
  final SampleFrame startSampleFrame;
  final int durationFrames;
  final double gainDb;
  final double pan;

  const ActiveTakePlaybackRegion({
    required this.takeId,
    required this.partId,
    required this.wavSha256,
    required this.startSampleFrame,
    required this.durationFrames,
    required this.gainDb,
    required this.pan,
  });
}

/// Transport state, loop range, and active audio take synchronization bridge.
abstract interface class ITransportBridge {
  Result<void> play();

  Result<void> pause();

  Result<void> stop();

  /// Advances the bridge's shared epoch counter (also visible via
  /// [ISynthEventBridge.currentEpoch]) and pushes `MUT_SEEK_SAMPLE` so MIDI
  /// events and Butler take playback seek atomically.
  Result<EpochId> seekToSample(SampleFrame targetFrame);

  Result<void> setLoopRegion({
    required bool enabled,
    required SampleFrame startFrame,
    required SampleFrame endFrame,
  });

  /// L4 passes only active, audible (unmuted / solo-passing) takes with part gain/pan applied.
  Future<Result<void>> syncActiveTakeRegions(
    List<ActiveTakePlaybackRegion> regions,
  );
}

/// Timestamped, epoch-tagged MIDI command dispatched to L2 `EventQueue`.
final class ScheduledMidiEvent {
  final EpochId epoch;

  /// Timeline sample frame, or `SampleFrame(MuseConstants.immediateDispatchFrame)`
  /// for live note audition.
  final SampleFrame targetSampleFrame;

  /// 1 = noteOn, 2 = noteOff, 3 = cc, 4 = pitchBend.
  final int type;

  /// MIDI channel `0..15`.
  final int channel;
  final int data1;
  final int data2;
  final int pitchBend;

  /// Modular 16-bit loop pass generation stamped in `SynthNoteEvent.reserved`
  /// so queued post-wrap events never fire before `endCycle` advances `loop_pass`.
  final int loopPass;

  const ScheduledMidiEvent({
    required this.epoch,
    required this.targetSampleFrame,
    required this.type,
    required this.channel,
    required this.data1,
    required this.data2,
    this.pitchBend = MuseConstants.neutralPitchBend,
    this.loopPass = 0,
  });
}

/// Epoch-gated MIDI event scheduler and channel patch/mixer bridge.
abstract interface class ISynthEventBridge {
  /// Shares the same underlying authoritative epoch counter as [ITransportBridge.seekToSample].
  EpochId get currentEpoch;

  Result<EpochId> flushAndAdvanceEpoch();

  Result<int> scheduleEvents(
    List<ScheduledMidiEvent> events, {
    SampleFrame? scheduledUpToFrame,
  });

  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  });

  Result<void> setChannelMix({
    required int midiChannel,
    required double gainDb,
    required double pan,
  });

  Result<void> silenceChannel(int midiChannel);

  Result<void> triggerLiveAuditionNote({
    required int midiChannel,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  });
}

/// Immutable receipt returned by L3 after finalizing a WAV capture and computing SHA-256.
final class RecordingCaptureReceipt {
  final TakeId takeId;
  final String stagingPath;
  final Sha256Digest sha256;
  final SampleFrame capturedSampleClock;
  final SampleFrame capturedPlayheadFrame;
  final int durationFrames;
  final int sampleRate;
  final int channelCount;
  final int outputBufferFrames;
  final int inputBufferFrames;

  const RecordingCaptureReceipt({
    required this.takeId,
    required this.stagingPath,
    required this.sha256,
    required this.capturedSampleClock,
    required this.capturedPlayheadFrame,
    required this.durationFrames,
    required this.sampleRate,
    required this.channelCount,
    required this.outputBufferFrames,
    required this.inputBufferFrames,
  });
}

/// Microphone monitoring and start/stop WAV recording capture bridge.
abstract interface class IRecordingBridge {
  Result<void> setMonitorGain(double gainLinear);

  /// Verifies runtime `RECORD_AUDIO` (Android) / `getUserMedia` (Web user gesture)
  /// permission before opening capture.
  Future<Result<void>> prepareAndStartCapture(TakeId takeId);

  Future<Result<RecordingCaptureReceipt>> stopAndFinalizeCapture(TakeId takeId);
}

/// Real-time playhead, metering, and underrun/overflow snapshot emitted by L3.
final class TelemetrySnapshot {
  final SampleFrame playheadSampleFrame;
  final EpochId activeEpoch;
  final double outputPeakL;
  final double outputPeakR;
  final double outputRmsL;
  final double outputRmsR;
  final double inputPeak;
  final double inputRms;
  final bool isPlaying;
  final bool isCapturing;
  final bool hasEventQueueUnderrun;
  final bool hasCaptureBufferOverflow;
  final bool hasTakePlaybackUnderrun;
  final int? loopPass;

  const TelemetrySnapshot({
    required this.playheadSampleFrame,
    required this.activeEpoch,
    required this.outputPeakL,
    required this.outputPeakR,
    required this.outputRmsL,
    required this.outputRmsR,
    required this.inputPeak,
    required this.inputRms,
    required this.isPlaying,
    required this.isCapturing,
    required this.hasEventQueueUnderrun,
    required this.hasCaptureBufferOverflow,
    required this.hasTakePlaybackUnderrun,
    this.loopPass,
  });
}

/// Single-consumer telemetry drainer with non-destructive cache for L4 lookahead.
abstract interface class ITelemetryBridge {
  /// Non-destructive latest snapshot cached whenever [drainTelemetry] runs
  /// (read by L4 lookahead feeder).
  TelemetrySnapshot? get latestSnapshot;

  /// Drains up to [maxFrames] queued [TelemetrySnapshot] blocks in chronological order.
  /// L5 `TransportAndTelemetryController` is the single drainer so SPSC frames are
  /// never split across consumers.
  List<TelemetrySnapshot> drainTelemetry({
    int maxFrames = MuseConstants.maxTelemetryDrainFrames,
  });
}

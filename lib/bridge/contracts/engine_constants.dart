/// Centralized numeric, timing, storage, and asset constants across Dart layers.
library;

/// Shared engine, notation, storage, and default SoundFont constants.
abstract final class MuseConstants {
  // ---------------------------------------------------------------------------
  // Canonical Timing & Rhythmic Subdivisions (960 PPQN)
  // ---------------------------------------------------------------------------

  /// Pulses (ticks) per quarter note; canonical integer resolution (`960 PPQN`).
  static const int ppqn = 960;

  /// Number of quarter-note beats in a whole note (4/4 reference).
  static const int beatsPerWholeNote = 4;

  /// Canonical ticks in one whole note (`3840`).
  static const int wholeNoteTicks = ppqn * beatsPerWholeNote;

  /// Default anacrusis (pickup measure) length in ticks for new projects.
  static const int defaultPickupTicks = 0;

  /// Numerator/denominator multipliers for dotted durations (`3/2`).
  static const int dottedMultiplierNumerator = 3;
  static const int dottedMultiplierDenominator = 2;

  /// Numerator/denominator multipliers for triplet durations (`2/3`).
  static const int tripletMultiplierNumerator = 2;
  static const int tripletMultiplierDenominator = 3;

  // Straight subdivisions (up to 1/64)
  static const int halfNoteTicks = wholeNoteTicks ~/ 2;
  static const int quarterNoteTicks = ppqn;
  static const int eighthNoteTicks = quarterNoteTicks ~/ 2;
  static const int sixteenthNoteTicks = eighthNoteTicks ~/ 2;
  static const int thirtySecondNoteTicks = sixteenthNoteTicks ~/ 2;
  static const int sixtyFourthNoteTicks = thirtySecondNoteTicks ~/ 2;

  // Dotted subdivisions (up to Dotted 1/32)
  static const int dottedHalfNoteTicks =
      (halfNoteTicks * dottedMultiplierNumerator) ~/
      dottedMultiplierDenominator;
  static const int dottedQuarterNoteTicks =
      (quarterNoteTicks * dottedMultiplierNumerator) ~/
      dottedMultiplierDenominator;
  static const int dottedEighthNoteTicks =
      (eighthNoteTicks * dottedMultiplierNumerator) ~/
      dottedMultiplierDenominator;
  static const int dottedSixteenthNoteTicks =
      (sixteenthNoteTicks * dottedMultiplierNumerator) ~/
      dottedMultiplierDenominator;
  static const int dottedThirtySecondNoteTicks =
      (thirtySecondNoteTicks * dottedMultiplierNumerator) ~/
      dottedMultiplierDenominator;

  // Triplet subdivisions (up to 1/32T)
  static const int tripletHalfNoteTicks =
      (halfNoteTicks * tripletMultiplierNumerator) ~/
      tripletMultiplierDenominator;
  static const int tripletQuarterNoteTicks =
      (quarterNoteTicks * tripletMultiplierNumerator) ~/
      tripletMultiplierDenominator;
  static const int tripletEighthNoteTicks =
      (eighthNoteTicks * tripletMultiplierNumerator) ~/
      tripletMultiplierDenominator;
  static const int tripletSixteenthNoteTicks =
      (sixteenthNoteTicks * tripletMultiplierNumerator) ~/
      tripletMultiplierDenominator;
  static const int tripletThirtySecondNoteTicks =
      (thirtySecondNoteTicks * tripletMultiplierNumerator) ~/
      tripletMultiplierDenominator;

  // ---------------------------------------------------------------------------
  // MIDI & Live Audition Bounds
  // ---------------------------------------------------------------------------

  /// Number of MIDI channels exposed by a single FluidSynth instance (`16`).
  static const int midiChannelCount = 16;

  /// Lowest valid 0-indexed MIDI channel.
  static const int minMidiChannel = 0;

  /// Highest valid 0-indexed MIDI channel (`15`).
  static const int maxMidiChannel = midiChannelCount - 1;

  /// General MIDI reserved percussion channel (`9`, 0-indexed channel 10).
  static const int gmPercussionChannel = 9;

  /// Valid 7-bit MIDI note pitch bounds (`0..127`).
  static const int minMidiPitch = 0;
  static const int maxMidiPitch = 127;

  /// Valid MIDI note-on velocity bounds (`1..127`; velocity 0 is note-off).
  static const int minMidiVelocity = 1;
  static const int maxMidiVelocity = 127;

  /// Valid MIDI program change bounds (`0..127`).
  static const int minProgramNum = 0;
  static const int maxProgramNum = 127;

  /// Valid 14-bit MIDI bank select bounds (`0..16383`).
  static const int minBankNum = 0;
  static const int maxBankNum = 16383;

  /// Neutral (centered) signed 14-bit MIDI pitch bend offset.
  static const int neutralPitchBend = 0;

  /// Wire tags matching `SynthEventType` in `rt_pods.h`.
  static const int midiEventNoteOn = 1;
  static const int midiEventNoteOff = 2;
  static const int midiEventControlChange = 3;
  static const int midiEventPitchBend = 4;

  /// Sentinel `targetSampleFrame` dispatching live note auditions on the next
  /// audio callback without colliding with timeline frame `0`.
  static const int immediateDispatchFrame = -1;

  // ---------------------------------------------------------------------------
  // Lookahead, Telemetry & Audio Limits
  // ---------------------------------------------------------------------------

  static const int bytesPerKib = 1024;
  static const int bytesPerMib = bytesPerKib * bytesPerKib;

  /// Rolling MIDI lookahead horizon ahead of the audio playhead in ms.
  static const int lookaheadWindowMs = 200;

  /// Interval between L4 lookahead refill timer ticks in ms.
  static const int lookaheadRefillIntervalMs = 25;

  /// Target L5 UI telemetry drain frequency in Hz.
  static const int telemetryPollHz = 60;

  /// Maximum queued `TelemetryFrame`s drained per UI tick.
  static const int maxTelemetryDrainFrames = 128;

  /// Web non-SAB AudioWorklet SoundFont memory cap (`64 MiB`) to prevent OOM.
  static const int maxWebSoundFontMib = 64;
  static const int maxWebSoundFontBytes = maxWebSoundFontMib * bytesPerMib;

  /// Minimum free disk/OPFS quota required before starting WAV capture (`50 MiB`).
  static const int minRecordingFreeQuotaMib = 50;
  static const int minRecordingFreeQuotaBytes =
      minRecordingFreeQuotaMib * bytesPerMib;

  /// Web `AudioWorklet` capture `MessagePort` batch size in 128-frame quanta (`4096` frames).
  static const int webCaptureBatchQuanta = 32;

  /// Master bus soft-limiter ceiling and knee threshold (mirrored in `engine_constants.h`).
  static const double limiterCeiling = 0.99;
  static const double limiterSoftKneeThreshold = 0.90;

  /// Native Butler worker wake watermark and take prefetch size in frames
  /// (mirrored in `engine_constants.h` and used by Web OPFS take worker).
  static const int butlerWakeWatermarkFrames = 2048;
  static const int takePrefetchFrames = 16384;

  /// Maximum presets extracted per SoundFont into `MuseSoundFontPresetPod` buffer.
  static const int maxSoundFontPresets = 2048;

  /// Maximum concurrent active recorded WAV takes (1 overwrite take per MIDI part).
  static const int maxActiveTakeRegions = midiChannelCount;

  /// Environment variable enabling headless/loopback audio HAL in CI test runs.
  static const String headlessAudioEnvVar = 'MUSE_HEADLESS_AUDIO';

  // ---------------------------------------------------------------------------
  // Count-In Metronome Constants (GM Percussion Channel 9)
  // ---------------------------------------------------------------------------

  static const int countInMidiChannel = gmPercussionChannel;
  static const int countInBankNum = 0;
  static const int countInProgramNum = 0;

  /// GM MIDI key 76 = Hi Wood Block (downbeat accent).
  static const int countInAccentKey = 76;

  /// GM MIDI key 77 = Low Wood Block (subsequent beats).
  static const int countInBeatKey = 77;
  static const int countInAccentVelocity = 110;
  static const int countInBeatVelocity = 80;

  // ---------------------------------------------------------------------------
  // Storage & CAS Layout Constants
  // ---------------------------------------------------------------------------

  /// SQLite `PRAGMA busy_timeout` in ms.
  static const int sqliteBusyTimeoutMs = 5000;

  /// Leading hex characters used for CAS directory sharding (`cas/<aa>/<sha256>.<ext>`).
  static const int casShardHexLength = 2;
  static const String dbDirName = 'db';
  static const String casDirName = 'cas';
  static const String stagingDirName = 'staging';
  static const String dbFileName = 'musegrid.db';

  // ---------------------------------------------------------------------------
  // Bundled Default SoundFont Asset Metadata
  // ---------------------------------------------------------------------------

  static const String defaultSoundFontAssetPath =
      'assets/sf2/GeneralUser_GS_MuseScore_v1.442.sf2';
  static const String defaultSoundFontDisplayName =
      'GeneralUser GS MuseScore v1.442';
  static const String defaultSoundFontSha256 =
      'd910e139f619048b331d72d2e0867f1729f9725e2a97a6be32b09b8b5b5c4b12';
  static const int defaultSoundFontByteSize = 31277462;
}

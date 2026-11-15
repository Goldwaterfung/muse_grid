/// Pure Dart immutable domain entities, input payloads, aggregates, and
/// mutation batches (`WasmGC`-ready).
library;

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';

enum PlaybackTimingMode { quantized, raw }

// ignore: constant_identifier_names
enum EnharmonicStep { C, D, E, F, G, A, B }

enum KeyMode {
  major,
  minor,
  dorian,
  phrygian,
  lydian,
  mixolydian,
  aeolian,
  locrian,
  none,
}

enum ClefSign {
  // ignore: constant_identifier_names
  G,
  // ignore: constant_identifier_names
  F,
  // ignore: constant_identifier_names
  C,
  percussion,
  tab,
  none,
}

enum SpannerType { tie, slur, beam }

enum SpannerPlacement { auto, above, below }

enum CalibrationPlatform { ios, android, macos, windows, linux, web }

/// Summary metadata for a MuseGrid project (`projects` table).
final class ProjectSummary {
  final ProjectId projectId;
  final String title;

  /// Canonical PPQN (always `960`).
  final int ppqn;
  final int gridSnapTicks;
  final int pickupTicks;
  final PlaybackTimingMode playbackTimingMode;
  final int revision;
  final int createdAtMs;
  final int updatedAtMs;

  const ProjectSummary({
    required this.projectId,
    required this.title,
    required this.ppqn,
    required this.gridSnapTicks,
    required this.pickupTicks,
    required this.playbackTimingMode,
    required this.revision,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
}

/// Payload for creating a new project with initial `tick == 0` tempo and time signature maps.
final class CreateProjectInput {
  final ProjectId projectId;
  final String title;
  final int gridSnapTicks;
  final int pickupTicks;
  final PlaybackTimingMode playbackTimingMode;
  final int initialUsPerQuarter;
  final int initialTimeSigNumerator;
  final int initialTimeSigDenominator;

  const CreateProjectInput({
    required this.projectId,
    required this.title,
    required this.gridSnapTicks,
    this.pickupTicks = MuseConstants.defaultPickupTicks,
    this.playbackTimingMode = PlaybackTimingMode.quantized,
    required this.initialUsPerQuarter,
    required this.initialTimeSigNumerator,
    required this.initialTimeSigDenominator,
  });
}

/// Optimistically concurrency-checked project metadata update payload.
final class UpdateProjectMetadataInput {
  final ProjectId projectId;
  final int expectedRevision;
  final String? title;
  final int? gridSnapTicks;
  final int? pickupTicks;
  final PlaybackTimingMode? playbackTimingMode;

  const UpdateProjectMetadataInput({
    required this.projectId,
    required this.expectedRevision,
    this.title,
    this.gridSnapTicks,
    this.pickupTicks,
    this.playbackTimingMode,
  });
}

/// Instrument/vocal part belonging to a project (`project_parts` table).
final class ProjectPartEntity {
  final PartId partId;
  final ProjectId projectId;
  final String musicXmlPartId;
  final int sortOrder;
  final String name;

  /// `1` (single staff) or `2` (grand staff).
  final int stavesCount;

  /// MIDI channel `0..15`.
  final int midiChannel;
  final SoundFontId? sfId;
  final int bankNum;
  final int programNum;
  final double gainDb;

  /// Stereo pan in `[-1.0, 1.0]`.
  final double pan;
  final bool isMuted;
  final bool isSolo;
  final int updatedAtMs;

  const ProjectPartEntity({
    required this.partId,
    required this.projectId,
    required this.musicXmlPartId,
    required this.sortOrder,
    required this.name,
    required this.stavesCount,
    required this.midiChannel,
    required this.sfId,
    required this.bankNum,
    required this.programNum,
    required this.gainDb,
    required this.pan,
    required this.isMuted,
    required this.isSolo,
    required this.updatedAtMs,
  });
}

/// Exact integer tempo event (`tempo_events` table; `tick == 0` protected from deletion).
final class TempoEventEntity {
  final TempoEventId tempoEventId;
  final ProjectId projectId;
  final Tick tick;
  final int usPerQuarter;
  final int updatedAtMs;

  const TempoEventEntity({
    required this.tempoEventId,
    required this.projectId,
    required this.tick,
    required this.usPerQuarter,
    required this.updatedAtMs,
  });
}

/// Time signature map event (`time_signature_events` table; `tick == 0` protected from deletion).
final class TimeSignatureEventEntity {
  final TimeSigEventId tsEventId;
  final ProjectId projectId;
  final Tick tick;
  final int numerator;

  /// Power-of-two denominator (`1, 2, 4, 8, 16, 32, 64`).
  final int denominator;
  final int updatedAtMs;

  const TimeSignatureEventEntity({
    required this.tsEventId,
    required this.projectId,
    required this.tick,
    required this.numerator,
    required this.denominator,
    required this.updatedAtMs,
  });
}

/// Global (`partId == null`) or part/staff-specific key signature (`key_signature_events` table).
final class KeySignatureEventEntity {
  final KeySigEventId keyEventId;
  final ProjectId projectId;
  final PartId? partId;

  /// `0` = all staves in part, `1` = upper staff, `2` = lower staff.
  final int staffNumber;
  final Tick tick;

  /// Circle of fifths offset (`-7..7`).
  final int fifths;
  final KeyMode mode;
  final int updatedAtMs;

  const KeySignatureEventEntity({
    required this.keyEventId,
    required this.projectId,
    required this.partId,
    required this.staffNumber,
    required this.tick,
    required this.fifths,
    required this.mode,
    required this.updatedAtMs,
  });
}

/// Staff clef event (`clef_events` table).
final class ClefEventEntity {
  final ClefEventId clefEventId;
  final ProjectId projectId;
  final PartId partId;

  /// `1` or `2`.
  final int staffNumber;
  final Tick tick;
  final ClefSign sign;

  /// Staff line `1..5`.
  final int line;

  /// Transposition octaves `-2..2`.
  final int octaveChange;
  final int updatedAtMs;

  const ClefEventEntity({
    required this.clefEventId,
    required this.projectId,
    required this.partId,
    required this.staffNumber,
    required this.tick,
    required this.sign,
    required this.line,
    required this.octaveChange,
    required this.updatedAtMs,
  });
}

/// Authoritative dual-model note shared by `960 PPQN` grid and `crisp_notation_core`.
final class TimelineNote {
  final NoteId noteId;
  final ProjectId projectId;
  final PartId partId;

  /// `1` or `2`.
  final int staffNumber;

  /// `1..4`.
  final int voiceNumber;

  /// MIDI pitch `0..127`.
  final int pitchMidi;
  final EnharmonicStep enharmonicStep;

  /// Chromatic alteration `-2..2`.
  final int enharmonicAlter;
  final Tick rawStartTick;
  final int rawDurationTicks;
  final Tick quantizedStartTick;
  final int quantizedDurationTicks;

  /// MIDI velocity `1..127`.
  final int velocity;
  final int updatedAtMs;

  const TimelineNote({
    required this.noteId,
    required this.projectId,
    required this.partId,
    required this.staffNumber,
    required this.voiceNumber,
    required this.pitchMidi,
    required this.enharmonicStep,
    required this.enharmonicAlter,
    required this.rawStartTick,
    required this.rawDurationTicks,
    required this.quantizedStartTick,
    required this.quantizedDurationTicks,
    required this.velocity,
    required this.updatedAtMs,
  });
}

/// Tie, slur, or beam spanner linking two [TimelineNote]s (`note_spanners` table).
final class NoteSpannerEntity {
  final SpannerId spannerId;
  final ProjectId projectId;
  final PartId partId;
  final SpannerType spannerType;
  final NoteId startNoteId;
  final NoteId endNoteId;

  /// Beam depth (`1..4`) or nested slur level (`1..6`); `1` for ties.
  final int spannerLevel;
  final SpannerPlacement placement;
  final int updatedAtMs;

  const NoteSpannerEntity({
    required this.spannerId,
    required this.projectId,
    required this.partId,
    required this.spannerType,
    required this.startNoteId,
    required this.endNoteId,
    required this.spannerLevel,
    required this.placement,
    required this.updatedAtMs,
  });
}

/// Recorded raw WAV audio take anchored to a part (`audio_takes` table).
final class AudioTakeEntity {
  final TakeId takeId;
  final ProjectId projectId;
  final PartId partId;
  final Sha256Digest blobSha256;
  final Tick startTick;
  final int sampleRate;

  /// `1` (mono) or `2` (stereo).
  final int channelCount;
  final int durationFrames;
  final SampleFrame capturedPlayheadFrame;
  final SampleFrame capturedSampleClock;
  final int outputBufferFrames;
  final int inputBufferFrames;
  final int calibrationOffsetFrames;
  final int createdAtMs;
  final int updatedAtMs;

  const AudioTakeEntity({
    required this.takeId,
    required this.projectId,
    required this.partId,
    required this.blobSha256,
    required this.startTick,
    required this.sampleRate,
    required this.channelCount,
    required this.durationFrames,
    required this.capturedPlayheadFrame,
    required this.capturedSampleClock,
    required this.outputBufferFrames,
    required this.inputBufferFrames,
    required this.calibrationOffsetFrames,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
}

/// Persisted `.sf2` SoundFont entry and extracted presets (`soundfonts` + `soundfont_presets`).
final class SoundFontCatalogEntry {
  final SoundFontId sfId;
  final String name;
  final Sha256Digest blobSha256;
  final int byteSize;
  final List<SoundFontPresetInfo> presets;
  final int createdAtMs;
  final int updatedAtMs;

  const SoundFontCatalogEntry({
    required this.sfId,
    required this.name,
    required this.blobSha256,
    required this.byteSize,
    required this.presets,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
}

/// Stored round-trip latency calibration offset (`latency_calibration_profiles` table).
final class LatencyCalibrationProfile {
  final CalibrationProfileId profileId;
  final CalibrationPlatform platform;
  final String deviceFingerprint;
  final int sampleRate;
  final int bufferSizeFrames;
  final int calibrationOffsetFrames;
  final int updatedAtMs;

  const LatencyCalibrationProfile({
    required this.profileId,
    required this.platform,
    required this.deviceFingerprint,
    required this.sampleRate,
    required this.bufferSizeFrames,
    required this.calibrationOffsetFrames,
    required this.updatedAtMs,
  });
}

/// Input payload for creating or updating a [LatencyCalibrationProfile].
final class UpsertCalibrationProfileInput {
  final CalibrationPlatform platform;
  final String deviceFingerprint;
  final int sampleRate;
  final int bufferSizeFrames;
  final int calibrationOffsetFrames;

  const UpsertCalibrationProfileInput({
    required this.platform,
    required this.deviceFingerprint,
    required this.sampleRate,
    required this.bufferSizeFrames,
    required this.calibrationOffsetFrames,
  });
}

/// Streamed file handle returned by [IExternalFileExchange.pickImportFile].
final class PickedExternalFile {
  final String fileName;

  /// Lowercase extension without dot, e.g. `'sf2'`, `'musicxml'`, `'mxl'`, `'xml'`.
  final String extension;
  final int byteLength;
  final Stream<List<int>> byteStream;

  /// Optional replayable stream factory supplied when backed by a readable OS path
  /// so large Native `.sf2` imports can parse `phdr` and stream to CAS in O(1) RAM.
  final Stream<List<int>> Function()? byteStreamFactory;

  const PickedExternalFile({
    required this.fileName,
    required this.extension,
    required this.byteLength,
    required this.byteStream,
    this.byteStreamFactory,
  });
}

/// Recomputed start tick and calibration offset when re-aligning an existing take.
final class AudioTakeRealignmentUpdate {
  final TakeId takeId;
  final Tick newStartTick;
  final int newCalibrationOffsetFrames;

  const AudioTakeRealignmentUpdate({
    required this.takeId,
    required this.newStartTick,
    required this.newCalibrationOffsetFrames,
  });
}

/// Complete authoritative project snapshot loaded from SQLite or imported from MusicXML.
final class ProjectWorkspaceAggregate {
  final ProjectSummary project;
  final List<ProjectPartEntity> parts;
  final List<TempoEventEntity> tempoEvents;
  final List<TimeSignatureEventEntity> timeSignatureEvents;
  final List<KeySignatureEventEntity> keySignatureEvents;
  final List<ClefEventEntity> clefEvents;
  final List<TimelineNote> notes;
  final List<NoteSpannerEntity> spanners;
  final List<AudioTakeEntity> audioTakes;

  const ProjectWorkspaceAggregate({
    required this.project,
    required this.parts,
    required this.tempoEvents,
    required this.timeSignatureEvents,
    required this.keySignatureEvents,
    required this.clefEvents,
    required this.notes,
    required this.spanners,
    required this.audioTakes,
  });
}

/// Atomic forward or inverse score delta committed in a single SQLite transaction
/// and applied in-place to the L4 dual model.
final class ScoreMutationBatch {
  final ProjectId projectId;
  final int expectedRevision;
  final UpdateProjectMetadataInput? projectMetadataUpdate;
  final List<ProjectPartEntity> upsertParts;
  final List<PartId> deletePartIds;
  final List<TempoEventEntity> upsertTempoEvents;
  final List<TempoEventId> deleteTempoEventIds;
  final List<TimeSignatureEventEntity> upsertTimeSignatureEvents;
  final List<TimeSigEventId> deleteTimeSignatureEventIds;
  final List<KeySignatureEventEntity> upsertKeySignatureEvents;
  final List<KeySigEventId> deleteKeySignatureEventIds;
  final List<ClefEventEntity> upsertClefEvents;
  final List<ClefEventId> deleteClefEventIds;
  final List<TimelineNote> upsertNotes;
  final List<NoteId> deleteNoteIds;
  final List<NoteSpannerEntity> upsertSpanners;
  final List<SpannerId> deleteSpannerIds;
  final List<AudioTakeEntity> upsertAudioTakes;
  final List<PartId> deleteAudioTakePartIds;

  const ScoreMutationBatch({
    required this.projectId,
    required this.expectedRevision,
    this.projectMetadataUpdate,
    this.upsertParts = const [],
    this.deletePartIds = const [],
    this.upsertTempoEvents = const [],
    this.deleteTempoEventIds = const [],
    this.upsertTimeSignatureEvents = const [],
    this.deleteTimeSignatureEventIds = const [],
    this.upsertKeySignatureEvents = const [],
    this.deleteKeySignatureEventIds = const [],
    this.upsertClefEvents = const [],
    this.deleteClefEventIds = const [],
    this.upsertNotes = const [],
    this.deleteNoteIds = const [],
    this.upsertSpanners = const [],
    this.deleteSpannerIds = const [],
    this.upsertAudioTakes = const [],
    this.deleteAudioTakePartIds = const [],
  });
}

/// Read queries and SQLite row mappers supporting [SqlProjectRepository].
library;

import 'package:sqlite3/common.dart';

import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import 'sqlite_schema_ddl.dart';

/// Encapsulates read-only snapshot queries and row-to-domain mappers for
/// [SqlProjectRepository].
abstract final class SqlProjectQueries {
  /// Executes [action] inside a `BEGIN ... COMMIT` read snapshot.
  static Result<T> runReadSnapshot<T>(
    CommonDatabase db,
    Result<T> Function() action,
  ) {
    try {
      db.execute('BEGIN;');
      final result = action();
      db.execute('COMMIT;');
      return result;
    } catch (error) {
      try {
        db.execute('ROLLBACK;');
      } catch (_) {}
      return Err(
        SqliteErrorMapper.mapException(
          error,
          contextMessage: 'Failed to read project snapshot',
        ),
      );
    }
  }

  /// Queries a paginated page of active (non-deleted) [ProjectSummary] rows.
  static List<ProjectSummary> listActiveProjects(
    CommonDatabase db, {
    required int limit,
    required int offset,
  }) {
    final rows = db.select(
      '''
SELECT project_id, title, ppqn, grid_snap_ticks, pickup_ticks,
       playback_timing_mode, revision, created_at, updated_at
FROM projects
WHERE deleted_at IS NULL
ORDER BY updated_at DESC, project_id ASC
LIMIT ? OFFSET ?;''',
      [limit, offset],
    );
    return rows.map(mapProjectSummary).toList(growable: false);
  }

  /// Loads the full [ProjectWorkspaceAggregate] for an active [projectId].
  static Result<ProjectWorkspaceAggregate> loadProjectAggregate(
    CommonDatabase db,
    ProjectId projectId,
  ) {
    final projectRows = db.select(
      '''
SELECT project_id, title, ppqn, grid_snap_ticks, pickup_ticks,
       playback_timing_mode, revision, created_at, updated_at
FROM projects
WHERE project_id = ? AND deleted_at IS NULL;''',
      [projectId.value],
    );
    if (projectRows.isEmpty) {
      return Err(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Active project "${projectId.value}" not found.',
        ),
      );
    }

    final project = mapProjectSummary(projectRows.first);
    final parts = db
        .select(
          '''
SELECT part_id, project_id, musicxml_part_id, sort_order, name, staves_count,
       midi_channel, sf_id, bank_num, program_num, gain_db, pan, is_muted,
       is_solo, updated_at
FROM project_parts
WHERE project_id = ?
ORDER BY sort_order ASC, part_id ASC;''',
          [projectId.value],
        )
        .map(mapPart)
        .toList(growable: false);

    final tempoEvents = db
        .select(
          '''
SELECT tempo_event_id, project_id, tick, us_per_quarter, updated_at
FROM tempo_events
WHERE project_id = ?
ORDER BY tick ASC, tempo_event_id ASC;''',
          [projectId.value],
        )
        .map(mapTempoEvent)
        .toList(growable: false);

    final timeSignatureEvents = db
        .select(
          '''
SELECT ts_event_id, project_id, tick, numerator, denominator, updated_at
FROM time_signature_events
WHERE project_id = ?
ORDER BY tick ASC, ts_event_id ASC;''',
          [projectId.value],
        )
        .map(mapTimeSignatureEvent)
        .toList(growable: false);

    final keySignatureEvents = db
        .select(
          '''
SELECT key_event_id, project_id, part_id, staff_number, tick, fifths, mode,
       updated_at
FROM key_signature_events
WHERE project_id = ?
ORDER BY tick ASC, part_id ASC, staff_number ASC, key_event_id ASC;''',
          [projectId.value],
        )
        .map(mapKeySignatureEvent)
        .toList(growable: false);

    final clefEvents = db
        .select(
          '''
SELECT clef_event_id, project_id, part_id, staff_number, tick, sign, line,
       octave_change, updated_at
FROM clef_events
WHERE project_id = ?
ORDER BY part_id ASC, staff_number ASC, tick ASC, clef_event_id ASC;''',
          [projectId.value],
        )
        .map(mapClefEvent)
        .toList(growable: false);

    final notes = db
        .select(
          '''
SELECT note_id, project_id, part_id, staff_number, voice_number, pitch_midi,
       enharmonic_step, enharmonic_alter, raw_start_tick, raw_duration_ticks,
       quantized_start_tick, quantized_duration_ticks, velocity, updated_at
FROM timeline_notes
WHERE project_id = ?
ORDER BY part_id ASC, raw_start_tick ASC, note_id ASC;''',
          [projectId.value],
        )
        .map(mapTimelineNote)
        .toList(growable: false);

    final spanners = db
        .select(
          '''
SELECT spanner_id, project_id, part_id, spanner_type, start_note_id,
       end_note_id, spanner_level, placement, updated_at
FROM note_spanners
WHERE project_id = ?
ORDER BY part_id ASC, start_note_id ASC, spanner_id ASC;''',
          [projectId.value],
        )
        .map(mapSpanner)
        .toList(growable: false);

    final audioTakes = loadProjectAudioTakes(db, projectId);

    return Ok(
      ProjectWorkspaceAggregate(
        project: project,
        parts: parts,
        tempoEvents: tempoEvents,
        timeSignatureEvents: timeSignatureEvents,
        keySignatureEvents: keySignatureEvents,
        clefEvents: clefEvents,
        notes: notes,
        spanners: spanners,
        audioTakes: audioTakes,
      ),
    );
  }

  /// Queries all [AudioTakeEntity] rows for [projectId] ordered deterministically.
  static List<AudioTakeEntity> loadProjectAudioTakes(
    CommonDatabase db,
    ProjectId projectId,
  ) {
    return db
        .select(
          '''
SELECT take_id, project_id, part_id, blob_sha256, start_tick, sample_rate,
       channel_count, duration_frames, captured_playhead_frame,
       captured_sample_clock, output_buffer_frames, input_buffer_frames,
       calibration_offset_frames, created_at, updated_at
FROM audio_takes
WHERE project_id = ?
ORDER BY start_tick ASC, part_id ASC;''',
          [projectId.value],
        )
        .map(mapAudioTake)
        .toList(growable: false);
  }

  static ProjectSummary mapProjectSummary(Row r) => ProjectSummary(
        projectId: ProjectId(r['project_id'] as String),
        title: r['title'] as String,
        ppqn: r['ppqn'] as int,
        gridSnapTicks: r['grid_snap_ticks'] as int,
        pickupTicks: r['pickup_ticks'] as int,
        playbackTimingMode: SqliteValueCodec.playbackTimingModeFromSql(
          r['playback_timing_mode'] as String,
        ),
        revision: r['revision'] as int,
        createdAtMs: r['created_at'] as int,
        updatedAtMs: r['updated_at'] as int,
      );

  static ProjectPartEntity mapPart(Row r) {
    final sfRaw = r['sf_id'] as String?;
    return ProjectPartEntity(
      partId: PartId(r['part_id'] as String),
      projectId: ProjectId(r['project_id'] as String),
      musicXmlPartId: r['musicxml_part_id'] as String,
      sortOrder: r['sort_order'] as int,
      name: r['name'] as String,
      stavesCount: r['staves_count'] as int,
      midiChannel: r['midi_channel'] as int,
      sfId: sfRaw == null ? null : SoundFontId(sfRaw),
      bankNum: r['bank_num'] as int,
      programNum: r['program_num'] as int,
      gainDb: (r['gain_db'] as num).toDouble(),
      pan: (r['pan'] as num).toDouble(),
      isMuted: SqliteValueCodec.boolFromSql(r['is_muted'], 'is_muted'),
      isSolo: SqliteValueCodec.boolFromSql(r['is_solo'], 'is_solo'),
      updatedAtMs: r['updated_at'] as int,
    );
  }

  static TempoEventEntity mapTempoEvent(Row r) => TempoEventEntity(
        tempoEventId: TempoEventId(r['tempo_event_id'] as String),
        projectId: ProjectId(r['project_id'] as String),
        tick: Tick(r['tick'] as int),
        usPerQuarter: r['us_per_quarter'] as int,
        updatedAtMs: r['updated_at'] as int,
      );

  static TimeSignatureEventEntity mapTimeSignatureEvent(Row r) =>
      TimeSignatureEventEntity(
        tsEventId: TimeSigEventId(r['ts_event_id'] as String),
        projectId: ProjectId(r['project_id'] as String),
        tick: Tick(r['tick'] as int),
        numerator: r['numerator'] as int,
        denominator: r['denominator'] as int,
        updatedAtMs: r['updated_at'] as int,
      );

  static KeySignatureEventEntity mapKeySignatureEvent(Row r) {
    final partRaw = r['part_id'] as String?;
    return KeySignatureEventEntity(
      keyEventId: KeySigEventId(r['key_event_id'] as String),
      projectId: ProjectId(r['project_id'] as String),
      partId: partRaw == null ? null : PartId(partRaw),
      staffNumber: r['staff_number'] as int,
      tick: Tick(r['tick'] as int),
      fifths: r['fifths'] as int,
      mode: SqliteValueCodec.keyModeFromSql(r['mode'] as String),
      updatedAtMs: r['updated_at'] as int,
    );
  }

  static ClefEventEntity mapClefEvent(Row r) => ClefEventEntity(
        clefEventId: ClefEventId(r['clef_event_id'] as String),
        projectId: ProjectId(r['project_id'] as String),
        partId: PartId(r['part_id'] as String),
        staffNumber: r['staff_number'] as int,
        tick: Tick(r['tick'] as int),
        sign: SqliteValueCodec.clefSignFromSql(r['sign'] as String),
        line: r['line'] as int,
        octaveChange: r['octave_change'] as int,
        updatedAtMs: r['updated_at'] as int,
      );

  static TimelineNote mapTimelineNote(Row r) => TimelineNote(
        noteId: NoteId(r['note_id'] as String),
        projectId: ProjectId(r['project_id'] as String),
        partId: PartId(r['part_id'] as String),
        staffNumber: r['staff_number'] as int,
        voiceNumber: r['voice_number'] as int,
        pitchMidi: r['pitch_midi'] as int,
        enharmonicStep: SqliteValueCodec.enharmonicStepFromSql(
          r['enharmonic_step'] as String,
        ),
        enharmonicAlter: r['enharmonic_alter'] as int,
        rawStartTick: Tick(r['raw_start_tick'] as int),
        rawDurationTicks: r['raw_duration_ticks'] as int,
        quantizedStartTick: Tick(r['quantized_start_tick'] as int),
        quantizedDurationTicks: r['quantized_duration_ticks'] as int,
        velocity: r['velocity'] as int,
        updatedAtMs: r['updated_at'] as int,
      );

  static NoteSpannerEntity mapSpanner(Row r) => NoteSpannerEntity(
        spannerId: SpannerId(r['spanner_id'] as String),
        projectId: ProjectId(r['project_id'] as String),
        partId: PartId(r['part_id'] as String),
        spannerType: SqliteValueCodec.spannerTypeFromSql(
          r['spanner_type'] as String,
        ),
        startNoteId: NoteId(r['start_note_id'] as String),
        endNoteId: NoteId(r['end_note_id'] as String),
        spannerLevel: r['spanner_level'] as int,
        placement: SqliteValueCodec.spannerPlacementFromSql(
          r['placement'] as String,
        ),
        updatedAtMs: r['updated_at'] as int,
      );

  static AudioTakeEntity mapAudioTake(Row r) => AudioTakeEntity(
        takeId: TakeId(r['take_id'] as String),
        projectId: ProjectId(r['project_id'] as String),
        partId: PartId(r['part_id'] as String),
        blobSha256: Sha256Digest(r['blob_sha256'] as String),
        startTick: Tick(r['start_tick'] as int),
        sampleRate: r['sample_rate'] as int,
        channelCount: r['channel_count'] as int,
        durationFrames: r['duration_frames'] as int,
        capturedPlayheadFrame: SampleFrame(r['captured_playhead_frame'] as int),
        capturedSampleClock: SampleFrame(r['captured_sample_clock'] as int),
        outputBufferFrames: r['output_buffer_frames'] as int,
        inputBufferFrames: r['input_buffer_frames'] as int,
        calibrationOffsetFrames: r['calibration_offset_frames'] as int,
        createdAtMs: r['created_at'] as int,
        updatedAtMs: r['updated_at'] as int,
      );
}

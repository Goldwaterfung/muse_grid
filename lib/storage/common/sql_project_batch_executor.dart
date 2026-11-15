/// Batch validation, ownership guards, and atomic SQLite mutation helpers
/// supporting [SqlProjectRepository].
library;

import 'package:sqlite3/common.dart';

import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import 'sqlite_schema_ddl.dart';

/// Validates and executes [ScoreMutationBatch] and metadata updates inside an
/// active SQLite write transaction.
abstract final class SqlProjectBatchExecutor {
  /// Maximum bind parameters per `IN (...)` query chunk to stay safely below
  /// SQLite's `SQLITE_MAX_VARIABLE_NUMBER` (`999` on legacy builds).
  static const int _maxSqlInClauseIds = 500;

  /// Validates field bounds on an [UpdateProjectMetadataInput].
  static MuseError? validateMetadataUpdate(UpdateProjectMetadataInput input) {
    if (input.projectId.value.trim().isEmpty || input.expectedRevision < 0) {
      return const MuseError(
        MuseErrorCode.sqliteConstraintViolation,
        'Invalid projectId or expectedRevision.',
      );
    }
    if (input.title != null && input.title!.trim().isEmpty) {
      return const MuseError(
        MuseErrorCode.sqliteConstraintViolation,
        'Project title cannot be blank.',
      );
    }
    if (input.gridSnapTicks != null && input.gridSnapTicks! <= 0) {
      return const MuseError(
        MuseErrorCode.sqliteConstraintViolation,
        'gridSnapTicks must be > 0.',
      );
    }
    if (input.pickupTicks != null && input.pickupTicks! < 0) {
      return const MuseError(
        MuseErrorCode.sqliteConstraintViolation,
        'pickupTicks must be >= 0.',
      );
    }
    return null;
  }

  /// Validates [batch] consistency before opening a SQLite transaction.
  static MuseError? validateMutationBatch(ScoreMutationBatch batch) {
    if (batch.projectId.value.trim().isEmpty || batch.expectedRevision < 0) {
      return const MuseError(
        MuseErrorCode.sqliteConstraintViolation,
        'Invalid batch projectId or expectedRevision.',
      );
    }
    if (batch.projectMetadataUpdate case final meta?) {
      if (meta.projectId != batch.projectId ||
          meta.expectedRevision != batch.expectedRevision) {
        return const MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Batch projectMetadataUpdate must match batch projectId and expectedRevision.',
        );
      }
      final metaErr = validateMetadataUpdate(meta);
      if (metaErr != null) {
        return metaErr;
      }
    }

    bool mismatch(ProjectId entityProjectId) =>
        entityProjectId != batch.projectId;
    if (batch.upsertParts.any((e) => mismatch(e.projectId)) ||
        batch.upsertTempoEvents.any((e) => mismatch(e.projectId)) ||
        batch.upsertTimeSignatureEvents.any((e) => mismatch(e.projectId)) ||
        batch.upsertKeySignatureEvents.any((e) => mismatch(e.projectId)) ||
        batch.upsertClefEvents.any((e) => mismatch(e.projectId)) ||
        batch.upsertNotes.any((e) => mismatch(e.projectId)) ||
        batch.upsertSpanners.any((e) => mismatch(e.projectId)) ||
        batch.upsertAudioTakes.any((e) => mismatch(e.projectId))) {
      return const MuseError(
        MuseErrorCode.sqliteConstraintViolation,
        'All upserted entities in ScoreMutationBatch must match batch.projectId.',
      );
    }

    for (final take in batch.upsertAudioTakes) {
      final shaCheck = SqliteValueCodec.validateSha256Hex(take.blobSha256);
      if (shaCheck case Err(:final error)) {
        return error;
      }
    }
    return null;
  }

  /// Merges [meta] onto [existingProject] and updates the `projects` row.
  ///
  /// When [expectedRevisionForUpdate] is provided, enforces compare-and-swap on
  /// `revision` and increments `revision + 1` in the same `UPDATE`.
  static void applyProjectMetadataUpdate(
    CommonDatabase db, {
    required UpdateProjectMetadataInput meta,
    required Row existingProject,
    required int nowEpochMs,
    int? expectedRevisionForUpdate,
  }) {
    final newTitle = meta.title ?? existingProject['title'] as String;
    final newGridSnap =
        meta.gridSnapTicks ?? existingProject['grid_snap_ticks'] as int;
    final newPickup =
        meta.pickupTicks ?? existingProject['pickup_ticks'] as int;
    final newMode = meta.playbackTimingMode != null
        ? SqliteValueCodec.playbackTimingModeToSql(meta.playbackTimingMode!)
        : existingProject['playback_timing_mode'] as String;

    if (expectedRevisionForUpdate != null) {
      db.execute(
        '''
UPDATE projects
SET title = ?,
    grid_snap_ticks = ?,
    pickup_ticks = ?,
    playback_timing_mode = ?,
    revision = revision + 1,
    updated_at = ?
WHERE project_id = ? AND revision = ?;''',
        [
          newTitle,
          newGridSnap,
          newPickup,
          newMode,
          nowEpochMs,
          meta.projectId.value,
          expectedRevisionForUpdate,
        ],
      );
      return;
    }

    db.execute(
      '''
UPDATE projects
SET title = ?,
    grid_snap_ticks = ?,
    pickup_ticks = ?,
    playback_timing_mode = ?,
    updated_at = ?
WHERE project_id = ?;''',
      [
        newTitle,
        newGridSnap,
        newPickup,
        newMode,
        nowEpochMs,
        meta.projectId.value,
      ],
    );
  }

  /// Pre-validates that [batch] does not delete `tick == 0` tempo or time
  /// signature entries without an atomic replacement at `tick == 0`.
  static MuseError? checkInitialMapDeletions(
    CommonDatabase db,
    ScoreMutationBatch batch,
  ) {
    final pid = batch.projectId.value;
    if (batch.deleteTempoEventIds.isNotEmpty) {
      final deletedSet = batch.deleteTempoEventIds.map((e) => e.value).toSet();
      final zeroRows = db.select(
        'SELECT tempo_event_id FROM tempo_events WHERE project_id = ? AND tick = 0;',
        [pid],
      );
      final deletingInitialTempo = zeroRows.any(
        (r) => deletedSet.contains(r['tempo_event_id'] as String),
      );
      final hasReplacementAtZero = batch.upsertTempoEvents.any(
        (e) => e.tick.value == 0 && !deletedSet.contains(e.tempoEventId.value),
      );
      if (deletingInitialTempo && !hasReplacementAtZero) {
        return const MuseError(
          MuseErrorCode.protectedInitialMapEvent,
          'Cannot delete tick == 0 tempo event without replacement.',
        );
      }
    }

    if (batch.deleteTimeSignatureEventIds.isNotEmpty) {
      final deletedSet =
          batch.deleteTimeSignatureEventIds.map((e) => e.value).toSet();
      final zeroRows = db.select(
        'SELECT ts_event_id FROM time_signature_events WHERE project_id = ? AND tick = 0;',
        [pid],
      );
      final deletingInitialTs = zeroRows.any(
        (r) => deletedSet.contains(r['ts_event_id'] as String),
      );
      final hasReplacementAtZero = batch.upsertTimeSignatureEvents.any(
        (e) => e.tick.value == 0 && !deletedSet.contains(e.tsEventId.value),
      );
      if (deletingInitialTs && !hasReplacementAtZero) {
        return const MuseError(
          MuseErrorCode.protectedInitialMapEvent,
          'Cannot delete tick == 0 time signature event without replacement.',
        );
      }
    }
    return null;
  }

  /// Rejects upserted entity PKs that already exist under a different `project_id`.
  static MuseError? verifyUpsertOwnership(
    CommonDatabase db,
    ScoreMutationBatch batch,
  ) {
    final pid = batch.projectId.value;
    final checks = <({String table, String pkCol, Iterable<String> ids})>[
      (
        table: 'project_parts',
        pkCol: 'part_id',
        ids: batch.upsertParts.map((e) => e.partId.value),
      ),
      (
        table: 'tempo_events',
        pkCol: 'tempo_event_id',
        ids: batch.upsertTempoEvents.map((e) => e.tempoEventId.value),
      ),
      (
        table: 'time_signature_events',
        pkCol: 'ts_event_id',
        ids: batch.upsertTimeSignatureEvents.map((e) => e.tsEventId.value),
      ),
      (
        table: 'key_signature_events',
        pkCol: 'key_event_id',
        ids: batch.upsertKeySignatureEvents.map((e) => e.keyEventId.value),
      ),
      (
        table: 'clef_events',
        pkCol: 'clef_event_id',
        ids: batch.upsertClefEvents.map((e) => e.clefEventId.value),
      ),
      (
        table: 'timeline_notes',
        pkCol: 'note_id',
        ids: batch.upsertNotes.map((e) => e.noteId.value),
      ),
      (
        table: 'note_spanners',
        pkCol: 'spanner_id',
        ids: batch.upsertSpanners.map((e) => e.spannerId.value),
      ),
      (
        table: 'audio_takes',
        pkCol: 'take_id',
        ids: batch.upsertAudioTakes.map((e) => e.takeId.value),
      ),
    ];

    for (final check in checks) {
      final err = _ensureIdsBelongToProject(
        db,
        table: check.table,
        pkCol: check.pkCol,
        ids: check.ids,
        projectId: pid,
      );
      if (err != null) {
        return err;
      }
    }
    return null;
  }

  /// Deletes child-to-parent entities targeted by [batch] scoped to `project_id`.
  static void executeBatchDeletions(
    CommonDatabase db,
    ScoreMutationBatch batch,
  ) {
    final pid = batch.projectId.value;
    final deletions = <({String table, String col, Iterable<String> ids})>[
      (
        table: 'note_spanners',
        col: 'spanner_id',
        ids: batch.deleteSpannerIds.map((e) => e.value),
      ),
      (
        table: 'timeline_notes',
        col: 'note_id',
        ids: batch.deleteNoteIds.map((e) => e.value),
      ),
      (
        table: 'audio_takes',
        col: 'part_id',
        ids: batch.deleteAudioTakePartIds.map((e) => e.value),
      ),
      (
        table: 'clef_events',
        col: 'clef_event_id',
        ids: batch.deleteClefEventIds.map((e) => e.value),
      ),
      (
        table: 'key_signature_events',
        col: 'key_event_id',
        ids: batch.deleteKeySignatureEventIds.map((e) => e.value),
      ),
      (
        table: 'time_signature_events',
        col: 'ts_event_id',
        ids: batch.deleteTimeSignatureEventIds.map((e) => e.value),
      ),
      (
        table: 'tempo_events',
        col: 'tempo_event_id',
        ids: batch.deleteTempoEventIds.map((e) => e.value),
      ),
      (
        table: 'project_parts',
        col: 'part_id',
        ids: batch.deletePartIds.map((e) => e.value),
      ),
    ];

    for (final deletion in deletions) {
      _deleteScopedRows(
        db,
        table: deletion.table,
        matchCol: deletion.col,
        ids: deletion.ids,
        projectId: pid,
      );
    }
  }

  /// Executes parent-to-child upserts for [batch].
  ///
  /// For tables with non-deferrable `UNIQUE(..., tick)` indexes and zero
  /// inbound child foreign keys (`tempo_events`, `time_signature_events`,
  /// `key_signature_events`, `clef_events`), clears the incoming PK rows inside
  /// the transaction first so multi-row tick swaps (including `tick == 0`
  /// swaps without deletions) never fail on transient unique collisions.
  static void executeBatchUpserts(
    CommonDatabase db,
    ScoreMutationBatch batch,
  ) {
    final pid = batch.projectId.value;
    for (final part in batch.upsertParts) {
      db.execute(
        '''
INSERT INTO project_parts (
  part_id, project_id, musicxml_part_id, sort_order, name, staves_count,
  midi_channel, sf_id, bank_num, program_num, gain_db, pan, is_muted,
  is_solo, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(part_id) DO UPDATE SET
  musicxml_part_id = excluded.musicxml_part_id,
  sort_order = excluded.sort_order,
  name = excluded.name,
  staves_count = excluded.staves_count,
  midi_channel = excluded.midi_channel,
  sf_id = excluded.sf_id,
  bank_num = excluded.bank_num,
  program_num = excluded.program_num,
  gain_db = excluded.gain_db,
  pan = excluded.pan,
  is_muted = excluded.is_muted,
  is_solo = excluded.is_solo,
  updated_at = excluded.updated_at;''',
        [
          part.partId.value,
          part.projectId.value,
          part.musicXmlPartId,
          part.sortOrder,
          part.name,
          part.stavesCount,
          part.midiChannel,
          part.sfId?.value,
          part.bankNum,
          part.programNum,
          part.gainDb,
          part.pan,
          SqliteValueCodec.boolToSql(part.isMuted),
          SqliteValueCodec.boolToSql(part.isSolo),
          part.updatedAtMs,
        ],
      );
    }

    _deleteScopedRows(
      db,
      table: 'tempo_events',
      matchCol: 'tempo_event_id',
      ids: batch.upsertTempoEvents.map((e) => e.tempoEventId.value),
      projectId: pid,
    );
    for (final tempo in batch.upsertTempoEvents) {
      db.execute(
        '''
INSERT INTO tempo_events (
  tempo_event_id, project_id, tick, us_per_quarter, updated_at
) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(tempo_event_id) DO UPDATE SET
  tick = excluded.tick,
  us_per_quarter = excluded.us_per_quarter,
  updated_at = excluded.updated_at;''',
        [
          tempo.tempoEventId.value,
          tempo.projectId.value,
          tempo.tick.value,
          tempo.usPerQuarter,
          tempo.updatedAtMs,
        ],
      );
    }

    _deleteScopedRows(
      db,
      table: 'time_signature_events',
      matchCol: 'ts_event_id',
      ids: batch.upsertTimeSignatureEvents.map((e) => e.tsEventId.value),
      projectId: pid,
    );
    for (final ts in batch.upsertTimeSignatureEvents) {
      db.execute(
        '''
INSERT INTO time_signature_events (
  ts_event_id, project_id, tick, numerator, denominator, updated_at
) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(ts_event_id) DO UPDATE SET
  tick = excluded.tick,
  numerator = excluded.numerator,
  denominator = excluded.denominator,
  updated_at = excluded.updated_at;''',
        [
          ts.tsEventId.value,
          ts.projectId.value,
          ts.tick.value,
          ts.numerator,
          ts.denominator,
          ts.updatedAtMs,
        ],
      );
    }

    _deleteScopedRows(
      db,
      table: 'key_signature_events',
      matchCol: 'key_event_id',
      ids: batch.upsertKeySignatureEvents.map((e) => e.keyEventId.value),
      projectId: pid,
    );
    for (final key in batch.upsertKeySignatureEvents) {
      db.execute(
        '''
INSERT INTO key_signature_events (
  key_event_id, project_id, part_id, staff_number, tick, fifths, mode,
  updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(key_event_id) DO UPDATE SET
  part_id = excluded.part_id,
  staff_number = excluded.staff_number,
  tick = excluded.tick,
  fifths = excluded.fifths,
  mode = excluded.mode,
  updated_at = excluded.updated_at;''',
        [
          key.keyEventId.value,
          key.projectId.value,
          key.partId?.value,
          key.staffNumber,
          key.tick.value,
          key.fifths,
          SqliteValueCodec.keyModeToSql(key.mode),
          key.updatedAtMs,
        ],
      );
    }

    _deleteScopedRows(
      db,
      table: 'clef_events',
      matchCol: 'clef_event_id',
      ids: batch.upsertClefEvents.map((e) => e.clefEventId.value),
      projectId: pid,
    );
    for (final clef in batch.upsertClefEvents) {
      db.execute(
        '''
INSERT INTO clef_events (
  clef_event_id, project_id, part_id, staff_number, tick, sign, line,
  octave_change, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(clef_event_id) DO UPDATE SET
  part_id = excluded.part_id,
  staff_number = excluded.staff_number,
  tick = excluded.tick,
  sign = excluded.sign,
  line = excluded.line,
  octave_change = excluded.octave_change,
  updated_at = excluded.updated_at;''',
        [
          clef.clefEventId.value,
          clef.projectId.value,
          clef.partId.value,
          clef.staffNumber,
          clef.tick.value,
          SqliteValueCodec.clefSignToSql(clef.sign),
          clef.line,
          clef.octaveChange,
          clef.updatedAtMs,
        ],
      );
    }

    for (final note in batch.upsertNotes) {
      db.execute(
        '''
INSERT INTO timeline_notes (
  note_id, project_id, part_id, staff_number, voice_number, pitch_midi,
  enharmonic_step, enharmonic_alter, raw_start_tick, raw_duration_ticks,
  quantized_start_tick, quantized_duration_ticks, velocity, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(note_id) DO UPDATE SET
  part_id = excluded.part_id,
  staff_number = excluded.staff_number,
  voice_number = excluded.voice_number,
  pitch_midi = excluded.pitch_midi,
  enharmonic_step = excluded.enharmonic_step,
  enharmonic_alter = excluded.enharmonic_alter,
  raw_start_tick = excluded.raw_start_tick,
  raw_duration_ticks = excluded.raw_duration_ticks,
  quantized_start_tick = excluded.quantized_start_tick,
  quantized_duration_ticks = excluded.quantized_duration_ticks,
  velocity = excluded.velocity,
  updated_at = excluded.updated_at;''',
        [
          note.noteId.value,
          note.projectId.value,
          note.partId.value,
          note.staffNumber,
          note.voiceNumber,
          note.pitchMidi,
          SqliteValueCodec.enharmonicStepToSql(note.enharmonicStep),
          note.enharmonicAlter,
          note.rawStartTick.value,
          note.rawDurationTicks,
          note.quantizedStartTick.value,
          note.quantizedDurationTicks,
          note.velocity,
          note.updatedAtMs,
        ],
      );
    }

    for (final spanner in batch.upsertSpanners) {
      db.execute(
        '''
INSERT INTO note_spanners (
  spanner_id, project_id, part_id, spanner_type, start_note_id,
  end_note_id, spanner_level, placement, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(spanner_id) DO UPDATE SET
  part_id = excluded.part_id,
  spanner_type = excluded.spanner_type,
  start_note_id = excluded.start_note_id,
  end_note_id = excluded.end_note_id,
  spanner_level = excluded.spanner_level,
  placement = excluded.placement,
  updated_at = excluded.updated_at;''',
        [
          spanner.spannerId.value,
          spanner.projectId.value,
          spanner.partId.value,
          SqliteValueCodec.spannerTypeToSql(spanner.spannerType),
          spanner.startNoteId.value,
          spanner.endNoteId.value,
          spanner.spannerLevel,
          SqliteValueCodec.spannerPlacementToSql(spanner.placement),
          spanner.updatedAtMs,
        ],
      );
    }

    for (final take in batch.upsertAudioTakes) {
      upsertAudioTake(db, take);
    }
  }

  /// Atomically inserts or overwrites the single active [take] per `(project_id, part_id)`.
  static void upsertAudioTake(CommonDatabase db, AudioTakeEntity take) {
    db.execute(
      '''
INSERT INTO audio_takes (
  take_id, project_id, part_id, blob_sha256, start_tick, sample_rate,
  channel_count, duration_frames, captured_playhead_frame,
  captured_sample_clock, output_buffer_frames, input_buffer_frames,
  calibration_offset_frames, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(project_id, part_id) DO UPDATE SET
  take_id = excluded.take_id,
  blob_sha256 = excluded.blob_sha256,
  start_tick = excluded.start_tick,
  sample_rate = excluded.sample_rate,
  channel_count = excluded.channel_count,
  duration_frames = excluded.duration_frames,
  captured_playhead_frame = excluded.captured_playhead_frame,
  captured_sample_clock = excluded.captured_sample_clock,
  output_buffer_frames = excluded.output_buffer_frames,
  input_buffer_frames = excluded.input_buffer_frames,
  calibration_offset_frames = excluded.calibration_offset_frames,
  created_at = excluded.created_at,
  updated_at = excluded.updated_at;''',
      [
        take.takeId.value,
        take.projectId.value,
        take.partId.value,
        take.blobSha256.value,
        take.startTick.value,
        take.sampleRate,
        take.channelCount,
        take.durationFrames,
        take.capturedPlayheadFrame.value,
        take.capturedSampleClock.value,
        take.outputBufferFrames,
        take.inputBufferFrames,
        take.calibrationOffsetFrames,
        take.createdAtMs,
        take.updatedAtMs,
      ],
    );
  }

  /// Ensures [projectId] still has exactly one `tick == 0` tempo event and one
  /// `tick == 0` time signature event after mutations apply.
  static MuseError? verifyPostMutationInitialMaps(
    CommonDatabase db,
    ProjectId projectId,
  ) {
    final tempoZeroCount = db
        .select(
          'SELECT COUNT(*) AS cnt FROM tempo_events WHERE project_id = ? AND tick = 0;',
          [projectId.value],
        )
        .first['cnt'] as int;
    final tsZeroCount = db
        .select(
          'SELECT COUNT(*) AS cnt FROM time_signature_events WHERE project_id = ? AND tick = 0;',
          [projectId.value],
        )
        .first['cnt'] as int;
    if (tempoZeroCount != 1 || tsZeroCount != 1) {
      return const MuseError(
        MuseErrorCode.protectedInitialMapEvent,
        'Project must retain tick == 0 tempo and time signature events.',
      );
    }
    return null;
  }

  static MuseError? _ensureIdsBelongToProject(
    CommonDatabase db, {
    required String table,
    required String pkCol,
    required Iterable<String> ids,
    required String projectId,
  }) {
    final uniqueIds = ids.toSet().toList(growable: false);
    if (uniqueIds.isEmpty) {
      return null;
    }

    for (var start = 0; start < uniqueIds.length; start += _maxSqlInClauseIds) {
      final end = start + _maxSqlInClauseIds < uniqueIds.length
          ? start + _maxSqlInClauseIds
          : uniqueIds.length;
      final chunk = uniqueIds.sublist(start, end);
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      final conflictRows = db.select(
        'SELECT $pkCol FROM $table '
        'WHERE $pkCol IN ($placeholders) AND project_id <> ? LIMIT 1;',
        <Object?>[...chunk, projectId],
      );
      if (conflictRows.isNotEmpty) {
        final conflictingId = conflictRows.first[pkCol];
        return MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Primary key "$conflictingId" in $table belongs to another project.',
        );
      }
    }
    return null;
  }

  static void _deleteScopedRows(
    CommonDatabase db, {
    required String table,
    required String matchCol,
    required Iterable<String> ids,
    required String projectId,
  }) {
    final uniqueIds = ids.toSet().toList(growable: false);
    if (uniqueIds.isEmpty) {
      return;
    }

    for (var start = 0; start < uniqueIds.length; start += _maxSqlInClauseIds) {
      final end = start + _maxSqlInClauseIds < uniqueIds.length
          ? start + _maxSqlInClauseIds
          : uniqueIds.length;
      final chunk = uniqueIds.sublist(start, end);
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      db.execute(
        'DELETE FROM $table WHERE project_id = ? AND $matchCol IN ($placeholders);',
        <Object?>[projectId, ...chunk],
      );
    }
  }
}

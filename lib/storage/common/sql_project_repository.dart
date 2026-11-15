/// Platform-agnostic SQLite implementation of [IProjectRepository].
library;

import 'package:sqlite3/common.dart';
import 'package:uuid/uuid.dart';

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import '../../domain/repositories/storage_contracts.dart';
import 'sql_project_batch_executor.dart';
import 'sql_project_queries.dart';
import 'sqlite_schema_ddl.dart';

/// SQLite-backed implementation of [IProjectRepository] operating over
/// `package:sqlite3/common.dart` and an injected [ICasBlobStore].
final class SqlProjectRepository implements IProjectRepository {
  final CommonDatabase _db;
  final ICasBlobStore _casStore;
  final int Function() _nowEpochMs;
  final String Function() _generateUuidV7;

  SqlProjectRepository({
    required this._db,
    required this._casStore,
    int Function()? nowEpochMs,
    String Function()? generateUuidV7,
  })  : _nowEpochMs =
            nowEpochMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
        _generateUuidV7 = generateUuidV7 ?? const Uuid().v7;

  @override
  Future<Result<List<ProjectSummary>>> listActiveProjects({
    required int limit,
    required int offset,
  }) async {
    if (limit <= 0 || offset < 0) {
      return Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Invalid pagination bounds (limit=$limit, offset=$offset).',
        ),
      );
    }

    try {
      return Ok(
        SqlProjectQueries.listActiveProjects(
          _db,
          limit: limit,
          offset: offset,
        ),
      );
    } catch (error) {
      return Err(
        SqliteErrorMapper.mapException(
          error,
          contextMessage: 'Failed to list active projects',
        ),
      );
    }
  }

  @override
  Future<Result<ProjectWorkspaceAggregate>> loadProjectAggregate(
    ProjectId projectId,
  ) async {
    if (projectId.value.trim().isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'projectId must not be empty.',
        ),
      );
    }

    return SqlProjectQueries.runReadSnapshot(
      _db,
      () => SqlProjectQueries.loadProjectAggregate(_db, projectId),
    );
  }

  @override
  Future<Result<ProjectSummary>> createProject(CreateProjectInput input) async {
    if (input.projectId.value.trim().isEmpty ||
        input.title.trim().isEmpty ||
        input.gridSnapTicks <= 0 ||
        input.pickupTicks < 0 ||
        input.initialUsPerQuarter <= 0 ||
        input.initialTimeSigNumerator <= 0 ||
        !SqliteSchemaDdl.validTimeSigDenominators
            .contains(input.initialTimeSigDenominator)) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Invalid CreateProjectInput parameters.',
        ),
      );
    }

    return SqliteTxHelper.runWriteTransaction<ProjectSummary>(
      _db,
      () {
        final now = _nowEpochMs();
        final defaultPartId = _generateUuidV7();
        final modeSql =
            SqliteValueCodec.playbackTimingModeToSql(input.playbackTimingMode);

        _db.execute(
          '''
INSERT INTO projects (
  project_id, title, ppqn, grid_snap_ticks, pickup_ticks,
  playback_timing_mode, revision, created_at, updated_at, deleted_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL);''',
          [
            input.projectId.value,
            input.title,
            MuseConstants.ppqn,
            input.gridSnapTicks,
            input.pickupTicks,
            modeSql,
            0,
            now,
            now,
          ],
        );

        _db.execute(
          '''
INSERT INTO project_parts (
  part_id, project_id, musicxml_part_id, sort_order, name, staves_count,
  midi_channel, sf_id, bank_num, program_num, gain_db, pan, is_muted,
  is_solo, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, 0, 0, ?);''',
          [
            defaultPartId,
            input.projectId.value,
            SqliteSchemaDdl.defaultMusicXmlPartId,
            SqliteSchemaDdl.defaultPartSortOrder,
            SqliteSchemaDdl.defaultPartName,
            SqliteSchemaDdl.defaultPartStavesCount,
            SqliteSchemaDdl.defaultPartMidiChannel,
            SqliteSchemaDdl.defaultPartBankNum,
            SqliteSchemaDdl.defaultPartProgramNum,
            SqliteSchemaDdl.defaultPartGainDb,
            SqliteSchemaDdl.defaultPartPan,
            now,
          ],
        );

        _db.execute(
          '''
INSERT INTO tempo_events (
  tempo_event_id, project_id, tick, us_per_quarter, updated_at
) VALUES (?, ?, ?, ?, ?);''',
          [
            _generateUuidV7(),
            input.projectId.value,
            SqliteSchemaDdl.minTick,
            input.initialUsPerQuarter,
            now,
          ],
        );

        _db.execute(
          '''
INSERT INTO time_signature_events (
  ts_event_id, project_id, tick, numerator, denominator, updated_at
) VALUES (?, ?, ?, ?, ?, ?);''',
          [
            _generateUuidV7(),
            input.projectId.value,
            SqliteSchemaDdl.minTick,
            input.initialTimeSigNumerator,
            input.initialTimeSigDenominator,
            now,
          ],
        );

        _db.execute(
          '''
INSERT INTO key_signature_events (
  key_event_id, project_id, part_id, staff_number, tick, fifths, mode, updated_at
) VALUES (?, ?, NULL, ?, ?, ?, ?, ?);''',
          [
            _generateUuidV7(),
            input.projectId.value,
            SqliteSchemaDdl.defaultGlobalKeyStaffNumber,
            SqliteSchemaDdl.minTick,
            SqliteSchemaDdl.defaultKeySignatureFifths,
            SqliteSchemaDdl.defaultKeyModeSql,
            now,
          ],
        );

        _db.execute(
          '''
INSERT INTO clef_events (
  clef_event_id, project_id, part_id, staff_number, tick, sign, line,
  octave_change, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);''',
          [
            _generateUuidV7(),
            input.projectId.value,
            defaultPartId,
            SqliteSchemaDdl.defaultClefStaffNumber,
            SqliteSchemaDdl.minTick,
            SqliteSchemaDdl.defaultClefSignSql,
            SqliteSchemaDdl.defaultClefLine,
            SqliteSchemaDdl.defaultClefOctaveChange,
            now,
          ],
        );

        return Ok(
          ProjectSummary(
            projectId: input.projectId,
            title: input.title,
            ppqn: MuseConstants.ppqn,
            gridSnapTicks: input.gridSnapTicks,
            pickupTicks: input.pickupTicks,
            playbackTimingMode: input.playbackTimingMode,
            revision: 0,
            createdAtMs: now,
            updatedAtMs: now,
          ),
        );
      },
      contextMessage: 'Failed to create project',
    );
  }

  @override
  Future<Result<void>> updateProjectMetadata(
    UpdateProjectMetadataInput input,
  ) async {
    final validationError =
        SqlProjectBatchExecutor.validateMetadataUpdate(input);
    if (validationError != null) {
      return Err(validationError);
    }

    return SqliteTxHelper.runWriteTransaction<void>(
      _db,
      () {
        final rows = _db.select(
          '''
SELECT revision, deleted_at, title, grid_snap_ticks, pickup_ticks,
       playback_timing_mode
FROM projects
WHERE project_id = ?;''',
          [input.projectId.value],
        );
        if (rows.isEmpty || rows.first['deleted_at'] != null) {
          return Err(
            MuseError(
              MuseErrorCode.entityNotFound,
              'Active project "${input.projectId.value}" not found.',
            ),
          );
        }

        final existing = rows.first;
        final currentRevision = existing['revision'] as int;
        if (currentRevision != input.expectedRevision) {
          return Err(
            MuseError(
              MuseErrorCode.revisionConflict,
              'Expected revision ${input.expectedRevision}, '
              'found $currentRevision.',
            ),
          );
        }

        SqlProjectBatchExecutor.applyProjectMetadataUpdate(
          _db,
          meta: input,
          existingProject: existing,
          nowEpochMs: _nowEpochMs(),
          expectedRevisionForUpdate: input.expectedRevision,
        );

        if (_db.updatedRows != 1) {
          return const Err(
            MuseError(
              MuseErrorCode.revisionConflict,
              'Concurrent project metadata modification detected.',
            ),
          );
        }

        return const Ok(null);
      },
      contextMessage: 'Failed to update project metadata',
    );
  }

  @override
  Future<Result<void>> softDeleteProject(
    ProjectId projectId, {
    required int deletedAtMs,
  }) async {
    if (projectId.value.trim().isEmpty || deletedAtMs <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'projectId must be non-empty and deletedAtMs must be > 0.',
        ),
      );
    }

    return SqliteTxHelper.runWriteTransaction<void>(
      _db,
      () {
        _db.execute(
          '''
UPDATE projects
SET deleted_at = ?, updated_at = ?, revision = revision + 1
WHERE project_id = ? AND deleted_at IS NULL;''',
          [deletedAtMs, deletedAtMs, projectId.value],
        );
        if (_db.updatedRows == 0) {
          return Err(
            MuseError(
              MuseErrorCode.entityNotFound,
              'Active project "${projectId.value}" not found.',
            ),
          );
        }
        return const Ok(null);
      },
      contextMessage: 'Failed to soft-delete project',
    );
  }

  @override
  Future<Result<int>> commitScoreMutationBatch(ScoreMutationBatch batch) async {
    final validationError =
        SqlProjectBatchExecutor.validateMutationBatch(batch);
    if (validationError != null) {
      return Err(validationError);
    }

    return SqliteTxHelper.runWriteTransaction<int>(
      _db,
      () {
        final projectRows = _db.select(
          '''
SELECT revision, deleted_at, title, grid_snap_ticks, pickup_ticks,
       playback_timing_mode
FROM projects
WHERE project_id = ?;''',
          [batch.projectId.value],
        );
        if (projectRows.isEmpty || projectRows.first['deleted_at'] != null) {
          return Err(
            MuseError(
              MuseErrorCode.entityNotFound,
              'Active project "${batch.projectId.value}" not found.',
            ),
          );
        }

        final existingProject = projectRows.first;
        final currentRevision = existingProject['revision'] as int;
        if (currentRevision != batch.expectedRevision) {
          return Err(
            MuseError(
              MuseErrorCode.revisionConflict,
              'Expected revision ${batch.expectedRevision}, '
              'found $currentRevision.',
            ),
          );
        }

        final initialMapError =
            SqlProjectBatchExecutor.checkInitialMapDeletions(_db, batch);
        if (initialMapError != null) {
          return Err(initialMapError);
        }

        final ownershipError =
            SqlProjectBatchExecutor.verifyUpsertOwnership(_db, batch);
        if (ownershipError != null) {
          return Err(ownershipError);
        }

        final now = _nowEpochMs();
        if (batch.projectMetadataUpdate case final meta?) {
          SqlProjectBatchExecutor.applyProjectMetadataUpdate(
            _db,
            meta: meta,
            existingProject: existingProject,
            nowEpochMs: now,
          );
        }

        SqlProjectBatchExecutor.executeBatchDeletions(_db, batch);
        SqlProjectBatchExecutor.executeBatchUpserts(_db, batch);

        final postGuardError =
            SqlProjectBatchExecutor.verifyPostMutationInitialMaps(
          _db,
          batch.projectId,
        );
        if (postGuardError != null) {
          return Err(postGuardError);
        }

        _db.execute(
          '''
UPDATE projects
SET revision = ? + 1,
    updated_at = ?
WHERE project_id = ? AND revision = ?;''',
          [
            batch.expectedRevision,
            now,
            batch.projectId.value,
            batch.expectedRevision,
          ],
        );
        if (_db.updatedRows != 1) {
          return const Err(
            MuseError(
              MuseErrorCode.revisionConflict,
              'Concurrent project revision conflict on batch commit.',
            ),
          );
        }

        return Ok(batch.expectedRevision + 1);
      },
      contextMessage: 'Failed to commit score mutation batch',
    );
  }

  @override
  Future<Result<AudioTakeEntity>> promoteAndCommitRecordedTake({
    required RecordingCaptureReceipt receipt,
    required ProjectId projectId,
    required PartId partId,
    required Tick alignedStartTick,
    required int calibrationOffsetFrames,
  }) async {
    if (projectId.value.trim().isEmpty ||
        partId.value.trim().isEmpty ||
        receipt.takeId.value.trim().isEmpty ||
        receipt.stagingPath.trim().isEmpty ||
        alignedStartTick.value < 0 ||
        receipt.durationFrames <= 0 ||
        receipt.sampleRate <= 0 ||
        (receipt.channelCount != 1 && receipt.channelCount != 2) ||
        receipt.capturedPlayheadFrame.value < 0 ||
        receipt.capturedSampleClock.value < 0 ||
        receipt.outputBufferFrames < 0 ||
        receipt.inputBufferFrames < 0) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Invalid promoteAndCommitRecordedTake arguments.',
        ),
      );
    }

    final shaCheck = SqliteValueCodec.validateSha256Hex(receipt.sha256);
    if (shaCheck case Err(:final error)) {
      return Err(error);
    }

    final preflightError = _verifyActiveProjectAndPart(projectId, partId);
    if (preflightError != null) {
      return Err(preflightError);
    }

    final promoResult = await _casStore.promoteStagingFileToCas(
      stagingPath: receipt.stagingPath,
      expectedSha256: receipt.sha256,
      ext: SqliteSchemaDdl.wavExtension,
    );
    if (promoResult case Err(:final error)) {
      return Err(error);
    }
    final verifiedByteSize = (promoResult as Ok<int>).value;

    return SqliteTxHelper.runWriteTransaction<AudioTakeEntity>(
      _db,
      () {
        final activeError = _verifyActiveProjectAndPart(projectId, partId);
        if (activeError != null) {
          return Err(activeError);
        }

        final now = _nowEpochMs();
        _db.execute(
          '''
INSERT OR IGNORE INTO content_blobs (
  sha256, ext, mime_type, byte_size, created_at
) VALUES (?, ?, ?, ?, ?);''',
          [
            receipt.sha256.value,
            SqliteSchemaDdl.wavExtension,
            SqliteSchemaDdl.wavMimeType,
            verifiedByteSize,
            now,
          ],
        );

        final take = AudioTakeEntity(
          takeId: receipt.takeId,
          projectId: projectId,
          partId: partId,
          blobSha256: receipt.sha256,
          startTick: alignedStartTick,
          sampleRate: receipt.sampleRate,
          channelCount: receipt.channelCount,
          durationFrames: receipt.durationFrames,
          capturedPlayheadFrame: receipt.capturedPlayheadFrame,
          capturedSampleClock: receipt.capturedSampleClock,
          outputBufferFrames: receipt.outputBufferFrames,
          inputBufferFrames: receipt.inputBufferFrames,
          calibrationOffsetFrames: calibrationOffsetFrames,
          createdAtMs: now,
          updatedAtMs: now,
        );
        SqlProjectBatchExecutor.upsertAudioTake(_db, take);

        _db.execute(
          '''
UPDATE projects
SET revision = revision + 1,
    updated_at = ?
WHERE project_id = ? AND deleted_at IS NULL;''',
          [now, projectId.value],
        );

        return Ok(take);
      },
      contextMessage: 'Failed to commit promoted audio take',
    );
  }

  @override
  Future<Result<List<AudioTakeEntity>>> realignAudioTakesCalibration({
    required ProjectId projectId,
    required List<AudioTakeRealignmentUpdate> updates,
  }) async {
    if (projectId.value.trim().isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'projectId must not be empty.',
        ),
      );
    }
    for (final update in updates) {
      if (update.takeId.value.trim().isEmpty || update.newStartTick.value < 0) {
        return const Err(
          MuseError(
            MuseErrorCode.sqliteConstraintViolation,
            'Invalid AudioTakeRealignmentUpdate entry.',
          ),
        );
      }
    }

    return SqliteTxHelper.runWriteTransaction<List<AudioTakeEntity>>(
      _db,
      () {
        final activeRows = _db.select(
          'SELECT 1 FROM projects WHERE project_id = ? AND deleted_at IS NULL;',
          [projectId.value],
        );
        if (activeRows.isEmpty) {
          return Err(
            MuseError(
              MuseErrorCode.entityNotFound,
              'Active project "${projectId.value}" not found.',
            ),
          );
        }

        final now = _nowEpochMs();
        for (final update in updates) {
          _db.execute(
            '''
UPDATE audio_takes
SET start_tick = ?,
    calibration_offset_frames = ?,
    updated_at = ?
WHERE project_id = ? AND take_id = ?;''',
            [
              update.newStartTick.value,
              update.newCalibrationOffsetFrames,
              now,
              projectId.value,
              update.takeId.value,
            ],
          );
          if (_db.updatedRows == 0) {
            return Err(
              MuseError(
                MuseErrorCode.entityNotFound,
                'AudioTake "${update.takeId.value}" not found in project '
                '"${projectId.value}".',
              ),
            );
          }
        }

        if (updates.isNotEmpty) {
          _db.execute(
            '''
UPDATE projects
SET revision = revision + 1,
    updated_at = ?
WHERE project_id = ?;''',
            [now, projectId.value],
          );
        }

        return Ok(SqlProjectQueries.loadProjectAudioTakes(_db, projectId));
      },
      contextMessage: 'Failed to realign audio takes calibration',
    );
  }

  @override
  Future<Result<void>> deletePartAudioTake({
    required ProjectId projectId,
    required PartId partId,
  }) async {
    if (projectId.value.trim().isEmpty || partId.value.trim().isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'projectId and partId must not be empty.',
        ),
      );
    }

    return SqliteTxHelper.runWriteTransaction<void>(
      _db,
      () {
        final activeRows = _db.select(
          'SELECT 1 FROM projects WHERE project_id = ? AND deleted_at IS NULL;',
          [projectId.value],
        );
        if (activeRows.isEmpty) {
          return Err(
            MuseError(
              MuseErrorCode.entityNotFound,
              'Active project "${projectId.value}" not found.',
            ),
          );
        }

        _db.execute(
          'DELETE FROM audio_takes WHERE project_id = ? AND part_id = ?;',
          [projectId.value, partId.value],
        );
        if (_db.updatedRows > 0) {
          _db.execute(
            '''
UPDATE projects
SET revision = revision + 1,
    updated_at = ?
WHERE project_id = ?;''',
            [_nowEpochMs(), projectId.value],
          );
        }

        return const Ok(null);
      },
      contextMessage: 'Failed to delete part audio take',
    );
  }

  MuseError? _verifyActiveProjectAndPart(ProjectId projectId, PartId partId) {
    try {
      final rows = _db.select(
        '''
SELECT 1
FROM projects p
INNER JOIN project_parts pp ON pp.project_id = p.project_id
WHERE p.project_id = ? AND p.deleted_at IS NULL AND pp.part_id = ?;''',
        [projectId.value, partId.value],
      );
      if (rows.isEmpty) {
        return MuseError(
          MuseErrorCode.entityNotFound,
          'Active project "${projectId.value}" or part "${partId.value}" not found.',
        );
      }
      return null;
    } catch (error) {
      return SqliteErrorMapper.mapException(error);
    }
  }
}

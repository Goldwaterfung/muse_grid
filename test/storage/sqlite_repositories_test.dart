import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/storage/common/sql_asset_library_repository.dart';
import 'package:muse_grid/storage/common/sql_project_repository.dart';
import 'package:muse_grid/storage/common/sqlite_schema_ddl.dart';
import 'package:sqlite3/sqlite3.dart';

final class InMemoryCasBlobStore implements ICasBlobStore {
  final Map<String, Uint8List> stagingFiles = <String, Uint8List>{};
  final Map<String, Uint8List> casBlobs = <String, Uint8List>{};
  bool failNextDelete = false;

  String casKey(Sha256Digest sha256, String ext) =>
      '${SqliteValueCodec.casShardPrefix(sha256)}/${SqliteValueCodec.casFileName(sha256, ext)}';

  @override
  Future<Result<int>> promoteStagingFileToCas({
    required String stagingPath,
    required Sha256Digest expectedSha256,
    required String ext,
  }) async {
    final digestCheck = SqliteValueCodec.validateSha256Hex(expectedSha256);
    if (digestCheck case Err(:final error)) {
      return Err(error);
    }
    final extCheck = SqliteValueCodec.validateCasExt(ext);
    if (extCheck case Err(:final error)) {
      return Err(error);
    }

    final bytes = stagingFiles[stagingPath];
    if (bytes == null || bytes.isEmpty) {
      stagingFiles.remove(stagingPath);
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Missing or empty staging artifact.',
        ),
      );
    }

    final actualSha = sha256.convert(bytes).toString();
    if (actualSha != expectedSha256.value) {
      stagingFiles.remove(stagingPath);
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'SHA-256 mismatch: expected ${expectedSha256.value}, got $actualSha.',
        ),
      );
    }

    casBlobs.putIfAbsent(casKey(expectedSha256, ext), () => bytes);
    stagingFiles.remove(stagingPath);
    return Ok(bytes.length);
  }

  @override
  Future<Result<({Sha256Digest sha256, int byteSize})>> writeStreamToCas({
    required Stream<List<int>> byteStream,
    required int expectedByteLength,
    required String ext,
  }) async {
    final extCheck = SqliteValueCodec.validateCasExt(ext);
    if (extCheck case Err(:final error)) {
      return Err(error);
    }
    if (expectedByteLength <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Expected byte length must be > 0.',
        ),
      );
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in byteStream) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != expectedByteLength) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Stream byte length mismatch: expected $expectedByteLength, '
          'got ${bytes.length}.',
        ),
      );
    }

    final digest = Sha256Digest(sha256.convert(bytes).toString());
    casBlobs.putIfAbsent(casKey(digest, ext), () => bytes);
    return Ok((sha256: digest, byteSize: bytes.length));
  }

  @override
  Future<Result<void>> deleteCasBlob(
    Sha256Digest sha256, {
    required String ext,
  }) async {
    if (failNextDelete) {
      failNextDelete = false;
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Simulated physical CAS unlink failure.',
        ),
      );
    }
    final digestCheck = SqliteValueCodec.validateSha256Hex(sha256);
    if (digestCheck case Err(:final error)) {
      return Err(error);
    }
    final extCheck = SqliteValueCodec.validateCasExt(ext);
    if (extCheck case Err(:final error)) {
      return Err(error);
    }
    casBlobs.remove(casKey(sha256, ext));
    return const Ok(null);
  }
}

void main() {
  late Database db;
  late InMemoryCasBlobStore casStore;

  setUp(() {
    db = sqlite3.openInMemory();
    casStore = InMemoryCasBlobStore();
    final pragmaResult = SqliteSchemaDdl.configureAndVerifyPragmas(
      db,
      isWeb: false,
      allowInMemoryJournalMode: true,
    );
    expect(pragmaResult.isOk, isTrue);
    final migrateResult = SqliteSchemaDdl.applyMigrations(
      db,
      nowEpochMs: () => 1000,
    );
    expect(migrateResult.isOk, isTrue);
  });

  tearDown(() {
    db.close();
  });

  group('Schema DDL, Pragmas, Migrations & Codecs', () {
    test('configureAndVerifyPragmas fails closed on incompatible journal_mode', () {
      final nativeInMem = SqliteSchemaDdl.configureAndVerifyPragmas(
        db,
        isWeb: false,
      );
      expect(nativeInMem, isA<Err<void>>());
      expect(
        (nativeInMem as Err<void>).error.code,
        MuseErrorCode.sqliteJournalModeMismatch,
      );

      final webInMem = SqliteSchemaDdl.configureAndVerifyPragmas(
        db,
        isWeb: true,
      );
      expect(webInMem, isA<Err<void>>());
      expect(
        (webInMem as Err<void>).error.code,
        MuseErrorCode.sqliteJournalModeMismatch,
      );

      final fkRow = db.select('PRAGMA foreign_keys;').first;
      expect(fkRow.values.first, 1);
    });

    test('applyMigrations creates all 14 tables & 11 indexes idempotently', () {
      final tableRows = db.select('''
SELECT name FROM sqlite_master
WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
ORDER BY name;''');
      final tables = tableRows.map((r) => r['name'] as String).toList();
      expect(
        tables,
        equals([
          'audio_takes',
          'clef_events',
          'content_blobs',
          'key_signature_events',
          'latency_calibration_profiles',
          'note_spanners',
          'project_parts',
          'projects',
          'schema_migrations',
          'soundfont_presets',
          'soundfonts',
          'tempo_events',
          'time_signature_events',
          'timeline_notes',
        ]),
      );
      expect(tables.length, 14);

      final indexRows = db.select('''
SELECT name FROM sqlite_master
WHERE type = 'index' AND name LIKE 'idx_%'
ORDER BY name;''');
      final indexes = indexRows.map((r) => r['name'] as String).toList();
      expect(
        indexes,
        equals([
          'idx_key_sig_global',
          'idx_key_sig_part',
          'idx_notes_quantized_part',
          'idx_notes_raw_window',
          'idx_projects_active',
          'idx_soundfonts_blob_sha256',
          'idx_spanners_end_note',
          'idx_spanners_part',
          'idx_spanners_start_note',
          'idx_takes_blob_sha256',
          'idx_takes_project',
        ]),
      );
      expect(indexes.length, 11);

      final versionRows = db.select('SELECT version FROM schema_migrations;');
      expect(versionRows.single['version'], 1);

      // Idempotent re-run succeeds.
      expect(SqliteSchemaDdl.applyMigrations(db).isOk, isTrue);

      // Future schema version fails closed.
      db.execute(
        'INSERT INTO schema_migrations (version, applied_at) VALUES (2, 2000);',
      );
      final futureResult = SqliteSchemaDdl.applyMigrations(db);
      expect(futureResult, isA<Err<void>>());
      expect(
        (futureResult as Err<void>).error.code,
        MuseErrorCode.sqliteConstraintViolation,
      );
    });

    test('STRICT typing, CHECK constraints & partial unique indexes reject invalid rows', () {
      expect(
        () => db.execute(
          '''
INSERT INTO projects (
  project_id, title, ppqn, grid_snap_ticks, pickup_ticks,
  playback_timing_mode, revision, created_at, updated_at
) VALUES ('p1', 'Bad PPQN', 480, 240, 0, 'quantized', 0, 1, 1);''',
        ),
        throwsA(isA<SqliteException>()),
      );

      expect(
        () => db.execute(
          '''
INSERT INTO content_blobs (sha256, ext, mime_type, byte_size, created_at)
VALUES ('short', 'wav', 'audio/wav', 100, 1);''',
        ),
        throwsA(isA<SqliteException>()),
      );

      db.execute(
        '''
INSERT INTO projects (
  project_id, title, ppqn, grid_snap_ticks, pickup_ticks,
  playback_timing_mode, revision, created_at, updated_at
) VALUES ('p1', 'Valid', ${MuseConstants.ppqn}, 240, 0, 'quantized', 0, 1, 1);''',
      );
      db.execute(
        '''
INSERT INTO project_parts (
  part_id, project_id, musicxml_part_id, sort_order, name, staves_count,
  midi_channel, sf_id, bank_num, program_num, gain_db, pan, is_muted,
  is_solo, updated_at
) VALUES ('pt1', 'p1', 'P1', 0, 'Piano', 1, 0, NULL, 0, 0, 0.0, 0.0, 0, 0, 1);''',
      );

      expect(
        () => db.execute(
          '''
INSERT INTO timeline_notes (
  note_id, project_id, part_id, staff_number, voice_number, pitch_midi,
  enharmonic_step, enharmonic_alter, raw_start_tick, raw_duration_ticks,
  quantized_start_tick, quantized_duration_ticks, velocity, updated_at
) VALUES ('n1', 'p1', 'pt1', 1, 1, 128, 'C', 0, 0, 960, 0, 960, 80, 1);''',
        ),
        throwsA(isA<SqliteException>()),
      );

      // Partial unique index: one global key per tick, distinct part key allowed at same tick.
      db.execute(
        '''
INSERT INTO key_signature_events (
  key_event_id, project_id, part_id, staff_number, tick, fifths, mode, updated_at
) VALUES ('k1', 'p1', NULL, 0, 0, 0, 'major', 1);''',
      );
      expect(
        () => db.execute(
          '''
INSERT INTO key_signature_events (
  key_event_id, project_id, part_id, staff_number, tick, fifths, mode, updated_at
) VALUES ('k2', 'p1', NULL, 0, 0, 2, 'major', 1);''',
        ),
        throwsA(isA<SqliteException>()),
      );
      db.execute(
        '''
INSERT INTO key_signature_events (
  key_event_id, project_id, part_id, staff_number, tick, fifths, mode, updated_at
) VALUES ('k3', 'p1', 'pt1', 1, 0, 1, 'minor', 1);''',
      );
    });

    test('ClefSign.tab <-> SQL TAB codec round-trips cleanly', () {
      expect(SqliteValueCodec.clefSignToSql(ClefSign.tab), 'TAB');
      expect(SqliteValueCodec.clefSignFromSql('TAB'), ClefSign.tab);
      for (final sign in ClefSign.values) {
        final sql = SqliteValueCodec.clefSignToSql(sign);
        expect(SqliteValueCodec.clefSignFromSql(sql), sign);
      }
      expect(
        () => SqliteValueCodec.clefSignFromSql('tab'),
        throwsFormatException,
      );
    });

    test('SqliteGarbageCollector purges expired tombstones & unreferenced blobs only', () async {
      final activeBytes = Uint8List.fromList(utf8.encode('active-sf2'));
      final expiredBytes = Uint8List.fromList(utf8.encode('expired-wav'));
      final activeWrite = await casStore.writeStreamToCas(
        byteStream: Stream.value(activeBytes),
        expectedByteLength: activeBytes.length,
        ext: SqliteSchemaDdl.sf2Extension,
      );
      final expiredWrite = await casStore.writeStreamToCas(
        byteStream: Stream.value(expiredBytes),
        expectedByteLength: expiredBytes.length,
        ext: SqliteSchemaDdl.wavExtension,
      );
      final activeSha = (activeWrite as Ok<({Sha256Digest sha256, int byteSize})>).value.sha256;
      final expiredSha = (expiredWrite as Ok<({Sha256Digest sha256, int byteSize})>).value.sha256;

      db.execute(
        '''
INSERT INTO content_blobs (sha256, ext, mime_type, byte_size, created_at)
VALUES (?, 'sf2', 'application/x-soundfont', ?, 100);''',
        [activeSha.value, activeBytes.length],
      );
      db.execute(
        '''
INSERT INTO content_blobs (sha256, ext, mime_type, byte_size, created_at)
VALUES (?, 'wav', 'audio/wav', ?, 100);''',
        [expiredSha.value, expiredBytes.length],
      );
      db.execute(
        '''
INSERT INTO soundfonts (sf_id, name, blob_sha256, format, created_at, updated_at, deleted_at)
VALUES ('sf1', 'Active', ?, 'sf2', 100, 100, NULL);''',
        [activeSha.value],
      );
      db.execute(
        '''
INSERT INTO projects (
  project_id, title, ppqn, grid_snap_ticks, pickup_ticks,
  playback_timing_mode, revision, created_at, updated_at, deleted_at
) VALUES ('p-old', 'Deleted', 960, 240, 0, 'quantized', 0, 100, 100, 500);''',
      );
      db.execute(
        '''
INSERT INTO project_parts (
  part_id, project_id, musicxml_part_id, sort_order, name, staves_count,
  midi_channel, sf_id, bank_num, program_num, gain_db, pan, is_muted,
  is_solo, updated_at
) VALUES ('pt-old', 'p-old', 'P1', 0, 'Voice', 1, 0, NULL, 0, 0, 0.0, 0.0, 0, 0, 100);''',
      );
      db.execute(
        '''
INSERT INTO audio_takes (
  take_id, project_id, part_id, blob_sha256, start_tick, sample_rate,
  channel_count, duration_frames, captured_playhead_frame, captured_sample_clock,
  output_buffer_frames, input_buffer_frames, calibration_offset_frames,
  created_at, updated_at
) VALUES ('t-old', 'p-old', 'pt-old', ?, 0, 48000, 1, 480, 0, 0, 128, 128, 0, 100, 100);''',
        [expiredSha.value],
      );

      final gcResult = await SqliteGarbageCollector.runGarbageCollection(
        db: db,
        casStore: casStore,
        olderThanEpochMs: 1000,
      );
      expect(gcResult, isA<Ok<int>>());
      expect((gcResult as Ok<int>).value, expiredBytes.length);
      expect(casStore.casBlobs.containsKey(casStore.casKey(expiredSha, 'wav')), isFalse);
      expect(casStore.casBlobs.containsKey(casStore.casKey(activeSha, 'sf2')), isTrue);
    });
  });

  group('SqlProjectRepository', () {
    late int clockMs;
    late int idCounter;
    late SqlProjectRepository projectRepo;

    setUp(() {
      clockMs = 10000;
      idCounter = 0;
      projectRepo = SqlProjectRepository(
        db: db,
        casStore: casStore,
        nowEpochMs: () => ++clockMs,
        generateUuidV7: () => '01950000-0000-7000-8000-${(++idCounter).toString().padLeft(12, '0')}',
      );
    });

    test('createProject, listActiveProjects & loadProjectAggregate bootstrap defaults', () async {
      final p1 = await projectRepo.createProject(
        const CreateProjectInput(
          projectId: ProjectId('proj-1'),
          title: 'First Score',
          gridSnapTicks: MuseConstants.sixteenthNoteTicks,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      );
      expect(p1, isA<Ok<ProjectSummary>>());
      expect((p1 as Ok<ProjectSummary>).value.revision, 0);

      final p2 = await projectRepo.createProject(
        const CreateProjectInput(
          projectId: ProjectId('proj-2'),
          title: 'Second Score',
          gridSnapTicks: MuseConstants.eighthNoteTicks,
          pickupTicks: MuseConstants.quarterNoteTicks,
          playbackTimingMode: PlaybackTimingMode.raw,
          initialUsPerQuarter: 600000,
          initialTimeSigNumerator: 3,
          initialTimeSigDenominator: 4,
        ),
      );
      expect(p2, isA<Ok<ProjectSummary>>());

      final listResult = await projectRepo.listActiveProjects(limit: 10, offset: 0);
      expect(listResult, isA<Ok<List<ProjectSummary>>>());
      final list = (listResult as Ok<List<ProjectSummary>>).value;
      expect(list.map((e) => e.projectId.value), equals(['proj-2', 'proj-1']));

      final aggResult = await projectRepo.loadProjectAggregate(const ProjectId('proj-2'));
      expect(aggResult, isA<Ok<ProjectWorkspaceAggregate>>());
      final agg = (aggResult as Ok<ProjectWorkspaceAggregate>).value;
      expect(agg.project.pickupTicks, MuseConstants.quarterNoteTicks);
      expect(agg.project.playbackTimingMode, PlaybackTimingMode.raw);
      expect(agg.parts.length, 1);
      expect(agg.tempoEvents.single.tick.value, 0);
      expect(agg.timeSignatureEvents.single.tick.value, 0);
      expect(agg.keySignatureEvents.single.partId, isNull);
      expect(agg.clefEvents.single.sign, ClefSign.G);
    });

    test('updateProjectMetadata & softDeleteProject enforce revision & active checks', () async {
      await projectRepo.createProject(
        const CreateProjectInput(
          projectId: ProjectId('proj-meta'),
          title: 'Initial',
          gridSnapTicks: 240,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      );

      final stale = await projectRepo.updateProjectMetadata(
        const UpdateProjectMetadataInput(
          projectId: ProjectId('proj-meta'),
          expectedRevision: 99,
          title: 'Stale',
        ),
      );
      expect((stale as Err<void>).error.code, MuseErrorCode.revisionConflict);

      final updated = await projectRepo.updateProjectMetadata(
        const UpdateProjectMetadataInput(
          projectId: ProjectId('proj-meta'),
          expectedRevision: 0,
          title: 'Renamed',
          playbackTimingMode: PlaybackTimingMode.raw,
        ),
      );
      expect(updated.isOk, isTrue);

      final agg = (await projectRepo.loadProjectAggregate(const ProjectId('proj-meta'))
              as Ok<ProjectWorkspaceAggregate>)
          .value;
      expect(agg.project.revision, 1);
      expect(agg.project.title, 'Renamed');
      expect(agg.project.playbackTimingMode, PlaybackTimingMode.raw);

      final deleted = await projectRepo.softDeleteProject(
        const ProjectId('proj-meta'),
        deletedAtMs: 20000,
      );
      expect(deleted.isOk, isTrue);
      expect(
        (await projectRepo.listActiveProjects(limit: 10, offset: 0)
                as Ok<List<ProjectSummary>>)
            .value,
        isEmpty,
      );
      expect(
        ((await projectRepo.loadProjectAggregate(const ProjectId('proj-meta')))
                as Err<ProjectWorkspaceAggregate>)
            .error
            .code,
        MuseErrorCode.entityNotFound,
      );
    });

    test('commitScoreMutationBatch handles notes, spanners, ClefSign.tab, conflicts & tick==0 guard', () async {
      await projectRepo.createProject(
        const CreateProjectInput(
          projectId: ProjectId('proj-batch'),
          title: 'Batch Project',
          gridSnapTicks: 240,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      );
      final initialAgg = (await projectRepo.loadProjectAggregate(
        const ProjectId('proj-batch'),
      ) as Ok<ProjectWorkspaceAggregate>)
          .value;
      final partId = initialAgg.parts.single.partId;
      final initialTempoId = initialAgg.tempoEvents.single.tempoEventId;
      final initialTsId = initialAgg.timeSignatureEvents.single.tsEventId;

      final n1 = TimelineNote(
        noteId: const NoteId('n1'),
        projectId: const ProjectId('proj-batch'),
        partId: partId,
        staffNumber: 1,
        voiceNumber: 1,
        pitchMidi: 60,
        enharmonicStep: EnharmonicStep.C,
        enharmonicAlter: 0,
        rawStartTick: const Tick(0),
        rawDurationTicks: 960,
        quantizedStartTick: const Tick(0),
        quantizedDurationTicks: 960,
        velocity: 90,
        updatedAtMs: 11000,
      );
      final n2 = TimelineNote(
        noteId: const NoteId('n2'),
        projectId: const ProjectId('proj-batch'),
        partId: partId,
        staffNumber: 1,
        voiceNumber: 1,
        pitchMidi: 62,
        enharmonicStep: EnharmonicStep.D,
        enharmonicAlter: 0,
        rawStartTick: const Tick(960),
        rawDurationTicks: 960,
        quantizedStartTick: const Tick(960),
        quantizedDurationTicks: 960,
        velocity: 90,
        updatedAtMs: 11000,
      );

      final commitOk = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-batch'),
          expectedRevision: 0,
          upsertClefEvents: [
            ClefEventEntity(
              clefEventId: const ClefEventId('clef-tab'),
              projectId: const ProjectId('proj-batch'),
              partId: partId,
              staffNumber: 1,
              tick: const Tick(960),
              sign: ClefSign.tab,
              line: 3,
              octaveChange: 0,
              updatedAtMs: 11000,
            ),
          ],
          upsertNotes: [n1, n2],
          upsertSpanners: [
            NoteSpannerEntity(
              spannerId: const SpannerId('sp1'),
              projectId: const ProjectId('proj-batch'),
              partId: partId,
              spannerType: SpannerType.slur,
              startNoteId: n1.noteId,
              endNoteId: n2.noteId,
              spannerLevel: 1,
              placement: SpannerPlacement.above,
              updatedAtMs: 11000,
            ),
          ],
        ),
      );
      expect((commitOk as Ok<int>).value, 1);

      final afterFirst = (await projectRepo.loadProjectAggregate(
        const ProjectId('proj-batch'),
      ) as Ok<ProjectWorkspaceAggregate>)
          .value;
      expect(afterFirst.clefEvents.map((e) => e.sign), contains(ClefSign.tab));
      expect(afterFirst.notes.length, 2);
      expect(afterFirst.spanners.single.placement, SpannerPlacement.above);

      // Stale revision fails closed without partial writes.
      final conflict = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-batch'),
          expectedRevision: 0,
          deleteNoteIds: const [NoteId('n2')],
        ),
      );
      expect((conflict as Err<int>).error.code, MuseErrorCode.revisionConflict);

      // Deleting tick==0 tempo or time signature fails closed.
      final delTempoZero = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-batch'),
          expectedRevision: 1,
          deleteTempoEventIds: [initialTempoId],
        ),
      );
      expect(
        (delTempoZero as Err<int>).error.code,
        MuseErrorCode.protectedInitialMapEvent,
      );

      final delTsZero = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-batch'),
          expectedRevision: 1,
          deleteTimeSignatureEventIds: [initialTsId],
        ),
      );
      expect(
        (delTsZero as Err<int>).error.code,
        MuseErrorCode.protectedInitialMapEvent,
      );

      // Moving tick==0 tempo event away from tick 0 also fails closed.
      final moveTempoZero = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-batch'),
          expectedRevision: 1,
          upsertTempoEvents: [
            TempoEventEntity(
              tempoEventId: initialTempoId,
              projectId: const ProjectId('proj-batch'),
              tick: const Tick(960),
              usPerQuarter: 400000,
              updatedAtMs: 12000,
            ),
          ],
        ),
      );
      expect(
        (moveTempoZero as Err<int>).error.code,
        MuseErrorCode.protectedInitialMapEvent,
      );

      // Simultaneous replacement of tick==0 tempo event succeeds.
      final replaceTempoZero = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-batch'),
          expectedRevision: 1,
          deleteTempoEventIds: [initialTempoId],
          upsertTempoEvents: [
            TempoEventEntity(
              tempoEventId: const TempoEventId('tempo-zero-replacement'),
              projectId: const ProjectId('proj-batch'),
              tick: const Tick(0),
              usPerQuarter: 480000,
              updatedAtMs: 12000,
            ),
          ],
        ),
      );
      expect((replaceTempoZero as Ok<int>).value, 2);

      // Tick-0 swap without deletion succeeds regardless of upsert order.
      final moveAndInsertZero = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-batch'),
          expectedRevision: 2,
          upsertTempoEvents: [
            TempoEventEntity(
              tempoEventId: const TempoEventId('tempo-zero-next'),
              projectId: const ProjectId('proj-batch'),
              tick: const Tick(0),
              usPerQuarter: 420000,
              updatedAtMs: 12500,
            ),
            TempoEventEntity(
              tempoEventId: const TempoEventId('tempo-zero-replacement'),
              projectId: const ProjectId('proj-batch'),
              tick: const Tick(480),
              usPerQuarter: 480000,
              updatedAtMs: 12500,
            ),
          ],
          upsertTimeSignatureEvents: [
            TimeSignatureEventEntity(
              tsEventId: const TimeSigEventId('ts-zero-next'),
              projectId: const ProjectId('proj-batch'),
              tick: const Tick(0),
              numerator: 3,
              denominator: 4,
              updatedAtMs: 12500,
            ),
            TimeSignatureEventEntity(
              tsEventId: initialTsId,
              projectId: const ProjectId('proj-batch'),
              tick: const Tick(960),
              numerator: 4,
              denominator: 4,
              updatedAtMs: 12500,
            ),
          ],
        ),
      );
      expect((moveAndInsertZero as Ok<int>).value, 3);

      // Direct two-row swap between tick==0 and tick>0 also succeeds without delete.
      final swapBackZero = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-batch'),
          expectedRevision: 3,
          upsertTempoEvents: [
            TempoEventEntity(
              tempoEventId: const TempoEventId('tempo-zero-replacement'),
              projectId: const ProjectId('proj-batch'),
              tick: const Tick(0),
              usPerQuarter: 480000,
              updatedAtMs: 12600,
            ),
            TempoEventEntity(
              tempoEventId: const TempoEventId('tempo-zero-next'),
              projectId: const ProjectId('proj-batch'),
              tick: const Tick(480),
              usPerQuarter: 420000,
              updatedAtMs: 12600,
            ),
          ],
        ),
      );
      expect((swapBackZero as Ok<int>).value, 4);

      // Deleting a note cascades to its spanner.
      final cascadeDelete = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-batch'),
          expectedRevision: 4,
          deleteNoteIds: const [NoteId('n2')],
        ),
      );
      expect((cascadeDelete as Ok<int>).value, 5);
      final afterDelete = (await projectRepo.loadProjectAggregate(
        const ProjectId('proj-batch'),
      ) as Ok<ProjectWorkspaceAggregate>)
          .value;
      expect(afterDelete.notes.map((e) => e.noteId.value), equals(['n1']));
      expect(afterDelete.spanners, isEmpty);
    });

    test('commitScoreMutationBatch rejects cross-project primary key collisions without mutating other project', () async {
      await projectRepo.createProject(
        const CreateProjectInput(
          projectId: ProjectId('proj-a'),
          title: 'Project A',
          gridSnapTicks: 240,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      );
      await projectRepo.createProject(
        const CreateProjectInput(
          projectId: ProjectId('proj-b'),
          title: 'Project B',
          gridSnapTicks: 240,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      );

      final aggA = (await projectRepo.loadProjectAggregate(
        const ProjectId('proj-a'),
      ) as Ok<ProjectWorkspaceAggregate>)
          .value;
      final aggB = (await projectRepo.loadProjectAggregate(
        const ProjectId('proj-b'),
      ) as Ok<ProjectWorkspaceAggregate>)
          .value;
      final partA = aggA.parts.single;
      final partB = aggB.parts.single;

      // Seed a note in Project A.
      final seedA = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-a'),
          expectedRevision: 0,
          upsertNotes: [
            TimelineNote(
              noteId: const NoteId('shared-note-id'),
              projectId: const ProjectId('proj-a'),
              partId: partA.partId,
              staffNumber: 1,
              voiceNumber: 1,
              pitchMidi: 60,
              enharmonicStep: EnharmonicStep.C,
              enharmonicAlter: 0,
              rawStartTick: const Tick(0),
              rawDurationTicks: 960,
              quantizedStartTick: const Tick(0),
              quantizedDurationTicks: 960,
              velocity: 90,
              updatedAtMs: 11000,
            ),
          ],
        ),
      );
      expect((seedA as Ok<int>).value, 1);

      // Project B attempting to upsert using Project A's note_id or part_id must fail closed.
      final collideNote = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-b'),
          expectedRevision: 0,
          upsertNotes: [
            TimelineNote(
              noteId: const NoteId('shared-note-id'),
              projectId: const ProjectId('proj-b'),
              partId: partB.partId,
              staffNumber: 1,
              voiceNumber: 1,
              pitchMidi: 72,
              enharmonicStep: EnharmonicStep.C,
              enharmonicAlter: 0,
              rawStartTick: const Tick(0),
              rawDurationTicks: 480,
              quantizedStartTick: const Tick(0),
              quantizedDurationTicks: 480,
              velocity: 110,
              updatedAtMs: 12000,
            ),
          ],
        ),
      );
      expect(
        (collideNote as Err<int>).error.code,
        MuseErrorCode.sqliteConstraintViolation,
      );

      final collidePart = await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-b'),
          expectedRevision: 0,
          upsertParts: [
            ProjectPartEntity(
              partId: partA.partId,
              projectId: const ProjectId('proj-b'),
              musicXmlPartId: 'P2',
              sortOrder: 1,
              name: 'Hijacked',
              stavesCount: 1,
              midiChannel: 1,
              sfId: null,
              bankNum: 0,
              programNum: 0,
              gainDb: 0.0,
              pan: 0.0,
              isMuted: false,
              isSolo: false,
              updatedAtMs: 12000,
            ),
          ],
        ),
      );
      expect(
        (collidePart as Err<int>).error.code,
        MuseErrorCode.sqliteConstraintViolation,
      );

      // Project A's note, part, and revision remain untouched.
      final afterA = (await projectRepo.loadProjectAggregate(
        const ProjectId('proj-a'),
      ) as Ok<ProjectWorkspaceAggregate>)
          .value;
      expect(afterA.project.revision, 1);
      expect(afterA.parts.single.name, partA.name);
      expect(afterA.notes.single.pitchMidi, 60);
    });

    test('promoteAndCommitRecordedTake, realignAudioTakesCalibration & deletePartAudioTake', () async {
      await projectRepo.createProject(
        const CreateProjectInput(
          projectId: ProjectId('proj-take'),
          title: 'Audio Project',
          gridSnapTicks: 240,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      );
      final partId = (await projectRepo.loadProjectAggregate(
        const ProjectId('proj-take'),
      ) as Ok<ProjectWorkspaceAggregate>)
          .value
          .parts
          .single
          .partId;

      final wav1 = Uint8List.fromList(utf8.encode('RIFF-take-1'));
      final sha1 = Sha256Digest(sha256.convert(wav1).toString());
      casStore.stagingFiles['/staging/rec_t1.wav.part'] = wav1;

      // Bad digest fails closed before touching SQLite.
      final badTake = await projectRepo.promoteAndCommitRecordedTake(
        receipt: RecordingCaptureReceipt(
          takeId: const TakeId('t-bad'),
          stagingPath: '/staging/rec_t1.wav.part',
          sha256: Sha256Digest('0' * 64),
          capturedSampleClock: const SampleFrame(100),
          capturedPlayheadFrame: const SampleFrame(0),
          durationFrames: 48000,
          sampleRate: 48000,
          channelCount: 1,
          outputBufferFrames: 128,
          inputBufferFrames: 128,
        ),
        projectId: const ProjectId('proj-take'),
        partId: partId,
        alignedStartTick: const Tick(0),
        calibrationOffsetFrames: -64,
      );
      expect((badTake as Err<AudioTakeEntity>).error.code, MuseErrorCode.casPromotionFailed);
      expect(
        (await projectRepo.loadProjectAggregate(const ProjectId('proj-take'))
                as Ok<ProjectWorkspaceAggregate>)
            .value
            .audioTakes,
        isEmpty,
      );

      // Re-stage valid take 1 and promote.
      casStore.stagingFiles['/staging/rec_t1.wav.part'] = wav1;
      final okTake1 = await projectRepo.promoteAndCommitRecordedTake(
        receipt: RecordingCaptureReceipt(
          takeId: const TakeId('t1'),
          stagingPath: '/staging/rec_t1.wav.part',
          sha256: sha1,
          capturedSampleClock: const SampleFrame(100),
          capturedPlayheadFrame: const SampleFrame(0),
          durationFrames: 48000,
          sampleRate: 48000,
          channelCount: 1,
          outputBufferFrames: 128,
          inputBufferFrames: 128,
        ),
        projectId: const ProjectId('proj-take'),
        partId: partId,
        alignedStartTick: const Tick(0),
        calibrationOffsetFrames: -64,
      );
      expect(okTake1, isA<Ok<AudioTakeEntity>>());

      // Overwrite same (projectId, partId) with take 2.
      final wav2 = Uint8List.fromList(utf8.encode('RIFF-take-2'));
      final sha2 = Sha256Digest(sha256.convert(wav2).toString());
      casStore.stagingFiles['/staging/rec_t2.wav.part'] = wav2;
      final okTake2 = await projectRepo.promoteAndCommitRecordedTake(
        receipt: RecordingCaptureReceipt(
          takeId: const TakeId('t2'),
          stagingPath: '/staging/rec_t2.wav.part',
          sha256: sha2,
          capturedSampleClock: const SampleFrame(500),
          capturedPlayheadFrame: const SampleFrame(24000),
          durationFrames: 48000,
          sampleRate: 48000,
          channelCount: 2,
          outputBufferFrames: 128,
          inputBufferFrames: 128,
        ),
        projectId: const ProjectId('proj-take'),
        partId: partId,
        alignedStartTick: const Tick(960),
        calibrationOffsetFrames: -32,
      );
      expect(okTake2, isA<Ok<AudioTakeEntity>>());

      // Realign calibration updates start_tick & calibration_offset_frames.
      final realigned = await projectRepo.realignAudioTakesCalibration(
        projectId: const ProjectId('proj-take'),
        updates: const [
          AudioTakeRealignmentUpdate(
            takeId: TakeId('t2'),
            newStartTick: Tick(1020),
            newCalibrationOffsetFrames: -96,
          ),
        ],
      );
      expect(realigned, isA<Ok<List<AudioTakeEntity>>>());
      final takeRow = (realigned as Ok<List<AudioTakeEntity>>).value.single;
      expect(takeRow.takeId, const TakeId('t2'));
      expect(takeRow.startTick, const Tick(1020));
      expect(takeRow.calibrationOffsetFrames, -96);

      // Delete take removes row cleanly.
      final deleted = await projectRepo.deletePartAudioTake(
        projectId: const ProjectId('proj-take'),
        partId: partId,
      );
      expect(deleted.isOk, isTrue);
      expect(
        (await projectRepo.loadProjectAggregate(const ProjectId('proj-take'))
                as Ok<ProjectWorkspaceAggregate>)
            .value
            .audioTakes,
        isEmpty,
      );
    });
  });

  group('SqlAssetLibraryRepository & End-to-End Mark-and-Sweep GC', () {
    late int clockMs;
    late int idCounter;
    late SqlProjectRepository projectRepo;
    late SqlAssetLibraryRepository assetRepo;

    setUp(() {
      clockMs = 50000;
      idCounter = 0;
      projectRepo = SqlProjectRepository(
        db: db,
        casStore: casStore,
        nowEpochMs: () => ++clockMs,
        generateUuidV7: () => '01960000-0000-7000-8000-${(++idCounter).toString().padLeft(12, '0')}',
      );
      assetRepo = SqlAssetLibraryRepository(
        db: db,
        casStore: casStore,
        nowEpochMs: () => ++clockMs,
        generateUuidV7: () => '01960000-0000-7000-9000-${(++idCounter).toString().padLeft(12, '0')}',
      );
    });

    test('importSoundFontBytes deduplicates SHA-256, restores tombstones & softDelete clears sf_id', () async {
      final sfBytes = Uint8List.fromList(utf8.encode('RIFFsfbk-demo-sf2'));
      final imported1 = await assetRepo.importSoundFontBytes(
        displayName: 'Grand Piano',
        byteStream: Stream.fromIterable([sfBytes.sublist(0, 6), sfBytes.sublist(6)]),
        byteLength: sfBytes.length,
        extractedPresets: const [
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Acoustic Grand'),
          SoundFontPresetInfo(bankNum: 0, programNum: 1, presetName: 'Bright Piano'),
        ],
      );
      expect(imported1, isA<Ok<SoundFontCatalogEntry>>());
      final entry1 = (imported1 as Ok<SoundFontCatalogEntry>).value;
      expect(entry1.presets.length, 2);

      // Re-importing identical bytes reuses existing sf_id & updates name/presets.
      final importedDup = await assetRepo.importSoundFontBytes(
        displayName: 'Grand Piano v2',
        byteStream: Stream.value(sfBytes),
        byteLength: sfBytes.length,
        extractedPresets: const [
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Concert Grand'),
        ],
      );
      final entryDup = (importedDup as Ok<SoundFontCatalogEntry>).value;
      expect(entryDup.sfId, entry1.sfId);
      expect(entryDup.name, 'Grand Piano v2');
      expect(entryDup.presets.single.presetName, 'Concert Grand');

      // Assign SoundFont to a project part, then soft-delete the SoundFont.
      await projectRepo.createProject(
        const CreateProjectInput(
          projectId: ProjectId('proj-sf'),
          title: 'SF Link Test',
          gridSnapTicks: 240,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      );
      final part = (await projectRepo.loadProjectAggregate(const ProjectId('proj-sf'))
              as Ok<ProjectWorkspaceAggregate>)
          .value
          .parts
          .single;
      await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-sf'),
          expectedRevision: 0,
          upsertParts: [
            ProjectPartEntity(
              partId: part.partId,
              projectId: part.projectId,
              musicXmlPartId: part.musicXmlPartId,
              sortOrder: part.sortOrder,
              name: part.name,
              stavesCount: part.stavesCount,
              midiChannel: part.midiChannel,
              sfId: entry1.sfId,
              bankNum: 0,
              programNum: 0,
              gainDb: 0.0,
              pan: 0.0,
              isMuted: false,
              isSolo: false,
              updatedAtMs: 55000,
            ),
          ],
        ),
      );

      final softDel = await assetRepo.softDeleteSoundFont(
        entry1.sfId,
        deletedAtMs: 60000,
      );
      expect(softDel.isOk, isTrue);
      expect(
        (await assetRepo.listActiveSoundFonts() as Ok<List<SoundFontCatalogEntry>>)
            .value,
        isEmpty,
      );
      final clearedPart = (await projectRepo.loadProjectAggregate(
        const ProjectId('proj-sf'),
      ) as Ok<ProjectWorkspaceAggregate>)
          .value
          .parts
          .single;
      expect(clearedPart.sfId, isNull);

      // Re-importing same SHA-256 restores the soft-deleted SoundFont row.
      final restored = await assetRepo.importSoundFontBytes(
        displayName: 'Restored Grand',
        byteStream: Stream.value(sfBytes),
        byteLength: sfBytes.length,
        extractedPresets: const [
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Restored Preset'),
        ],
      );
      final restoredEntry = (restored as Ok<SoundFontCatalogEntry>).value;
      expect(restoredEntry.sfId, entry1.sfId);
      expect(
        (await assetRepo.listActiveSoundFonts() as Ok<List<SoundFontCatalogEntry>>)
            .value
            .single
            .name,
        'Restored Grand',
      );
    });

    test('getCalibrationProfile & upsertCalibrationProfile preserve profileId on update', () async {
      final missing = await assetRepo.getCalibrationProfile(
        platform: CalibrationPlatform.macos,
        deviceFingerprint: 'BuiltInSpeaker',
        sampleRate: 48000,
        bufferSizeFrames: 256,
      );
      expect((missing as Ok<LatencyCalibrationProfile?>).value, isNull);

      final first = await assetRepo.upsertCalibrationProfile(
        const UpsertCalibrationProfileInput(
          platform: CalibrationPlatform.macos,
          deviceFingerprint: 'BuiltInSpeaker',
          sampleRate: 48000,
          bufferSizeFrames: 256,
          calibrationOffsetFrames: -120,
        ),
      );
      final profile1 = (first as Ok<LatencyCalibrationProfile>).value;
      expect(profile1.calibrationOffsetFrames, -120);

      final second = await assetRepo.upsertCalibrationProfile(
        const UpsertCalibrationProfileInput(
          platform: CalibrationPlatform.macos,
          deviceFingerprint: 'BuiltInSpeaker',
          sampleRate: 48000,
          bufferSizeFrames: 256,
          calibrationOffsetFrames: -96,
        ),
      );
      final profile2 = (second as Ok<LatencyCalibrationProfile>).value;
      expect(profile2.profileId, profile1.profileId);
      expect(profile2.calibrationOffsetFrames, -96);

      final fetched = await assetRepo.getCalibrationProfile(
        platform: CalibrationPlatform.macos,
        deviceFingerprint: 'BuiltInSpeaker',
        sampleRate: 48000,
        bufferSizeFrames: 256,
      );
      expect((fetched as Ok<LatencyCalibrationProfile?>).value?.calibrationOffsetFrames, -96);
    });

    test('GC retains non-expired tombstones and sweeps only expired blobs', () async {
      final keptSfBytes = Uint8List.fromList(utf8.encode('kept-sf2-data'));
      final recentDelSfBytes = Uint8List.fromList(utf8.encode('recent-del-sf2'));
      final oldDelSfBytes = Uint8List.fromList(utf8.encode('old-del-sf2'));

      final keptSf = (await assetRepo.importSoundFontBytes(
        displayName: 'Kept SF',
        byteStream: Stream.value(keptSfBytes),
        byteLength: keptSfBytes.length,
        extractedPresets: const [],
      ) as Ok<SoundFontCatalogEntry>)
          .value;

      final recentSf = (await assetRepo.importSoundFontBytes(
        displayName: 'Recent Deleted SF',
        byteStream: Stream.value(recentDelSfBytes),
        byteLength: recentDelSfBytes.length,
        extractedPresets: const [],
      ) as Ok<SoundFontCatalogEntry>)
          .value;
      await assetRepo.softDeleteSoundFont(recentSf.sfId, deletedAtMs: 9000);

      final oldSf = (await assetRepo.importSoundFontBytes(
        displayName: 'Old Deleted SF',
        byteStream: Stream.value(oldDelSfBytes),
        byteLength: oldDelSfBytes.length,
        extractedPresets: const [],
      ) as Ok<SoundFontCatalogEntry>)
          .value;
      await assetRepo.softDeleteSoundFont(oldSf.sfId, deletedAtMs: 2000);

      final gcResult = await SqliteGarbageCollector.runGarbageCollection(
        db: db,
        casStore: casStore,
        olderThanEpochMs: 5000,
      );
      expect((gcResult as Ok<int>).value, oldDelSfBytes.length);
      expect(
        casStore.casBlobs.containsKey(casStore.casKey(keptSf.blobSha256, 'sf2')),
        isTrue,
      );
      expect(
        casStore.casBlobs.containsKey(casStore.casKey(recentSf.blobSha256, 'sf2')),
        isTrue,
      );
      expect(
        casStore.casBlobs.containsKey(casStore.casKey(oldSf.blobSha256, 'sf2')),
        isFalse,
      );
    });

    test('GC continues unlinking remaining blobs if one physical unlink fails', () async {
      final sfABytes = Uint8List.fromList(utf8.encode('gc-best-effort-sf-a'));
      final sfBBytes = Uint8List.fromList(utf8.encode('gc-best-effort-sf-b'));

      final sfA = (await assetRepo.importSoundFontBytes(
        displayName: 'GC Fail A',
        byteStream: Stream.value(sfABytes),
        byteLength: sfABytes.length,
        extractedPresets: const [],
      ) as Ok<SoundFontCatalogEntry>)
          .value;
      final sfB = (await assetRepo.importSoundFontBytes(
        displayName: 'GC Succeed B',
        byteStream: Stream.value(sfBBytes),
        byteLength: sfBBytes.length,
        extractedPresets: const [],
      ) as Ok<SoundFontCatalogEntry>)
          .value;

      await assetRepo.softDeleteSoundFont(sfA.sfId, deletedAtMs: 1000);
      await assetRepo.softDeleteSoundFont(sfB.sfId, deletedAtMs: 1000);

      casStore.failNextDelete = true;
      final gcErr = await SqliteGarbageCollector.runGarbageCollection(
        db: db,
        casStore: casStore,
        olderThanEpochMs: 5000,
      );
      expect(gcErr, isA<Err<int>>());
      expect(
        (gcErr as Err<int>).error.code,
        MuseErrorCode.casPromotionFailed,
      );
      // Only the single failed blob remains on disk; the sibling was unlinked.
      expect(casStore.casBlobs.length, 1);
    });
  });
}

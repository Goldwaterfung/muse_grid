/// Shared SQLite schema DDL, pragma/migration guards, codecs, error mapping,
/// and Mark-and-Sweep CAS garbage collection for Native and Web storage.
library;

import 'package:sqlite3/common.dart';

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';

/// Platform-agnostic Content-Addressed Storage (CAS) seam injected into
/// shared SQLite repositories (`SqlProjectRepository`, `SqlAssetLibraryRepository`).
abstract interface class ICasBlobStore {
  /// Verifies the finalized staging artifact against [expectedSha256], promotes
  /// it atomically to `cas/<aa>/<sha256>.<ext>` (idempotent if already present,
  /// still unlinking [stagingPath]), and returns the verified byte length.
  ///
  /// Deletes corrupt staging `.part` artifacts and returns
  /// `Err(MuseErrorCode.casPromotionFailed)` if missing, empty, unreadable, or
  /// failing SHA-256 verification.
  Future<Result<int>> promoteStagingFileToCas({
    required String stagingPath,
    required Sha256Digest expectedSha256,
    required String ext,
  });

  /// Streams [byteStream] into a staging `.part` file while hashing SHA-256 on
  /// the fly, verifies byte count matches [expectedByteLength] (`> 0`) and
  /// platform caps, promotes atomically to `cas/<aa>/<sha256>.<ext>`, and
  /// cleans up staging `.part` on error.
  Future<Result<({Sha256Digest sha256, int byteSize})>> writeStreamToCas({
    required Stream<List<int>> byteStream,
    required int expectedByteLength,
    required String ext,
  });

  /// Deletes `cas/<aa>/<sha256>.<ext>` if present (idempotent if already absent).
  Future<Result<void>> deleteCasBlob(
    Sha256Digest sha256, {
    required String ext,
  });
}

/// Canonical v1 `STRICT` SQLite DDL, pragma setup, and migration runner.
abstract final class SqliteSchemaDdl {
  static const int currentSchemaVersion = 1;
  static const int sha256HexLength = 64;
  static const int millisPerSecond = 1000;
  static const int _sqliteFullResultCode = 13;

  // Pragma modes & values
  static const String nativeJournalMode = 'wal';
  static const String webTargetJournalMode = 'delete';
  static const String inMemoryJournalMode = 'memory';
  static const Set<String> webAllowedJournalModes = {'delete', 'truncate'};
  static const String sqliteSynchronousNormal = 'NORMAL';
  static const int _foreignKeysEnabledFlag = 1;

  // CAS & asset constants
  static const String wavExtension = 'wav';
  static const String sf2Extension = 'sf2';
  static const Set<String> supportedCasExtensions = {wavExtension, sf2Extension};
  static const String wavMimeType = 'audio/wav';
  static const String sf2MimeType = 'application/x-soundfont';
  static const String partFileSuffix = '.part';
  static const String recordingFilePrefix = 'rec_';

  // Default project bootstrap constants (`createProject`)
  static const String defaultMusicXmlPartId = 'P1';
  static const String defaultPartName = 'Part 1';
  static const int defaultPartSortOrder = 0;
  static const int defaultPartStavesCount = 1;
  static const int defaultPartMidiChannel = MuseConstants.minMidiChannel;
  static const int defaultPartBankNum = MuseConstants.minBankNum;
  static const int defaultPartProgramNum = MuseConstants.minProgramNum;
  static const double defaultPartGainDb = 0.0;
  static const double defaultPartPan = 0.0;
  static const int defaultGlobalKeyStaffNumber = 0;
  static const int defaultKeySignatureFifths = 0;
  static const int defaultClefStaffNumber = 1;
  static const int defaultClefLine = 2;
  static const int defaultClefOctaveChange = 0;
  static const String defaultClefSignSql = 'G';
  static const String defaultKeyModeSql = 'major';
  static const int minTick = 0;
  static const Set<int> validTimeSigDenominators = {1, 2, 4, 8, 16, 32, 64};

  static const String _createSchemaMigrationsTableSql = '''
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     INTEGER PRIMARY KEY CHECK (version > 0),
    applied_at  INTEGER NOT NULL
) STRICT;''';

  /// All 14 `STRICT` tables and 11 indexes in topological FK creation order.
  static final List<String> createSchemaStatements = List<String>.unmodifiable([
    // 1. schema_migrations
    '''
CREATE TABLE schema_migrations (
    version     INTEGER PRIMARY KEY CHECK (version > 0),
    applied_at  INTEGER NOT NULL
) STRICT;''',
    // 2. content_blobs
    '''
CREATE TABLE content_blobs (
    sha256      TEXT PRIMARY KEY CHECK (length(sha256) = 64),
    ext         TEXT NOT NULL CHECK (ext IN ('sf2', 'wav')),
    mime_type   TEXT NOT NULL,
    byte_size   INTEGER NOT NULL CHECK (byte_size > 0),
    created_at  INTEGER NOT NULL
) STRICT;''',
    // 3. soundfonts
    '''
CREATE TABLE soundfonts (
    sf_id        TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    blob_sha256  TEXT NOT NULL REFERENCES content_blobs(sha256) ON DELETE RESTRICT,
    format       TEXT NOT NULL CHECK (format = 'sf2'),
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    deleted_at   INTEGER
) STRICT;''',
    // 4. idx_soundfonts_blob_sha256
    '''
CREATE INDEX idx_soundfonts_blob_sha256
    ON soundfonts(blob_sha256);''',
    // 5. soundfont_presets
    '''
CREATE TABLE soundfont_presets (
    sf_id        TEXT NOT NULL REFERENCES soundfonts(sf_id) ON DELETE CASCADE,
    bank_num     INTEGER NOT NULL CHECK (bank_num >= 0),
    program_num  INTEGER NOT NULL CHECK (program_num BETWEEN 0 AND 127),
    preset_name  TEXT NOT NULL,
    PRIMARY KEY (sf_id, bank_num, program_num)
) STRICT;''',
    // 6. projects
    '''
CREATE TABLE projects (
    project_id            TEXT PRIMARY KEY,
    title                 TEXT NOT NULL,
    ppqn                  INTEGER NOT NULL CHECK (ppqn = 960),
    grid_snap_ticks       INTEGER NOT NULL CHECK (grid_snap_ticks > 0),
    pickup_ticks          INTEGER NOT NULL DEFAULT 0 CHECK (pickup_ticks >= 0),
    playback_timing_mode  TEXT NOT NULL DEFAULT 'quantized' CHECK (playback_timing_mode IN ('quantized', 'raw')),
    revision              INTEGER NOT NULL CHECK (revision >= 0),
    created_at            INTEGER NOT NULL,
    updated_at            INTEGER NOT NULL,
    deleted_at            INTEGER
) STRICT;''',
    // 7. idx_projects_active
    '''
CREATE INDEX idx_projects_active
    ON projects(updated_at DESC)
    WHERE deleted_at IS NULL;''',
    // 8. project_parts
    '''
CREATE TABLE project_parts (
    part_id           TEXT PRIMARY KEY,
    project_id        TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    musicxml_part_id  TEXT NOT NULL,
    sort_order        INTEGER NOT NULL CHECK (sort_order >= 0),
    name              TEXT NOT NULL,
    staves_count      INTEGER NOT NULL CHECK (staves_count IN (1, 2)),
    midi_channel      INTEGER NOT NULL CHECK (midi_channel BETWEEN 0 AND 15),
    sf_id             TEXT REFERENCES soundfonts(sf_id) ON DELETE SET NULL,
    bank_num          INTEGER NOT NULL CHECK (bank_num >= 0),
    program_num       INTEGER NOT NULL CHECK (program_num BETWEEN 0 AND 127),
    gain_db           REAL NOT NULL,
    pan               REAL NOT NULL CHECK (pan BETWEEN -1.0 AND 1.0),
    is_muted          INTEGER NOT NULL CHECK (is_muted IN (0, 1)),
    is_solo           INTEGER NOT NULL CHECK (is_solo IN (0, 1)),
    updated_at        INTEGER NOT NULL,
    UNIQUE (project_id, part_id),
    UNIQUE (project_id, musicxml_part_id)
) STRICT;''',
    // 9. tempo_events
    '''
CREATE TABLE tempo_events (
    tempo_event_id  TEXT PRIMARY KEY,
    project_id      TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    tick            INTEGER NOT NULL CHECK (tick >= 0),
    us_per_quarter  INTEGER NOT NULL CHECK (us_per_quarter > 0),
    updated_at      INTEGER NOT NULL,
    UNIQUE (project_id, tick)
) STRICT;''',
    // 10. time_signature_events
    '''
CREATE TABLE time_signature_events (
    ts_event_id  TEXT PRIMARY KEY,
    project_id   TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    tick         INTEGER NOT NULL CHECK (tick >= 0),
    numerator    INTEGER NOT NULL CHECK (numerator > 0),
    denominator  INTEGER NOT NULL CHECK (denominator IN (1, 2, 4, 8, 16, 32, 64)),
    updated_at   INTEGER NOT NULL,
    UNIQUE (project_id, tick)
) STRICT;''',
    // 11. key_signature_events
    '''
CREATE TABLE key_signature_events (
    key_event_id  TEXT PRIMARY KEY,
    project_id    TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    part_id       TEXT,
    staff_number  INTEGER NOT NULL DEFAULT 0 CHECK (staff_number IN (0, 1, 2)),
    tick          INTEGER NOT NULL CHECK (tick >= 0),
    fifths        INTEGER NOT NULL CHECK (fifths BETWEEN -7 AND 7),
    mode          TEXT NOT NULL CHECK (mode IN (
                      'major', 'minor', 'dorian', 'phrygian',
                      'lydian', 'mixolydian', 'aeolian', 'locrian', 'none'
                  )),
    updated_at    INTEGER NOT NULL,
    FOREIGN KEY (project_id, part_id) REFERENCES project_parts(project_id, part_id) ON DELETE CASCADE
) STRICT;''',
    // 12. idx_key_sig_global
    '''
CREATE UNIQUE INDEX idx_key_sig_global
    ON key_signature_events(project_id, tick)
    WHERE part_id IS NULL;''',
    // 13. idx_key_sig_part
    '''
CREATE UNIQUE INDEX idx_key_sig_part
    ON key_signature_events(project_id, part_id, staff_number, tick)
    WHERE part_id IS NOT NULL;''',
    // 14. clef_events
    '''
CREATE TABLE clef_events (
    clef_event_id  TEXT PRIMARY KEY,
    project_id     TEXT NOT NULL,
    part_id        TEXT NOT NULL,
    staff_number   INTEGER NOT NULL CHECK (staff_number IN (1, 2)),
    tick           INTEGER NOT NULL CHECK (tick >= 0),
    sign           TEXT NOT NULL CHECK (sign IN ('G', 'F', 'C', 'percussion', 'TAB', 'none')),
    line           INTEGER NOT NULL CHECK (line BETWEEN 1 AND 5),
    octave_change  INTEGER NOT NULL DEFAULT 0 CHECK (octave_change BETWEEN -2 AND 2),
    updated_at     INTEGER NOT NULL,
    FOREIGN KEY (project_id, part_id) REFERENCES project_parts(project_id, part_id) ON DELETE CASCADE,
    UNIQUE (project_id, part_id, staff_number, tick)
) STRICT;''',
    // 15. timeline_notes
    '''
CREATE TABLE timeline_notes (
    note_id                   TEXT PRIMARY KEY,
    project_id                TEXT NOT NULL,
    part_id                   TEXT NOT NULL,
    staff_number              INTEGER NOT NULL CHECK (staff_number IN (1, 2)),
    voice_number              INTEGER NOT NULL CHECK (voice_number BETWEEN 1 AND 4),
    pitch_midi                INTEGER NOT NULL CHECK (pitch_midi BETWEEN 0 AND 127),
    enharmonic_step           TEXT NOT NULL CHECK (enharmonic_step IN ('C', 'D', 'E', 'F', 'G', 'A', 'B')),
    enharmonic_alter          INTEGER NOT NULL CHECK (enharmonic_alter BETWEEN -2 AND 2),
    raw_start_tick            INTEGER NOT NULL CHECK (raw_start_tick >= 0),
    raw_duration_ticks        INTEGER NOT NULL CHECK (raw_duration_ticks > 0),
    quantized_start_tick      INTEGER NOT NULL CHECK (quantized_start_tick >= 0),
    quantized_duration_ticks  INTEGER NOT NULL CHECK (quantized_duration_ticks > 0),
    velocity                  INTEGER NOT NULL CHECK (velocity BETWEEN 1 AND 127),
    updated_at                INTEGER NOT NULL,
    FOREIGN KEY (project_id, part_id) REFERENCES project_parts(project_id, part_id) ON DELETE CASCADE
) STRICT;''',
    // 16. idx_notes_raw_window
    '''
CREATE INDEX idx_notes_raw_window
    ON timeline_notes(project_id, raw_start_tick);''',
    // 17. idx_notes_quantized_part
    '''
CREATE INDEX idx_notes_quantized_part
    ON timeline_notes(project_id, part_id, quantized_start_tick);''',
    // 18. note_spanners
    '''
CREATE TABLE note_spanners (
    spanner_id     TEXT PRIMARY KEY,
    project_id     TEXT NOT NULL,
    part_id        TEXT NOT NULL,
    spanner_type   TEXT NOT NULL CHECK (spanner_type IN ('tie', 'slur', 'beam')),
    start_note_id  TEXT NOT NULL REFERENCES timeline_notes(note_id) ON DELETE CASCADE,
    end_note_id    TEXT NOT NULL REFERENCES timeline_notes(note_id) ON DELETE CASCADE,
    spanner_level  INTEGER NOT NULL DEFAULT 1 CHECK (spanner_level BETWEEN 1 AND 6),
    placement      TEXT NOT NULL DEFAULT 'auto' CHECK (placement IN ('auto', 'above', 'below')),
    updated_at     INTEGER NOT NULL,
    FOREIGN KEY (project_id, part_id) REFERENCES project_parts(project_id, part_id) ON DELETE CASCADE
) STRICT;''',
    // 19. idx_spanners_part
    '''
CREATE INDEX idx_spanners_part
    ON note_spanners(project_id, part_id);''',
    // 20. idx_spanners_start_note
    '''
CREATE INDEX idx_spanners_start_note
    ON note_spanners(start_note_id);''',
    // 21. idx_spanners_end_note
    '''
CREATE INDEX idx_spanners_end_note
    ON note_spanners(end_note_id);''',
    // 22. audio_takes
    '''
CREATE TABLE audio_takes (
    take_id                    TEXT PRIMARY KEY,
    project_id                 TEXT NOT NULL,
    part_id                    TEXT NOT NULL,
    blob_sha256                TEXT NOT NULL REFERENCES content_blobs(sha256) ON DELETE RESTRICT,
    start_tick                 INTEGER NOT NULL CHECK (start_tick >= 0),
    sample_rate                INTEGER NOT NULL CHECK (sample_rate > 0),
    channel_count              INTEGER NOT NULL CHECK (channel_count IN (1, 2)),
    duration_frames            INTEGER NOT NULL CHECK (duration_frames > 0),
    captured_playhead_frame    INTEGER NOT NULL CHECK (captured_playhead_frame >= 0),
    captured_sample_clock      INTEGER NOT NULL CHECK (captured_sample_clock >= 0),
    output_buffer_frames       INTEGER NOT NULL CHECK (output_buffer_frames >= 0),
    input_buffer_frames        INTEGER NOT NULL CHECK (input_buffer_frames >= 0),
    calibration_offset_frames  INTEGER NOT NULL,
    created_at                 INTEGER NOT NULL,
    updated_at                 INTEGER NOT NULL,
    FOREIGN KEY (project_id, part_id) REFERENCES project_parts(project_id, part_id) ON DELETE CASCADE,
    UNIQUE (project_id, part_id)
) STRICT;''',
    // 23. idx_takes_project
    '''
CREATE INDEX idx_takes_project
    ON audio_takes(project_id, start_tick);''',
    // 24. idx_takes_blob_sha256
    '''
CREATE INDEX idx_takes_blob_sha256
    ON audio_takes(blob_sha256);''',
    // 25. latency_calibration_profiles
    '''
CREATE TABLE latency_calibration_profiles (
    profile_id                 TEXT PRIMARY KEY,
    platform                   TEXT NOT NULL CHECK (platform IN ('ios', 'android', 'macos', 'windows', 'linux', 'web')),
    device_fingerprint         TEXT NOT NULL,
    sample_rate                INTEGER NOT NULL CHECK (sample_rate > 0),
    buffer_size_frames         INTEGER NOT NULL CHECK (buffer_size_frames > 0),
    calibration_offset_frames  INTEGER NOT NULL,
    updated_at                 INTEGER NOT NULL,
    UNIQUE (platform, device_fingerprint, sample_rate, buffer_size_frames)
) STRICT;''',
  ]);

  /// Enables `foreign_keys`, sets `busy_timeout`, configures platform
  /// `journal_mode`, and fails closed if the active mode violates policy.
  ///
  /// [allowInMemoryJournalMode] must remain `false` in production Native/Web
  /// adapters; hermetic VM tests using `sqlite3.openInMemory()` may set it to
  /// `true` because `:memory:` databases always report `'memory'`.
  static Result<void> configureAndVerifyPragmas(
    CommonDatabase db, {
    required bool isWeb,
    bool allowInMemoryJournalMode = false,
  }) {
    try {
      db.execute('PRAGMA foreign_keys = ON;');
      final fkResult = db.select('PRAGMA foreign_keys;');
      if (fkResult.isEmpty || fkResult.first.values.first != _foreignKeysEnabledFlag) {
        return const Err(
          MuseError(
            MuseErrorCode.sqliteConstraintViolation,
            'SQLite failed to enable PRAGMA foreign_keys = ON.',
          ),
        );
      }

      db.execute('PRAGMA busy_timeout = ${MuseConstants.sqliteBusyTimeoutMs};');

      if (!isWeb) {
        db.execute('PRAGMA journal_mode = WAL;');
        db.execute('PRAGMA synchronous = $sqliteSynchronousNormal;');
        final modeResult = db.select('PRAGMA journal_mode;');
        final activeMode = _extractPragmaString(modeResult);
        final allowed = activeMode == nativeJournalMode ||
            (allowInMemoryJournalMode && activeMode == inMemoryJournalMode);
        if (!allowed) {
          return Err(
            MuseError(
              MuseErrorCode.sqliteJournalModeMismatch,
              'Expected Native SQLite journal_mode=$nativeJournalMode, '
              'got "$activeMode".',
            ),
          );
        }
      } else {
        db.execute('PRAGMA journal_mode = DELETE;');
        final modeResult = db.select('PRAGMA journal_mode;');
        final activeMode = _extractPragmaString(modeResult);
        final allowed = webAllowedJournalModes.contains(activeMode) ||
            (allowInMemoryJournalMode && activeMode == inMemoryJournalMode);
        if (!allowed) {
          return Err(
            MuseError(
              MuseErrorCode.sqliteJournalModeMismatch,
              'Expected Web SQLite journal_mode in $webAllowedJournalModes, '
              'got "$activeMode".',
            ),
          );
        }
      }

      return const Ok(null);
    } catch (error) {
      return Err(
        SqliteErrorMapper.mapException(
          error,
          contextMessage: 'Failed to configure SQLite pragmas',
        ),
      );
    }
  }

  static String? _extractPragmaString(ResultSet rows) {
    if (rows.isEmpty || rows.first.values.isEmpty) {
      return null;
    }
    final raw = rows.first.values.first;
    return raw?.toString().trim().toLowerCase();
  }

  /// Idempotently migrates the database to [currentSchemaVersion] (`1`) and
  /// fails closed if an unsupported future version is encountered.
  static Result<void> applyMigrations(
    CommonDatabase db, {
    int Function()? nowEpochMs,
  }) {
    final nowFn =
        nowEpochMs ?? () => DateTime.now().toUtc().millisecondsSinceEpoch;
    try {
      db.execute(_createSchemaMigrationsTableSql);
      final versionRows = db.select(
        'SELECT COALESCE(MAX(version), 0) AS current_version FROM schema_migrations;',
      );
      final currentVersion = versionRows.first['current_version'] as int;

      if (currentVersion > currentSchemaVersion) {
        return Err(
          MuseError(
            MuseErrorCode.sqliteConstraintViolation,
            'Unsupported database schema version $currentVersion > '
            '$currentSchemaVersion',
          ),
        );
      }

      if (currentVersion == currentSchemaVersion) {
        return const Ok(null);
      }

      return SqliteTxHelper.runWriteTransaction<void>(db, () {
        // Statement 0 is schema_migrations, already created above.
        for (final statement in createSchemaStatements.skip(1)) {
          db.execute(statement);
        }
        db.execute(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);',
          [currentSchemaVersion, nowFn()],
        );
        return const Ok(null);
      });
    } catch (error) {
      return Err(
        SqliteErrorMapper.mapException(
          error,
          contextMessage: 'Failed to apply SQLite schema migrations',
        ),
      );
    }
  }

  /// Returns `true` when [digest] is a 64-character lowercase hex SHA-256 string.
  static bool isValidSha256Hex(Sha256Digest digest) =>
      SqliteValueCodec.isValidSha256Hex(digest);

  /// Returns the 2-character CAS shard directory prefix for [digest].
  static String casShardPrefix(Sha256Digest digest) =>
      SqliteValueCodec.casShardPrefix(digest);
}

/// Pure Dart codecs mapping domain enums, booleans, and CAS digests to SQL values.
abstract final class SqliteValueCodec {
  static final RegExp _sha256Regex = RegExp(r'^[0-9a-f]{64}$');

  static bool isValidSha256Hex(Sha256Digest digest) =>
      _sha256Regex.hasMatch(digest.value);

  static Result<Sha256Digest> validateSha256Hex(Sha256Digest digest) {
    if (!isValidSha256Hex(digest)) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Invalid SHA-256 digest format: "${digest.value}".',
        ),
      );
    }
    return Ok(digest);
  }

  static Result<String> validateCasExt(String ext) {
    if (!SqliteSchemaDdl.supportedCasExtensions.contains(ext)) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Unsupported CAS file extension "$ext".',
        ),
      );
    }
    return Ok(ext);
  }

  static String casShardPrefix(Sha256Digest digest) {
    if (!isValidSha256Hex(digest)) {
      throw FormatException('Invalid SHA-256 digest: "${digest.value}".');
    }
    return digest.value.substring(0, MuseConstants.casShardHexLength);
  }

  static String casFileName(Sha256Digest digest, String ext) {
    if (!isValidSha256Hex(digest)) {
      throw FormatException('Invalid SHA-256 digest: "${digest.value}".');
    }
    if (!SqliteSchemaDdl.supportedCasExtensions.contains(ext)) {
      throw FormatException('Unsupported CAS extension: "$ext".');
    }
    return '${digest.value}.$ext';
  }

  static String clefSignToSql(ClefSign sign) => switch (sign) {
        ClefSign.G => 'G',
        ClefSign.F => 'F',
        ClefSign.C => 'C',
        ClefSign.percussion => 'percussion',
        ClefSign.tab => 'TAB',
        ClefSign.none => 'none',
      };

  static ClefSign clefSignFromSql(String raw) => switch (raw) {
        'G' => ClefSign.G,
        'F' => ClefSign.F,
        'C' => ClefSign.C,
        'percussion' => ClefSign.percussion,
        'TAB' => ClefSign.tab,
        'none' => ClefSign.none,
        _ => throw FormatException('Unknown SQL clef sign "$raw".'),
      };

  static String playbackTimingModeToSql(PlaybackTimingMode mode) => mode.name;

  static PlaybackTimingMode playbackTimingModeFromSql(String raw) =>
      _parseEnum(PlaybackTimingMode.values, raw, 'playback_timing_mode');

  static String enharmonicStepToSql(EnharmonicStep step) => step.name;

  static EnharmonicStep enharmonicStepFromSql(String raw) =>
      _parseEnum(EnharmonicStep.values, raw, 'enharmonic_step');

  static String keyModeToSql(KeyMode mode) => mode.name;

  static KeyMode keyModeFromSql(String raw) =>
      _parseEnum(KeyMode.values, raw, 'key_signature_events.mode');

  static String spannerTypeToSql(SpannerType type) => type.name;

  static SpannerType spannerTypeFromSql(String raw) =>
      _parseEnum(SpannerType.values, raw, 'spanner_type');

  static String spannerPlacementToSql(SpannerPlacement placement) =>
      placement.name;

  static SpannerPlacement spannerPlacementFromSql(String raw) =>
      _parseEnum(SpannerPlacement.values, raw, 'placement');

  static String calibrationPlatformToSql(CalibrationPlatform platform) =>
      platform.name;

  static CalibrationPlatform calibrationPlatformFromSql(String raw) =>
      _parseEnum(CalibrationPlatform.values, raw, 'platform');

  static int boolToSql(bool value) => value ? 1 : 0;

  static bool boolFromSql(Object? raw, String columnName) => switch (raw) {
        1 => true,
        0 => false,
        _ => throw FormatException('Invalid boolean integer $raw for $columnName.'),
      };

  static T _parseEnum<T extends Enum>(
    List<T> values,
    String raw,
    String fieldName,
  ) {
    for (final value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    throw FormatException('Unknown SQL enum value "$raw" for $fieldName.');
  }
}

/// Maps SQLite, codec, and unexpected exceptions to fail-closed [MuseError]s.
abstract final class SqliteErrorMapper {
  static MuseError mapException(
    Object error, {
    String? contextMessage,
    MuseErrorCode fallbackCode = MuseErrorCode.sqliteConstraintViolation,
  }) {
    if (error is MuseError) {
      return error;
    }
    if (error is SqliteException) {
      final code = error.resultCode == SqliteSchemaDdl._sqliteFullResultCode
          ? MuseErrorCode.insufficientStorageQuota
          : MuseErrorCode.sqliteConstraintViolation;
      final prefix = contextMessage == null ? '' : '$contextMessage: ';
      return MuseError(code, '$prefix${error.message}', cause: error);
    }
    if (error is FormatException) {
      final prefix = contextMessage == null ? '' : '$contextMessage: ';
      return MuseError(
        MuseErrorCode.sqliteConstraintViolation,
        '$prefix${error.message}',
        cause: error,
      );
    }
    final prefix = contextMessage == null ? '' : '$contextMessage: ';
    return MuseError(fallbackCode, '$prefix$error', cause: error);
  }
}

/// Executes atomic `BEGIN IMMEDIATE ... COMMIT` write transactions with rollback.
abstract final class SqliteTxHelper {
  static Result<T> runWriteTransaction<T>(
    CommonDatabase db,
    Result<T> Function() action, {
    String? contextMessage,
  }) {
    try {
      db.execute('BEGIN IMMEDIATE;');
    } catch (error) {
      return Err(
        SqliteErrorMapper.mapException(error, contextMessage: contextMessage),
      );
    }

    try {
      final result = action();
      if (result is Ok<T>) {
        db.execute('COMMIT;');
        return result;
      }
      _safeRollback(db);
      return result;
    } catch (error) {
      _safeRollback(db);
      return Err(
        SqliteErrorMapper.mapException(error, contextMessage: contextMessage),
      );
    }
  }

  static void _safeRollback(CommonDatabase db) {
    try {
      db.execute('ROLLBACK;');
    } catch (_) {
      // Ignore rollback failure when SQLite already auto-rolled back on error.
    }
  }
}

/// Mark-and-Sweep CAS garbage collector (`projects` + `soundfonts` + `content_blobs`).
abstract final class SqliteGarbageCollector {
  /// Purges expired soft-deleted `projects` and `soundfonts`, sweeps unreferenced
  /// `content_blobs` via `DELETE ... RETURNING`, and physically unlinks each
  /// swept CAS blob only after the SQLite transaction commits cleanly.
  static Future<Result<int>> runGarbageCollection({
    required CommonDatabase db,
    required ICasBlobStore casStore,
    required int olderThanEpochMs,
  }) async {
    if (olderThanEpochMs < 0) {
      return Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'olderThanEpochMs must be >= 0 (got $olderThanEpochMs).',
        ),
      );
    }

    final sweptResult =
        SqliteTxHelper.runWriteTransaction<List<({String sha256, String ext, int byteSize})>>(
      db,
      () {
        db.execute(
          'DELETE FROM projects WHERE deleted_at IS NOT NULL AND deleted_at < ?;',
          [olderThanEpochMs],
        );
        db.execute(
          'DELETE FROM soundfonts WHERE deleted_at IS NOT NULL AND deleted_at < ?;',
          [olderThanEpochMs],
        );

        final sweptRows = db.select('''
DELETE FROM content_blobs
WHERE NOT EXISTS (
  SELECT 1 FROM audio_takes WHERE blob_sha256 = content_blobs.sha256
)
AND NOT EXISTS (
  SELECT 1 FROM soundfonts WHERE blob_sha256 = content_blobs.sha256
)
RETURNING sha256, ext, byte_size;''');

        final swept = <({String sha256, String ext, int byteSize})>[];
        for (final row in sweptRows) {
          swept.add((
            sha256: row['sha256'] as String,
            ext: row['ext'] as String,
            byteSize: row['byte_size'] as int,
          ));
        }
        return Ok(swept);
      },
      contextMessage: 'Failed to mark-and-sweep SQLite content_blobs',
    );

    if (sweptResult case Err(:final error)) {
      return Err(error);
    }

    final sweptBlobs = (sweptResult as Ok<List<({String sha256, String ext, int byteSize})>>).value;
    var reclaimedBytes = 0;
    MuseError? firstError;
    var failedCount = 0;
    for (final blob in sweptBlobs) {
      final unlinkResult = await casStore.deleteCasBlob(
        Sha256Digest(blob.sha256),
        ext: blob.ext,
      );
      if (unlinkResult case Err(:final error)) {
        firstError ??= error;
        failedCount++;
        continue;
      }
      reclaimedBytes += blob.byteSize;
    }

    if (firstError != null) {
      return Err(
        MuseError(
          firstError.code,
          '${firstError.message} '
          '(unlinked $reclaimedBytes bytes; '
          '$failedCount of ${sweptBlobs.length} CAS blob unlink(s) failed)',
          cause: firstError.cause,
        ),
      );
    }

    return Ok(reclaimedBytes);
  }
}

/// Platform-agnostic SQLite implementation of [IAssetLibraryRepository].
library;

import 'package:sqlite3/common.dart';
import 'package:uuid/uuid.dart';

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import '../../domain/repositories/storage_contracts.dart';
import 'sqlite_schema_ddl.dart';

/// SQLite-backed implementation of [IAssetLibraryRepository] managing
/// `soundfonts`, `soundfont_presets`, and `latency_calibration_profiles`.
final class SqlAssetLibraryRepository implements IAssetLibraryRepository {
  final CommonDatabase _db;
  final ICasBlobStore _casStore;
  final int Function() _nowEpochMs;
  final String Function() _generateUuidV7;

  SqlAssetLibraryRepository({
    required this._db,
    required this._casStore,
    int Function()? nowEpochMs,
    String Function()? generateUuidV7,
  })  : _nowEpochMs =
            nowEpochMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
        _generateUuidV7 = generateUuidV7 ?? const Uuid().v7;

  @override
  Future<Result<List<SoundFontCatalogEntry>>> listActiveSoundFonts() async {
    try {
      final sfRows = _db.select('''
SELECT s.sf_id, s.name, s.blob_sha256, b.byte_size, s.created_at, s.updated_at
FROM soundfonts s
INNER JOIN content_blobs b ON b.sha256 = s.blob_sha256
WHERE s.deleted_at IS NULL
ORDER BY s.created_at ASC, s.sf_id ASC;''');

      final presetRows = _db.select('''
SELECT p.sf_id, p.bank_num, p.program_num, p.preset_name
FROM soundfont_presets p
INNER JOIN soundfonts s ON s.sf_id = p.sf_id
WHERE s.deleted_at IS NULL
ORDER BY p.sf_id ASC, p.bank_num ASC, p.program_num ASC;''');

      final presetsBySfId = <String, List<SoundFontPresetInfo>>{};
      for (final row in presetRows) {
        final sfId = row['sf_id'] as String;
        presetsBySfId
            .putIfAbsent(sfId, () => <SoundFontPresetInfo>[])
            .add(
              SoundFontPresetInfo(
                bankNum: row['bank_num'] as int,
                programNum: row['program_num'] as int,
                presetName: row['preset_name'] as String,
              ),
            );
      }

      final entries = sfRows.map((row) {
        final sfId = row['sf_id'] as String;
        final presets = presetsBySfId[sfId] ?? const <SoundFontPresetInfo>[];
        return SoundFontCatalogEntry(
          sfId: SoundFontId(sfId),
          name: row['name'] as String,
          blobSha256: Sha256Digest(row['blob_sha256'] as String),
          byteSize: row['byte_size'] as int,
          presets: List<SoundFontPresetInfo>.unmodifiable(presets),
          createdAtMs: row['created_at'] as int,
          updatedAtMs: row['updated_at'] as int,
        );
      }).toList(growable: false);

      return Ok(entries);
    } catch (error) {
      return Err(
        SqliteErrorMapper.mapException(
          error,
          contextMessage: 'Failed to list active SoundFonts',
        ),
      );
    }
  }

  @override
  Future<Result<SoundFontCatalogEntry>> importSoundFontBytes({
    required String displayName,
    required Stream<List<int>> byteStream,
    required int byteLength,
    required List<SoundFontPresetInfo> extractedPresets,
  }) async {
    if (displayName.trim().isEmpty || byteLength <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          'SoundFont displayName must be non-empty and byteLength must be > 0.',
        ),
      );
    }
    for (final preset in extractedPresets) {
      if (preset.bankNum < MuseConstants.minBankNum ||
          preset.programNum < MuseConstants.minProgramNum ||
          preset.programNum > MuseConstants.maxProgramNum) {
        return Err(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'Invalid SoundFont preset bank=${preset.bankNum}, '
            'program=${preset.programNum}.',
          ),
        );
      }
    }

    final writeResult = await _casStore.writeStreamToCas(
      byteStream: byteStream,
      expectedByteLength: byteLength,
      ext: SqliteSchemaDdl.sf2Extension,
    );
    if (writeResult case Err(:final error)) {
      return Err(error);
    }
    final written =
        (writeResult as Ok<({Sha256Digest sha256, int byteSize})>).value;

    return SqliteTxHelper.runWriteTransaction<SoundFontCatalogEntry>(
      _db,
      () {
        final now = _nowEpochMs();
        _db.execute(
          '''
INSERT OR IGNORE INTO content_blobs (
  sha256, ext, mime_type, byte_size, created_at
) VALUES (?, ?, ?, ?, ?);''',
          [
            written.sha256.value,
            SqliteSchemaDdl.sf2Extension,
            SqliteSchemaDdl.sf2MimeType,
            written.byteSize,
            now,
          ],
        );

        final existingRows = _db.select(
          '''
SELECT sf_id, created_at
FROM soundfonts
WHERE blob_sha256 = ?
ORDER BY created_at ASC
LIMIT 1;''',
          [written.sha256.value],
        );

        final String sfId;
        final int createdAt;
        if (existingRows.isNotEmpty) {
          sfId = existingRows.first['sf_id'] as String;
          createdAt = existingRows.first['created_at'] as int;
          _db.execute(
            '''
UPDATE soundfonts
SET name = ?, deleted_at = NULL, updated_at = ?
WHERE sf_id = ?;''',
            [displayName, now, sfId],
          );
        } else {
          sfId = _generateUuidV7();
          createdAt = now;
          _db.execute(
            '''
INSERT INTO soundfonts (
  sf_id, name, blob_sha256, format, created_at, updated_at, deleted_at
) VALUES (?, ?, ?, ?, ?, ?, NULL);''',
            [
              sfId,
              displayName,
              written.sha256.value,
              SqliteSchemaDdl.sf2Extension,
              createdAt,
              now,
            ],
          );
        }

        _db.execute('DELETE FROM soundfont_presets WHERE sf_id = ?;', [sfId]);
        for (final preset in extractedPresets) {
          _db.execute(
            '''
INSERT INTO soundfont_presets (
  sf_id, bank_num, program_num, preset_name
) VALUES (?, ?, ?, ?);''',
            [sfId, preset.bankNum, preset.programNum, preset.presetName],
          );
        }

        return Ok(
          SoundFontCatalogEntry(
            sfId: SoundFontId(sfId),
            name: displayName,
            blobSha256: written.sha256,
            byteSize: written.byteSize,
            presets: List<SoundFontPresetInfo>.unmodifiable(extractedPresets),
            createdAtMs: createdAt,
            updatedAtMs: now,
          ),
        );
      },
      contextMessage: 'Failed to import SoundFont metadata',
    );
  }

  @override
  Future<Result<void>> softDeleteSoundFont(
    SoundFontId sfId, {
    required int deletedAtMs,
  }) async {
    if (sfId.value.trim().isEmpty || deletedAtMs <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'sfId must be non-empty and deletedAtMs must be > 0.',
        ),
      );
    }

    return SqliteTxHelper.runWriteTransaction<void>(
      _db,
      () {
        _db.execute(
          '''
UPDATE soundfonts
SET deleted_at = ?, updated_at = ?
WHERE sf_id = ? AND deleted_at IS NULL;''',
          [deletedAtMs, deletedAtMs, sfId.value],
        );
        if (_db.updatedRows == 0) {
          return Err(
            MuseError(
              MuseErrorCode.entityNotFound,
              'Active SoundFont "${sfId.value}" not found.',
            ),
          );
        }

        _db.execute(
          '''
UPDATE project_parts
SET sf_id = NULL, updated_at = ?
WHERE sf_id = ?;''',
          [deletedAtMs, sfId.value],
        );
        return const Ok(null);
      },
      contextMessage: 'Failed to soft-delete SoundFont',
    );
  }

  @override
  Future<Result<LatencyCalibrationProfile?>> getCalibrationProfile({
    required CalibrationPlatform platform,
    required String deviceFingerprint,
    required int sampleRate,
    required int bufferSizeFrames,
  }) async {
    if (deviceFingerprint.trim().isEmpty ||
        sampleRate <= 0 ||
        bufferSizeFrames <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Invalid calibration profile lookup parameters.',
        ),
      );
    }

    try {
      final rows = _db.select(
        '''
SELECT profile_id, platform, device_fingerprint, sample_rate,
       buffer_size_frames, calibration_offset_frames, updated_at
FROM latency_calibration_profiles
WHERE platform = ?
  AND device_fingerprint = ?
  AND sample_rate = ?
  AND buffer_size_frames = ?;''',
        [
          SqliteValueCodec.calibrationPlatformToSql(platform),
          deviceFingerprint,
          sampleRate,
          bufferSizeFrames,
        ],
      );
      if (rows.isEmpty) {
        return const Ok(null);
      }
      return Ok(_mapCalibrationProfile(rows.first));
    } catch (error) {
      return Err(
        SqliteErrorMapper.mapException(
          error,
          contextMessage: 'Failed to query latency calibration profile',
        ),
      );
    }
  }

  @override
  Future<Result<LatencyCalibrationProfile>> upsertCalibrationProfile(
    UpsertCalibrationProfileInput input,
  ) async {
    if (input.deviceFingerprint.trim().isEmpty ||
        input.sampleRate <= 0 ||
        input.bufferSizeFrames <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Invalid UpsertCalibrationProfileInput parameters.',
        ),
      );
    }

    return SqliteTxHelper.runWriteTransaction<LatencyCalibrationProfile>(
      _db,
      () {
        final now = _nowEpochMs();
        final platformSql =
            SqliteValueCodec.calibrationPlatformToSql(input.platform);
        final candidateProfileId = _generateUuidV7();

        _db.execute(
          '''
INSERT INTO latency_calibration_profiles (
  profile_id, platform, device_fingerprint, sample_rate,
  buffer_size_frames, calibration_offset_frames, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(platform, device_fingerprint, sample_rate, buffer_size_frames) DO UPDATE SET
  calibration_offset_frames = excluded.calibration_offset_frames,
  updated_at = excluded.updated_at;''',
          [
            candidateProfileId,
            platformSql,
            input.deviceFingerprint,
            input.sampleRate,
            input.bufferSizeFrames,
            input.calibrationOffsetFrames,
            now,
          ],
        );

        final persisted = _db.select(
          '''
SELECT profile_id, platform, device_fingerprint, sample_rate,
       buffer_size_frames, calibration_offset_frames, updated_at
FROM latency_calibration_profiles
WHERE platform = ?
  AND device_fingerprint = ?
  AND sample_rate = ?
  AND buffer_size_frames = ?;''',
          [
            platformSql,
            input.deviceFingerprint,
            input.sampleRate,
            input.bufferSizeFrames,
          ],
        );
        return Ok(_mapCalibrationProfile(persisted.first));
      },
      contextMessage: 'Failed to upsert latency calibration profile',
    );
  }

  static LatencyCalibrationProfile _mapCalibrationProfile(Row r) =>
      LatencyCalibrationProfile(
        profileId: CalibrationProfileId(r['profile_id'] as String),
        platform: SqliteValueCodec.calibrationPlatformFromSql(
          r['platform'] as String,
        ),
        deviceFingerprint: r['device_fingerprint'] as String,
        sampleRate: r['sample_rate'] as int,
        bufferSizeFrames: r['buffer_size_frames'] as int,
        calibrationOffsetFrames: r['calibration_offset_frames'] as int,
        updatedAtMs: r['updated_at'] as int,
      );
}

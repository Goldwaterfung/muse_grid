/// Pure Dart persistence, CAS maintenance, and external file exchange interfaces
/// implemented by `lib/storage/{common,native,web}/` and wired by `lib/app/`.
library;

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../models/score_models.dart';

/// Storage lifecycle, quota verification, and Mark-and-Sweep CAS maintenance
/// (called by `lib/app/` on startup/shutdown and L4/L5 pre-flight checks).
abstract interface class IStorageMaintenanceRepository {
  /// Opens SQLite, enforces `PRAGMA foreign_keys = ON`, verifies platform `journal_mode`
  /// (`WAL` on Native, `DELETE`/`TRUNCATE` on Web), runs `schema_migrations`,
  /// and sweeps `staging/*.part` orphans.
  Future<Result<void>> initializeAndVerifyStorage();

  /// Checks Web OPFS / Native free disk quota before recording or importing SoundFonts.
  /// Returns available free bytes if `>= requiredBytes`; fails closed with
  /// [MuseErrorCode.insufficientStorageQuota] otherwise.
  Future<Result<int>> verifyAvailableQuotaBytes({required int requiredBytes});

  /// Purges soft-deleted rows older than [olderThanEpochMs] and runs Mark-and-Sweep CAS GC
  /// (`DELETE FROM content_blobs WHERE NOT EXISTS ... RETURNING sha256, ext -> unlink cas file`).
  Future<Result<int>> runGarbageCollection({required int olderThanEpochMs});

  Future<void> close();
}

/// Project, score, part, map, and recorded audio take persistence repository.
abstract interface class IProjectRepository {
  Future<Result<List<ProjectSummary>>> listActiveProjects({
    required int limit,
    required int offset,
  });

  Future<Result<ProjectWorkspaceAggregate>> loadProjectAggregate(
    ProjectId projectId,
  );

  Future<Result<ProjectSummary>> createProject(CreateProjectInput input);

  Future<Result<void>> updateProjectMetadata(UpdateProjectMetadataInput input);

  Future<Result<void>> softDeleteProject(
    ProjectId projectId, {
    required int deletedAtMs,
  });

  /// Commits an atomic batch of score edits (notes, spanners, tempo/time/key/clef maps,
  /// part settings) and increments `projects.revision` in one `BEGIN IMMEDIATE` transaction.
  Future<Result<int>> commitScoreMutationBatch(ScoreMutationBatch batch);

  /// Promotes `staging/rec_<take_id>.wav.part` -> `cas/<aa>/<sha256>.wav` and inserts
  /// `content_blobs` + `UPSERT`s `audio_takes` on `(project_id, part_id)`.
  Future<Result<AudioTakeEntity>> promoteAndCommitRecordedTake({
    required RecordingCaptureReceipt receipt,
    required ProjectId projectId,
    required PartId partId,
    required Tick alignedStartTick,
    required int calibrationOffsetFrames,
  });

  /// Updates `start_tick` and `calibration_offset_frames` for existing takes
  /// when latency calibration changes.
  Future<Result<List<AudioTakeEntity>>> realignAudioTakesCalibration({
    required ProjectId projectId,
    required List<AudioTakeRealignmentUpdate> updates,
  });

  Future<Result<void>> deletePartAudioTake({
    required ProjectId projectId,
    required PartId partId,
  });
}

/// SoundFont asset library (`soundfonts`, `soundfont_presets`, `content_blobs`)
/// and hardware latency calibration repository (`latency_calibration_profiles`).
abstract interface class IAssetLibraryRepository {
  Future<Result<List<SoundFontCatalogEntry>>> listActiveSoundFonts();

  Future<Result<SoundFontCatalogEntry>> importSoundFontBytes({
    required String displayName,
    required Stream<List<int>> byteStream,
    required int byteLength,
    required List<SoundFontPresetInfo> extractedPresets,
  });

  Future<Result<void>> softDeleteSoundFont(
    SoundFontId sfId, {
    required int deletedAtMs,
  });

  /// Returns `Ok(null)` only when no profile has been calibrated yet for this
  /// hardware tuple; storage or query failures reject loudly via [Err].
  Future<Result<LatencyCalibrationProfile?>> getCalibrationProfile({
    required CalibrationPlatform platform,
    required String deviceFingerprint,
    required int sampleRate,
    required int bufferSizeFrames,
  });

  Future<Result<LatencyCalibrationProfile>> upsertCalibrationProfile(
    UpsertCalibrationProfileInput input,
  );
}

/// Platform import/export exchange (Copy-on-Import / Stage-on-Export / Web File Picker).
abstract interface class IExternalFileExchange {
  /// Returns `Ok(null)` only when the user cancels the file picker; permission,
  /// unreadable URI, or I/O failures reject loudly via [Err].
  Future<Result<PickedExternalFile?>> pickImportFile({
    required List<String> allowedExtensions,
  });

  Future<Result<void>> exportFileToUser({
    required String suggestedFileName,
    required String mimeType,
    required List<int> bytes,
  });

  Future<Result<void>> exportCasWavTakeToUser({
    required Sha256Digest wavSha256,
    required String suggestedFileName,
  });
}

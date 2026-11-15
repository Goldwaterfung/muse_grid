/// Layer 5 controller managing paginated project catalog CRUD, MusicXML/MXL
/// import/export, SoundFont preset extraction/CAS import/deletion, and
/// hardware-aware latency calibration realignment.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb;
import 'package:uuid/uuid.dart';

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/assets/soundfont_preset_parser.dart';
import '../../domain/models/score_models.dart';
import '../../domain/notation/crisp_score_mapper.dart';
import '../../domain/notation/dual_model_score_service.dart';
import '../../domain/playback/lookahead_playback_coordinator.dart';
import '../../domain/recording/recording_session_coordinator.dart';
import '../../domain/repositories/storage_contracts.dart';
import '../../domain/timeline/tempo_timeline_calculator.dart';
import '../theme/muse_presentation_constants.dart';
import 'audio_session_contract.dart';

/// Immutable UI snapshot for [ProjectCatalogController].
final class ProjectCatalogState {
  final List<ProjectSummary> projects;
  final bool hasMoreProjects;
  final int nextOffset;
  final List<SoundFontCatalogEntry> soundFonts;
  final LatencyCalibrationProfile? currentCalibrationProfile;
  final bool isBusy;
  final MuseError? lastError;

  const ProjectCatalogState({
    this.projects = const <ProjectSummary>[],
    this.hasMoreProjects = false,
    this.nextOffset = 0,
    this.soundFonts = const <SoundFontCatalogEntry>[],
    this.currentCalibrationProfile,
    this.isBusy = false,
    this.lastError,
  });

  ProjectCatalogState copyWith({
    List<ProjectSummary>? projects,
    bool? hasMoreProjects,
    int? nextOffset,
    List<SoundFontCatalogEntry>? soundFonts,
    LatencyCalibrationProfile? currentCalibrationProfile,
    bool clearCalibrationProfile = false,
    bool? isBusy,
    MuseError? lastError,
    bool clearLastError = false,
  }) => ProjectCatalogState(
    projects: projects ?? this.projects,
    hasMoreProjects: hasMoreProjects ?? this.hasMoreProjects,
    nextOffset: nextOffset ?? this.nextOffset,
    soundFonts: soundFonts ?? this.soundFonts,
    currentCalibrationProfile: clearCalibrationProfile
        ? null
        : (currentCalibrationProfile ?? this.currentCalibrationProfile),
    isBusy: isBusy ?? this.isBusy,
    lastError: clearLastError ? null : (lastError ?? this.lastError),
  );
}

/// Manages project catalog pagination, MusicXML/SF2 import/export, storage GC,
/// and hardware latency calibration profiles strictly downward onto L4/Storage.
final class ProjectCatalogController extends ChangeNotifier {
  static final RegExp _unsafeFileNameCharsRegex = RegExp(r'[/\\]');

  final IProjectRepository _projectRepository;
  final IAssetLibraryRepository _assetLibraryRepository;
  final IExternalFileExchange _externalFileExchange;
  final IStorageMaintenanceRepository _storageMaintenanceRepository;
  final IDualModelScoreService _dualModelScoreService;
  final ISoundFontPresetParser _soundFontPresetParser;
  final ILookaheadPlaybackCoordinator _playbackCoordinator;
  final IRecordingSessionCoordinator _recordingCoordinator;
  final IAudioSessionController _audioSessionController;
  final ProjectId? Function() _activeProjectIdProvider;
  final Set<SoundFontId> Function() _activeProjectSoundFontIdsProvider;
  final Future<Result<void>> Function() _detachActiveProjectHook;
  final Future<Result<void>> Function(ProjectId projectId) _reopenProjectHook;
  final String Function() _uuidV7Generator;
  final int Function() _nowEpochMs;

  ProjectCatalogState _state = const ProjectCatalogState();
  bool _isDisposed = false;

  ProjectCatalogController({
    required this._projectRepository,
    required this._assetLibraryRepository,
    required this._externalFileExchange,
    required this._storageMaintenanceRepository,
    required this._dualModelScoreService,
    required this._soundFontPresetParser,
    required this._playbackCoordinator,
    required this._recordingCoordinator,
    required this._audioSessionController,
    required this._activeProjectIdProvider,
    required this._activeProjectSoundFontIdsProvider,
    required this._detachActiveProjectHook,
    required this._reopenProjectHook,
    String Function()? uuidV7Generator,
    int Function()? nowEpochMs,
  }) : _uuidV7Generator = uuidV7Generator ?? (() => const Uuid().v7()),
       _nowEpochMs =
           nowEpochMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  ProjectCatalogState get state => _state;

  Future<Result<void>> loadCatalogInitial() async {
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final projectsResult = await _projectRepository.listActiveProjects(
      limit: MusePresentationConstants.catalogPageSize,
      offset: MusePresentationConstants.initialTick,
    );
    if (projectsResult case Err<List<ProjectSummary>>(:final error)) {
      return _failWith(error);
    }
    final soundFontsResult = await _assetLibraryRepository
        .listActiveSoundFonts();
    if (soundFontsResult case Err<List<SoundFontCatalogEntry>>(:final error)) {
      return _failWith(error);
    }

    final page = (projectsResult as Ok<List<ProjectSummary>>).value;
    final soundFonts = (soundFontsResult as Ok<List<SoundFontCatalogEntry>>)
        .value;
    _emit(
      _state.copyWith(
        projects: List<ProjectSummary>.unmodifiable(page),
        hasMoreProjects:
            page.length == MusePresentationConstants.catalogPageSize,
        nextOffset: page.length,
        soundFonts: List<SoundFontCatalogEntry>.unmodifiable(soundFonts),
        isBusy: false,
        clearLastError: true,
      ),
    );
    return const Ok(null);
  }

  Future<Result<void>> loadMoreProjects() async {
    if (!_state.hasMoreProjects || _state.isBusy) {
      return const Ok(null);
    }
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final pageResult = await _projectRepository.listActiveProjects(
      limit: MusePresentationConstants.catalogPageSize,
      offset: _state.nextOffset,
    );
    if (pageResult case Err<List<ProjectSummary>>(:final error)) {
      return _failWith(error);
    }

    final page = (pageResult as Ok<List<ProjectSummary>>).value;
    final merged = <ProjectSummary>[..._state.projects, ...page];
    _emit(
      _state.copyWith(
        projects: List<ProjectSummary>.unmodifiable(merged),
        hasMoreProjects:
            page.length == MusePresentationConstants.catalogPageSize,
        nextOffset: _state.nextOffset + page.length,
        isBusy: false,
        clearLastError: true,
      ),
    );
    return const Ok(null);
  }

  Future<Result<ProjectSummary>> createBlankProject({
    required String title,
    required SoundFontId initialSoundFontId,
    int tempoBpm = MusePresentationConstants.defaultNewProjectTempoBpm,
    int numerator = MusePresentationConstants.defaultNewProjectTimeSigNum,
    int denominator = MusePresentationConstants.defaultNewProjectTimeSigDen,
    int stavesCount = MusePresentationConstants.defaultInitialPartStavesCount,
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      return _failWith(
        const MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Project title must not be empty.',
        ),
      );
    }
    if (tempoBpm < TelemetryConstants.bpmMinValid ||
        tempoBpm > TelemetryConstants.bpmMaxValid) {
      return _failWith(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Tempo BPM ($tempoBpm) must be in ${TelemetryConstants.bpmMinValid}..${TelemetryConstants.bpmMaxValid}.',
        ),
      );
    }
    if (numerator < TempoTimelineCalculator.minValidTimeSigNumerator ||
        !TempoTimelineCalculator.validTimeSigDenominators.contains(
          denominator,
        )) {
      return _failWith(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Time signature $numerator/$denominator is invalid.',
        ),
      );
    }
    if (stavesCount < CrispScoreMapperConstants.singleStaffCount ||
        stavesCount > CrispScoreMapperConstants.grandStaffCount) {
      return _failWith(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'stavesCount ($stavesCount) must be ${CrispScoreMapperConstants.singleStaffCount} or ${CrispScoreMapperConstants.grandStaffCount}.',
        ),
      );
    }

    _emit(_state.copyWith(isBusy: true, clearLastError: true));

    final sfResult = await _assetLibraryRepository.listActiveSoundFonts();
    if (sfResult case Err<List<SoundFontCatalogEntry>>(:final error)) {
      return _failWith(error);
    }
    final activeSoundFonts = (sfResult as Ok<List<SoundFontCatalogEntry>>).value;
    if (!activeSoundFonts.any((sf) => sf.sfId == initialSoundFontId)) {
      return _failWith(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Initial SoundFont "${initialSoundFontId.value}" was not found in active library.',
        ),
      );
    }

    final usPerQuarter =
        MusePresentationConstants.microsecondsPerMinute ~/ tempoBpm;
    final projectId = ProjectId(_uuidV7Generator());
    final createResult = await _projectRepository.createProject(
      CreateProjectInput(
        projectId: projectId,
        title: trimmedTitle,
        gridSnapTicks: MusePresentationConstants.defaultGridSnapTicks,
        pickupTicks: MusePresentationConstants.defaultPickupTicks,
        playbackTimingMode: PlaybackTimingMode.quantized,
        initialUsPerQuarter: usPerQuarter,
        initialTimeSigNumerator: numerator,
        initialTimeSigDenominator: denominator,
      ),
    );
    if (createResult case Err<ProjectSummary>(:final error)) {
      return _failWith(error);
    }
    final created = (createResult as Ok<ProjectSummary>).value;

    final loadSeededResult = await _projectRepository.loadProjectAggregate(
      created.projectId,
    );
    if (loadSeededResult case Err<ProjectWorkspaceAggregate>(:final error)) {
      return _failWith(error);
    }
    final seeded = (loadSeededResult as Ok<ProjectWorkspaceAggregate>).value;
    if (seeded.parts.length != CrispScoreMapperConstants.singleStaffCount) {
      return _failWith(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Expected exactly 1 seeded part in new project "${created.projectId.value}", found ${seeded.parts.length}.',
        ),
      );
    }
    final seededPart = seeded.parts.single;
    final now = _nowEpochMs();

    final configuredPart = ProjectPartEntity(
      partId: seededPart.partId,
      projectId: created.projectId,
      musicXmlPartId: seededPart.musicXmlPartId,
      sortOrder: seededPart.sortOrder,
      name: MusePresentationConstants.defaultInitialPartName,
      stavesCount: stavesCount,
      midiChannel: MuseConstants.minMidiChannel,
      sfId: initialSoundFontId,
      bankNum: MuseConstants.minBankNum,
      programNum: MuseConstants.minProgramNum,
      gainDb: CrispScoreMapperConstants.defaultGainDb,
      pan: CrispScoreMapperConstants.defaultPan,
      isMuted: false,
      isSolo: false,
      updatedAtMs: now,
    );

    final upsertClefs = stavesCount == CrispScoreMapperConstants.grandStaffCount
        ? <ClefEventEntity>[
            ClefEventEntity(
              clefEventId: ClefEventId(_uuidV7Generator()),
              projectId: created.projectId,
              partId: seededPart.partId,
              staffNumber: MusePresentationConstants.grandStaffLowerNumber,
              tick: const Tick(MusePresentationConstants.initialTick),
              sign: ClefSign.F,
              line: CrispScoreMapperConstants.bassClefLine,
              octaveChange: MusePresentationConstants.defaultClefOctaveChange,
              updatedAtMs: now,
            ),
          ]
        : const <ClefEventEntity>[];

    final batchResult = await _projectRepository.commitScoreMutationBatch(
      ScoreMutationBatch(
        projectId: created.projectId,
        expectedRevision: created.revision,
        upsertParts: <ProjectPartEntity>[configuredPart],
        upsertClefEvents: upsertClefs,
      ),
    );
    if (batchResult case Err<int>(:final error)) {
      return _failWith(error);
    }
    final newRevision = (batchResult as Ok<int>).value;

    final updatedSummary = ProjectSummary(
      projectId: created.projectId,
      title: created.title,
      ppqn: created.ppqn,
      gridSnapTicks: created.gridSnapTicks,
      pickupTicks: created.pickupTicks,
      playbackTimingMode: created.playbackTimingMode,
      revision: newRevision,
      createdAtMs: created.createdAtMs,
      updatedAtMs: now,
    );

    final refreshResult = await _refreshCatalogAfterChange(
      soundFonts: activeSoundFonts,
      expandPageByOne: true,
    );
    if (refreshResult case Err<void>(:final error)) {
      return Err(error);
    }
    return Ok(updatedSummary);
  }

  Future<Result<void>> renameProjectInCatalog({
    required ProjectSummary project,
    required String newTitle,
  }) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) {
      return _failWith(
        const MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Project title must not be empty.',
        ),
      );
    }

    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final updateResult = await _projectRepository.updateProjectMetadata(
      UpdateProjectMetadataInput(
        projectId: project.projectId,
        expectedRevision: project.revision,
        title: trimmed,
      ),
    );
    if (updateResult case Err<void>(:final error)) {
      return _failWith(error);
    }
    return _refreshCatalogAfterChange();
  }

  Future<Result<void>> deleteProject(ProjectId projectId) async {
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    if (_activeProjectIdProvider() == projectId) {
      final detachResult = await _detachActiveProjectHook();
      if (detachResult case Err<void>(:final error)) {
        return _failWith(error);
      }
    }

    final deleteResult = await _projectRepository.softDeleteProject(
      projectId,
      deletedAtMs: _nowEpochMs(),
    );
    if (deleteResult case Err<void>(:final error)) {
      return _failWith(error);
    }

    final remaining = _state.projects
        .where((p) => p.projectId != projectId)
        .toList(growable: false);
    final removedCount = _state.projects.length - remaining.length;
    _emit(
      _state.copyWith(
        projects: List<ProjectSummary>.unmodifiable(remaining),
        nextOffset: (_state.nextOffset - removedCount).clamp(
          MusePresentationConstants.initialTick,
          remaining.length + _state.nextOffset,
        ),
        isBusy: false,
        clearLastError: true,
      ),
    );
    return const Ok(null);
  }

  Future<Result<void>> purgePartAudioTakeInCatalog({
    required ProjectId projectId,
    required PartId partId,
  }) async {
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    if (_activeProjectIdProvider() == projectId) {
      final detachResult = await _detachActiveProjectHook();
      if (detachResult case Err<void>(:final error)) {
        return _failWith(error);
      }
    }

    final purgeResult = await _projectRepository.deletePartAudioTake(
      projectId: projectId,
      partId: partId,
    );
    if (purgeResult case Err<void>(:final error)) {
      return _failWith(error);
    }
    return _refreshCatalogAfterChange();
  }

  Future<Result<int>> reclaimUnusedStorageNow() async {
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final gcResult = await _storageMaintenanceRepository.runGarbageCollection(
      olderThanEpochMs: _nowEpochMs(),
    );
    if (gcResult case Err<int>(:final error)) {
      return _failWith(error);
    }
    _emit(_state.copyWith(isBusy: false, clearLastError: true));
    return gcResult;
  }

  Future<Result<ProjectSummary?>> importMusicXmlProject({
    SoundFontId? defaultSoundFontId,
  }) async {
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final pickResult = await _externalFileExchange.pickImportFile(
      allowedExtensions: MusePresentationConstants.importMusicXmlExtensions,
    );
    if (pickResult case Err<PickedExternalFile?>(:final error)) {
      return _failWith(error);
    }
    final picked = (pickResult as Ok<PickedExternalFile?>).value;
    if (picked == null) {
      _emit(_state.copyWith(isBusy: false, clearLastError: true));
      return const Ok(null);
    }

    final Uint8List rawBytes;
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in picked.byteStream) {
        builder.add(chunk);
      }
      rawBytes = builder.takeBytes();
    } catch (error) {
      return _failWith(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Failed to read MusicXML import stream "${picked.fileName}": $error',
          cause: error,
        ),
      );
    }

    if (rawBytes.length != picked.byteLength) {
      return _failWith(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Imported file "${picked.fileName}" byte length (${rawBytes.length}) '
          'did not match declared size (${picked.byteLength}).',
        ),
      );
    }

    var activeSoundFonts = _state.soundFonts;
    if (defaultSoundFontId == null && activeSoundFonts.isEmpty) {
      final sfResult = await _assetLibraryRepository.listActiveSoundFonts();
      if (sfResult case Err<List<SoundFontCatalogEntry>>(:final error)) {
        return _failWith(error);
      }
      activeSoundFonts = (sfResult as Ok<List<SoundFontCatalogEntry>>).value;
    }

    final resolvedSfId = defaultSoundFontId ?? activeSoundFonts.firstOrNull?.sfId;
    if (resolvedSfId == null) {
      return _failWith(
        const MuseError(
          MuseErrorCode.missingSoundFontForPart,
          'Cannot import MusicXML: no active SoundFont exists in the library.',
        ),
      );
    }

    final fallbackTitle = _stripExtensionStem(picked.fileName);
    if (fallbackTitle.isEmpty) {
      return _failWith(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Cannot derive a valid project title from filename "${picked.fileName}".',
        ),
      );
    }

    final isCompressedMxl =
        picked.extension == MusePresentationConstants.compressedMxlExtension;
    final importResult = _dualModelScoreService.importFromMusicXmlBytes(
      bytes: rawBytes,
      isCompressedMxl: isCompressedMxl,
      fallbackTitle: fallbackTitle,
      defaultSoundFontId: resolvedSfId,
    );
    if (importResult case Err<ProjectWorkspaceAggregate>(:final error)) {
      return _failWith(error);
    }
    final agg = (importResult as Ok<ProjectWorkspaceAggregate>).value;

    final tick0Tempo = _findTickZeroTempo(agg.tempoEvents);
    final tick0Ts = _findTickZeroTimeSignature(agg.timeSignatureEvents);
    if (tick0Tempo == null || tick0Ts == null) {
      return _failWith(
        const MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Imported MusicXML aggregate is missing initial tick-0 tempo or time signature.',
        ),
      );
    }

    final createResult = await _projectRepository.createProject(
      CreateProjectInput(
        projectId: agg.project.projectId,
        title: agg.project.title,
        gridSnapTicks: agg.project.gridSnapTicks,
        pickupTicks: agg.project.pickupTicks,
        playbackTimingMode: agg.project.playbackTimingMode,
        initialUsPerQuarter: tick0Tempo.usPerQuarter,
        initialTimeSigNumerator: tick0Ts.numerator,
        initialTimeSigDenominator: tick0Ts.denominator,
      ),
    );
    if (createResult case Err<ProjectSummary>(:final error)) {
      return _failWith(error);
    }
    final created = (createResult as Ok<ProjectSummary>).value;

    final seededResult = await _projectRepository.loadProjectAggregate(
      created.projectId,
    );
    if (seededResult case Err<ProjectWorkspaceAggregate>(:final error)) {
      return _failWith(error);
    }
    final seeded = (seededResult as Ok<ProjectWorkspaceAggregate>).value;

    final batchResult = await _projectRepository.commitScoreMutationBatch(
      ScoreMutationBatch(
        projectId: created.projectId,
        expectedRevision: created.revision,
        deleteClefEventIds: seeded.clefEvents
            .map((c) => c.clefEventId)
            .toList(growable: false),
        deleteKeySignatureEventIds: seeded.keySignatureEvents
            .map((k) => k.keyEventId)
            .toList(growable: false),
        deletePartIds: seeded.parts
            .map((p) => p.partId)
            .toList(growable: false),
        upsertParts: agg.parts,
        upsertTempoEvents: agg.tempoEvents
            .where((e) => e.tick.value > MusePresentationConstants.initialTick)
            .toList(growable: false),
        upsertTimeSignatureEvents: agg.timeSignatureEvents
            .where((e) => e.tick.value > MusePresentationConstants.initialTick)
            .toList(growable: false),
        upsertKeySignatureEvents: agg.keySignatureEvents,
        upsertClefEvents: agg.clefEvents,
        upsertNotes: agg.notes,
        upsertSpanners: agg.spanners,
      ),
    );
    if (batchResult case Err<int>(:final error)) {
      return _failWith(error);
    }
    final newRevision = (batchResult as Ok<int>).value;

    final summary = ProjectSummary(
      projectId: created.projectId,
      title: created.title,
      ppqn: created.ppqn,
      gridSnapTicks: created.gridSnapTicks,
      pickupTicks: created.pickupTicks,
      playbackTimingMode: created.playbackTimingMode,
      revision: newRevision,
      createdAtMs: created.createdAtMs,
      updatedAtMs: _nowEpochMs(),
    );

    final refreshResult = await _refreshCatalogAfterChange(
      soundFonts: activeSoundFonts,
      expandPageByOne: true,
    );
    if (refreshResult case Err<void>(:final error)) {
      return Err(error);
    }
    return Ok(summary);
  }

  Future<Result<void>> exportProjectToMusicXml({
    required ProjectId projectId,
    required bool compressAsMxl,
  }) async {
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final loadResult = await _projectRepository.loadProjectAggregate(projectId);
    if (loadResult case Err<ProjectWorkspaceAggregate>(:final error)) {
      return _failWith(error);
    }
    final aggregate = (loadResult as Ok<ProjectWorkspaceAggregate>).value;

    final exportBytesResult = _dualModelScoreService.exportToMusicXmlBytes(
      aggregate: aggregate,
      compressAsMxl: compressAsMxl,
    );
    if (exportBytesResult case Err<List<int>>(:final error)) {
      return _failWith(error);
    }
    final bytes = (exportBytesResult as Ok<List<int>>).value;

    final stem = aggregate.project.title
        .trim()
        .replaceAll(_unsafeFileNameCharsRegex, '_');
    if (stem.isEmpty) {
      return _failWith(
        const MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Project title cannot form a valid export filename.',
        ),
      );
    }

    final suffix = compressAsMxl
        ? MusePresentationConstants.mxlExportFileSuffix
        : MusePresentationConstants.musicXmlExportFileSuffix;
    final mimeType = compressAsMxl
        ? MusePresentationConstants.mxlMimeType
        : MusePresentationConstants.musicXmlMimeType;

    final exportResult = await _externalFileExchange.exportFileToUser(
      suggestedFileName: '$stem$suffix',
      mimeType: mimeType,
      bytes: bytes,
    );
    if (exportResult case Err<void>(:final error)) {
      return _failWith(error);
    }
    _emit(_state.copyWith(isBusy: false, clearLastError: true));
    return const Ok(null);
  }

  Future<Result<void>> exportRecordedTakeToWav({
    required AudioTakeEntity take,
    required String partName,
  }) async {
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final sanitizedPart = partName
        .trim()
        .replaceAll(_unsafeFileNameCharsRegex, '_');
    final partLabel =
        sanitizedPart.isEmpty ? take.partId.value : sanitizedPart;
    final suggestedFileName =
        '${partLabel}_${take.takeId.value}${MusePresentationConstants.wavExportFileSuffix}';

    final exportResult = await _externalFileExchange.exportCasWavTakeToUser(
      wavSha256: take.blobSha256,
      suggestedFileName: suggestedFileName,
    );
    if (exportResult case Err<void>(:final error)) {
      return _failWith(error);
    }
    _emit(_state.copyWith(isBusy: false, clearLastError: true));
    return const Ok(null);
  }

  Future<Result<SoundFontCatalogEntry?>> importSoundFontFile() async {
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final pickResult = await _externalFileExchange.pickImportFile(
      allowedExtensions: MusePresentationConstants.importSoundFontExtensions,
    );
    if (pickResult case Err<PickedExternalFile?>(:final error)) {
      return _failWith(error);
    }
    final picked = (pickResult as Ok<PickedExternalFile?>).value;
    if (picked == null) {
      _emit(_state.copyWith(isBusy: false, clearLastError: true));
      return const Ok(null);
    }

    final isWeb =
        kIsWeb ||
        _audioSessionController.currentPlatform == CalibrationPlatform.web;
    if (isWeb && picked.byteLength > MuseConstants.maxWebSoundFontBytes) {
      return _failWith(
        MuseError(
          MuseErrorCode.soundFontTooLargeForWeb,
          'SoundFont "${picked.fileName}" (${picked.byteLength} bytes) exceeds the Web limit (${MuseConstants.maxWebSoundFontBytes} bytes).',
        ),
      );
    }

    final quotaResult = await _storageMaintenanceRepository
        .verifyAvailableQuotaBytes(requiredBytes: picked.byteLength);
    if (quotaResult case Err<int>(:final error)) {
      return _failWith(error);
    }

    final stem = _stripExtensionStem(picked.fileName);
    final displayName = stem.isEmpty ? picked.fileName.trim() : stem;
    final streamFactory = picked.byteStreamFactory;

    final Result<SoundFontCatalogEntry> importResult;
    if (streamFactory != null) {
      final presetResult = await _soundFontPresetParser
          .parsePresetsFromSf2Stream(
            byteStream: picked.byteStream,
            byteLength: picked.byteLength,
          );
      if (presetResult case Err<List<SoundFontPresetInfo>>(:final error)) {
        return _failWith(error);
      }
      final presets = (presetResult as Ok<List<SoundFontPresetInfo>>).value;
      importResult = await _assetLibraryRepository.importSoundFontBytes(
        displayName: displayName,
        byteStream: streamFactory(),
        byteLength: picked.byteLength,
        extractedPresets: presets,
      );
    } else {
      if (picked.byteLength > MuseConstants.maxWebSoundFontBytes) {
        return _failWith(
          MuseError(
            MuseErrorCode.soundFontTooLargeForWeb,
            'SoundFont "${picked.fileName}" (${picked.byteLength} bytes) exceeds the bounded single-pass buffer limit (${MuseConstants.maxWebSoundFontBytes} bytes).',
          ),
        );
      }

      final capturedChunks = <List<int>>[];
      var capturedByteCount = 0;
      try {
        final passThroughStream = _captureBoundedChunks(
          picked.byteStream,
          capturedChunks,
          maxBytes: MuseConstants.maxWebSoundFontBytes,
          onBytesCaptured: (count) => capturedByteCount = count,
        );
        final presetResult = await _soundFontPresetParser
            .parsePresetsFromSf2Stream(
              byteStream: passThroughStream,
              byteLength: picked.byteLength,
            );
        if (presetResult case Err<List<SoundFontPresetInfo>>(:final error)) {
          capturedChunks.clear();
          return _failWith(error);
        }
        if (capturedByteCount != picked.byteLength) {
          capturedChunks.clear();
          return _failWith(
            MuseError(
              MuseErrorCode.invalidSoundFontFormat,
              'Captured SoundFont stream length ($capturedByteCount) did not match declared size (${picked.byteLength}).',
            ),
          );
        }
        final presets = (presetResult as Ok<List<SoundFontPresetInfo>>).value;
        importResult = await _assetLibraryRepository.importSoundFontBytes(
          displayName: displayName,
          byteStream: Stream<List<int>>.fromIterable(capturedChunks),
          byteLength: picked.byteLength,
          extractedPresets: presets,
        );
      } on StateError catch (error) {
        capturedChunks.clear();
        return _failWith(
          MuseError(
            MuseErrorCode.soundFontTooLargeForWeb,
            error.message,
            cause: error,
          ),
        );
      } finally {
        capturedChunks.clear();
      }
    }

    if (importResult case Err<SoundFontCatalogEntry>(:final error)) {
      return _failWith(error);
    }
    final createdEntry = (importResult as Ok<SoundFontCatalogEntry>).value;

    final listSfResult = await _assetLibraryRepository.listActiveSoundFonts();
    if (listSfResult case Err<List<SoundFontCatalogEntry>>(:final error)) {
      return _failWith(error);
    }
    final refreshedSoundFonts =
        (listSfResult as Ok<List<SoundFontCatalogEntry>>).value;
    _emit(
      _state.copyWith(
        soundFonts: List<SoundFontCatalogEntry>.unmodifiable(
          refreshedSoundFonts,
        ),
        isBusy: false,
        clearLastError: true,
      ),
    );
    return Ok(createdEntry);
  }

  Future<Result<void>> deleteSoundFont(SoundFontId sfId) async {
    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final activeProjectId = _activeProjectIdProvider();
    final activeUsedSfIds = _activeProjectSoundFontIdsProvider();
    final wasUsedByActiveProject =
        activeProjectId != null && activeUsedSfIds.contains(sfId);

    if (wasUsedByActiveProject) {
      final detachResult = await _detachActiveProjectHook();
      if (detachResult case Err<void>(:final error)) {
        return _failWith(error);
      }
    }

    final deleteResult = await _assetLibraryRepository.softDeleteSoundFont(
      sfId,
      deletedAtMs: _nowEpochMs(),
    );
    if (deleteResult case Err<void>(:final error)) {
      return _failWith(error);
    }

    if (!wasUsedByActiveProject) {
      final unloadResult = await _playbackCoordinator.unloadUnusedSoundFont(
        sfId,
      );
      if (unloadResult case Err<void>(:final error)) {
        return _failWith(error);
      }
    }

    final gcResult = await _storageMaintenanceRepository.runGarbageCollection(
      olderThanEpochMs:
          _nowEpochMs() - MusePresentationConstants.softDeleteRetentionMs,
    );
    if (gcResult case Err<int>(:final error)) {
      return _failWith(error);
    }

    final listSfResult = await _assetLibraryRepository.listActiveSoundFonts();
    if (listSfResult case Err<List<SoundFontCatalogEntry>>(:final error)) {
      return _failWith(error);
    }
    final refreshedSoundFonts =
        (listSfResult as Ok<List<SoundFontCatalogEntry>>).value;
    _emit(
      _state.copyWith(
        soundFonts: List<SoundFontCatalogEntry>.unmodifiable(
          refreshedSoundFonts,
        ),
        isBusy: false,
        clearLastError: true,
      ),
    );

    if (wasUsedByActiveProject) {
      final reopenRes = await _reopenProjectHook(activeProjectId);
      if (reopenRes case Err<void>(:final error)) {
        return _failWith(error);
      }
    }

    return const Ok(null);
  }

  Future<Result<LatencyCalibrationProfile?>>
  loadCalibrationProfileForCurrentHardware() async {
    final status = _audioSessionController.audioSessionStatus.value;
    final hw = status.hardwareInfo;
    if (status.phase != AudioSessionPhase.ready || hw == null) {
      return _failWith(
        status.error ??
            const MuseError(
              MuseErrorCode.audioDeviceInitFailed,
              'Audio hardware is not initialized; calibration profile cannot be loaded.',
            ),
      );
    }

    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final profileResult = await _assetLibraryRepository.getCalibrationProfile(
      platform: _audioSessionController.currentPlatform,
      deviceFingerprint: hw.deviceFingerprint,
      sampleRate: hw.sampleRate,
      bufferSizeFrames: hw.outputBufferFrames,
    );
    if (profileResult case Err<LatencyCalibrationProfile?>(:final error)) {
      return _failWith(error);
    }
    final profile = (profileResult as Ok<LatencyCalibrationProfile?>).value;
    _emit(
      _state.copyWith(
        currentCalibrationProfile: profile,
        clearCalibrationProfile: profile == null,
        isBusy: false,
        clearLastError: true,
      ),
    );
    return Ok(profile);
  }

  Future<Result<LatencyCalibrationProfile>> saveCalibrationProfileAndRealign({
    required int calibrationOffsetFrames,
    ProjectId? targetProjectId,
  }) async {
    final status = _audioSessionController.audioSessionStatus.value;
    final hw = status.hardwareInfo;
    if (status.phase != AudioSessionPhase.ready || hw == null) {
      return _failWith(
        status.error ??
            const MuseError(
              MuseErrorCode.audioDeviceInitFailed,
              'Audio hardware is not initialized; calibration profile cannot be saved.',
            ),
      );
    }

    final maxOffsetFrames =
        (MusePresentationConstants.calibrationMaxOffsetMs * hw.sampleRate) ~/
        MusePresentationConstants.millisecondsPerSecond;
    if (calibrationOffsetFrames.abs() > maxOffsetFrames) {
      return _failWith(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Calibration offset ($calibrationOffsetFrames frames) exceeds ±$maxOffsetFrames frames at ${hw.sampleRate} Hz.',
        ),
      );
    }

    _emit(_state.copyWith(isBusy: true, clearLastError: true));
    final upsertResult = await _assetLibraryRepository.upsertCalibrationProfile(
      UpsertCalibrationProfileInput(
        platform: _audioSessionController.currentPlatform,
        deviceFingerprint: hw.deviceFingerprint,
        sampleRate: hw.sampleRate,
        bufferSizeFrames: hw.outputBufferFrames,
        calibrationOffsetFrames: calibrationOffsetFrames,
      ),
    );
    if (upsertResult case Err<LatencyCalibrationProfile>(:final error)) {
      return _failWith(error);
    }
    final saved = (upsertResult as Ok<LatencyCalibrationProfile>).value;
    _emit(
      _state.copyWith(
        currentCalibrationProfile: saved,
        isBusy: false,
        clearLastError: true,
      ),
    );

    final projectIdToRealign = targetProjectId ?? _activeProjectIdProvider();
    if (projectIdToRealign != null) {
      final realignResult = await _recordingCoordinator
          .realignProjectTakesForCalibration(
            projectId: projectIdToRealign,
            newCalibrationOffsetFrames: saved.calibrationOffsetFrames,
          );
      if (realignResult case Err<List<AudioTakeEntity>>(:final error)) {
        return _failWith(error);
      }
    }
    return Ok(saved);
  }

  Future<Result<void>> _refreshCatalogAfterChange({
    List<SoundFontCatalogEntry>? soundFonts,
    bool expandPageByOne = false,
  }) async {
    final limit = _state.projects.length >= MusePresentationConstants.catalogPageSize
        ? _state.projects.length + (expandPageByOne ? 1 : 0)
        : MusePresentationConstants.catalogPageSize;
    final projectsResult = await _projectRepository.listActiveProjects(
      limit: limit,
      offset: MusePresentationConstants.initialTick,
    );
    if (projectsResult case Err<List<ProjectSummary>>(:final error)) {
      return _failWith(error);
    }
    final projects = (projectsResult as Ok<List<ProjectSummary>>).value;
    _emit(
      _state.copyWith(
        projects: List<ProjectSummary>.unmodifiable(projects),
        hasMoreProjects: projects.length == limit,
        nextOffset: projects.length,
        soundFonts: soundFonts == null
            ? null
            : List<SoundFontCatalogEntry>.unmodifiable(soundFonts),
        isBusy: false,
        clearLastError: true,
      ),
    );
    return const Ok(null);
  }

  static Stream<List<int>> _captureBoundedChunks(
    Stream<List<int>> source,
    List<List<int>> capturedChunks, {
    required int maxBytes,
    required void Function(int totalBytes) onBytesCaptured,
  }) async* {
    var totalBytes = 0;
    await for (final chunk in source) {
      if (chunk.isEmpty) {
        continue;
      }
      totalBytes += chunk.length;
      if (totalBytes > maxBytes) {
        capturedChunks.clear();
        throw StateError(
          'SoundFont stream exceeded bounded cap ($maxBytes bytes).',
        );
      }
      final copy = Uint8List.fromList(chunk);
      capturedChunks.add(copy);
      onBytesCaptured(totalBytes);
      yield copy;
    }
  }

  static String _stripExtensionStem(String fileName) {
    final trimmed = fileName.trim();
    final lastDot = trimmed.lastIndexOf('.');
    if (lastDot <= 0) {
      return trimmed;
    }
    return trimmed.substring(0, lastDot).trim();
  }

  static TempoEventEntity? _findTickZeroTempo(List<TempoEventEntity> events) {
    for (final event in events) {
      if (event.tick.value == MusePresentationConstants.initialTick) {
        return event;
      }
    }
    return null;
  }

  static TimeSignatureEventEntity? _findTickZeroTimeSignature(
    List<TimeSignatureEventEntity> events,
  ) {
    for (final event in events) {
      if (event.tick.value == MusePresentationConstants.initialTick) {
        return event;
      }
    }
    return null;
  }

  /// Loads an aggregate snapshot strictly for catalog-level inspection (such
  /// as listing recorded audio takes available for purging).
  Future<Result<ProjectWorkspaceAggregate>> inspectProjectAggregateForCatalog(
    ProjectId projectId,
  ) => _projectRepository.loadProjectAggregate(projectId);

  Err<T> _failWith<T>(MuseError error) {
    _emit(_state.copyWith(isBusy: false, lastError: error));
    return Err<T>(error);
  }

  void _emit(ProjectCatalogState next) {
    _state = next;
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}

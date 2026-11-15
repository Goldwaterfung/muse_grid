/// End-to-end Flutter widget & bootstrap integration tests covering Scenarios 1–9
/// from `spec/phase6.md` via [MuseGridRootApp] and [MuseGridAppBootstrap].
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crisp_notation/crisp_notation.dart'
    show MusicFont, MusicFonts, RenderStaffSystemView, StaffSystemView;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muse_grid/app/muse_grid_app_bootstrap.dart';
import 'package:muse_grid/app/platform_wiring_types.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/domain/repositories/storage_contracts.dart';
import 'package:muse_grid/main.dart';
import 'package:muse_grid/presentation/controllers/audio_session_contract.dart';
import 'package:muse_grid/presentation/notation/staff_notation_panel.dart';
import 'package:muse_grid/presentation/piano_roll/piano_roll_panel.dart';
import 'package:muse_grid/presentation/theme/muse_presentation_constants.dart';
import 'package:muse_grid/presentation/workspace/muse_grid_workspace_screen.dart';
import 'package:muse_grid/presentation/workspace/part_mixer_sidebar.dart';
import 'package:muse_grid/presentation/workspace/transport_toolbar.dart';

final class _E2EStorageMaintenance implements IStorageMaintenanceRepository {
  MuseError? nextInitError;
  bool isClosed = false;
  int gcCount = 0;

  @override
  Future<Result<void>> initializeAndVerifyStorage() async {
    if (nextInitError != null) {
      return Err<void>(nextInitError!);
    }
    return const Ok<void>(null);
  }

  @override
  Future<Result<int>> verifyAvailableQuotaBytes({
    required int requiredBytes,
  }) async => const Ok<int>(MuseConstants.maxWebSoundFontBytes * 10);

  @override
  Future<Result<int>> runGarbageCollection({
    required int olderThanEpochMs,
  }) async {
    gcCount += 1;
    return const Ok<int>(0);
  }

  @override
  Future<void> close() async {
    isClosed = true;
  }
}

final class _E2EProjectRepository implements IProjectRepository {
  final Map<ProjectId, ProjectWorkspaceAggregate> projects =
      <ProjectId, ProjectWorkspaceAggregate>{};
  int _clock = 1000;
  int _takeSeq = 0;

  @override
  Future<Result<List<ProjectSummary>>> listActiveProjects({
    required int limit,
    required int offset,
  }) async {
    final list = projects.values
        .map((agg) => agg.project)
        .toList(growable: false);
    if (offset >= list.length) {
      return const Ok<List<ProjectSummary>>(<ProjectSummary>[]);
    }
    final end = (offset + limit) > list.length ? list.length : (offset + limit);
    return Ok<List<ProjectSummary>>(list.sublist(offset, end));
  }

  @override
  Future<Result<ProjectWorkspaceAggregate>> loadProjectAggregate(
    ProjectId projectId,
  ) async {
    final agg = projects[projectId];
    if (agg == null) {
      return const Err<ProjectWorkspaceAggregate>(
        MuseError(MuseErrorCode.entityNotFound, 'Project not found.'),
      );
    }
    return Ok<ProjectWorkspaceAggregate>(agg);
  }

  @override
  Future<Result<ProjectSummary>> createProject(CreateProjectInput input) async {
    _clock += 10;
    final summary = ProjectSummary(
      projectId: input.projectId,
      title: input.title,
      ppqn: MuseConstants.ppqn,
      gridSnapTicks: input.gridSnapTicks,
      pickupTicks: input.pickupTicks,
      playbackTimingMode: input.playbackTimingMode,
      revision: 1,
      createdAtMs: _clock,
      updatedAtMs: _clock,
    );
    projects[input.projectId] = ProjectWorkspaceAggregate(
      project: summary,
      parts: <ProjectPartEntity>[
        ProjectPartEntity(
          partId: PartId('part-${input.projectId.value}-1'),
          projectId: input.projectId,
          musicXmlPartId: 'P1',
          sortOrder: 0,
          name: 'Part 1',
          stavesCount: 1,
          midiChannel: 0,
          sfId: null,
          bankNum: 0,
          programNum: 0,
          gainDb: 0.0,
          pan: 0.0,
          isMuted: false,
          isSolo: false,
          updatedAtMs: _clock,
        ),
      ],
      tempoEvents: <TempoEventEntity>[
        TempoEventEntity(
          tempoEventId: TempoEventId('t0-${input.projectId.value}'),
          projectId: input.projectId,
          tick: const Tick(0),
          usPerQuarter: input.initialUsPerQuarter,
          updatedAtMs: _clock,
        ),
      ],
      timeSignatureEvents: <TimeSignatureEventEntity>[
        TimeSignatureEventEntity(
          tsEventId: TimeSigEventId('ts0-${input.projectId.value}'),
          projectId: input.projectId,
          tick: const Tick(0),
          numerator: input.initialTimeSigNumerator,
          denominator: input.initialTimeSigDenominator,
          updatedAtMs: _clock,
        ),
      ],
      keySignatureEvents: const <KeySignatureEventEntity>[],
      clefEvents: const <ClefEventEntity>[],
      notes: const <TimelineNote>[],
      spanners: const <NoteSpannerEntity>[],
      audioTakes: const <AudioTakeEntity>[],
    );
    return Ok<ProjectSummary>(summary);
  }

  @override
  Future<Result<void>> updateProjectMetadata(
    UpdateProjectMetadataInput input,
  ) async {
    final existing = projects[input.projectId];
    if (existing == null) {
      return const Err<void>(
        MuseError(MuseErrorCode.entityNotFound, 'Missing project.'),
      );
    }
    _clock += 1;
    final nextProject = ProjectSummary(
      projectId: existing.project.projectId,
      title: input.title ?? existing.project.title,
      ppqn: existing.project.ppqn,
      gridSnapTicks: input.gridSnapTicks ?? existing.project.gridSnapTicks,
      pickupTicks: input.pickupTicks ?? existing.project.pickupTicks,
      playbackTimingMode:
          input.playbackTimingMode ?? existing.project.playbackTimingMode,
      revision: existing.project.revision + 1,
      createdAtMs: existing.project.createdAtMs,
      updatedAtMs: _clock,
    );
    projects[input.projectId] = ProjectWorkspaceAggregate(
      project: nextProject,
      parts: existing.parts,
      tempoEvents: existing.tempoEvents,
      timeSignatureEvents: existing.timeSignatureEvents,
      keySignatureEvents: existing.keySignatureEvents,
      clefEvents: existing.clefEvents,
      notes: existing.notes,
      spanners: existing.spanners,
      audioTakes: existing.audioTakes,
    );
    return const Ok<void>(null);
  }

  @override
  Future<Result<void>> softDeleteProject(
    ProjectId projectId, {
    required int deletedAtMs,
  }) async {
    projects.remove(projectId);
    return const Ok<void>(null);
  }

  @override
  Future<Result<int>> commitScoreMutationBatch(ScoreMutationBatch batch) async {
    final existing = projects[batch.projectId];
    if (existing == null) {
      return const Err<int>(
        MuseError(MuseErrorCode.entityNotFound, 'Missing project.'),
      );
    }
    if (existing.project.revision != batch.expectedRevision) {
      return const Err<int>(
        MuseError(MuseErrorCode.revisionConflict, 'Revision conflict.'),
      );
    }
    _clock += 1;
    final nextRev = existing.project.revision + 1;

    final meta = batch.projectMetadataUpdate;
    final nextProject = ProjectSummary(
      projectId: existing.project.projectId,
      title: meta?.title ?? existing.project.title,
      ppqn: existing.project.ppqn,
      gridSnapTicks: meta?.gridSnapTicks ?? existing.project.gridSnapTicks,
      pickupTicks: meta?.pickupTicks ?? existing.project.pickupTicks,
      playbackTimingMode:
          meta?.playbackTimingMode ?? existing.project.playbackTimingMode,
      revision: nextRev,
      createdAtMs: existing.project.createdAtMs,
      updatedAtMs: _clock,
    );

    final parts = <PartId, ProjectPartEntity>{
      for (final p in existing.parts) p.partId: p,
    };
    for (final id in batch.deletePartIds) {
      parts.remove(id);
    }
    for (final p in batch.upsertParts) {
      parts[p.partId] = p;
    }

    final tempos = <TempoEventId, TempoEventEntity>{
      for (final e in existing.tempoEvents) e.tempoEventId: e,
    };
    for (final id in batch.deleteTempoEventIds) {
      tempos.remove(id);
    }
    for (final e in batch.upsertTempoEvents) {
      tempos[e.tempoEventId] = e;
    }

    final tsEvents = <TimeSigEventId, TimeSignatureEventEntity>{
      for (final e in existing.timeSignatureEvents) e.tsEventId: e,
    };
    for (final id in batch.deleteTimeSignatureEventIds) {
      tsEvents.remove(id);
    }
    for (final e in batch.upsertTimeSignatureEvents) {
      tsEvents[e.tsEventId] = e;
    }

    final keyEvents = <KeySigEventId, KeySignatureEventEntity>{
      for (final e in existing.keySignatureEvents) e.keyEventId: e,
    };
    for (final id in batch.deleteKeySignatureEventIds) {
      keyEvents.remove(id);
    }
    for (final e in batch.upsertKeySignatureEvents) {
      keyEvents[e.keyEventId] = e;
    }

    final clefEvents = <ClefEventId, ClefEventEntity>{
      for (final e in existing.clefEvents) e.clefEventId: e,
    };
    for (final id in batch.deleteClefEventIds) {
      clefEvents.remove(id);
    }
    for (final e in batch.upsertClefEvents) {
      clefEvents[e.clefEventId] = e;
    }

    final notes = <NoteId, TimelineNote>{
      for (final n in existing.notes) n.noteId: n,
    };
    for (final id in batch.deleteNoteIds) {
      notes.remove(id);
    }
    for (final n in batch.upsertNotes) {
      notes[n.noteId] = n;
    }

    final spanners = <SpannerId, NoteSpannerEntity>{
      for (final s in existing.spanners) s.spannerId: s,
    };
    for (final id in batch.deleteSpannerIds) {
      spanners.remove(id);
    }
    for (final s in batch.upsertSpanners) {
      spanners[s.spannerId] = s;
    }

    final takes = <TakeId, AudioTakeEntity>{
      for (final t in existing.audioTakes) t.takeId: t,
    };
    for (final partId in batch.deleteAudioTakePartIds) {
      takes.removeWhere((_, t) => t.partId == partId);
    }
    for (final t in batch.upsertAudioTakes) {
      takes[t.takeId] = t;
    }

    projects[batch.projectId] = ProjectWorkspaceAggregate(
      project: nextProject,
      parts: parts.values.toList(growable: false),
      tempoEvents: tempos.values.toList(growable: false),
      timeSignatureEvents: tsEvents.values.toList(growable: false),
      keySignatureEvents: keyEvents.values.toList(growable: false),
      clefEvents: clefEvents.values.toList(growable: false),
      notes: notes.values.toList(growable: false),
      spanners: spanners.values.toList(growable: false),
      audioTakes: takes.values.toList(growable: false),
    );
    return Ok<int>(nextRev);
  }

  @override
  Future<Result<AudioTakeEntity>> promoteAndCommitRecordedTake({
    required RecordingCaptureReceipt receipt,
    required ProjectId projectId,
    required PartId partId,
    required Tick alignedStartTick,
    required int calibrationOffsetFrames,
  }) async {
    _clock += 10;
    _takeSeq += 1;
    final take = AudioTakeEntity(
      takeId: TakeId('take-e2e-$_takeSeq'),
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
      createdAtMs: _clock,
      updatedAtMs: _clock,
    );
    return Ok<AudioTakeEntity>(take);
  }

  @override
  Future<Result<List<AudioTakeEntity>>> realignAudioTakesCalibration({
    required ProjectId projectId,
    required List<AudioTakeRealignmentUpdate> updates,
  }) async => const Ok<List<AudioTakeEntity>>(<AudioTakeEntity>[]);

  @override
  Future<Result<void>> deletePartAudioTake({
    required ProjectId projectId,
    required PartId partId,
  }) async => const Ok<void>(null);
}

final class _E2EAssetLibraryRepository implements IAssetLibraryRepository {
  final List<SoundFontCatalogEntry> entries = <SoundFontCatalogEntry>[];
  LatencyCalibrationProfile? savedCalibration;
  int _sfSeq = 0;

  @override
  Future<Result<List<SoundFontCatalogEntry>>> listActiveSoundFonts() async =>
      Ok<List<SoundFontCatalogEntry>>(
        List<SoundFontCatalogEntry>.unmodifiable(entries),
      );

  @override
  Future<Result<SoundFontCatalogEntry>> importSoundFontBytes({
    required String displayName,
    required Stream<List<int>> byteStream,
    required int byteLength,
    required List<SoundFontPresetInfo> extractedPresets,
  }) async {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in byteStream) {
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    final digest = crypto.sha256.convert(bytes).toString();
    _sfSeq += 1;
    final entry = SoundFontCatalogEntry(
      sfId: SoundFontId('sf-e2e-$_sfSeq'),
      name: displayName,
      blobSha256: Sha256Digest(digest),
      byteSize: byteLength,
      presets: List<SoundFontPresetInfo>.unmodifiable(extractedPresets),
      createdAtMs: 200,
      updatedAtMs: 200,
    );
    entries.add(entry);
    return Ok<SoundFontCatalogEntry>(entry);
  }

  @override
  Future<Result<void>> softDeleteSoundFont(
    SoundFontId sfId, {
    required int deletedAtMs,
  }) async {
    entries.removeWhere((e) => e.sfId == sfId);
    return const Ok<void>(null);
  }

  @override
  Future<Result<LatencyCalibrationProfile?>> getCalibrationProfile({
    required CalibrationPlatform platform,
    required String deviceFingerprint,
    required int sampleRate,
    required int bufferSizeFrames,
  }) async => Ok<LatencyCalibrationProfile?>(savedCalibration);

  @override
  Future<Result<LatencyCalibrationProfile>> upsertCalibrationProfile(
    UpsertCalibrationProfileInput input,
  ) async {
    final profile = LatencyCalibrationProfile(
      profileId: const CalibrationProfileId('cal-e2e-1'),
      platform: input.platform,
      deviceFingerprint: input.deviceFingerprint,
      sampleRate: input.sampleRate,
      bufferSizeFrames: input.bufferSizeFrames,
      calibrationOffsetFrames: input.calibrationOffsetFrames,
      updatedAtMs: 500,
    );
    savedCalibration = profile;
    return Ok<LatencyCalibrationProfile>(profile);
  }
}

final class _E2EExternalFileExchange implements IExternalFileExchange {
  @override
  Future<Result<PickedExternalFile?>> pickImportFile({
    required List<String> allowedExtensions,
  }) async => const Ok<PickedExternalFile?>(null);

  @override
  Future<Result<void>> exportFileToUser({
    required String suggestedFileName,
    required String mimeType,
    required List<int> bytes,
  }) async => const Ok<void>(null);

  @override
  Future<Result<void>> exportCasWavTakeToUser({
    required Sha256Digest wavSha256,
    required String suggestedFileName,
  }) async => const Ok<void>(null);
}

final class _E2EAudioBridge
    implements
        IAudioLifecycleBridge,
        ITransportBridge,
        ISynthEventBridge,
        IRecordingBridge,
        ITelemetryBridge {
  static const AudioHardwareInfo _defaultHw = AudioHardwareInfo(
    sampleRate: 48000,
    inputChannels: 1,
    outputChannels: 2,
    inputBufferFrames: 256,
    outputBufferFrames: 256,
    deviceFingerprint: 'e2e-coreaudio',
  );

  bool _initialized = false;
  int initializeCalls = 0;
  int loadSoundFontCalls = 0;
  int syncTakesCalls = 0;
  bool disposed = false;
  int _sfHandleSeq = 0;
  EpochId _epoch = const EpochId(1);
  bool isPlaying = false;
  bool isRecording = false;
  TelemetrySnapshot? _latestSnapshot;

  final List<({int midiChannel, int pitchMidi, int velocity, bool isNoteOn})>
  auditionEvents =
      <({int midiChannel, int pitchMidi, int velocity, bool isNoteOn})>[];
  final List<TelemetrySnapshot> queuedTelemetry = <TelemetrySnapshot>[];

  @override
  AudioHardwareInfo get currentHardwareInfo {
    if (!_initialized) {
      throw StateError('Audio engine not initialized');
    }
    return _defaultHw;
  }

  @override
  Future<Result<AudioHardwareInfo>> initialize() async {
    initializeCalls += 1;
    _initialized = true;
    return const Ok<AudioHardwareInfo>(_defaultHw);
  }

  @override
  Future<Result<void>> dispose() async {
    disposed = true;
    return const Ok<void>(null);
  }

  @override
  Future<Result<LoadedSoundFontDescriptor>> loadSoundFontFromCas({
    required Sha256Digest sha256,
  }) async {
    loadSoundFontCalls += 1;
    _sfHandleSeq += 1;
    return Ok<LoadedSoundFontDescriptor>(
      LoadedSoundFontDescriptor(
        handle: SoundFontHandle(_sfHandleSeq),
        presets: const <SoundFontPresetInfo>[
          SoundFontPresetInfo(
            bankNum: 0,
            programNum: 0,
            presetName: 'Acoustic Grand Piano',
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<void>> unloadSoundFont(SoundFontHandle handle) async =>
      const Ok<void>(null);

  @override
  Result<void> play() {
    isPlaying = true;
    return const Ok<void>(null);
  }

  @override
  Result<void> pause() {
    isPlaying = false;
    return const Ok<void>(null);
  }

  @override
  Result<void> stop() {
    isPlaying = false;
    return const Ok<void>(null);
  }

  @override
  Result<EpochId> seekToSample(SampleFrame targetFrame) {
    _epoch = EpochId(_epoch.value + 1);
    return Ok<EpochId>(_epoch);
  }

  @override
  Result<void> setLoopRegion({
    required bool enabled,
    required SampleFrame startFrame,
    required SampleFrame endFrame,
  }) => const Ok<void>(null);

  @override
  Future<Result<void>> syncActiveTakeRegions(
    List<ActiveTakePlaybackRegion> regions,
  ) async {
    syncTakesCalls += 1;
    return const Ok<void>(null);
  }

  @override
  EpochId get currentEpoch => _epoch;

  @override
  Result<EpochId> flushAndAdvanceEpoch() {
    _epoch = EpochId(_epoch.value + 1);
    return Ok<EpochId>(_epoch);
  }

  @override
  Result<int> scheduleEvents(
    List<ScheduledMidiEvent> events, {
    SampleFrame? scheduledUpToFrame,
  }) => Ok<int>(events.length);

  @override
  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  }) => const Ok<void>(null);

  @override
  Result<void> setChannelMix({
    required int midiChannel,
    required double gainDb,
    required double pan,
  }) => const Ok<void>(null);

  @override
  Result<void> silenceChannel(int midiChannel) => const Ok<void>(null);

  @override
  Result<void> triggerLiveAuditionNote({
    required int midiChannel,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  }) {
    auditionEvents.add((
      midiChannel: midiChannel,
      pitchMidi: pitchMidi,
      velocity: velocity,
      isNoteOn: isNoteOn,
    ));
    return const Ok<void>(null);
  }

  @override
  Result<void> setMonitorGain(double gainLinear) => const Ok<void>(null);

  @override
  Future<Result<void>> prepareAndStartCapture(TakeId takeId) async {
    isRecording = true;
    return const Ok<void>(null);
  }

  @override
  Future<Result<RecordingCaptureReceipt>> stopAndFinalizeCapture(
    TakeId takeId,
  ) async {
    isRecording = false;
    return Ok<RecordingCaptureReceipt>(
      RecordingCaptureReceipt(
        takeId: takeId,
        stagingPath: 'staging/rec_${takeId.value}.wav.part',
        sha256: const Sha256Digest(
          '0000000000000000000000000000000000000000000000000000000000000000',
        ),
        capturedSampleClock: const SampleFrame(0),
        capturedPlayheadFrame: const SampleFrame(0),
        durationFrames: 4800,
        sampleRate: _defaultHw.sampleRate,
        channelCount: 1,
        outputBufferFrames: _defaultHw.outputBufferFrames,
        inputBufferFrames: _defaultHw.inputBufferFrames,
      ),
    );
  }

  @override
  TelemetrySnapshot? get latestSnapshot => _latestSnapshot;

  @override
  List<TelemetrySnapshot> drainTelemetry({
    int maxFrames = MuseConstants.maxTelemetryDrainFrames,
  }) {
    if (queuedTelemetry.isEmpty) {
      return const <TelemetrySnapshot>[];
    }
    final drained = queuedTelemetry.take(maxFrames).toList(growable: false);
    final removeCount = drained.length;
    queuedTelemetry.removeRange(0, removeCount);
    _latestSnapshot = drained.last;
    return drained;
  }
}

final class _ManualTestTicker extends Ticker {
  final TickerCallback _callback;

  _ManualTestTicker(this._callback) : super(_callback);

  @override
  TickerFuture start() => TickerFuture.complete();

  @override
  void stop({bool canceled = false}) {}

  void step([Duration elapsed = const Duration(milliseconds: 16)]) {
    _callback(elapsed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ByteData realDefaultSf2Bytes;

  setUpAll(() async {
    await MusicFonts.load(MusicFont.bravura);
    final raw = await File(MuseConstants.defaultSoundFontAssetPath).readAsBytes();
    realDefaultSf2Bytes = ByteData.sublistView(raw);
  });

  ({
    MuseGridAppBootstrap bootstrap,
    _E2EStorageMaintenance storage,
    _E2EProjectRepository projectRepo,
    _E2EAssetLibraryRepository assetRepo,
    _E2EAudioBridge bridge,
    _ManualTestTicker? Function() getTicker,
  })
  buildTestBootstrap({
    CalibrationPlatform platform = CalibrationPlatform.macos,
    bool requiresExplicitAudioUserGesture = false,
  }) {
    final storage = _E2EStorageMaintenance();
    final projectRepo = _E2EProjectRepository();
    final assetRepo = _E2EAssetLibraryRepository();
    final fileExchange = _E2EExternalFileExchange();
    final bridge = _E2EAudioBridge();
    _ManualTestTicker? ticker;
    var uuidSeq = 0;

    final wiring = MuseGridPlatformWiring(
      storageMaintenance: storage,
      createProjectRepository: () => projectRepo,
      createAssetLibraryRepository: () => assetRepo,
      externalFileExchange: fileExchange,
      audioLifecycleBridge: bridge,
      transportBridge: bridge,
      synthEventBridge: bridge,
      recordingBridge: bridge,
      telemetryBridge: bridge,
      currentPlatform: platform,
      requiresExplicitAudioUserGesture: requiresExplicitAudioUserGesture,
    );

    final bootstrap = MuseGridAppBootstrap(
      platformWiringOverride: wiring,
      loadNotationFontHook: (_) async {
        if (MusicFonts.metadataOrNull(MusicFont.bravura) == null) {
          return const Err<void>(
            MuseError(
              MuseErrorCode.casBlobMissing,
              BootstrapConstants.missingBravuraFontMessage,
            ),
          );
        }
        return const Ok<void>(null);
      },
      loadAssetByteDataHook: (assetPath) async {
        if (assetPath == MuseConstants.defaultSoundFontAssetPath) {
          return realDefaultSf2Bytes;
        }
        throw StateError('Unexpected asset lookup: $assetPath');
      },
      nowEpochMs: () => 10000 + (++uuidSeq),
      uuidV7Generator: () => 'e2e-id-${++uuidSeq}',
      telemetryTickerFactory: (onTick) {
        ticker = _ManualTestTicker(onTick);
        return ticker!;
      },
      playbackPeriodicTimerFactory: (_, _) =>
          Timer(const Duration(days: 1), () {}),
      countInDelay: (_) async {},
      auditionReleaseDelay: (_) async {},
    );

    return (
      bootstrap: bootstrap,
      storage: storage,
      projectRepo: projectRepo,
      assetRepo: assetRepo,
      bridge: bridge,
      getTicker: () => ticker,
    );
  }

  testWidgets(
    'Scenarios 1–6: Cold boot SF2 seed & Bravura -> Blank project -> Piano Roll Draw -> Undo/Redo -> Staff tap audition -> Play/Stop telemetry',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final env = buildTestBootstrap();

      await tester.pumpWidget(MuseGridRootApp(bootstrapOverride: env.bootstrap));
      // Allow async SF2 stream preset parsing to finish cleanly across FakeAsync.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      // Scenario 1: Default SoundFont seeded from real asset + Bravura ready -> Catalog view.
      expect(find.byKey(const Key('project_catalog_view')), findsOneWidget);
      expect(MusicFonts.metadataOrNull(MusicFont.bravura), isNotNull);
      expect(env.assetRepo.entries.length, 1);
      expect(
        env.assetRepo.entries.first.byteSize,
        MuseConstants.defaultSoundFontByteSize,
      );
      expect(env.assetRepo.entries.first.presets, isNotEmpty);

      final initResult = await env.bootstrap.initialize();
      final bundle = (initResult as Ok<MuseGridControllerBundle>).value;

      // Scenario 2: Create Blank Project -> opens full workspace views.
      await tester.tap(find.byKey(const Key('catalog_new_project_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('new_project_title_field')),
        'E2E Sonata',
      );
      await tester.tap(find.byKey(const Key('new_project_confirm_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('project_catalog_view')), findsNothing);
      expect(find.byType(StaffNotationPanel), findsOneWidget);
      expect(find.byType(PianoRollPanel), findsOneWidget);
      expect(find.byType(TransportToolbar), findsOneWidget);
      expect(find.byType(PartMixerSidebar), findsOneWidget);

      // Scenario 3: Switch Piano Roll to Draw tool & draw a note -> updates Staff + auditions.
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();

      final canvasFinder = find.byKey(const Key('piano_roll_grid_canvas'));
      final canvasRect = tester.getRect(canvasFinder);
      final startPoint = Offset(canvasRect.left + 20.0, canvasRect.top + 80.0);
      final endPoint = Offset(canvasRect.left + 80.0, canvasRect.top + 80.0);

      final auditionCountBeforeDraw = env.bridge.auditionEvents.length;
      final gesture = await tester.startGesture(startPoint);
      await tester.pump();
      await gesture.moveTo(endPoint);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        bundle.workspaceShellController.currentWorkspace!.aggregate.notes.length,
        1,
      );
      expect(
        env.bridge.auditionEvents.length,
        greaterThanOrEqualTo(auditionCountBeforeDraw + 2),
      );

      // Scenario 4: Undo & Redo buttons toggle canUndo/canRedo and revert/reapply both grid & staff.
      expect(bundle.workspaceShellController.state.canUndo, isTrue);
      expect(bundle.workspaceShellController.state.canRedo, isFalse);

      await tester.tap(find.byKey(const Key('transport_undo_button')));
      await tester.pumpAndSettle();
      expect(
        bundle.workspaceShellController.currentWorkspace!.aggregate.notes,
        isEmpty,
      );
      expect(bundle.workspaceShellController.state.canUndo, isFalse);
      expect(bundle.workspaceShellController.state.canRedo, isTrue);

      await tester.tap(find.byKey(const Key('transport_redo_button')));
      await tester.pumpAndSettle();
      expect(
        bundle.workspaceShellController.currentWorkspace!.aggregate.notes.length,
        1,
      );
      expect(bundle.workspaceShellController.state.canUndo, isTrue);
      expect(bundle.workspaceShellController.state.canRedo, isFalse);

      // Scenario 5: Tap rendered note in StaffSystemView -> highlights element & plays audition note.
      final insertedNote = bundle
          .workspaceShellController
          .currentWorkspace!
          .aggregate
          .notes
          .single;
      final renderStaff = tester.renderObject<RenderStaffSystemView>(
        find.byType(StaffSystemView),
      );
      final layout = renderStaff.systemLayout!;
      final staffOrigin = renderStaff.staffOrigin(0);
      final staffSpace =
          NotationViewConstants.baseStaffSpacePx *
          bundle.staffNotationViewController.zoomScale;
      final noteRegion = layout.staves.first.regions.firstWhere(
        (r) => r.elementId == insertedNote.noteId.value,
      );
      final noteCenterLocal =
          staffOrigin +
          Offset(
                (noteRegion.bounds.left + noteRegion.bounds.right) / 2.0,
                (noteRegion.bounds.top + noteRegion.bounds.bottom) / 2.0,
              ) *
              staffSpace;
      final noteGlobal = renderStaff.localToGlobal(noteCenterLocal);

      final auditionCountBeforeTap = env.bridge.auditionEvents.length;
      await tester.tapAt(noteGlobal);
      await tester.pumpAndSettle();

      expect(
        bundle.staffNotationViewController.selectedNoteIds,
        contains(insertedNote.noteId),
      );
      expect(
        bundle.staffNotationViewController.highlightedCrispElementIds,
        isNotEmpty,
      );
      expect(
        env.bridge.auditionEvents.length,
        greaterThanOrEqualTo(auditionCountBeforeTap + 2),
      );

      // Scenario 6: Play advances playheadTick via drained telemetry; Stop resets tick to 0.
      await tester.tap(find.byKey(const Key('transport_play_button')));
      await tester.pumpAndSettle();
      expect(bundle.transportAndTelemetryController.isPlaying, isTrue);

      env.bridge.queuedTelemetry.add(
        TelemetrySnapshot(
          playheadSampleFrame: const SampleFrame(48000),
          activeEpoch: env.bridge.currentEpoch,
          outputPeakL: 0.25,
          outputPeakR: 0.25,
          outputRmsL: 0.12,
          outputRmsR: 0.12,
          inputPeak: 0.0,
          inputRms: 0.0,
          isPlaying: true,
          isCapturing: false,
          hasEventQueueUnderrun: false,
          hasCaptureBufferOverflow: false,
          hasTakePlaybackUnderrun: false,
        ),
      );
      env.getTicker()!.step();
      await tester.pump();
      expect(
        bundle.transportAndTelemetryController.playheadTick.value.value,
        MuseConstants.quarterNoteTicks * 2,
      );

      await tester.tap(find.byKey(const Key('transport_stop_button')));
      await tester.pumpAndSettle();
      expect(bundle.transportAndTelemetryController.isPlaying, isFalse);
      expect(
        bundle.transportAndTelemetryController.playheadTick.value,
        const Tick(0),
      );

      // Cleanly return to catalog & unmount so stream subscriptions close inside FakeAsync.
      await tester.tap(find.byKey(const Key('transport_back_to_catalog')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    },
  );

  testWidgets(
    'Scenario 7: Web AudioSessionPhase.requiresWebUserGesture banner blocks until tapped then attaches workspace',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final env = buildTestBootstrap(
        platform: CalibrationPlatform.web,
        requiresExplicitAudioUserGesture: true,
      );

      await tester.pumpWidget(MuseGridRootApp(bootstrapOverride: env.bootstrap));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('catalog_new_project_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new_project_confirm_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('web_audio_gesture_banner')), findsOneWidget);
      expect(find.byKey(const Key('enable_web_audio_button')), findsOneWidget);
      expect(env.bridge.initializeCalls, 0);
      expect(env.bridge.syncTakesCalls, 0);

      await tester.tap(find.byKey(const Key('enable_web_audio_button')));
      await tester.pumpAndSettle();

      expect(env.bridge.initializeCalls, 1);
      expect(
        env.bootstrap.audioSessionStatus.value.phase,
        AudioSessionPhase.ready,
      );
      expect(find.byKey(const Key('web_audio_gesture_banner')), findsNothing);
      expect(env.bridge.syncTakesCalls, greaterThanOrEqualTo(1));

      await tester.tap(find.byKey(const Key('transport_back_to_catalog')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    },
  );

  testWidgets(
    'Scenario 8: captureBufferOverflow in drained telemetry stops recording fail-closed and displays error banner',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final env = buildTestBootstrap();

      await tester.pumpWidget(MuseGridRootApp(bootstrapOverride: env.bootstrap));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      final bundle =
          (await env.bootstrap.initialize() as Ok<MuseGridControllerBundle>)
              .value;

      await tester.tap(find.byKey(const Key('catalog_new_project_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new_project_confirm_button')));
      await tester.pumpAndSettle();

      final partId = bundle
          .workspaceShellController
          .currentWorkspace!
          .aggregate
          .parts
          .first
          .partId;

      await tester.tap(find.byKey(Key('part_arm_${partId.value}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('transport_record_button')));
      await tester.pumpAndSettle();

      expect(bundle.transportAndTelemetryController.isRecording, isTrue);

      env.bridge.queuedTelemetry.add(
        TelemetrySnapshot(
          playheadSampleFrame: const SampleFrame(0),
          activeEpoch: env.bridge.currentEpoch,
          outputPeakL: 0.0,
          outputPeakR: 0.0,
          outputRmsL: 0.0,
          outputRmsR: 0.0,
          inputPeak: 0.1,
          inputRms: 0.05,
          isPlaying: false,
          isCapturing: true,
          hasEventQueueUnderrun: false,
          hasCaptureBufferOverflow: true,
          hasTakePlaybackUnderrun: false,
        ),
      );
      env.getTicker()!.step();
      await tester.pumpAndSettle();

      expect(bundle.transportAndTelemetryController.isRecording, isFalse);
      expect(find.byKey(const Key('transport_alert_banner')), findsOneWidget);
      expect(
        find.textContaining(MuseErrorCode.captureBufferOverflow.name),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('transport_back_to_catalog')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    },
  );

  testWidgets(
    'Scenario 9: Fail-closed sqliteJournalModeMismatch during bootstrap displays fatal error screen with verbatim code',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final env = buildTestBootstrap();
      env.storage.nextInitError = const MuseError(
        MuseErrorCode.sqliteJournalModeMismatch,
        'SQLite journal_mode did not enter WAL.',
      );

      await tester.pumpWidget(MuseGridRootApp(bootstrapOverride: env.bootstrap));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('bootstrap_fatal_error_screen')),
        findsOneWidget,
      );
      expect(
        find.textContaining(MuseErrorCode.sqliteJournalModeMismatch.name),
        findsOneWidget,
      );
      expect(
        find.text('SQLite journal_mode did not enter WAL.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('project_catalog_view')), findsNothing);
      expect(find.byType(MuseGridWorkspaceScreen), findsNothing);
    },
  );
}

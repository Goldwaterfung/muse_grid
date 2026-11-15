import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/domain/notation/dual_model_score_service.dart';
import 'package:muse_grid/domain/playback/lookahead_playback_coordinator.dart';
import 'package:muse_grid/domain/recording/recording_session_coordinator.dart';
import 'package:muse_grid/domain/repositories/storage_contracts.dart';

final class _FakeRecordingAudioBridge
    implements
        IAudioLifecycleBridge,
        ITransportBridge,
        ISynthEventBridge,
        IRecordingBridge,
        ITelemetryBridge {
  AudioHardwareInfo hardwareInfo = const AudioHardwareInfo(
    sampleRate: 48000,
    inputChannels: 1,
    outputChannels: 2,
    inputBufferFrames: 128,
    outputBufferFrames: 256,
    deviceFingerprint: 'usb-audio-1',
  );

  EpochId _epoch = const EpochId(1);
  TelemetrySnapshot? latest;
  double? lastMonitorGain;
  TakeId? activeCaptureTakeId;
  MuseError? nextPrepareCaptureError;
  MuseError? nextFinalizeCaptureError;
  RecordingCaptureReceipt? nextReceipt;

  final List<({int channel, SoundFontHandle handle, int bank, int program})>
  patchCalls =
      <({int channel, SoundFontHandle handle, int bank, int program})>[];
  final List<({bool enabled, SampleFrame start, SampleFrame end})> loopCalls =
      <({bool enabled, SampleFrame start, SampleFrame end})>[];
  final List<int> silencedChannels = <int>[];
  final List<ScheduledMidiEvent> scheduledEvents = <ScheduledMidiEvent>[];
  final List<List<ActiveTakePlaybackRegion>> syncedTakesHistory =
      <List<ActiveTakePlaybackRegion>>[];
  final List<String> ops = <String>[];

  @override
  AudioHardwareInfo get currentHardwareInfo => hardwareInfo;

  @override
  Future<Result<AudioHardwareInfo>> initialize() async => Ok(hardwareInfo);

  @override
  Future<Result<LoadedSoundFontDescriptor>> loadSoundFontFromCas({
    required Sha256Digest sha256,
  }) async {
    return const Ok(
      LoadedSoundFontDescriptor(
        handle: SoundFontHandle(42),
        presets: <SoundFontPresetInfo>[
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Standard'),
        ],
      ),
    );
  }

  @override
  Future<Result<void>> unloadSoundFont(SoundFontHandle handle) async =>
      const Ok(null);

  @override
  Future<void> dispose() async {}

  @override
  Result<void> play() {
    ops.add('play');
    return const Ok(null);
  }

  @override
  Result<void> pause() {
    ops.add('pause');
    return const Ok(null);
  }

  @override
  Result<void> stop() {
    ops.add('stop');
    return const Ok(null);
  }

  @override
  Result<EpochId> seekToSample(SampleFrame targetFrame) {
    _epoch = EpochId(_epoch.value + 1);
    ops.add('seek:${targetFrame.value}');
    return Ok(_epoch);
  }

  @override
  Result<void> setLoopRegion({
    required bool enabled,
    required SampleFrame startFrame,
    required SampleFrame endFrame,
  }) {
    loopCalls.add((enabled: enabled, start: startFrame, end: endFrame));
    ops.add('loop:$enabled:${startFrame.value}:${endFrame.value}');
    return const Ok(null);
  }

  @override
  Future<Result<void>> syncActiveTakeRegions(
    List<ActiveTakePlaybackRegion> regions,
  ) async {
    syncedTakesHistory.add(List<ActiveTakePlaybackRegion>.unmodifiable(regions));
    return const Ok(null);
  }

  @override
  EpochId get currentEpoch => _epoch;

  @override
  Result<EpochId> flushAndAdvanceEpoch() {
    _epoch = EpochId(_epoch.value + 1);
    return Ok(_epoch);
  }

  @override
  Result<int> scheduleEvents(
    List<ScheduledMidiEvent> events, {
    SampleFrame? scheduledUpToFrame,
  }) {
    scheduledEvents.addAll(events);
    return Ok(events.length);
  }

  @override
  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  }) {
    patchCalls.add((
      channel: midiChannel,
      handle: sfHandle,
      bank: bankNum,
      program: programNum,
    ));
    return const Ok(null);
  }

  @override
  Result<void> setChannelMix({
    required int midiChannel,
    required double gainDb,
    required double pan,
  }) => const Ok(null);

  @override
  Result<void> silenceChannel(int midiChannel) {
    silencedChannels.add(midiChannel);
    return const Ok(null);
  }

  @override
  Result<void> triggerLiveAuditionNote({
    required int midiChannel,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  }) => const Ok(null);

  @override
  Result<void> setMonitorGain(double gainLinear) {
    lastMonitorGain = gainLinear;
    return const Ok(null);
  }

  @override
  Future<Result<void>> prepareAndStartCapture(TakeId takeId) async {
    if (nextPrepareCaptureError != null) {
      final err = nextPrepareCaptureError!;
      nextPrepareCaptureError = null;
      return Err(err);
    }
    activeCaptureTakeId = takeId;
    ops.add('startCapture:${takeId.value}');
    return const Ok(null);
  }

  @override
  Future<Result<RecordingCaptureReceipt>> stopAndFinalizeCapture(
    TakeId takeId,
  ) async {
    if (nextFinalizeCaptureError != null) {
      final err = nextFinalizeCaptureError!;
      nextFinalizeCaptureError = null;
      return Err(err);
    }
    activeCaptureTakeId = null;
    ops.add('stopCapture:${takeId.value}');
    final receipt =
        nextReceipt ??
        RecordingCaptureReceipt(
          takeId: takeId,
          stagingPath: '/staging/rec_${takeId.value}.wav.part',
          sha256: const Sha256Digest(
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
          ),
          capturedSampleClock: const SampleFrame(100000),
          capturedPlayheadFrame: const SampleFrame(24884),
          durationFrames: 48000,
          sampleRate: 48000,
          channelCount: 1,
          outputBufferFrames: 256,
          inputBufferFrames: 128,
        );
    return Ok(receipt);
  }

  @override
  TelemetrySnapshot? get latestSnapshot => latest;

  @override
  List<TelemetrySnapshot> drainTelemetry({
    int maxFrames = MuseConstants.maxTelemetryDrainFrames,
  }) => const <TelemetrySnapshot>[];
}

final class _FakeStorageMaintenanceRepository
    implements IStorageMaintenanceRepository {
  MuseError? quotaError;
  int availableBytes = MuseConstants.minRecordingFreeQuotaBytes * 2;
  int quotaCheckCalls = 0;

  @override
  Future<Result<int>> verifyAvailableQuotaBytes({
    required int requiredBytes,
  }) async {
    quotaCheckCalls++;
    if (quotaError != null) {
      return Err(quotaError!);
    }
    if (availableBytes < requiredBytes) {
      return const Err(
        MuseError(
          MuseErrorCode.insufficientStorageQuota,
          'Insufficient disk quota',
        ),
      );
    }
    return Ok(availableBytes);
  }

  @override
  Future<Result<void>> initializeAndVerifyStorage() async => const Ok(null);

  @override
  Future<Result<int>> runGarbageCollection({required int olderThanEpochMs}) async =>
      const Ok(0);

  @override
  Future<void> close() async {}
}

final class _FakeAssetRepository implements IAssetLibraryRepository {
  final List<SoundFontCatalogEntry> soundFonts;
  LatencyCalibrationProfile? calibrationProfile;
  MuseError? calibrationError;

  _FakeAssetRepository({
    required this.soundFonts,
    this.calibrationProfile,
  });

  @override
  Future<Result<List<SoundFontCatalogEntry>>> listActiveSoundFonts() async =>
      Ok(soundFonts);

  @override
  Future<Result<LatencyCalibrationProfile?>> getCalibrationProfile({
    required CalibrationPlatform platform,
    required String deviceFingerprint,
    required int sampleRate,
    required int bufferSizeFrames,
  }) async {
    if (calibrationError != null) {
      return Err(calibrationError!);
    }
    return Ok(calibrationProfile);
  }

  @override
  Future<Result<SoundFontCatalogEntry>> importSoundFontBytes({
    required String displayName,
    required Stream<List<int>> byteStream,
    required int byteLength,
    required List<SoundFontPresetInfo> extractedPresets,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> softDeleteSoundFont(
    SoundFontId sfId, {
    required int deletedAtMs,
  }) => throw UnimplementedError();

  @override
  Future<Result<LatencyCalibrationProfile>> upsertCalibrationProfile(
    UpsertCalibrationProfileInput input,
  ) => throw UnimplementedError();
}

final class _FakeProjectRepo implements IProjectRepository {
  ProjectWorkspaceAggregate storedAggregate;
  AudioTakeEntity? lastCommittedTake;
  List<AudioTakeRealignmentUpdate> lastRealignmentUpdates =
      const <AudioTakeRealignmentUpdate>[];
  MuseError? commitError;

  _FakeProjectRepo(this.storedAggregate);

  @override
  Future<Result<ProjectWorkspaceAggregate>> loadProjectAggregate(
    ProjectId projectId,
  ) async {
    if (projectId != storedAggregate.project.projectId) {
      return const Err(
        MuseError(MuseErrorCode.entityNotFound, 'Project not found'),
      );
    }
    return Ok(storedAggregate);
  }

  @override
  Future<Result<AudioTakeEntity>> promoteAndCommitRecordedTake({
    required RecordingCaptureReceipt receipt,
    required ProjectId projectId,
    required PartId partId,
    required Tick alignedStartTick,
    required int calibrationOffsetFrames,
  }) async {
    if (commitError != null) {
      return Err(commitError!);
    }
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
      createdAtMs: 2000,
      updatedAtMs: 2000,
    );
    lastCommittedTake = take;
    final nextTakes = <AudioTakeEntity>[
      for (final existing in storedAggregate.audioTakes)
        if (existing.partId != partId) existing,
      take,
    ];
    storedAggregate = ProjectWorkspaceAggregate(
      project: storedAggregate.project,
      parts: storedAggregate.parts,
      tempoEvents: storedAggregate.tempoEvents,
      timeSignatureEvents: storedAggregate.timeSignatureEvents,
      keySignatureEvents: storedAggregate.keySignatureEvents,
      clefEvents: storedAggregate.clefEvents,
      notes: storedAggregate.notes,
      spanners: storedAggregate.spanners,
      audioTakes: nextTakes,
    );
    return Ok(take);
  }

  @override
  Future<Result<List<AudioTakeEntity>>> realignAudioTakesCalibration({
    required ProjectId projectId,
    required List<AudioTakeRealignmentUpdate> updates,
  }) async {
    lastRealignmentUpdates = updates;
    final byId = <TakeId, AudioTakeRealignmentUpdate>{
      for (final u in updates) u.takeId: u,
    };
    final updated = <AudioTakeEntity>[
      for (final take in storedAggregate.audioTakes)
        if (byId.containsKey(take.takeId))
          AudioTakeEntity(
            takeId: take.takeId,
            projectId: take.projectId,
            partId: take.partId,
            blobSha256: take.blobSha256,
            startTick: byId[take.takeId]!.newStartTick,
            sampleRate: take.sampleRate,
            channelCount: take.channelCount,
            durationFrames: take.durationFrames,
            capturedPlayheadFrame: take.capturedPlayheadFrame,
            capturedSampleClock: take.capturedSampleClock,
            outputBufferFrames: take.outputBufferFrames,
            inputBufferFrames: take.inputBufferFrames,
            calibrationOffsetFrames: byId[take.takeId]!.newCalibrationOffsetFrames,
            createdAtMs: take.createdAtMs,
            updatedAtMs: 3000,
          )
        else
          take,
    ];
    storedAggregate = ProjectWorkspaceAggregate(
      project: storedAggregate.project,
      parts: storedAggregate.parts,
      tempoEvents: storedAggregate.tempoEvents,
      timeSignatureEvents: storedAggregate.timeSignatureEvents,
      keySignatureEvents: storedAggregate.keySignatureEvents,
      clefEvents: storedAggregate.clefEvents,
      notes: storedAggregate.notes,
      spanners: storedAggregate.spanners,
      audioTakes: updated,
    );
    return Ok(updated);
  }

  @override
  Future<Result<int>> commitScoreMutationBatch(ScoreMutationBatch batch) =>
      throw UnimplementedError();

  @override
  Future<Result<ProjectSummary>> createProject(CreateProjectInput input) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> deletePartAudioTake({
    required ProjectId projectId,
    required PartId partId,
  }) => throw UnimplementedError();

  @override
  Future<Result<List<ProjectSummary>>> listActiveProjects({
    required int limit,
    required int offset,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> softDeleteProject(
    ProjectId projectId, {
    required int deletedAtMs,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> updateProjectMetadata(UpdateProjectMetadataInput input) =>
      throw UnimplementedError();
}

ScoreWorkspaceState _makeWorkspace({
  List<TempoEventEntity>? tempoEvents,
  List<AudioTakeEntity>? takes,
}) {
  const projectId = ProjectId('proj-rec');
  final service = DualModelScoreService();
  final agg = ProjectWorkspaceAggregate(
    project: ProjectSummary(
      projectId: projectId,
      title: 'Rec Session',
      ppqn: MuseConstants.ppqn,
      gridSnapTicks: MuseConstants.quarterNoteTicks,
      pickupTicks: 0,
      playbackTimingMode: PlaybackTimingMode.quantized,
      revision: 1,
      createdAtMs: 1000,
      updatedAtMs: 1000,
    ),
    parts: const <ProjectPartEntity>[
      ProjectPartEntity(
        partId: PartId('part-armed'),
        projectId: projectId,
        musicXmlPartId: 'P1',
        sortOrder: 0,
        name: 'Vocal',
        stavesCount: 1,
        midiChannel: 0,
        sfId: SoundFontId('sf-drums'),
        bankNum: 0,
        programNum: 0,
        gainDb: 0.0,
        pan: 0.0,
        isMuted: false,
        isSolo: false,
        updatedAtMs: 1000,
      ),
      ProjectPartEntity(
        partId: PartId('part-backing'),
        projectId: projectId,
        musicXmlPartId: 'P2',
        sortOrder: 1,
        name: 'Guitar Backing',
        stavesCount: 1,
        midiChannel: 1,
        sfId: null,
        bankNum: 0,
        programNum: 0,
        gainDb: -2.0,
        pan: 0.0,
        isMuted: false,
        isSolo: false,
        updatedAtMs: 1000,
      ),
    ],
    tempoEvents:
        tempoEvents ??
        const <TempoEventEntity>[
          TempoEventEntity(
            tempoEventId: TempoEventId('t0'),
            projectId: projectId,
            tick: Tick(0),
            usPerQuarter: 500000, // 120 BPM => 24000 frames / 960 ticks @ 48 kHz
            updatedAtMs: 1000,
          ),
        ],
    timeSignatureEvents: const <TimeSignatureEventEntity>[
      TimeSignatureEventEntity(
        tsEventId: TimeSigEventId('ts0'),
        projectId: projectId,
        tick: Tick(0),
        numerator: 4,
        denominator: 4,
        updatedAtMs: 1000,
      ),
    ],
    keySignatureEvents: const <KeySignatureEventEntity>[
      KeySignatureEventEntity(
        keyEventId: KeySigEventId('k0'),
        projectId: projectId,
        partId: null,
        staffNumber: 0,
        tick: Tick(0),
        fifths: 0,
        mode: KeyMode.major,
        updatedAtMs: 1000,
      ),
    ],
    clefEvents: const <ClefEventEntity>[
      ClefEventEntity(
        clefEventId: ClefEventId('c1'),
        projectId: projectId,
        partId: PartId('part-armed'),
        staffNumber: 1,
        tick: Tick(0),
        sign: ClefSign.G,
        line: 2,
        octaveChange: 0,
        updatedAtMs: 1000,
      ),
      ClefEventEntity(
        clefEventId: ClefEventId('c2'),
        projectId: projectId,
        partId: PartId('part-backing'),
        staffNumber: 1,
        tick: Tick(0),
        sign: ClefSign.G,
        line: 2,
        octaveChange: 0,
        updatedAtMs: 1000,
      ),
    ],
    notes: const <TimelineNote>[],
    spanners: const <NoteSpannerEntity>[],
    audioTakes:
        takes ??
        const <AudioTakeEntity>[
          AudioTakeEntity(
            takeId: TakeId('take-old-armed'),
            projectId: projectId,
            partId: PartId('part-armed'),
            blobSha256: Sha256Digest(
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            ),
            startTick: Tick(0),
            sampleRate: 48000,
            channelCount: 1,
            durationFrames: 48000,
            capturedPlayheadFrame: SampleFrame(384),
            capturedSampleClock: SampleFrame(1000),
            outputBufferFrames: 256,
            inputBufferFrames: 128,
            calibrationOffsetFrames: 0,
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
          AudioTakeEntity(
            takeId: TakeId('take-backing'),
            projectId: projectId,
            partId: PartId('part-backing'),
            blobSha256: Sha256Digest(
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ),
            startTick: Tick(960),
            sampleRate: 48000,
            channelCount: 1,
            durationFrames: 48000,
            capturedPlayheadFrame: SampleFrame(24384),
            capturedSampleClock: SampleFrame(25000),
            outputBufferFrames: 256,
            inputBufferFrames: 128,
            calibrationOffsetFrames: 0,
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
        ],
  );
  return (service.buildWorkspaceState(agg) as Ok<ScoreWorkspaceState>).value;
}

void main() {
  final sfEntries = const <SoundFontCatalogEntry>[
    SoundFontCatalogEntry(
      sfId: SoundFontId('sf-drums'),
      name: 'GeneralUser',
      blobSha256: Sha256Digest(
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      ),
      byteSize: 1024,
      presets: <SoundFontPresetInfo>[
        SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Standard'),
      ],
      createdAtMs: 1000,
      updatedAtMs: 1000,
    ),
  ];

  test(
    'setInputMonitorGain validates bounds and startRecordingOnPart enforces storage quota before arming',
    () async {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository()
        ..availableBytes = MuseConstants.minRecordingFreeQuotaBytes - 1;
      final assets = _FakeAssetRepository(soundFonts: sfEntries);
      var workspace = _makeWorkspace();
      final projectRepo = _FakeProjectRepo(workspace.aggregate);
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => workspace,
      );
      await playback.attachProject(workspace);

      final recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storage,
        assetLibrary: assets,
        projectRepository: projectRepo,
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        recordingBridge: engine,
        telemetryBridge: engine,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => workspace,
        countInDelay: (_) async {},
      );

      expect(recorder.setInputMonitorGain(-0.1).isErr, isTrue);
      expect(recorder.setInputMonitorGain(double.nan).isErr, isTrue);
      expect(recorder.setInputMonitorGain(0.75).isOk, isTrue);
      expect(engine.lastMonitorGain, 0.75);

      final quotaFail = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
      );
      expect(quotaFail, isA<Err<TakeId>>());
      expect(
        (quotaFail as Err<TakeId>).error.code,
        MuseErrorCode.insufficientStorageQuota,
      );
      expect(storage.quotaCheckCalls, 1);
      // Should abort before changing active take regions or opening capture.
      expect(engine.syncedTakesHistory, hasLength(1));
      expect(engine.activeCaptureTakeId, isNull);
    },
  );

  test(
    'suppresses armed part WAV take, restores on capture/finalize error, and schedules GM Ch 9 count-in',
    () async {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository();
      final assets = _FakeAssetRepository(soundFonts: sfEntries);
      final workspace = _makeWorkspace();
      final projectRepo = _FakeProjectRepo(workspace.aggregate);
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => workspace,
      );
      await playback.attachProject(workspace);

      final recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storage,
        assetLibrary: assets,
        projectRepository: projectRepo,
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        recordingBridge: engine,
        telemetryBridge: engine,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => workspace,
        countInDelay: (_) async {},
      );

      // 1) If prepareAndStartCapture fails after suppression, previous armed take is restored cleanly.
      engine.nextPrepareCaptureError = const MuseError(
        MuseErrorCode.microphonePermissionDenied,
        'Mic denied',
      );
      final permFail = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
      );
      expect(permFail, isA<Err<TakeId>>());
      expect(
        (permFail as Err<TakeId>).error.code,
        MuseErrorCode.microphonePermissionDenied,
      );
      expect(
        engine.syncedTakesHistory[1].map((t) => t.partId),
        <PartId>[const PartId('part-backing')],
      );
      expect(
        engine.syncedTakesHistory.last.map((t) => t.partId),
        containsAll(<PartId>[
          const PartId('part-armed'),
          const PartId('part-backing'),
        ]),
      );

      // 2) Punch-in at Tick(0) schedules 4 beats of immediate woodblock clicks on Ch 9 (76, 77, 77, 77).
      engine.scheduledEvents.clear();
      final startOk = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
      );
      expect(startOk, isA<Ok<TakeId>>());
      final countInNoteOns = engine.scheduledEvents
          .where((e) => e.type == MuseConstants.midiEventNoteOn)
          .toList();
      expect(countInNoteOns, hasLength(4));
      expect(
        countInNoteOns.every(
          (e) =>
              e.channel == MuseConstants.countInMidiChannel &&
              e.targetSampleFrame.value == MuseConstants.immediateDispatchFrame,
        ),
        isTrue,
      );
      expect(
        countInNoteOns.map((e) => e.data1).toList(),
        <int>[
          MuseConstants.countInAccentKey,
          MuseConstants.countInBeatKey,
          MuseConstants.countInBeatKey,
          MuseConstants.countInBeatKey,
        ],
      );
      // Armed take suppressed during capture while backing track remains active.
      expect(
        engine.syncedTakesHistory.last.map((t) => t.partId),
        <PartId>[const PartId('part-backing')],
      );

      // 3) Failure in stopAndFinalizeCapture restores armed part's previous take in finally.
      engine.nextFinalizeCaptureError = const MuseError(
        MuseErrorCode.captureBufferOverflow,
        'Capture ring overflow',
      );
      final finalizeFail = await recorder.stopAndCommitRecording();
      expect(finalizeFail, isA<Err<AudioTakeEntity>>());
      expect(
        engine.syncedTakesHistory.last.map((t) => t.partId),
        containsAll(<PartId>[
          const PartId('part-armed'),
          const PartId('part-backing'),
        ]),
      );

      await playback.detachProject();
    },
  );

  test(
    'stopAndCommitRecording compensates latency, propagates calibration errors fail-closed, and defaults calibration to 0 only on Ok(null)',
    () async {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository();
      final assets = _FakeAssetRepository(
        soundFonts: sfEntries,
        calibrationProfile: const LatencyCalibrationProfile(
          profileId: CalibrationProfileId('cal-1'),
          platform: CalibrationPlatform.macos,
          deviceFingerprint: 'usb-audio-1',
          sampleRate: 48000,
          bufferSizeFrames: 256,
          calibrationOffsetFrames: 500,
          updatedAtMs: 1000,
        ),
      );
      var workspace = _makeWorkspace();
      final projectRepo = _FakeProjectRepo(workspace.aggregate);
      final committedCallbacks = <AudioTakeEntity>[];
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => workspace,
      );
      await playback.attachProject(workspace);

      final recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storage,
        assetLibrary: assets,
        projectRepository: projectRepo,
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        recordingBridge: engine,
        telemetryBridge: engine,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => workspace,
        onTakeCommitted: committedCallbacks.add,
        countInDelay: (_) async {},
      );

      // Punch-in at bar 2 (tick 3840) triggers timeline pre-roll [0, 3840) before seeking back to 3840.
      final startRes = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(3840),
      );
      expect(startRes, isA<Ok<TakeId>>());
      final preRollOnFrames = engine.scheduledEvents
          .where((e) => e.type == MuseConstants.midiEventNoteOn)
          .map((e) => e.targetSampleFrame.value)
          .toList();
      expect(preRollOnFrames, <int>[0, 24000, 48000, 72000]);

      // Receipt capturedPlayheadFrame = 24884; latency = 256 + 128 + 500 = 884 -> compensated = 24000 -> tick 960.
      final commitRes = await recorder.stopAndCommitRecording();
      expect(commitRes, isA<Ok<AudioTakeEntity>>());
      final committed = (commitRes as Ok<AudioTakeEntity>).value;
      expect(committed.startTick.value, 960);
      expect(committed.calibrationOffsetFrames, 500);
      expect(committedCallbacks, <AudioTakeEntity>[committed]);
      expect(
        engine.syncedTakesHistory.last.any(
          (r) => r.takeId == committed.takeId && r.startSampleFrame.value == 24000,
        ),
        isTrue,
      );

      // Calibration storage error rejects loudly (never falls back to 0).
      await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
      );
      assets.calibrationError = const MuseError(
        MuseErrorCode.sqliteConstraintViolation,
        'Calibration query corrupted',
      );
      final calErr = await recorder.stopAndCommitRecording();
      expect(calErr, isA<Err<AudioTakeEntity>>());
      expect(projectRepo.lastCommittedTake?.takeId, committed.takeId);

      // Ok(null) calibration falls back to 0 offset and clamps negative frame at tick 0.
      assets.calibrationError = null;
      assets.calibrationProfile = null;
      final startZeroRes = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
      );
      final zeroTakeId = (startZeroRes as Ok<TakeId>).value;
      engine.nextReceipt = RecordingCaptureReceipt(
        takeId: zeroTakeId,
        stagingPath: '/staging/rec.wav.part',
        sha256: const Sha256Digest(
          'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        ),
        capturedSampleClock: const SampleFrame(500),
        capturedPlayheadFrame: const SampleFrame(100), // < 256 + 128 -> clamps at 0
        durationFrames: 24000,
        sampleRate: 48000,
        channelCount: 1,
        outputBufferFrames: 256,
        inputBufferFrames: 128,
      );
      final zeroCommit = await recorder.stopAndCommitRecording();
      expect(zeroCommit, isA<Ok<AudioTakeEntity>>());
      expect((zeroCommit as Ok<AudioTakeEntity>).value.startTick.value, 0);
      expect(zeroCommit.value.calibrationOffsetFrames, 0);

      await playback.detachProject();
    },
  );

  test(
    'realignProjectTakesForCalibration updates startTick across multi-tempo scores and refreshes active takes',
    () async {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository();
      final assets = _FakeAssetRepository(soundFonts: sfEntries);
      // Multi-tempo: 0..960 @ 120 BPM (24000 frames), 960+ @ 60 BPM (1,000,000 us/quarter => 48000 frames/960 ticks).
      // Capture at frame 48884 with latency buffers 256 + 128 = 384 and newCalibrationOffsetFrames = 500 ->
      // compensated frame = 48000 -> 24000 frames in 60 BPM = 480 ticks past tick 960 -> tick 1440!
      final multiTempoWorkspace = _makeWorkspace(
        tempoEvents: const <TempoEventEntity>[
          TempoEventEntity(
            tempoEventId: TempoEventId('t0'),
            projectId: ProjectId('proj-rec'),
            tick: Tick(0),
            usPerQuarter: 500000,
            updatedAtMs: 1000,
          ),
          TempoEventEntity(
            tempoEventId: TempoEventId('t1'),
            projectId: ProjectId('proj-rec'),
            tick: Tick(960),
            usPerQuarter: 1000000,
            updatedAtMs: 1000,
          ),
        ],
        takes: const <AudioTakeEntity>[
          AudioTakeEntity(
            takeId: TakeId('take-multi'),
            projectId: ProjectId('proj-rec'),
            partId: PartId('part-backing'),
            blobSha256: Sha256Digest(
              'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
            ),
            startTick: Tick(1450),
            sampleRate: 48000,
            channelCount: 1,
            durationFrames: 48000,
            capturedPlayheadFrame: SampleFrame(48884),
            capturedSampleClock: SampleFrame(90000),
            outputBufferFrames: 256,
            inputBufferFrames: 128,
            calibrationOffsetFrames: 0,
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
        ],
      );

      final projectRepo = _FakeProjectRepo(multiTempoWorkspace.aggregate);
      final realignedCallbacks = <List<AudioTakeEntity>>[];
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => multiTempoWorkspace,
      );
      await playback.attachProject(multiTempoWorkspace);

      final recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storage,
        assetLibrary: assets,
        projectRepository: projectRepo,
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        recordingBridge: engine,
        telemetryBridge: engine,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => multiTempoWorkspace,
        onTakesRealigned: realignedCallbacks.add,
        countInDelay: (_) async {},
      );

      final realignRes = await recorder.realignProjectTakesForCalibration(
        projectId: const ProjectId('proj-rec'),
        newCalibrationOffsetFrames: 500,
      );
      expect(realignRes, isA<Ok<List<AudioTakeEntity>>>());
      final realigned = (realignRes as Ok<List<AudioTakeEntity>>).value;
      expect(realigned, hasLength(1));
      expect(realigned.first.startTick.value, 1440);
      expect(realigned.first.calibrationOffsetFrames, 500);
      expect(realignedCallbacks, hasLength(1));
      expect(
        engine.syncedTakesHistory.last.single.startSampleFrame.value,
        48000,
      );

      await playback.detachProject();
    },
  );

  test(
    'negative countInMeasures throws ArgumentError fail-closed',
    () {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository();
      final assets = _FakeAssetRepository(soundFonts: const <SoundFontCatalogEntry>[]);
      final workspace = _makeWorkspace();
      final projectRepo = _FakeProjectRepo(workspace.aggregate);
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => workspace,
      );

      expect(
        () => RecordingSessionCoordinator(
          currentPlatform: CalibrationPlatform.macos,
          storageMaintenance: storage,
          assetLibrary: assets,
          projectRepository: projectRepo,
          lifecycleBridge: engine,
          transportBridge: engine,
          synthEventBridge: engine,
          recordingBridge: engine,
          telemetryBridge: engine,
          playbackCoordinator: playback,
          activeWorkspaceProvider: () => workspace,
          countInMeasures: -1,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'concurrent startRecordingOnPart() call during async count-in is rejected fail-closed',
    () async {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository();
      final assets = _FakeAssetRepository(
        soundFonts: const <SoundFontCatalogEntry>[
          SoundFontCatalogEntry(
            sfId: SoundFontId('sf-drums'),
            name: 'GM Drums',
            blobSha256: Sha256Digest(
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            ),
            byteSize: 2048,
            presets: <SoundFontPresetInfo>[
              SoundFontPresetInfo(
                bankNum: 128,
                programNum: 0,
                presetName: 'Standard Kit',
              ),
            ],
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
        ],
      );
      final workspace = _makeWorkspace();
      final projectRepo = _FakeProjectRepo(workspace.aggregate);
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => workspace,
      );
      await playback.attachProject(workspace);

      final countInGate = Completer<void>();
      final recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storage,
        assetLibrary: assets,
        projectRepository: projectRepo,
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        recordingBridge: engine,
        telemetryBridge: engine,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => workspace,
        countInMeasures: 1,
        countInDelay: (_) => countInGate.future,
      );

      final firstCall = recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
      );
      await pumpEventQueue();

      final concurrentCall = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(960),
      );
      expect(concurrentCall, isA<Err<TakeId>>());
      expect(
        (concurrentCall as Err<TakeId>).error.code,
        MuseErrorCode.captureBufferOverflow,
      );

      countInGate.complete();
      final firstResult = await firstCall;
      expect(firstResult, isA<Ok<TakeId>>());

      expect(await recorder.stopAndCommitRecording(), isA<Ok<AudioTakeEntity>>());
      await playback.detachProject();
    },
  );

  test(
    'suspends active loop during recording/count-in, restores loop and GM Ch9 patch on commit and on capture failure',
    () async {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository();
      final assets = _FakeAssetRepository(
        soundFonts: const <SoundFontCatalogEntry>[
          SoundFontCatalogEntry(
            sfId: SoundFontId('sf-drums'),
            name: 'GM Drums',
            blobSha256: Sha256Digest(
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            ),
            byteSize: 2048,
            presets: <SoundFontPresetInfo>[
              SoundFontPresetInfo(
                bankNum: 128,
                programNum: 0,
                presetName: 'Standard Kit',
              ),
            ],
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
        ],
      );

      // Include a backing part using GM percussion Channel 9 with bank 128 program 25 so patch restore is verifiable!
      const projectId = ProjectId('proj-rec');
      const customPercBank = 128;
      final base = _makeWorkspace().aggregate;
      final percussionAggregate = ProjectWorkspaceAggregate(
        project: base.project,
        parts: <ProjectPartEntity>[
          base.parts[0],
          const ProjectPartEntity(
            partId: PartId('part-perc'),
            projectId: projectId,
            musicXmlPartId: 'P2',
            sortOrder: 1,
            name: 'Drums',
            stavesCount: 1,
            midiChannel: MuseConstants.gmPercussionChannel,
            sfId: SoundFontId('sf-drums'),
            bankNum: customPercBank,
            programNum: 25,
            gainDb: 0.0,
            pan: 0.0,
            isMuted: false,
            isSolo: false,
            updatedAtMs: 1000,
          ),
        ],
        tempoEvents: base.tempoEvents,
        timeSignatureEvents: base.timeSignatureEvents,
        keySignatureEvents: base.keySignatureEvents,
        clefEvents: base.clefEvents,
        notes: base.notes,
        spanners: base.spanners,
        audioTakes: base.audioTakes,
      );
      final workspace = DualModelScoreService()
          .buildWorkspaceState(percussionAggregate)
          as Ok<ScoreWorkspaceState>;
      final projectRepo = _FakeProjectRepo(workspace.value.aggregate);
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => workspace.value,
      );
      await playback.attachProject(workspace.value);

      expect(
        playback
            .setLoopTickRange(
              enabled: true,
              startTick: const Tick(960),
              endTick: const Tick(3840),
            )
            .isOk,
        isTrue,
      );
      expect(playback.isLoopEnabled, isTrue);

      final recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storage,
        assetLibrary: assets,
        projectRepository: projectRepo,
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        recordingBridge: engine,
        telemetryBridge: engine,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => workspace.value,
        countInMeasures: 1,
        countInDelay: (_) async {},
      );

      // 1) Normal start -> count-in overwrites Ch 9 to bank=0,prog=0, then restores Ch 9 to bank=128,prog=25 before capture;
      // loop is suspended while recording, then restored upon commit!
      engine.patchCalls.clear();
      engine.loopCalls.clear();
      final startOk = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
      );
      expect(startOk, isA<Ok<TakeId>>());
      expect(playback.isLoopEnabled, isFalse);

      final ch9PatchesAfterCountIn = engine.patchCalls
          .where((p) => p.channel == MuseConstants.gmPercussionChannel)
          .toList();
      expect(ch9PatchesAfterCountIn.first.bank, 0);
      expect(ch9PatchesAfterCountIn.first.program, 0);
      expect(ch9PatchesAfterCountIn.last.bank, customPercBank);
      expect(ch9PatchesAfterCountIn.last.program, 25);

      final commitOk = await recorder.stopAndCommitRecording();
      expect(commitOk, isA<Ok<AudioTakeEntity>>());
      expect(playback.isLoopEnabled, isTrue);
      expect(
        playback.loopTickRange,
        (startTick: const Tick(960), endTick: const Tick(3840)),
      );

      // 2) prepareAndStartCapture failure must STILL restore Ch 9 patch AND restore suspended loop!
      engine.patchCalls.clear();
      engine.nextPrepareCaptureError = const MuseError(
        MuseErrorCode.audioDeviceInitFailed,
        'Mic capture init failed',
      );
      final startFail = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
      );
      expect(startFail, isA<Err<TakeId>>());
      expect(playback.isLoopEnabled, isTrue);
      expect(
        playback.loopTickRange,
        (startTick: const Tick(960), endTick: const Tick(3840)),
      );
      final ch9AfterFail = engine.patchCalls
          .where((p) => p.channel == MuseConstants.gmPercussionChannel)
          .toList();
      expect(ch9AfterFail.last.bank, customPercBank);
      expect(ch9AfterFail.last.program, 25);

      await playback.detachProject();
    },
  );

  test(
    'invalid tempo map returns Err(invalidTickRange) instead of throwing out of startRecordingOnPart and realignProjectTakesForCalibration',
    () async {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository();
      final assets = _FakeAssetRepository(soundFonts: sfEntries);
      final validWs = _makeWorkspace();
      final invalidAgg = ProjectWorkspaceAggregate(
        project: validWs.aggregate.project,
        parts: validWs.aggregate.parts,
        tempoEvents: const <TempoEventEntity>[], // invalid: missing tick-0 tempo
        timeSignatureEvents: validWs.aggregate.timeSignatureEvents,
        keySignatureEvents: validWs.aggregate.keySignatureEvents,
        clefEvents: validWs.aggregate.clefEvents,
        notes: validWs.aggregate.notes,
        spanners: validWs.aggregate.spanners,
        audioTakes: const <AudioTakeEntity>[
          AudioTakeEntity(
            takeId: TakeId('take-invalid-map'),
            projectId: ProjectId('proj-rec'),
            partId: PartId('part-backing'),
            blobSha256: Sha256Digest(
              'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
            ),
            startTick: Tick(0),
            sampleRate: 48000,
            channelCount: 1,
            durationFrames: 48000,
            capturedPlayheadFrame: SampleFrame(48000),
            capturedSampleClock: SampleFrame(90000),
            outputBufferFrames: 256,
            inputBufferFrames: 128,
            calibrationOffsetFrames: 0,
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
        ],
      );
      final invalidWs = ScoreWorkspaceState(
        aggregate: invalidAgg,
        renderSnapshot: validWs.renderSnapshot,
      );
      final projectRepo = _FakeProjectRepo(invalidAgg);
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => validWs,
      );
      await playback.attachProject(validWs);

      final recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storage,
        assetLibrary: assets,
        projectRepository: projectRepo,
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        recordingBridge: engine,
        telemetryBridge: engine,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => invalidWs,
        countInMeasures: 1,
        countInDelay: (_) async {},
      );

      final recRes = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
      );
      expect(recRes, isA<Err<TakeId>>());
      expect(
        (recRes as Err<TakeId>).error.code,
        MuseErrorCode.invalidTickRange,
      );

      final realignRes = await recorder.realignProjectTakesForCalibration(
        projectId: const ProjectId('proj-rec'),
        newCalibrationOffsetFrames: 256,
      );
      expect(realignRes, isA<Err<List<AudioTakeEntity>>>());
      expect(
        (realignRes as Err<List<AudioTakeEntity>>).error.code,
        MuseErrorCode.invalidTickRange,
      );

      await playback.detachProject();
    },
  );

  test(
    'serializedProjectWrite wraps commit and awaits FutureOr onTakeCommitted before resolving',
    () async {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository();
      final assets = _FakeAssetRepository(soundFonts: sfEntries);
      final workspace = _makeWorkspace();
      final projectRepo = _FakeProjectRepo(workspace.aggregate);
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => workspace,
      );
      await playback.attachProject(workspace);

      final events = <String>[];
      final recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storage,
        assetLibrary: assets,
        projectRepository: projectRepo,
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        recordingBridge: engine,
        telemetryBridge: engine,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => workspace,
        countInMeasures: 0,
        serializedProjectWrite: <T>(op) async {
          events.add('lock_enter');
          try {
            return await op();
          } finally {
            events.add('lock_exit');
          }
        },
        onTakeCommitted: (take) async {
          events.add('callback_start:${take.takeId.value}');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          events.add('callback_done:${take.takeId.value}');
        },
      );

      expect(
        await recorder.startRecordingOnPart(
          partId: const PartId('part-armed'),
          countInStartTick: const Tick(0),
        ),
        isA<Ok<TakeId>>(),
      );

      final commitRes = await recorder.stopAndCommitRecording();
      expect(commitRes, isA<Ok<AudioTakeEntity>>());
      final committed = (commitRes as Ok<AudioTakeEntity>).value;

      expect(events, <String>[
        'lock_enter',
        'callback_start:${committed.takeId.value}',
        'callback_done:${committed.takeId.value}',
        'lock_exit',
      ]);

      await playback.detachProject();
    },
  );

  test(
    'countInMeasuresOverride skips count-in when 0 and rejects negative overrides fail-closed',
    () async {
      final engine = _FakeRecordingAudioBridge();
      final storage = _FakeStorageMaintenanceRepository();
      final assets = _FakeAssetRepository(soundFonts: sfEntries);
      final workspace = _makeWorkspace();
      final projectRepo = _FakeProjectRepo(workspace.aggregate);
      final playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => workspace,
      );
      await playback.attachProject(workspace);

      var delayCalls = 0;
      final recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storage,
        assetLibrary: assets,
        projectRepository: projectRepo,
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        recordingBridge: engine,
        telemetryBridge: engine,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => workspace,
        countInMeasures: 1,
        countInDelay: (_) async {
          delayCalls += 1;
        },
      );

      final invalidRes = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
        countInMeasuresOverride: -1,
      );
      expect(
        (invalidRes as Err<TakeId>).error.code,
        MuseErrorCode.invalidTickRange,
      );
      expect(delayCalls, 0);

      final okRes = await recorder.startRecordingOnPart(
        partId: const PartId('part-armed'),
        countInStartTick: const Tick(0),
        countInMeasuresOverride: 0,
      );
      expect(okRes, isA<Ok<TakeId>>());
      expect(delayCalls, 0);
      expect(
        engine.scheduledEvents.where(
          (e) => e.channel == MuseConstants.countInMidiChannel,
        ),
        isEmpty,
      );

      await recorder.stopAndCommitRecording();
      await playback.detachProject();
    },
  );
}

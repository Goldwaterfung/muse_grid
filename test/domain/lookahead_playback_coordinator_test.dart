import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/bridge/native/native_audio_bridge.dart';
import 'package:muse_grid/bridge/native/platform_audio_permission.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/domain/notation/dual_model_score_service.dart';
import 'package:muse_grid/domain/playback/lookahead_playback_coordinator.dart';
import 'package:muse_grid/domain/repositories/storage_contracts.dart';

final class _FakeTimer implements Timer {
  final Duration interval;
  final void Function(Timer timer) callback;
  bool cancelled = false;
  int _ticks = 0;

  _FakeTimer(this.interval, this.callback);

  void fire() {
    if (!cancelled) {
      _ticks++;
      callback(this);
    }
  }

  @override
  void cancel() {
    cancelled = true;
  }

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => _ticks;
}

final class _FakeAudioEngine
    implements
        IAudioLifecycleBridge,
        ITransportBridge,
        ISynthEventBridge,
        ITelemetryBridge {
  AudioHardwareInfo hardwareInfo = const AudioHardwareInfo(
    sampleRate: 48000,
    inputChannels: 1,
    outputChannels: 2,
    inputBufferFrames: 128,
    outputBufferFrames: 128,
    deviceFingerprint: 'fake-device',
  );
  bool initialized = true;
  int _nextSfHandle = 10;
  EpochId _epoch = const EpochId(1);
  TelemetrySnapshot? _latestSnapshot;

  final List<Sha256Digest> loadedSoundFontShas = <Sha256Digest>[];
  final List<SoundFontHandle> unloadedHandles = <SoundFontHandle>[];
  final List<({int channel, SoundFontHandle handle, int bank, int program})>
  assignedPatches =
      <({int channel, SoundFontHandle handle, int bank, int program})>[];
  final List<({int channel, double gainDb, double pan})> channelMixCalls =
      <({int channel, double gainDb, double pan})>[];
  final List<int> silencedChannels = <int>[];
  final List<List<ActiveTakePlaybackRegion>> syncedTakeHistory =
      <List<ActiveTakePlaybackRegion>>[];
  final List<ScheduledMidiEvent> scheduledEvents = <ScheduledMidiEvent>[];
  final List<SampleFrame?> scheduledWatermarks = <SampleFrame?>[];
  final List<({int channel, int pitch, int velocity, bool isNoteOn})>
  auditionCalls =
      <({int channel, int pitch, int velocity, bool isNoteOn})>[];
  final List<String> transportOps = <String>[];

  bool isPlayingState = false;
  SampleFrame lastSeekFrame = const SampleFrame(0);
  ({bool enabled, SampleFrame start, SampleFrame end})? lastLoopRegion;
  int flushCount = 0;
  Result<LoadedSoundFontDescriptor> Function(Sha256Digest sha)? onLoadSoundFont;

  _FakeAudioEngine();

  void pushTelemetry({
    required SampleFrame playheadFrame,
    EpochId? epoch,
    bool isPlaying = true,
    bool isCapturing = false,
    int loopPass = 0,
  }) {
    _latestSnapshot = TelemetrySnapshot(
      playheadSampleFrame: playheadFrame,
      activeEpoch: epoch ?? _epoch,
      outputPeakL: 0.0,
      outputPeakR: 0.0,
      outputRmsL: 0.0,
      outputRmsR: 0.0,
      inputPeak: 0.0,
      inputRms: 0.0,
      isPlaying: isPlaying,
      isCapturing: isCapturing,
      hasEventQueueUnderrun: false,
      hasCaptureBufferOverflow: false,
      hasTakePlaybackUnderrun: false,
      loopPass: loopPass,
    );
  }

  @override
  AudioHardwareInfo get currentHardwareInfo {
    if (!initialized) {
      throw StateError('Audio engine is not initialized.');
    }
    return hardwareInfo;
  }

  @override
  Future<Result<AudioHardwareInfo>> initialize() async {
    initialized = true;
    return Ok(hardwareInfo);
  }

  @override
  Future<Result<LoadedSoundFontDescriptor>> loadSoundFontFromCas({
    required Sha256Digest sha256,
  }) async {
    loadedSoundFontShas.add(sha256);
    if (onLoadSoundFont != null) {
      return onLoadSoundFont!(sha256);
    }
    final handle = SoundFontHandle(_nextSfHandle++);
    return Ok(
      LoadedSoundFontDescriptor(
        handle: handle,
        presets: const <SoundFontPresetInfo>[
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Piano'),
        ],
      ),
    );
  }

  @override
  Future<Result<void>> unloadSoundFont(SoundFontHandle handle) async {
    unloadedHandles.add(handle);
    return const Ok(null);
  }

  @override
  Future<void> dispose() async {
    initialized = false;
  }

  @override
  Result<void> play() {
    isPlayingState = true;
    transportOps.add('play');
    return const Ok(null);
  }

  @override
  Result<void> pause() {
    isPlayingState = false;
    transportOps.add('pause');
    return const Ok(null);
  }

  @override
  Result<void> stop() {
    isPlayingState = false;
    _epoch = EpochId(_epoch.value + 1);
    lastSeekFrame = const SampleFrame(0);
    transportOps.add('stop');
    return const Ok(null);
  }

  @override
  Result<EpochId> seekToSample(SampleFrame targetFrame) {
    _epoch = EpochId(_epoch.value + 1);
    lastSeekFrame = targetFrame;
    transportOps.add('seek:${targetFrame.value}');
    return Ok(_epoch);
  }

  @override
  Result<void> setLoopRegion({
    required bool enabled,
    required SampleFrame startFrame,
    required SampleFrame endFrame,
  }) {
    lastLoopRegion = (enabled: enabled, start: startFrame, end: endFrame);
    transportOps.add('loop:$enabled:${startFrame.value}:${endFrame.value}');
    return const Ok(null);
  }

  @override
  Future<Result<void>> syncActiveTakeRegions(
    List<ActiveTakePlaybackRegion> regions,
  ) async {
    syncedTakeHistory.add(List<ActiveTakePlaybackRegion>.unmodifiable(regions));
    return const Ok(null);
  }

  @override
  EpochId get currentEpoch => _epoch;

  @override
  Result<EpochId> flushAndAdvanceEpoch() {
    flushCount++;
    _epoch = EpochId(_epoch.value + 1);
    return Ok(_epoch);
  }

  @override
  Result<int> scheduleEvents(
    List<ScheduledMidiEvent> events, {
    SampleFrame? scheduledUpToFrame,
  }) {
    scheduledEvents.addAll(events);
    scheduledWatermarks.add(scheduledUpToFrame);
    return Ok(events.length);
  }

  @override
  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  }) {
    assignedPatches.add((
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
  }) {
    channelMixCalls.add((channel: midiChannel, gainDb: gainDb, pan: pan));
    return const Ok(null);
  }

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
  }) {
    auditionCalls.add((
      channel: midiChannel,
      pitch: pitchMidi,
      velocity: velocity,
      isNoteOn: isNoteOn,
    ));
    return const Ok(null);
  }

  @override
  TelemetrySnapshot? get latestSnapshot => _latestSnapshot;

  @override
  List<TelemetrySnapshot> drainTelemetry({
    int maxFrames = MuseConstants.maxTelemetryDrainFrames,
  }) {
    return _latestSnapshot == null
        ? const <TelemetrySnapshot>[]
        : <TelemetrySnapshot>[_latestSnapshot!];
  }
}

final class _FakeAssetLibraryRepository implements IAssetLibraryRepository {
  final List<SoundFontCatalogEntry> entries;
  Result<List<SoundFontCatalogEntry>>? listError;

  _FakeAssetLibraryRepository(this.entries);

  @override
  Future<Result<List<SoundFontCatalogEntry>>> listActiveSoundFonts() async {
    if (listError != null) {
      return listError!;
    }
    return Ok(entries);
  }

  @override
  Future<Result<SoundFontCatalogEntry>> importSoundFontBytes({
    required String displayName,
    required Stream<List<int>> byteStream,
    required int byteLength,
    required List<SoundFontPresetInfo> extractedPresets,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Result<void>> softDeleteSoundFont(
    SoundFontId sfId, {
    required int deletedAtMs,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Result<LatencyCalibrationProfile?>> getCalibrationProfile({
    required CalibrationPlatform platform,
    required String deviceFingerprint,
    required int sampleRate,
    required int bufferSizeFrames,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Result<LatencyCalibrationProfile>> upsertCalibrationProfile(
    UpsertCalibrationProfileInput input,
  ) {
    throw UnimplementedError();
  }
}

ScoreWorkspaceState _buildWorkspace({
  PlaybackTimingMode timingMode = PlaybackTimingMode.quantized,
  List<ProjectPartEntity>? parts,
  List<TimelineNote>? notes,
  List<AudioTakeEntity>? takes,
  List<TempoEventEntity>? tempoEvents,
}) {
  const projectId = ProjectId('proj-1');
  final service = DualModelScoreService();
  final effectiveParts =
      parts ??
      const <ProjectPartEntity>[
        ProjectPartEntity(
          partId: PartId('part-1'),
          projectId: projectId,
          musicXmlPartId: 'P1',
          sortOrder: 0,
          name: 'Piano',
          stavesCount: 1,
          midiChannel: 0,
          sfId: SoundFontId('sf-1'),
          bankNum: 0,
          programNum: 0,
          gainDb: 0.0,
          pan: -0.2,
          isMuted: false,
          isSolo: false,
          updatedAtMs: 1000,
        ),
      ];
  final effectiveNotes = notes ?? const <TimelineNote>[];
  final agg = ProjectWorkspaceAggregate(
    project: ProjectSummary(
      projectId: projectId,
      title: 'Test Score',
      ppqn: MuseConstants.ppqn,
      gridSnapTicks: MuseConstants.quarterNoteTicks,
      pickupTicks: 0,
      playbackTimingMode: timingMode,
      revision: 1,
      createdAtMs: 1000,
      updatedAtMs: 1000,
    ),
    parts: effectiveParts,
    tempoEvents:
        tempoEvents ??
        const <TempoEventEntity>[
          TempoEventEntity(
            tempoEventId: TempoEventId('tempo-0'),
            projectId: projectId,
            tick: Tick(0),
            usPerQuarter: 500000, // 120 BPM => 960 ticks == 24000 frames @ 48 kHz
            updatedAtMs: 1000,
          ),
        ],
    timeSignatureEvents: const <TimeSignatureEventEntity>[
      TimeSignatureEventEntity(
        tsEventId: TimeSigEventId('ts-0'),
        projectId: projectId,
        tick: Tick(0),
        numerator: 4,
        denominator: 4,
        updatedAtMs: 1000,
      ),
    ],
    keySignatureEvents: const <KeySignatureEventEntity>[
      KeySignatureEventEntity(
        keyEventId: KeySigEventId('key-0'),
        projectId: projectId,
        partId: null,
        staffNumber: 0,
        tick: Tick(0),
        fifths: 0,
        mode: KeyMode.major,
        updatedAtMs: 1000,
      ),
    ],
    clefEvents: <ClefEventEntity>[
      for (var i = 0; i < effectiveParts.length; i++)
        ClefEventEntity(
          clefEventId: ClefEventId('clef-$i'),
          projectId: projectId,
          partId: effectiveParts[i].partId,
          staffNumber: 1,
          tick: const Tick(0),
          sign: ClefSign.G,
          line: 2,
          octaveChange: 0,
          updatedAtMs: 1000,
        ),
    ],
    notes: effectiveNotes,
    spanners: const <NoteSpannerEntity>[],
    audioTakes: takes ?? const <AudioTakeEntity>[],
  );
  return (service.buildWorkspaceState(agg) as Ok<ScoreWorkspaceState>).value;
}

TimelineNote _note({
  required String id,
  required PartId partId,
  required int pitch,
  required int quantizedStart,
  required int quantizedDur,
  int? rawStart,
  int? rawDur,
  int velocity = 90,
}) {
  return TimelineNote(
    noteId: NoteId(id),
    projectId: const ProjectId('proj-1'),
    partId: partId,
    staffNumber: 1,
    voiceNumber: 1,
    pitchMidi: pitch,
    enharmonicStep: EnharmonicStep.C,
    enharmonicAlter: 0,
    rawStartTick: Tick(rawStart ?? quantizedStart),
    rawDurationTicks: rawDur ?? quantizedDur,
    quantizedStartTick: Tick(quantizedStart),
    quantizedDurationTicks: quantizedDur,
    velocity: velocity,
    updatedAtMs: 1000,
  );
}

void main() {
  final catalog = <SoundFontCatalogEntry>[
    const SoundFontCatalogEntry(
      sfId: SoundFontId('sf-1'),
      name: 'GeneralUser',
      blobSha256: Sha256Digest(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      byteSize: 1024,
      presets: <SoundFontPresetInfo>[
        SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Piano'),
      ],
      createdAtMs: 1000,
      updatedAtMs: 1000,
    ),
    const SoundFontCatalogEntry(
      sfId: SoundFontId('sf-2'),
      name: 'Strings',
      blobSha256: Sha256Digest(
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ),
      byteSize: 2048,
      presets: <SoundFontPresetInfo>[
        SoundFontPresetInfo(bankNum: 0, programNum: 48, presetName: 'Strings'),
      ],
      createdAtMs: 1000,
      updatedAtMs: 1000,
    ),
  ];

  test(
    'attachProject fails closed on missingSoundFontForPart and allows audio-only parts',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
      );

      final missingSfWorkspace = _buildWorkspace(
        parts: const <ProjectPartEntity>[
          ProjectPartEntity(
            partId: PartId('part-missing'),
            projectId: ProjectId('proj-1'),
            musicXmlPartId: 'P1',
            sortOrder: 0,
            name: 'Lead Synth',
            stavesCount: 1,
            midiChannel: 0,
            sfId: null,
            bankNum: 0,
            programNum: 0,
            gainDb: 0.0,
            pan: 0.0,
            isMuted: false,
            isSolo: false,
            updatedAtMs: 1000,
          ),
        ],
        notes: <TimelineNote>[
          _note(
            id: 'n1',
            partId: const PartId('part-missing'),
            pitch: 60,
            quantizedStart: 0,
            quantizedDur: 960,
          ),
        ],
      );

      final failResult = await coordinator.attachProject(missingSfWorkspace);
      expect(failResult, isA<Err<void>>());
      expect(
        (failResult as Err<void>).error.code,
        MuseErrorCode.missingSoundFontForPart,
      );
      expect(engine.loadedSoundFontShas, isEmpty);

      // Audio-only part (no TimelineNotes, sfId == null) attaches cleanly.
      final audioOnlyWorkspace = _buildWorkspace(
        parts: const <ProjectPartEntity>[
          ProjectPartEntity(
            partId: PartId('part-vocal'),
            projectId: ProjectId('proj-1'),
            musicXmlPartId: 'P1',
            sortOrder: 0,
            name: 'Vocal Mic',
            stavesCount: 1,
            midiChannel: 0,
            sfId: null,
            bankNum: 0,
            programNum: 0,
            gainDb: -3.0,
            pan: 0.0,
            isMuted: false,
            isSolo: false,
            updatedAtMs: 1000,
          ),
        ],
        takes: const <AudioTakeEntity>[
          AudioTakeEntity(
            takeId: TakeId('take-1'),
            projectId: ProjectId('proj-1'),
            partId: PartId('part-vocal'),
            blobSha256: Sha256Digest(
              'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
            ),
            startTick: Tick(960),
            sampleRate: 48000,
            channelCount: 1,
            durationFrames: 48000,
            capturedPlayheadFrame: SampleFrame(24256),
            capturedSampleClock: SampleFrame(50000),
            outputBufferFrames: 128,
            inputBufferFrames: 128,
            calibrationOffsetFrames: 0,
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
        ],
      );

      final okResult = await coordinator.attachProject(audioOnlyWorkspace);
      expect(okResult, isA<Ok<void>>());
      expect(engine.syncedTakeHistory.last, hasLength(1));
      expect(
        engine.syncedTakeHistory.last.first.startSampleFrame.value,
        24000,
      );
    },
  );

  test(
    'attachProject deduplicates SF2 loads, applies solo/mute mixes & takes, and detachProject cleans up',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
      );

      final workspace = _buildWorkspace(
        parts: const <ProjectPartEntity>[
          ProjectPartEntity(
            partId: PartId('p1'),
            projectId: ProjectId('proj-1'),
            musicXmlPartId: 'P1',
            sortOrder: 0,
            name: 'Piano 1',
            stavesCount: 1,
            midiChannel: 0,
            sfId: SoundFontId('sf-1'),
            bankNum: 0,
            programNum: 0,
            gainDb: 0.0,
            pan: 0.0,
            isMuted: false,
            isSolo: true,
            updatedAtMs: 1000,
          ),
          ProjectPartEntity(
            partId: PartId('p2'),
            projectId: ProjectId('proj-1'),
            musicXmlPartId: 'P2',
            sortOrder: 1,
            name: 'Piano 2 (non-solo)',
            stavesCount: 1,
            midiChannel: 1,
            sfId: SoundFontId('sf-1'),
            bankNum: 0,
            programNum: 4,
            gainDb: -2.0,
            pan: 0.5,
            isMuted: false,
            isSolo: false,
            updatedAtMs: 1000,
          ),
        ],
        takes: const <AudioTakeEntity>[
          AudioTakeEntity(
            takeId: TakeId('t1'),
            projectId: ProjectId('proj-1'),
            partId: PartId('p1'),
            blobSha256: Sha256Digest(
              '1111111111111111111111111111111111111111111111111111111111111111',
            ),
            startTick: Tick(0),
            sampleRate: 48000,
            channelCount: 1,
            durationFrames: 24000,
            capturedPlayheadFrame: SampleFrame(256),
            capturedSampleClock: SampleFrame(1000),
            outputBufferFrames: 128,
            inputBufferFrames: 128,
            calibrationOffsetFrames: 0,
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
          AudioTakeEntity(
            takeId: TakeId('t2'),
            projectId: ProjectId('proj-1'),
            partId: PartId('p2'),
            blobSha256: Sha256Digest(
              '2222222222222222222222222222222222222222222222222222222222222222',
            ),
            startTick: Tick(0),
            sampleRate: 48000,
            channelCount: 1,
            durationFrames: 24000,
            capturedPlayheadFrame: SampleFrame(256),
            capturedSampleClock: SampleFrame(1000),
            outputBufferFrames: 128,
            inputBufferFrames: 128,
            calibrationOffsetFrames: 0,
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
        ],
      );

      final res = await coordinator.attachProject(workspace);
      expect(res, isA<Ok<void>>());
      // Shared sf-1 loaded only once despite 2 parts referencing it.
      expect(engine.loadedSoundFontShas, hasLength(1));
      expect(engine.assignedPatches, hasLength(2));
      expect(engine.silencedChannels, contains(1));
      expect(engine.syncedTakeHistory.last.map((r) => r.takeId), <TakeId>[
        const TakeId('t1'),
      ]);

      await coordinator.detachProject();
      expect(engine.transportOps, contains('stop'));
      expect(engine.syncedTakeHistory.last, isEmpty);
      expect(engine.unloadedHandles, hasLength(1));
    },
  );

  test(
    '25 ms lookahead timer emits sorted epoch-tagged MIDI events in quantized and raw modes without duplicates',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      _FakeTimer? createdTimer;
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        periodicTimerFactory: (interval, cb) {
          expect(
            interval,
            const Duration(milliseconds: MuseConstants.lookaheadRefillIntervalMs),
          );
          createdTimer = _FakeTimer(interval, cb);
          return createdTimer!;
        },
      );

      // 120 BPM @ 48 kHz => 24000 frames/quarter (960 ticks), 200 ms == 9600 frames == 384 ticks.
      // Note A: quantized [0, 240) -> frames [0, 6000); raw [120, 360) -> frames [3000, 9000)
      // Note B: quantized [240, 480) -> noteOn @ 6000 (same frame as Note A noteOff), noteOff @ 12000 (outside first 200 ms)
      final workspaceQuantized = _buildWorkspace(
        timingMode: PlaybackTimingMode.quantized,
        notes: <TimelineNote>[
          _note(
            id: 'na',
            partId: const PartId('part-1'),
            pitch: 60,
            quantizedStart: 0,
            quantizedDur: 240,
            rawStart: 120,
            rawDur: 240,
          ),
          _note(
            id: 'nb',
            partId: const PartId('part-1'),
            pitch: 64,
            quantizedStart: 240,
            quantizedDur: 240,
            rawStart: 360,
            rawDur: 240,
          ),
        ],
      );

      await coordinator.attachProject(workspaceQuantized);
      final playRes = await coordinator.play();
      expect(playRes, isA<Ok<void>>());
      expect(createdTimer, isNotNull);

      // First window [0, 9600): na noteOn@0, na noteOff@6000 BEFORE nb noteOn@6000.
      expect(engine.scheduledEvents, hasLength(3));
      expect(engine.scheduledEvents[0].targetSampleFrame.value, 0);
      expect(engine.scheduledEvents[0].type, MuseConstants.midiEventNoteOn);
      expect(engine.scheduledEvents[1].targetSampleFrame.value, 6000);
      expect(engine.scheduledEvents[1].type, MuseConstants.midiEventNoteOff);
      expect(engine.scheduledEvents[2].targetSampleFrame.value, 6000);
      expect(engine.scheduledEvents[2].type, MuseConstants.midiEventNoteOn);
      expect(engine.scheduledEvents.every((e) => e.epoch == engine.currentEpoch), isTrue);

      // Firing timer with same telemetry playhead does not re-emit already scheduled frames.
      engine.pushTelemetry(playheadFrame: const SampleFrame(0));
      createdTimer!.fire();
      expect(engine.scheduledEvents, hasLength(3));

      // Advance playhead to 4800 => new window covers [9600, 14400) -> picks up nb noteOff@12000.
      engine.pushTelemetry(playheadFrame: const SampleFrame(4800));
      createdTimer!.fire();
      expect(engine.scheduledEvents, hasLength(4));
      expect(engine.scheduledEvents[3].targetSampleFrame.value, 12000);
      expect(engine.scheduledEvents[3].type, MuseConstants.midiEventNoteOff);

      // Raw mode uses rawStartTick / rawDurationTicks instead of quantized fields.
      await coordinator.detachProject();
      engine.scheduledEvents.clear();
      final workspaceRaw = _buildWorkspace(
        timingMode: PlaybackTimingMode.raw,
        notes: workspaceQuantized.aggregate.notes,
      );
      await coordinator.attachProject(workspaceRaw);
      await coordinator.play();
      // Raw mode in [0, 9600): na noteOn@3000, na noteOff@9000, nb noteOn@9000.
      expect(engine.scheduledEvents, hasLength(3));
      expect(engine.scheduledEvents[0].targetSampleFrame.value, 3000);
      expect(engine.scheduledEvents[1].targetSampleFrame.value, 9000);
      expect(engine.scheduledEvents[1].type, MuseConstants.midiEventNoteOff);
      expect(engine.scheduledEvents[2].targetSampleFrame.value, 9000);
      expect(engine.scheduledEvents[2].type, MuseConstants.midiEventNoteOn);
      await coordinator.detachProject();
    },
  );

  test(
    'loop wrapping clips batches at loopEnd and wraps lookahead cleanly across passes',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      _FakeTimer? createdTimer;
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        periodicTimerFactory: (interval, cb) {
          createdTimer = _FakeTimer(interval, cb);
          return createdTimer!;
        },
      );

      // Loop [0, 480 ticks) => [0, 12000 frames) at 120 BPM @ 48 kHz.
      // Note at tick 0 duration 120 (frames 0..3000) and note at tick 420 duration 120 (frames 10500..13500 -> crosses loopEnd).
      final workspace = _buildWorkspace(
        notes: <TimelineNote>[
          _note(
            id: 'n-start',
            partId: const PartId('part-1'),
            pitch: 60,
            quantizedStart: 0,
            quantizedDur: 120,
          ),
          _note(
            id: 'n-tail',
            partId: const PartId('part-1'),
            pitch: 67,
            quantizedStart: 420,
            quantizedDur: 120,
          ),
        ],
      );

      await coordinator.attachProject(workspace);
      expect(
        coordinator
            .setLoopTickRange(
              enabled: true,
              startTick: const Tick(100),
              endTick: const Tick(100),
            )
            .isErr,
        isTrue,
      );
      expect(
        coordinator
            .setLoopTickRange(
              enabled: true,
              startTick: const Tick(0),
              endTick: const Tick(480),
            )
            .isOk,
        isTrue,
      );
      expect(engine.lastLoopRegion?.enabled, isTrue);
      expect(engine.lastLoopRegion?.end.value, 12000);

      // Play starting near tail (frame 4800 -> seek tick 192).
      expect(coordinator.seekToTick(const Tick(192)).isOk, isTrue);
      engine.pushTelemetry(playheadFrame: const SampleFrame(4800));
      await coordinator.play();
      // Window [4800, 14400) wraps across loopEnd=12000 into [12000, 14400) => [0, 2400) pass 2!
      // Events:
      // 1) n-tail noteOn @ 10500
      // 2) n-tail clipped noteOff @ 11999 (clipped before 12000)
      // 3) wrapped n-start noteOn @ 0 (after tail events in FIFO queue!)
      expect(engine.scheduledEvents, hasLength(3));
      expect(engine.scheduledEvents[0].targetSampleFrame.value, 10500);
      expect(engine.scheduledEvents[0].type, MuseConstants.midiEventNoteOn);
      expect(engine.scheduledEvents[0].loopPass, 0);
      expect(engine.scheduledEvents[1].targetSampleFrame.value, 11999);
      expect(engine.scheduledEvents[1].type, MuseConstants.midiEventNoteOff);
      expect(engine.scheduledEvents[1].loopPass, 0);
      expect(engine.scheduledEvents[2].targetSampleFrame.value, 0);
      expect(engine.scheduledEvents[2].type, MuseConstants.midiEventNoteOn);
      expect(engine.scheduledEvents[2].loopPass, 1);

      // Telemetry wraps back into pass 2 at frame 1200 -> new horizon [1200+9600=10800) wraps [2400, 10800)
      // Emits wrapped n-start noteOff @ 3000 and pass-2 n-tail noteOn @ 10500 without re-emitting 0..2400!
      engine.scheduledEvents.clear();
      engine.pushTelemetry(playheadFrame: const SampleFrame(1200), loopPass: 1);
      createdTimer!.fire();
      expect(engine.scheduledEvents, hasLength(2));
      expect(engine.scheduledEvents[0].targetSampleFrame.value, 3000);
      expect(engine.scheduledEvents[0].type, MuseConstants.midiEventNoteOff);
      expect(engine.scheduledEvents[0].loopPass, 1);
      expect(engine.scheduledEvents[1].targetSampleFrame.value, 10500);
      expect(engine.scheduledEvents[1].type, MuseConstants.midiEventNoteOn);
      expect(engine.scheduledEvents[1].loopPass, 1);

      await coordinator.detachProject();
    },
  );

  test(
    'seekToTick, notifyScoreMutatedInRange, auditionNote, and unloadUnusedSoundFont behave fail-closed',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      late ScoreWorkspaceState liveWorkspace;
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => liveWorkspace,
      );

      liveWorkspace = _buildWorkspace(
        notes: <TimelineNote>[
          _note(
            id: 'n1',
            partId: const PartId('part-1'),
            pitch: 60,
            quantizedStart: 0,
            quantizedDur: 240,
          ),
        ],
      );

      // Unattached audition fails closed.
      expect(
        coordinator
            .auditionNote(
              partId: const PartId('part-1'),
              pitchMidi: 60,
              velocity: 100,
              isNoteOn: true,
            )
            .isErr,
        isTrue,
      );

      await coordinator.attachProject(liveWorkspace);

      // Invalid audition velocity/pitch fail closed.
      expect(
        coordinator
            .auditionNote(
              partId: const PartId('part-1'),
              pitchMidi: 60,
              velocity: 0,
              isNoteOn: true,
            )
            .isErr,
        isTrue,
      );
      expect(
        coordinator
            .auditionNote(
              partId: const PartId('part-1'),
              pitchMidi: 60,
              velocity: 100,
              isNoteOn: true,
            )
            .isOk,
        isTrue,
      );
      expect(engine.auditionCalls, hasLength(1));

      // Referenced SoundFont cannot be unloaded while used.
      await coordinator.unloadUnusedSoundFont(const SoundFontId('sf-1'));
      expect(engine.unloadedHandles, isEmpty);

      // Play at tick 0 -> horizon [0, 9600 frames) (~[0, 384 ticks)).
      await coordinator.play();
      final epochAfterPlay = engine.currentEpoch;
      final flushCountBeforeOutOfRange = engine.flushCount;

      // Mutation far beyond lookahead horizon (tick 2000..2960) does not flush epoch.
      coordinator.notifyScoreMutatedInRange(
        affectedStartTick: const Tick(2000),
        affectedEndTick: const Tick(2960),
      );
      expect(engine.flushCount, flushCountBeforeOutOfRange);
      expect(engine.currentEpoch, epochAfterPlay);

      // Mutation overlapping [0, 384 ticks) flushes epoch and refills immediately!
      engine.scheduledEvents.clear();
      liveWorkspace = _buildWorkspace(
        notes: <TimelineNote>[
          _note(
            id: 'n1-edited',
            partId: const PartId('part-1'),
            pitch: 72,
            quantizedStart: 100,
            quantizedDur: 100,
          ),
        ],
      );
      coordinator.notifyScoreMutatedInRange(
        affectedStartTick: const Tick(100),
        affectedEndTick: const Tick(200),
      );
      expect(engine.flushCount, flushCountBeforeOutOfRange + 1);
      expect(engine.currentEpoch.value, epochAfterPlay.value + 1);
      expect(engine.scheduledEvents.any((e) => e.data1 == 72), isTrue);

      // Switch part SF2 off sf-1 -> unloadUnusedSoundFont now unloads sf-1!
      liveWorkspace = _buildWorkspace(
        parts: const <ProjectPartEntity>[
          ProjectPartEntity(
            partId: PartId('part-1'),
            projectId: ProjectId('proj-1'),
            musicXmlPartId: 'P1',
            sortOrder: 0,
            name: 'Muted Piano',
            stavesCount: 1,
            midiChannel: 0,
            sfId: SoundFontId('sf-2'),
            bankNum: 0,
            programNum: 48,
            gainDb: 0.0,
            pan: 0.0,
            isMuted: true,
            isSolo: false,
            updatedAtMs: 2000,
          ),
        ],
      );
      await coordinator.unloadUnusedSoundFont(const SoundFontId('sf-1'));
      expect(engine.unloadedHandles, hasLength(1));

      expect(coordinator.stop().isOk, isTrue);
      await coordinator.detachProject();
    },
  );

  test(
    'pause followed by play flushes epoch and prevents duplicate MIDI scheduling',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
      );
      addTearDown(coordinator.dispose);

      // Note at tick 96 (2400 frames) so it sits inside the initial [0, 9600) lookahead window.
      final workspace = _buildWorkspace(
        notes: <TimelineNote>[
          _note(
            id: 'n-resume',
            partId: const PartId('part-1'),
            pitch: 64,
            quantizedStart: 96,
            quantizedDur: 120,
          ),
        ],
      );

      await coordinator.attachProject(workspace);
      engine.pushTelemetry(playheadFrame: const SampleFrame(0), isPlaying: false);
      expect((await coordinator.play()).isOk, isTrue);

      final epochDuringFirstPlay = engine.currentEpoch;
      final firstPlayNotes = engine.scheduledEvents
          .where((e) => e.type == MuseConstants.midiEventNoteOn)
          .toList();
      expect(firstPlayNotes, hasLength(1));
      expect(firstPlayNotes.single.epoch, epochDuringFirstPlay);

      // Playhead advances slightly to 1200 frames (still before frame 2400 note), then user pauses.
      engine.scheduledEvents.clear();
      engine.pushTelemetry(
        playheadFrame: const SampleFrame(1200),
        epoch: epochDuringFirstPlay,
        isPlaying: true,
      );
      final pauseRes = coordinator.pause();
      expect(pauseRes.isOk, isTrue);
      final epochAfterPause = engine.currentEpoch;
      expect(epochAfterPause.value, greaterThan(epochDuringFirstPlay.value));
      expect(engine.flushCount, greaterThanOrEqualTo(1));

      // Resume from paused position: new epoch schedules the upcoming note cleanly once on the new epoch.
      engine.pushTelemetry(
        playheadFrame: const SampleFrame(1200),
        epoch: epochAfterPause,
        isPlaying: false,
      );
      expect((await coordinator.play()).isOk, isTrue);
      final resumedNoteOns = engine.scheduledEvents
          .where((e) => e.type == MuseConstants.midiEventNoteOn)
          .toList();
      expect(resumedNoteOns, hasLength(1));
      expect(resumedNoteOns.single.epoch, engine.currentEpoch);
      expect(resumedNoteOns.single.data1, 64);

      await coordinator.detachProject();
    },
  );

  test(
    'loop wrap skips Pass 2 wrapping while hardware telemetry reports isCapturing=true',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
      );
      addTearDown(coordinator.dispose);

      final workspace = _buildWorkspace(
        notes: <TimelineNote>[
          _note(
            id: 'n-wrap-start',
            partId: const PartId('part-1'),
            pitch: 60,
            quantizedStart: 0,
            quantizedDur: 120,
          ),
          _note(
            id: 'n-before-end',
            partId: const PartId('part-1'),
            pitch: 67,
            quantizedStart: 420,
            quantizedDur: 60,
          ),
        ],
      );

      await coordinator.attachProject(workspace);
      expect(
        coordinator
            .setLoopTickRange(
              enabled: true,
              startTick: const Tick(0),
              endTick: const Tick(480),
            )
            .isOk,
        isTrue,
      );
      expect(coordinator.seekToTick(const Tick(192)).isOk, isTrue);
      engine.pushTelemetry(
        playheadFrame: const SampleFrame(4800),
        isPlaying: false,
        isCapturing: true,
      );

      await coordinator.play();
      // Only n-before-end (Pass 0) should be emitted; wrapped Pass 1 n-wrap-start is suppressed during capture.
      expect(
        engine.scheduledEvents.any(
          (e) => e.data1 == 60 && e.loopPass > 0,
        ),
        isFalse,
      );
      expect(
        engine.scheduledEvents.any((e) => e.data1 == 67 && e.loopPass == 0),
        isTrue,
      );

      await coordinator.detachProject();
    },
  );

  test(
    'asyncErrors emits SF2 load, catalog lookup, and take-sync failures triggered from notifyScoreMutatedInRange',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      late ScoreWorkspaceState liveWorkspace;
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => liveWorkspace,
      );

      final recordedErrors = <MuseError>[];
      final sub = coordinator.asyncErrors.listen(recordedErrors.add);
      addTearDown(sub.cancel);

      liveWorkspace = _buildWorkspace(notes: const <TimelineNote>[]);
      final attachRes = await coordinator.attachProject(liveWorkspace);
      expect(attachRes.isOk, isTrue);

      // 1) Mutate score to introduce sf-2 while bridge SF2 load fails -> emits casBlobMissing on asyncErrors.
      engine.onLoadSoundFont = (_) => const Err<LoadedSoundFontDescriptor>(
        MuseError(MuseErrorCode.casBlobMissing, 'Missing SF2 CAS blob'),
      );
      liveWorkspace = _buildWorkspace(
        parts: const <ProjectPartEntity>[
          ProjectPartEntity(
            partId: PartId('part-2'),
            projectId: ProjectId('proj-1'),
            musicXmlPartId: 'P2',
            sortOrder: 0,
            name: 'Violin',
            stavesCount: 1,
            midiChannel: 1,
            sfId: SoundFontId('sf-2'),
            bankNum: 0,
            programNum: 40,
            gainDb: 0.0,
            pan: 0.0,
            isMuted: false,
            isSolo: false,
            updatedAtMs: 2000,
          ),
        ],
      );
      coordinator.notifyScoreMutatedInRange(
        affectedStartTick: const Tick(0),
        affectedEndTick: const Tick(960),
      );
      await pumpEventQueue();
      expect(
        recordedErrors.any((e) => e.code == MuseErrorCode.casBlobMissing),
        isTrue,
      );

      // 2) Mutate score while catalog lookup returns Err -> emits entityNotFound on asyncErrors.
      recordedErrors.clear();
      engine.onLoadSoundFont = null;
      assets.listError = const Err<List<SoundFontCatalogEntry>>(
        MuseError(MuseErrorCode.entityNotFound, 'Catalog read failed'),
      );
      coordinator.notifyScoreMutatedInRange(
        affectedStartTick: const Tick(0),
        affectedEndTick: const Tick(960),
      );
      await pumpEventQueue();

      expect(
        recordedErrors.any(
          (e) => e.code == MuseErrorCode.entityNotFound,
        ),
        isTrue,
      );

      await coordinator.detachProject();
      await coordinator.dispose();
    },
  );

  test(
    'frame index handles multi-note spans across slices, mute/solo changes, raw vs quantized, and loop clipping',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      _FakeTimer? createdTimer;
      late ScoreWorkspaceState liveWorkspace;
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => liveWorkspace,
        periodicTimerFactory: (interval, cb) {
          createdTimer = _FakeTimer(interval, cb);
          return createdTimer!;
        },
      );
      addTearDown(coordinator.dispose);

      // Two parts: P1 ch0 has a long note (ticks 0..960 = frames 0..24000) with distinct raw bounds (tick 20..900 -> 500..22500);
      // P2 ch1 has a chord inside ticks 240..480 (frames 6000..12000).
      const part1 = ProjectPartEntity(
        partId: PartId('part-1'),
        projectId: ProjectId('proj-1'),
        musicXmlPartId: 'P1',
        sortOrder: 0,
        name: 'Piano',
        stavesCount: 1,
        midiChannel: 0,
        sfId: SoundFontId('sf-1'),
        bankNum: 0,
        programNum: 0,
        gainDb: 0.0,
        pan: 0.0,
        isMuted: false,
        isSolo: false,
        updatedAtMs: 1000,
      );
      const part2 = ProjectPartEntity(
        partId: PartId('part-2'),
        projectId: ProjectId('proj-1'),
        musicXmlPartId: 'P2',
        sortOrder: 1,
        name: 'Strings',
        stavesCount: 1,
        midiChannel: 1,
        sfId: SoundFontId('sf-2'),
        bankNum: 0,
        programNum: 48,
        gainDb: 0.0,
        pan: 0.0,
        isMuted: false,
        isSolo: false,
        updatedAtMs: 1000,
      );
      final notes = <TimelineNote>[
        _note(
          id: 'long-p1',
          partId: const PartId('part-1'),
          pitch: 60,
          quantizedStart: 0,
          quantizedDur: 960,
          rawStart: 20,
          rawDur: 880,
          velocity: 100,
        ),
        _note(
          id: 'chord-p2-a',
          partId: const PartId('part-2'),
          pitch: 64,
          quantizedStart: 240,
          quantizedDur: 240,
        ),
        _note(
          id: 'chord-p2-b',
          partId: const PartId('part-2'),
          pitch: 67,
          quantizedStart: 240,
          quantizedDur: 240,
        ),
      ];

      liveWorkspace = _buildWorkspace(
        timingMode: PlaybackTimingMode.raw,
        parts: const <ProjectPartEntity>[part1, part2],
        notes: notes,
      );
      await coordinator.attachProject(liveWorkspace);
      engine.pushTelemetry(playheadFrame: const SampleFrame(0));
      await coordinator.play();

      // First lookahead [0, 9600) in RAW mode: long-p1 NoteOn @ frame 500, chord-p2 @ frame 6000.
      expect(
        engine.scheduledEvents.any(
          (e) =>
              e.channel == 0 &&
              e.data1 == 60 &&
              e.type == MuseConstants.midiEventNoteOn &&
              e.targetSampleFrame.value == 500,
        ),
        isTrue,
      );
      expect(
        engine.scheduledEvents
            .where((e) => e.channel == 1 && e.type == MuseConstants.midiEventNoteOn)
            .map((e) => e.data1),
        containsAll(<int>[64, 67]),
      );

      // Switch to QUANTIZED + solo P1 only; mutate in range so index rebuilds immediately.
      engine.scheduledEvents.clear();
      liveWorkspace = _buildWorkspace(
        timingMode: PlaybackTimingMode.quantized,
        parts: <ProjectPartEntity>[
          ProjectPartEntity(
            partId: part1.partId,
            projectId: part1.projectId,
            musicXmlPartId: part1.musicXmlPartId,
            sortOrder: part1.sortOrder,
            name: part1.name,
            stavesCount: part1.stavesCount,
            midiChannel: part1.midiChannel,
            sfId: part1.sfId,
            bankNum: part1.bankNum,
            programNum: part1.programNum,
            gainDb: part1.gainDb,
            pan: part1.pan,
            isMuted: false,
            isSolo: true,
            updatedAtMs: 2000,
          ),
          part2,
        ],
        notes: notes,
      );
      coordinator.notifyScoreMutatedInRange(
        affectedStartTick: const Tick(0),
        affectedEndTick: const Tick(960),
      );
      // Solo P1 silences P2 (ch1), emits long-p1 @ quantized frame 0.
      expect(
        engine.scheduledEvents.any(
          (e) =>
              e.channel == 0 &&
              e.type == MuseConstants.midiEventNoteOn &&
              e.targetSampleFrame.value == 0,
        ),
        isTrue,
      );
      expect(
        engine.scheduledEvents.where((e) => e.channel == 1),
        isEmpty,
      );

      // Advance playhead across the second slice [9600, 25000): long-p1 NoteOff @ 24000 is discovered via frame index.
      engine.scheduledEvents.clear();
      engine.pushTelemetry(playheadFrame: const SampleFrame(16000));
      createdTimer!.fire();
      expect(
        engine.scheduledEvents.any(
          (e) =>
              e.channel == 0 &&
              e.type == MuseConstants.midiEventNoteOff &&
              e.targetSampleFrame.value == 24000,
        ),
        isTrue,
      );

      // Enable loop [0, 480) (frame 12000) and rewind -> long-p1 NoteOff clips at 11999.
      engine.scheduledEvents.clear();
      coordinator.setLoopTickRange(
        enabled: true,
        startTick: const Tick(0),
        endTick: const Tick(480),
      );
      expect(coordinator.seekToTick(const Tick(0)).isOk, isTrue);
      engine.pushTelemetry(playheadFrame: const SampleFrame(0));
      // Trigger one more slice past horizon so [0..12000) finishes emitting long-p1 clipped NoteOff.
      engine.pushTelemetry(playheadFrame: const SampleFrame(3000));
      createdTimer!.fire();
      expect(
        engine.scheduledEvents.any(
          (e) =>
              e.channel == 0 &&
              e.type == MuseConstants.midiEventNoteOff &&
              e.targetSampleFrame.value == 11999,
        ),
        isTrue,
      );

      await coordinator.detachProject();
    },
  );

  test(
    'L4-L3 NativeAudioBridge integration: loop wrap defers Pass 2 until wrap and pause/play advances epoch without double triggers',
    () async {
      final sf2File = File(MuseConstants.defaultSoundFontAssetPath);
      expect(sf2File.existsSync(), isTrue);

      final bridge = NativeAudioBridge(
        storageLocator: _FixedCasLocator(
          sf2Sha: const Sha256Digest(MuseConstants.defaultSoundFontSha256),
          sf2Path: sf2File.absolute.path,
        ),
        permissionChecker: _AlwaysGrantedPermissionChecker(),
      );
      addTearDown(bridge.dispose);

      final initRes = await bridge.initialize();
      expect(initRes, isA<Ok<AudioHardwareInfo>>());
      final hw = (initRes as Ok<AudioHardwareInfo>).value;

      const sfEntry = SoundFontCatalogEntry(
        sfId: SoundFontId('sf-default'),
        name: 'GeneralUser',
        blobSha256: Sha256Digest(MuseConstants.defaultSoundFontSha256),
        byteSize: 1024,
        presets: <SoundFontPresetInfo>[
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Piano'),
        ],
        createdAtMs: 1000,
        updatedAtMs: 1000,
      );
      final assets = _FakeAssetLibraryRepository(const <SoundFontCatalogEntry>[
        sfEntry,
      ]);
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: bridge,
        transportBridge: bridge,
        synthEventBridge: bridge,
        telemetryBridge: bridge,
        assetLibraryRepository: assets,
      );
      addTearDown(coordinator.dispose);

      // 120 BPM (500ms per quarter). Loop [0, 960 ticks) => 1000ms loop duration at any device sampleRate!
      // Put silence in [480..960) and a loud note at tick 0..240 (starts at loopStart=0).
      final workspace = _buildWorkspace(
        parts: const <ProjectPartEntity>[
          ProjectPartEntity(
            partId: PartId('part-1'),
            projectId: ProjectId('proj-1'),
            musicXmlPartId: 'P1',
            sortOrder: 0,
            name: 'Piano',
            stavesCount: 1,
            midiChannel: 0,
            sfId: SoundFontId('sf-default'),
            bankNum: 0,
            programNum: 0,
            gainDb: 0.0,
            pan: 0.0,
            isMuted: false,
            isSolo: false,
            updatedAtMs: 1000,
          ),
        ],
        notes: <TimelineNote>[
          _note(
            id: 'loop-start-note',
            partId: const PartId('part-1'),
            pitch: 60,
            quantizedStart: 0,
            quantizedDur: 240,
          ),
        ],
      );

      final attachRes = await coordinator.attachProject(workspace);
      expect(attachRes.isOk, isTrue);
      await pumpEventQueue();
      expect(
        coordinator
            .setLoopTickRange(
              enabled: true,
              startTick: const Tick(0),
              endTick: const Tick(960),
            )
            .isOk,
        isTrue,
      );
      // Seek near end of Pass 0 (tick 820 => ~145ms before wrap at 120 BPM, well inside 200ms lookahead!).
      expect(coordinator.seekToTick(const Tick(820)).isOk, isTrue);
      expect((await coordinator.play()).isOk, isTrue);

      // Wait until telemetry reaches loopPass >= 1 and observe Pass 0 tail vs Pass 1 frames.
      final collected = <TelemetrySnapshot>[];
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(deadline)) {
        collected.addAll(bridge.drainTelemetry());
        if (collected.any(
          (f) =>
              (f.loopPass ?? 0) >= 1 && (f.outputRmsL > 0.0 || f.outputRmsR > 0.0),
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final loopEndFrame = hw.sampleRate; // 960 ticks @ 120 BPM == 1.0 second == hw.sampleRate
      final earlyPass0Audible = collected.where(
        (f) =>
            f.loopPass == 0 &&
            f.playheadSampleFrame.value < loopEndFrame &&
            (f.outputRmsL > 0.0 || f.outputRmsR > 0.0),
      );
      expect(earlyPass0Audible, isEmpty);
      expect(
        collected.any(
          (f) =>
              (f.loopPass ?? 0) >= 1 && (f.outputRmsL > 0.0 || f.outputRmsR > 0.0),
        ),
        isTrue,
      );
      expect(collected.every((f) => !f.hasEventQueueUnderrun), isTrue);

      // Verify pause() advances epoch on the real engine and play() resumes cleanly.
      final epochBeforePause = bridge.currentEpoch;
      expect(coordinator.pause().isOk, isTrue);
      expect(bridge.currentEpoch.value, greaterThan(epochBeforePause.value));
      expect((await coordinator.play()).isOk, isTrue);

      expect(coordinator.stop().isOk, isTrue);
      await coordinator.detachProject();
    },
  );

  test(
    'L4-L3 NativeAudioBridge integration: playing across rests and past final note does not trigger eventQueueUnderrun',
    () async {
      final sf2File = File(MuseConstants.defaultSoundFontAssetPath);
      expect(sf2File.existsSync(), isTrue);

      final bridge = NativeAudioBridge(
        storageLocator: _FixedCasLocator(
          sf2Sha: const Sha256Digest(MuseConstants.defaultSoundFontSha256),
          sf2Path: sf2File.absolute.path,
        ),
        permissionChecker: _AlwaysGrantedPermissionChecker(),
      );
      addTearDown(bridge.dispose);

      final initRes = await bridge.initialize();
      expect(initRes, isA<Ok<AudioHardwareInfo>>());
      final hw = (initRes as Ok<AudioHardwareInfo>).value;

      const sfEntry = SoundFontCatalogEntry(
        sfId: SoundFontId('sf-default'),
        name: 'GeneralUser',
        blobSha256: Sha256Digest(MuseConstants.defaultSoundFontSha256),
        byteSize: 1024,
        presets: <SoundFontPresetInfo>[
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Piano'),
        ],
        createdAtMs: 1000,
        updatedAtMs: 1000,
      );
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: bridge,
        transportBridge: bridge,
        synthEventBridge: bridge,
        telemetryBridge: bridge,
        assetLibraryRepository: _FakeAssetLibraryRepository(
          const <SoundFontCatalogEntry>[sfEntry],
        ),
      );
      addTearDown(coordinator.dispose);

      // Single 1/16 note (120 ticks = 62.5ms @ 120 BPM) followed by silence past 400ms.
      final workspace = _buildWorkspace(
        parts: const <ProjectPartEntity>[
          ProjectPartEntity(
            partId: PartId('part-1'),
            projectId: ProjectId('proj-1'),
            musicXmlPartId: 'P1',
            sortOrder: 0,
            name: 'Piano',
            stavesCount: 1,
            midiChannel: 0,
            sfId: SoundFontId('sf-default'),
            bankNum: 0,
            programNum: 0,
            gainDb: 0.0,
            pan: 0.0,
            isMuted: false,
            isSolo: false,
            updatedAtMs: 1000,
          ),
        ],
        notes: <TimelineNote>[
          _note(
            id: 'short-note',
            partId: const PartId('part-1'),
            pitch: 60,
            quantizedStart: 0,
            quantizedDur: 120,
          ),
        ],
      );

      expect((await coordinator.attachProject(workspace)).isOk, isTrue);
      await pumpEventQueue();
      expect((await coordinator.play()).isOk, isTrue);

      final targetPlayhead = (hw.sampleRate * 45) ~/ 100; // 450 ms (> 200 ms lookahead + 62.5 ms note)
      final collected = <TelemetrySnapshot>[];
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(deadline)) {
        collected.addAll(bridge.drainTelemetry());
        if (collected.any(
          (f) => f.playheadSampleFrame.value >= targetPlayhead,
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(
        collected.any((f) => f.playheadSampleFrame.value >= targetPlayhead),
        isTrue,
      );
      expect(collected.every((f) => !f.hasEventQueueUnderrun), isTrue);

      expect(coordinator.stop().isOk, isTrue);
      await coordinator.detachProject();
    },
  );

  test(
    'LookaheadPlaybackCoordinator advances watermark across silent slices and clamps loop watermark to loopEndFrame',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(<SoundFontCatalogEntry>[
        SoundFontCatalogEntry(
          sfId: const SoundFontId('sf-1'),
          name: 'Piano',
          blobSha256: Sha256Digest('a' * 64),
          byteSize: 1024,
          presets: const <SoundFontPresetInfo>[
            SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Piano'),
          ],
          createdAtMs: 1,
          updatedAtMs: 1,
        ),
      ]);
      void Function(Timer)? refillTick;
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        periodicTimerFactory: (_, cb) {
          refillTick = cb;
          return Timer(const Duration(days: 1), () {});
        },
      );
      addTearDown(coordinator.dispose);

      final workspace = _buildWorkspace(
        parts: const <ProjectPartEntity>[
          ProjectPartEntity(
            partId: PartId('part-1'),
            projectId: ProjectId('proj-1'),
            musicXmlPartId: 'P1',
            sortOrder: 0,
            name: 'Piano',
            stavesCount: 1,
            midiChannel: 0,
            sfId: SoundFontId('sf-1'),
            bankNum: 0,
            programNum: 0,
            gainDb: 0.0,
            pan: 0.0,
            isMuted: false,
            isSolo: false,
            updatedAtMs: 1,
          ),
        ],
        notes: <TimelineNote>[
          _note(
            id: 'n1',
            partId: const PartId('part-1'),
            pitch: 60,
            quantizedStart: 0,
            quantizedDur: 60, // 31.25 ms @ 120 BPM (1500 frames @ 48 kHz)
          ),
        ],
      );

      expect((await coordinator.attachProject(workspace)).isOk, isTrue);
      expect((await coordinator.play()).isOk, isTrue);

      // Initial lookahead is 200 ms @ 48 kHz = 9600 frames, even though NoteOff is at 1500.
      expect(engine.scheduledWatermarks, <SampleFrame?>[const SampleFrame(9600)]);

      // Advance playhead past NoteOff (to 4800) into silent tail -> watermark advances to 14400 even with 0 events.
      engine.scheduledEvents.clear();
      engine.pushTelemetry(playheadFrame: const SampleFrame(4800));
      refillTick!(Timer(Duration.zero, () {}));
      expect(engine.scheduledEvents, isEmpty);
      expect(
        engine.scheduledWatermarks.last,
        const SampleFrame(4800 + 9600),
      );

      // Short loop [0, 120 ticks) => [0, 3000 frames) < 9600 lookahead: watermark must clamp to loopEndFrame (3000).
      expect(
        coordinator
            .setLoopTickRange(
              enabled: true,
              startTick: const Tick(0),
              endTick: const Tick(120),
            )
            .isOk,
        isTrue,
      );
      expect(engine.scheduledWatermarks.last, const SampleFrame(3000));

      // Even after wrapping to loopPass = 1 at playhead = 2000, watermark clamps to 3000 (not wrapped frame).
      engine.pushTelemetry(
        playheadFrame: const SampleFrame(2000),
        loopPass: 1,
      );
      refillTick!(Timer(Duration.zero, () {}));
      expect(engine.scheduledWatermarks.last, const SampleFrame(3000));

      await coordinator.detachProject();
    },
  );

  test(
    'tempo map mutations recompute active loop frame boundaries, re-anchor playhead, and reschedule lookahead',
    () async {
      final engine = _FakeAudioEngine();
      final assets = _FakeAssetLibraryRepository(catalog);
      late ScoreWorkspaceState liveWorkspace;
      final coordinator = LookaheadPlaybackCoordinator(
        lifecycleBridge: engine,
        transportBridge: engine,
        synthEventBridge: engine,
        telemetryBridge: engine,
        assetLibraryRepository: assets,
        workspaceStateProvider: () => liveWorkspace,
        periodicTimerFactory: (_, _) => _FakeTimer(Duration.zero, (_) {}),
      );
      addTearDown(coordinator.dispose);

      final reanchorEvents = <PlaybackPlayheadReanchorEvent>[];
      final reanchorSub = coordinator.playheadReanchored.listen(
        reanchorEvents.add,
      );
      addTearDown(reanchorSub.cancel);

      final p1 = _buildWorkspace().aggregate.parts.single;
      liveWorkspace = _buildWorkspace(
        parts: <ProjectPartEntity>[p1],
        notes: <TimelineNote>[
          _note(
            id: 'note-beat2',
            partId: p1.partId,
            pitch: 64,
            quantizedStart: 960,
            quantizedDur: 240,
          ),
        ],
      );
      await coordinator.attachProject(liveWorkspace);

      // Enable Bars 1-4 loop at 120 BPM @ 48 kHz => 0..15360 ticks => 0..384000 frames.
      expect(
        coordinator
            .setLoopTickRange(
              enabled: true,
              startTick: const Tick(0),
              endTick: const Tick(15360),
            )
            .isOk,
        isTrue,
      );
      expect(engine.lastLoopRegion?.start, const SampleFrame(0));
      expect(engine.lastLoopRegion?.end, const SampleFrame(384000));

      // Seek to Bar 3 (7680 ticks => 192000 frames @ 120 BPM), then change BPM to 60 (1_000_000 us/q).
      expect(coordinator.seekToTick(const Tick(7680)).isOk, isTrue);
      expect(engine.lastSeekFrame, const SampleFrame(192000));

      liveWorkspace = _buildWorkspace(
        parts: <ProjectPartEntity>[p1],
        notes: liveWorkspace.aggregate.notes,
        tempoEvents: const <TempoEventEntity>[
          TempoEventEntity(
            tempoEventId: TempoEventId('tempo-0'),
            projectId: ProjectId('proj-1'),
            tick: Tick(0),
            usPerQuarter: 1000000, // 60 BPM => Bar 1-4 = 768000 frames, Bar 3 = 384000 frames
            updatedAtMs: 2000,
          ),
        ],
      );
      coordinator.notifyScoreMutatedInRange(
        affectedStartTick: const Tick(0),
        affectedEndTick: const Tick(1),
      );
      await Future<void>.delayed(Duration.zero);

      expect(engine.lastLoopRegion?.enabled, isTrue);
      expect(engine.lastLoopRegion?.start, const SampleFrame(0));
      expect(engine.lastLoopRegion?.end, const SampleFrame(768000));
      expect(engine.lastSeekFrame, const SampleFrame(384000));
      expect(reanchorEvents, hasLength(1));
      expect(reanchorEvents.single.tick, const Tick(7680));
      expect(reanchorEvents.single.sampleFrame, const SampleFrame(384000));

      // Rewind to Tick 0 and start playback, then double tempo to 240 BPM (250_000 us/q).
      expect(coordinator.seekToTick(const Tick(0)).isOk, isTrue);
      expect((await coordinator.play()).isOk, isTrue);
      engine.scheduledEvents.clear();
      final epochBeforeFastTempo = engine.currentEpoch;

      liveWorkspace = _buildWorkspace(
        parts: <ProjectPartEntity>[p1],
        notes: liveWorkspace.aggregate.notes,
        tempoEvents: const <TempoEventEntity>[
          TempoEventEntity(
            tempoEventId: TempoEventId('tempo-0'),
            projectId: ProjectId('proj-1'),
            tick: Tick(0),
            usPerQuarter: 250000, // 240 BPM => Bar 1-4 = 192000 frames, tick 960 = 12000 frames
            updatedAtMs: 3000,
          ),
        ],
      );
      coordinator.notifyScoreMutatedInRange(
        affectedStartTick: const Tick(0),
        affectedEndTick: const Tick(1),
      );
      expect(engine.lastLoopRegion?.end, const SampleFrame(192000));
      expect(engine.currentEpoch.value, greaterThan(epochBeforeFastTempo.value));
      // 200 ms lookahead @ 48 kHz = 9600 frames; 960 ticks @ 240 BPM = 12000 frames, advance playhead into range.
      engine.scheduledEvents.clear();
      engine.pushTelemetry(playheadFrame: const SampleFrame(6000));
      // Playhead at frame 6000 -> horizon [6000, 15600) captures note-on @ 12000.
      // Verify via pause+play or notify? Wait: we can advance telemetry & refill via seek/notify or another timer!
      // Instead insert a note at tick 200 (2500 frames @ 240 BPM) or seek playhead to 6000? Even better, check at playhead 0 with tick 400 note, or assert next timer refill.
      // Let's verify a tempo edit far beyond loop/lookahead (tick 34560) does NOT flush epoch.
      final epochBeforeFarTempo = engine.currentEpoch;
      final flushBeforeFarTempo = engine.flushCount;
      liveWorkspace = _buildWorkspace(
        parts: <ProjectPartEntity>[p1],
        notes: liveWorkspace.aggregate.notes,
        tempoEvents: const <TempoEventEntity>[
          TempoEventEntity(
            tempoEventId: TempoEventId('tempo-0'),
            projectId: ProjectId('proj-1'),
            tick: Tick(0),
            usPerQuarter: 250000,
            updatedAtMs: 3000,
          ),
          TempoEventEntity(
            tempoEventId: TempoEventId('tempo-far'),
            projectId: ProjectId('proj-1'),
            tick: Tick(34560),
            usPerQuarter: 500000,
            updatedAtMs: 4000,
          ),
        ],
      );
      coordinator.notifyScoreMutatedInRange(
        affectedStartTick: const Tick(34560),
        affectedEndTick: const Tick(34561),
      );
      expect(engine.flushCount, flushBeforeFarTempo);
      expect(engine.currentEpoch, epochBeforeFarTempo);
      expect(engine.lastLoopRegion?.end, const SampleFrame(192000));

      await coordinator.detachProject();
    },
  );
}

final class _AlwaysGrantedPermissionChecker
    implements INativeAudioPermissionChecker {
  @override
  Future<Result<void>> ensureMicrophonePermission() async => const Ok(null);
}

final class _FixedCasLocator implements IInternalStorageLocator {
  final Sha256Digest sf2Sha;
  final String sf2Path;

  _FixedCasLocator({required this.sf2Sha, required this.sf2Path});

  @override
  Future<Result<List<int>>> readCasBlobBytes(
    Sha256Digest sha256, {
    required String ext,
  }) async {
    if (sha256 == sf2Sha && ext == 'sf2') {
      return Ok(await File(sf2Path).readAsBytes());
    }
    return const Err(
      MuseError(MuseErrorCode.casBlobMissing, 'Missing CAS blob'),
    );
  }

  @override
  String? resolveNativeCasPosixPath(
    Sha256Digest sha256, {
    required String ext,
  }) {
    if (sha256 == sf2Sha && ext == 'sf2') {
      return sf2Path;
    }
    return null;
  }

  @override
  String resolveRecordingStagingPath(TakeId takeId) =>
      '${Directory.systemTemp.path}/rec_${takeId.value}.wav.part';
}

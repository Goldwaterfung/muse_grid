import 'package:crisp_notation_core/crisp_notation_core.dart'
    show NoteElement, StaffSystem;
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/commands/score_editing_command_bus.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/domain/notation/dual_model_score_service.dart';
import 'package:muse_grid/domain/playback/lookahead_playback_coordinator.dart';
import 'package:muse_grid/domain/repositories/storage_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeProjectRepository implements IProjectRepository {
  ProjectWorkspaceAggregate _agg;
  MuseError? nextCommitError;
  int? overrideReturnedRevision;
  int commitCallCount = 0;
  Duration commitDelay = Duration.zero;

  _FakeProjectRepository(this._agg);

  ProjectWorkspaceAggregate get storedAggregate => _agg;

  @override
  Future<Result<int>> commitScoreMutationBatch(ScoreMutationBatch batch) async {
    commitCallCount++;
    if (commitDelay > Duration.zero) {
      await Future<void>.delayed(commitDelay);
    }
    if (nextCommitError != null) {
      final err = nextCommitError!;
      nextCommitError = null;
      return Err<int>(err);
    }
    if (batch.projectId != _agg.project.projectId ||
        batch.expectedRevision != _agg.project.revision) {
      return Err<int>(
        MuseError(
          MuseErrorCode.revisionConflict,
          'Fake repo revision mismatch: expected=${batch.expectedRevision}, '
          'actual=${_agg.project.revision}',
        ),
      );
    }

    final deletedParts = batch.deletePartIds.toSet();
    final partMap = <PartId, ProjectPartEntity>{
      for (final p in _agg.parts)
        if (!deletedParts.contains(p.partId)) p.partId: p,
    };
    for (final p in batch.upsertParts) {
      partMap[p.partId] = p;
    }

    final deletedTempos = batch.deleteTempoEventIds.toSet();
    final tempoMap = <TempoEventId, TempoEventEntity>{
      for (final t in _agg.tempoEvents)
        if (!deletedTempos.contains(t.tempoEventId)) t.tempoEventId: t,
    };
    for (final t in batch.upsertTempoEvents) {
      tempoMap[t.tempoEventId] = t;
    }

    final deletedTs = batch.deleteTimeSignatureEventIds.toSet();
    final tsMap = <TimeSigEventId, TimeSignatureEventEntity>{
      for (final ts in _agg.timeSignatureEvents)
        if (!deletedTs.contains(ts.tsEventId)) ts.tsEventId: ts,
    };
    for (final ts in batch.upsertTimeSignatureEvents) {
      tsMap[ts.tsEventId] = ts;
    }

    final deletedKs = batch.deleteKeySignatureEventIds.toSet();
    final ksMap = <KeySigEventId, KeySignatureEventEntity>{
      for (final ks in _agg.keySignatureEvents)
        if (!deletedKs.contains(ks.keyEventId) &&
            !(ks.partId != null && deletedParts.contains(ks.partId)))
          ks.keyEventId: ks,
    };
    for (final ks in batch.upsertKeySignatureEvents) {
      ksMap[ks.keyEventId] = ks;
    }

    final deletedClefs = batch.deleteClefEventIds.toSet();
    final clefMap = <ClefEventId, ClefEventEntity>{
      for (final c in _agg.clefEvents)
        if (!deletedClefs.contains(c.clefEventId) &&
            !deletedParts.contains(c.partId))
          c.clefEventId: c,
    };
    for (final c in batch.upsertClefEvents) {
      clefMap[c.clefEventId] = c;
    }

    final deletedNotes = batch.deleteNoteIds.toSet();
    final cascadedDeletedNoteIds = <NoteId>{...deletedNotes};
    final noteMap = <NoteId, TimelineNote>{};
    for (final n in _agg.notes) {
      if (deletedNotes.contains(n.noteId) || deletedParts.contains(n.partId)) {
        cascadedDeletedNoteIds.add(n.noteId);
        continue;
      }
      noteMap[n.noteId] = n;
    }
    for (final n in batch.upsertNotes) {
      noteMap[n.noteId] = n;
    }

    final deletedSpanners = batch.deleteSpannerIds.toSet();
    final spannerMap = <SpannerId, NoteSpannerEntity>{
      for (final s in _agg.spanners)
        if (!deletedSpanners.contains(s.spannerId) &&
            !deletedParts.contains(s.partId) &&
            !cascadedDeletedNoteIds.contains(s.startNoteId) &&
            !cascadedDeletedNoteIds.contains(s.endNoteId))
          s.spannerId: s,
    };
    for (final s in batch.upsertSpanners) {
      spannerMap[s.spannerId] = s;
    }

    final deletedTakeParts = batch.deleteAudioTakePartIds.toSet();
    final takeMap = <PartId, AudioTakeEntity>{
      for (final t in _agg.audioTakes)
        if (!deletedParts.contains(t.partId) &&
            !deletedTakeParts.contains(t.partId))
          t.partId: t,
    };
    for (final t in batch.upsertAudioTakes) {
      takeMap[t.partId] = t;
    }

    final meta = batch.projectMetadataUpdate;
    final nextRev = overrideReturnedRevision ?? (_agg.project.revision + 1);
    overrideReturnedRevision = null;

    _agg = ProjectWorkspaceAggregate(
      project: ProjectSummary(
        projectId: _agg.project.projectId,
        title: meta?.title ?? _agg.project.title,
        ppqn: _agg.project.ppqn,
        gridSnapTicks: meta?.gridSnapTicks ?? _agg.project.gridSnapTicks,
        pickupTicks: meta?.pickupTicks ?? _agg.project.pickupTicks,
        playbackTimingMode:
            meta?.playbackTimingMode ?? _agg.project.playbackTimingMode,
        revision: nextRev,
        createdAtMs: _agg.project.createdAtMs,
        updatedAtMs: _agg.project.updatedAtMs + 1,
      ),
      parts: partMap.values.toList(),
      tempoEvents: tempoMap.values.toList(),
      timeSignatureEvents: tsMap.values.toList(),
      keySignatureEvents: ksMap.values.toList(),
      clefEvents: clefMap.values.toList(),
      notes: noteMap.values.toList(),
      spanners: spannerMap.values.toList(),
      audioTakes: takeMap.values.toList(),
    );
    return Ok<int>(nextRev);
  }

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
  Future<Result<ProjectWorkspaceAggregate>> loadProjectAggregate(
    ProjectId projectId,
  ) => throw UnimplementedError();

  @override
  Future<Result<AudioTakeEntity>> promoteAndCommitRecordedTake({
    required RecordingCaptureReceipt receipt,
    required ProjectId projectId,
    required PartId partId,
    required Tick alignedStartTick,
    required int calibrationOffsetFrames,
  }) => throw UnimplementedError();

  @override
  Future<Result<List<AudioTakeEntity>>> realignAudioTakesCalibration({
    required ProjectId projectId,
    required List<AudioTakeRealignmentUpdate> updates,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> softDeleteProject(
    ProjectId projectId, {
    required int deletedAtMs,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> updateProjectMetadata(
    UpdateProjectMetadataInput input,
  ) => throw UnimplementedError();
}

final class _RecordingPlaybackCoordinator
    implements ILookaheadPlaybackCoordinator {
  final List<({Tick start, Tick end})> mutationNotifications =
      <({Tick start, Tick end})>[];

  @override
  void notifyScoreMutatedInRange({
    required Tick affectedStartTick,
    required Tick affectedEndTick,
  }) {
    mutationNotifications.add((
      start: affectedStartTick,
      end: affectedEndTick,
    ));
  }

  @override
  bool get isAttached => false;

  @override
  bool get isPlaying => false;

  @override
  bool get isLoopEnabled => false;

  @override
  ({Tick startTick, Tick endTick})? get loopTickRange => null;

  @override
  SoundFontHandle? get preferredPercussionSoundFontHandle => null;

  @override
  Stream<MuseError> get asyncErrors => const Stream<MuseError>.empty();

  @override
  Stream<PlaybackLoopStateSnapshot> get loopStateChanges =>
      const Stream<PlaybackLoopStateSnapshot>.empty();

  @override
  Stream<PlaybackPlayheadReanchorEvent> get playheadReanchored =>
      const Stream<PlaybackPlayheadReanchorEvent>.empty();

  @override
  Future<Result<void>> attachProject(ScoreWorkspaceState workspace) async =>
      const Ok<void>(null);

  @override
  Future<Result<void>> setArmedRecordingPartSuppression(
    PartId? partId, {
    ScoreWorkspaceState? updatedWorkspace,
  }) async => const Ok<void>(null);

  @override
  Future<Result<void>> refreshActiveTakeRegionsIfAttached(
    ProjectId projectId, {
    ScoreWorkspaceState? updatedWorkspace,
  }) async => const Ok<void>(null);

  @override
  Result<void> restoreChannelPatches() => const Ok<void>(null);

  @override
  Future<void> dispose() async {}

  @override
  Result<void> auditionNote({
    required PartId partId,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  }) => const Ok<void>(null);

  @override
  Future<void> detachProject() async {}

  @override
  Result<void> pause() => const Ok<void>(null);

  @override
  Future<Result<void>> play() async => const Ok<void>(null);

  @override
  Result<void> seekToTick(Tick targetTick) => const Ok<void>(null);

  @override
  Result<void> setLoopTickRange({
    required bool enabled,
    required Tick startTick,
    required Tick endTick,
  }) => const Ok<void>(null);

  @override
  Result<void> stop() => const Ok<void>(null);

  @override
  Future<Result<void>> unloadUnusedSoundFont(SoundFontId sfId) async =>
      const Ok<void>(null);
}

ProjectPartEntity _part({
  required String id,
  required String xmlId,
  required int sortOrder,
  required String name,
  int staves = 1,
  int channel = 0,
}) => ProjectPartEntity(
  partId: PartId(id),
  projectId: const ProjectId('proj-1'),
  musicXmlPartId: xmlId,
  sortOrder: sortOrder,
  name: name,
  stavesCount: staves,
  midiChannel: channel,
  sfId: const SoundFontId('sf-1'),
  bankNum: 0,
  programNum: 0,
  gainDb: 0.0,
  pan: 0.0,
  isMuted: false,
  isSolo: false,
  updatedAtMs: 1000,
);

TimelineNote _note({
  required String id,
  String partId = 'part-1',
  int staff = 1,
  int voice = 1,
  int pitch = 60,
  int rawStart = 0,
  int rawDuration = 960,
  int quantStart = 0,
  int quantDuration = 960,
  int velocity = 80,
}) => TimelineNote(
  noteId: NoteId(id),
  projectId: const ProjectId('proj-1'),
  partId: PartId(partId),
  staffNumber: staff,
  voiceNumber: voice,
  pitchMidi: pitch,
  enharmonicStep: EnharmonicStep.C,
  enharmonicAlter: 0,
  rawStartTick: Tick(rawStart),
  rawDurationTicks: rawDuration,
  quantizedStartTick: Tick(quantStart),
  quantizedDurationTicks: quantDuration,
  velocity: velocity,
  updatedAtMs: 1000,
);

ProjectWorkspaceAggregate _initialAggregate() => ProjectWorkspaceAggregate(
  project: const ProjectSummary(
    projectId: ProjectId('proj-1'),
    title: 'Initial Score',
    ppqn: MuseConstants.ppqn,
    gridSnapTicks: MuseConstants.sixteenthNoteTicks,
    pickupTicks: 0,
    playbackTimingMode: PlaybackTimingMode.quantized,
    revision: 1,
    createdAtMs: 1000,
    updatedAtMs: 1000,
  ),
  parts: <ProjectPartEntity>[
    _part(id: 'part-1', xmlId: 'P1', sortOrder: 0, name: 'Piano', staves: 2),
    _part(
      id: 'part-2',
      xmlId: 'P2',
      sortOrder: 1,
      name: 'Violin',
      staves: 1,
      channel: 1,
    ),
  ],
  tempoEvents: const <TempoEventEntity>[
    TempoEventEntity(
      tempoEventId: TempoEventId('tempo-0'),
      projectId: ProjectId('proj-1'),
      tick: Tick(0),
      usPerQuarter: 500000,
      updatedAtMs: 1000,
    ),
  ],
  timeSignatureEvents: const <TimeSignatureEventEntity>[
    TimeSignatureEventEntity(
      tsEventId: TimeSigEventId('ts-0'),
      projectId: ProjectId('proj-1'),
      tick: Tick(0),
      numerator: 4,
      denominator: 4,
      updatedAtMs: 1000,
    ),
  ],
  keySignatureEvents: const <KeySignatureEventEntity>[
    KeySignatureEventEntity(
      keyEventId: KeySigEventId('ks-part-1'),
      projectId: ProjectId('proj-1'),
      partId: PartId('part-1'),
      staffNumber: 0,
      tick: Tick(0),
      fifths: 0,
      mode: KeyMode.major,
      updatedAtMs: 1000,
    ),
  ],
  clefEvents: const <ClefEventEntity>[
    ClefEventEntity(
      clefEventId: ClefEventId('clef-1'),
      projectId: ProjectId('proj-1'),
      partId: PartId('part-1'),
      staffNumber: 1,
      tick: Tick(0),
      sign: ClefSign.G,
      line: 2,
      octaveChange: 0,
      updatedAtMs: 1000,
    ),
    ClefEventEntity(
      clefEventId: ClefEventId('clef-2'),
      projectId: ProjectId('proj-1'),
      partId: PartId('part-1'),
      staffNumber: 2,
      tick: Tick(0),
      sign: ClefSign.F,
      line: 4,
      octaveChange: 0,
      updatedAtMs: 1000,
    ),
    ClefEventEntity(
      clefEventId: ClefEventId('clef-3'),
      projectId: ProjectId('proj-1'),
      partId: PartId('part-2'),
      staffNumber: 1,
      tick: Tick(0),
      sign: ClefSign.G,
      line: 2,
      octaveChange: 0,
      updatedAtMs: 1000,
    ),
  ],
  notes: <TimelineNote>[
    _note(id: 'n-1', rawStart: 0, quantStart: 0),
    _note(id: 'n-2', pitch: 64, rawStart: 960, quantStart: 960),
    _note(id: 'n-p2', partId: 'part-2', pitch: 67, rawStart: 0, quantStart: 0),
  ],
  spanners: const <NoteSpannerEntity>[
    NoteSpannerEntity(
      spannerId: SpannerId('sp-1'),
      projectId: ProjectId('proj-1'),
      partId: PartId('part-1'),
      spannerType: SpannerType.slur,
      startNoteId: NoteId('n-1'),
      endNoteId: NoteId('n-2'),
      spannerLevel: 1,
      placement: SpannerPlacement.auto,
      updatedAtMs: 1000,
    ),
  ],
  audioTakes: const <AudioTakeEntity>[
    AudioTakeEntity(
      takeId: TakeId('take-1'),
      projectId: ProjectId('proj-1'),
      partId: PartId('part-1'),
      blobSha256: Sha256Digest(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      startTick: Tick(960),
      sampleRate: 48000,
      channelCount: 1,
      durationFrames: 48000,
      capturedPlayheadFrame: SampleFrame(48000),
      capturedSampleClock: SampleFrame(48000),
      outputBufferFrames: 256,
      inputBufferFrames: 256,
      calibrationOffsetFrames: 0,
      createdAtMs: 1000,
      updatedAtMs: 1000,
    ),
  ],
);

ScoreEditingCommandBus _createBus({
  _FakeProjectRepository? repo,
  _RecordingPlaybackCoordinator? coordinator,
  int maxHistoryDepth = ScoreEditingCommandBus.defaultMaxHistoryDepth,
}) {
  final dualModelService = DualModelScoreService();
  final agg = repo?.storedAggregate ?? _initialAggregate();
  final initialResult = dualModelService.buildWorkspaceState(agg);
  final initialState = (initialResult as Ok<ScoreWorkspaceState>).value;
  return ScoreEditingCommandBus(
    initialState: initialState,
    projectRepository: repo ?? _FakeProjectRepository(agg),
    dualModelService: dualModelService,
    playbackCoordinator: coordinator,
    maxHistoryDepth: maxHistoryDepth,
  );
}

void main() {
  group('ScoreEditingCommandBus — 19 commands + Undo/Redo', () {
    test('InsertNotesCommand, UpdateNotesCommand, DeleteNotesCommand with cascade spanner restore', () async {
      final repo = _FakeProjectRepository(_initialAggregate());
      final playback = _RecordingPlaybackCoordinator();
      final bus = _createBus(repo: repo, coordinator: playback);
      addTearDown(bus.dispose);

      // Insert
      final inserted = _note(
        id: 'n-3',
        pitch: 67,
        rawStart: 1920,
        quantStart: 1920,
      );
      final execRes = await bus.execute(InsertNotesCommand([inserted]));
      expect(execRes, isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.notes.any((n) => n.noteId == inserted.noteId), isTrue);
      expect(bus.currentState.aggregate.project.revision, 2);
      expect(bus.canUndo, isTrue);
      expect(playback.mutationNotifications.last, (
        start: const Tick(1920),
        end: const Tick(2880),
      ));

      // Undo Insert
      final undoRes = await bus.undo();
      expect(undoRes, isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.notes.any((n) => n.noteId == inserted.noteId), isFalse);
      expect(bus.currentState.aggregate.project.revision, 3);
      expect(bus.canRedo, isTrue);

      // Redo Insert
      final redoRes = await bus.redo();
      expect(redoRes, isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.notes.any((n) => n.noteId == inserted.noteId), isTrue);

      // Update
      final updated = _note(
        id: 'n-3',
        pitch: 69,
        rawStart: 2400,
        quantStart: 2400,
      );
      expect(await bus.execute(UpdateNotesCommand([updated])), isA<Ok<ScoreWorkspaceState>>());
      expect(
        bus.currentState.aggregate.notes.firstWhere((n) => n.noteId == updated.noteId).pitchMidi,
        69,
      );
      expect(playback.mutationNotifications.last, (
        start: const Tick(1920),
        end: const Tick(3360),
      ));
      await bus.undo();
      expect(
        bus.currentState.aggregate.notes.firstWhere((n) => n.noteId == updated.noteId).pitchMidi,
        67,
      );
      await bus.redo();
      expect(
        bus.currentState.aggregate.notes.firstWhere((n) => n.noteId == updated.noteId).pitchMidi,
        69,
      );

      // Delete n-1 cascades sp-1; Undo restores BOTH n-1 and sp-1
      final delRes = await bus.execute(const DeleteNotesCommand([NoteId('n-1')]));
      expect(delRes, isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.notes.any((n) => n.noteId == const NoteId('n-1')), isFalse);
      expect(bus.currentState.aggregate.spanners, isEmpty);

      await bus.undo();
      expect(bus.currentState.aggregate.notes.any((n) => n.noteId == const NoteId('n-1')), isTrue);
      expect(bus.currentState.aggregate.spanners.map((s) => s.spannerId), [
        const SpannerId('sp-1'),
      ]);

      await bus.redo();
      expect(bus.currentState.aggregate.spanners, isEmpty);
    });

    test('UpsertNoteSpannerCommand and DeleteNoteSpannerCommand round-trip', () async {
      final bus = _createBus();
      addTearDown(bus.dispose);

      const beam = NoteSpannerEntity(
        spannerId: SpannerId('sp-beam'),
        projectId: ProjectId('proj-1'),
        partId: PartId('part-1'),
        spannerType: SpannerType.beam,
        startNoteId: NoteId('n-1'),
        endNoteId: NoteId('n-2'),
        spannerLevel: 1,
        placement: SpannerPlacement.below,
        updatedAtMs: 2000,
      );
      expect(await bus.execute(const UpsertNoteSpannerCommand(beam)), isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.spanners.length, 2);

      await bus.undo();
      expect(bus.currentState.aggregate.spanners.length, 1);

      await bus.redo();
      expect(bus.currentState.aggregate.spanners.length, 2);

      expect(
        await bus.execute(const DeleteNoteSpannerCommand(SpannerId('sp-beam'))),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.spanners.length, 1);
      await bus.undo();
      expect(bus.currentState.aggregate.spanners.length, 2);
      await bus.redo();
      expect(bus.currentState.aggregate.spanners.length, 1);
    });

    test('Tempo & TimeSignature upsert (including same-tick replacement) and delete', () async {
      final playback = _RecordingPlaybackCoordinator();
      final bus = _createBus(coordinator: playback);
      addTearDown(bus.dispose);

      const tempoA = TempoEventEntity(
        tempoEventId: TempoEventId('t-1'),
        projectId: ProjectId('proj-1'),
        tick: Tick(3840),
        usPerQuarter: 400000,
        updatedAtMs: 2000,
      );
      expect(await bus.execute(const UpsertTempoEventCommand(tempoA)), isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.tempoEvents.length, 2);
      expect(playback.mutationNotifications.last.start, const Tick(3840));

      // Overwrite tick 3840 with a DIFFERENT tempoEventId
      const tempoB = TempoEventEntity(
        tempoEventId: TempoEventId('t-2'),
        projectId: ProjectId('proj-1'),
        tick: Tick(3840),
        usPerQuarter: 300000,
        updatedAtMs: 2001,
      );
      expect(await bus.execute(const UpsertTempoEventCommand(tempoB)), isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.tempoEvents.map((e) => e.tempoEventId), containsAll([
        const TempoEventId('tempo-0'),
        const TempoEventId('t-2'),
      ]));
      expect(bus.currentState.aggregate.tempoEvents.length, 2);

      await bus.undo();
      expect(
        bus.currentState.aggregate.tempoEvents.firstWhere((e) => e.tick == const Tick(3840)).tempoEventId,
        const TempoEventId('t-1'),
      );
      await bus.redo();
      expect(
        bus.currentState.aggregate.tempoEvents.firstWhere((e) => e.tick == const Tick(3840)).tempoEventId,
        const TempoEventId('t-2'),
      );

      expect(
        await bus.execute(const DeleteTempoEventCommand(TempoEventId('t-2'))),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.tempoEvents.length, 1);
      await bus.undo();
      expect(bus.currentState.aggregate.tempoEvents.length, 2);

      // Time signature
      const tsNew = TimeSignatureEventEntity(
        tsEventId: TimeSigEventId('ts-1'),
        projectId: ProjectId('proj-1'),
        tick: Tick(3840),
        numerator: 3,
        denominator: 4,
        updatedAtMs: 2000,
      );
      expect(await bus.execute(const UpsertTimeSignatureCommand(tsNew)), isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.timeSignatureEvents.length, 2);

      expect(
        await bus.execute(const DeleteTimeSignatureCommand(TimeSigEventId('ts-1'))),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.timeSignatureEvents.length, 1);
      await bus.undo();
      expect(bus.currentState.aggregate.timeSignatureEvents.length, 2);
      await bus.redo();
      expect(bus.currentState.aggregate.timeSignatureEvents.length, 1);
    });

    test('KeySignature and Clef upserts/deletes and Undo/Redo (zero playback flush)', () async {
      final playback = _RecordingPlaybackCoordinator();
      final bus = _createBus(coordinator: playback);
      addTearDown(bus.dispose);

      const ksGlobal = KeySignatureEventEntity(
        keyEventId: KeySigEventId('ks-g'),
        projectId: ProjectId('proj-1'),
        partId: null,
        staffNumber: 0,
        tick: Tick(3840),
        fifths: 2,
        mode: KeyMode.major,
        updatedAtMs: 2000,
      );
      expect(await bus.execute(const UpsertKeySignatureCommand(ksGlobal)), isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.keySignatureEvents.length, 2);
      expect(playback.mutationNotifications, isEmpty);

      expect(
        await bus.execute(const DeleteKeySignatureCommand(KeySigEventId('ks-g'))),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.keySignatureEvents.length, 1);
      await bus.undo();
      expect(bus.currentState.aggregate.keySignatureEvents.length, 2);
      await bus.redo();
      expect(bus.currentState.aggregate.keySignatureEvents.length, 1);

      const newClef = ClefEventEntity(
        clefEventId: ClefEventId('clef-new'),
        projectId: ProjectId('proj-1'),
        partId: PartId('part-2'),
        staffNumber: 1,
        tick: Tick(3840),
        sign: ClefSign.C,
        line: 3,
        octaveChange: 0,
        updatedAtMs: 2000,
      );
      expect(await bus.execute(const UpsertClefEventCommand(newClef)), isA<Ok<ScoreWorkspaceState>>());
      expect(bus.currentState.aggregate.clefEvents.length, 4);
      expect(
        await bus.execute(const DeleteClefEventCommand(ClefEventId('clef-new'))),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.clefEvents.length, 3);
      await bus.undo();
      expect(bus.currentState.aggregate.clefEvents.length, 4);
      await bus.redo();
      expect(bus.currentState.aggregate.clefEvents.length, 3);
      expect(playback.mutationNotifications, isEmpty);
    });

    test('AddProjectPart, UpdatePartMixerOrPatch, ReorderProjectParts, RemoveProjectPart, ClearPartAudio, UpdateProjectSettings', () async {
      final playback = _RecordingPlaybackCoordinator();
      final bus = _createBus(coordinator: playback);
      addTearDown(bus.dispose);

      // AddProjectPartCommand
      final addedPart = _part(
        id: 'part-3',
        xmlId: 'P3',
        sortOrder: 2,
        name: 'Cello',
        channel: 2,
      );
      const addedClef = ClefEventEntity(
        clefEventId: ClefEventId('clef-p3'),
        projectId: ProjectId('proj-1'),
        partId: PartId('part-3'),
        staffNumber: 1,
        tick: Tick(0),
        sign: ClefSign.F,
        line: 4,
        octaveChange: 0,
        updatedAtMs: 2000,
      );
      expect(
        await bus.execute(
          AddProjectPartCommand(part: addedPart, initialClefs: const [addedClef]),
        ),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.parts.length, 3);
      expect(bus.currentState.aggregate.clefEvents.length, 4);
      await bus.undo();
      expect(bus.currentState.aggregate.parts.length, 2);
      expect(bus.currentState.aggregate.clefEvents.length, 3);
      await bus.redo();
      expect(bus.currentState.aggregate.parts.length, 3);

      // UpdatePartMixerOrPatchCommand
      final mutedCello = ProjectPartEntity(
        partId: addedPart.partId,
        projectId: addedPart.projectId,
        musicXmlPartId: addedPart.musicXmlPartId,
        sortOrder: addedPart.sortOrder,
        name: addedPart.name,
        stavesCount: addedPart.stavesCount,
        midiChannel: addedPart.midiChannel,
        sfId: addedPart.sfId,
        bankNum: 1,
        programNum: 42,
        gainDb: -3.5,
        pan: -0.25,
        isMuted: true,
        isSolo: false,
        updatedAtMs: 2100,
      );
      expect(
        await bus.execute(UpdatePartMixerOrPatchCommand(mutedCello)),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(
        bus.currentState.aggregate.parts.firstWhere((p) => p.partId == addedPart.partId).programNum,
        42,
      );
      await bus.undo();
      expect(
        bus.currentState.aggregate.parts.firstWhere((p) => p.partId == addedPart.partId).programNum,
        0,
      );
      await bus.redo();
      expect(
        bus.currentState.aggregate.parts.firstWhere((p) => p.partId == addedPart.partId).isMuted,
        isTrue,
      );

      // ReorderProjectPartsCommand
      final prevNotificationCount = playback.mutationNotifications.length;
      expect(
        await bus.execute(
          const ReorderProjectPartsCommand([
            PartId('part-3'),
            PartId('part-2'),
            PartId('part-1'),
          ]),
        ),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(
        bus.currentState.aggregate.parts
            .firstWhere((p) => p.partId == const PartId('part-3'))
            .sortOrder,
        0,
      );
      expect(playback.mutationNotifications.length, prevNotificationCount);
      await bus.undo();
      expect(
        bus.currentState.aggregate.parts
            .firstWhere((p) => p.partId == const PartId('part-1'))
            .sortOrder,
        0,
      );
      await bus.redo();

      // RemoveProjectPartCommand restores full part + clefs + key sigs + notes + spanners + audio take!
      expect(
        await bus.execute(const RemoveProjectPartCommand(PartId('part-1'))),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.parts.any((p) => p.partId == const PartId('part-1')), isFalse);
      expect(bus.currentState.aggregate.notes.any((n) => n.partId == const PartId('part-1')), isFalse);
      expect(bus.currentState.aggregate.spanners, isEmpty);
      expect(bus.currentState.aggregate.audioTakes, isEmpty);
      expect(bus.currentState.aggregate.keySignatureEvents, isEmpty);
      expect(bus.currentState.aggregate.clefEvents.any((c) => c.partId == const PartId('part-1')), isFalse);

      await bus.undo();
      expect(bus.currentState.aggregate.parts.any((p) => p.partId == const PartId('part-1')), isTrue);
      expect(bus.currentState.aggregate.notes.where((n) => n.partId == const PartId('part-1')).length, 2);
      expect(bus.currentState.aggregate.spanners.length, 1);
      expect(bus.currentState.aggregate.audioTakes.length, 1);
      expect(bus.currentState.aggregate.keySignatureEvents.length, 1);
      expect(bus.currentState.aggregate.clefEvents.where((c) => c.partId == const PartId('part-1')).length, 2);

      // ClearPartAudioCommand restores AudioTakeEntity on undo
      expect(
        await bus.execute(const ClearPartAudioCommand(PartId('part-1'))),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.audioTakes, isEmpty);
      await bus.undo();
      expect(bus.currentState.aggregate.audioTakes.single.takeId, const TakeId('take-1'));
      await bus.redo();
      expect(bus.currentState.aggregate.audioTakes, isEmpty);

      // UpdateProjectSettingsCommand (title-only does not notify playback; timingMode does!)
      final countBeforeTitle = playback.mutationNotifications.length;
      expect(
        await bus.execute(
          const UpdateProjectSettingsCommand(title: 'Revised Score'),
        ),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.project.title, 'Revised Score');
      expect(playback.mutationNotifications.length, countBeforeTitle);

      expect(
        await bus.execute(
          const UpdateProjectSettingsCommand(
            pickupTicks: 480,
            playbackTimingMode: PlaybackTimingMode.raw,
          ),
        ),
        isA<Ok<ScoreWorkspaceState>>(),
      );
      expect(bus.currentState.aggregate.project.pickupTicks, 480);
      expect(
        bus.currentState.aggregate.project.playbackTimingMode,
        PlaybackTimingMode.raw,
      );
      expect(playback.mutationNotifications.length, countBeforeTitle + 1);

      await bus.undo();
      expect(bus.currentState.aggregate.project.pickupTicks, 0);
      expect(
        bus.currentState.aggregate.project.playbackTimingMode,
        PlaybackTimingMode.quantized,
      );
    });
  });

  group('ScoreEditingCommandBus — fail-closed guards & resilience', () {
    test('rejects tick == 0 tempo/time-signature deletions with protectedInitialMapEvent before repo call', () async {
      final repo = _FakeProjectRepository(_initialAggregate());
      final bus = _createBus(repo: repo);
      addTearDown(bus.dispose);

      final tRes = await bus.execute(
        const DeleteTempoEventCommand(TempoEventId('tempo-0')),
      );
      expect(
        (tRes as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.protectedInitialMapEvent,
      );

      final tsRes = await bus.execute(
        const DeleteTimeSignatureCommand(TimeSigEventId('ts-0')),
      );
      expect(
        (tsRes as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.protectedInitialMapEvent,
      );
      expect(repo.commitCallCount, 0);
      expect(bus.canUndo, isFalse);
    });

    test('rejects invalid MIDI bounds, invalid ticks, and missing entities fail-closed', () async {
      final repo = _FakeProjectRepository(_initialAggregate());
      final bus = _createBus(repo: repo);
      addTearDown(bus.dispose);

      final badPitch = await bus.execute(
        InsertNotesCommand([_note(id: 'bad-p', pitch: 128)]),
      );
      expect(
        (badPitch as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      final badVelocity = await bus.execute(
        InsertNotesCommand([_note(id: 'bad-v', velocity: 0)]),
      );
      expect(
        (badVelocity as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      final badPartChannel = await bus.execute(
        AddProjectPartCommand(
          part: _part(id: 'p-bad', xmlId: 'P9', sortOrder: 2, name: 'Bad', channel: 16),
          initialClefs: const [],
        ),
      );
      expect(
        (badPartChannel as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      final badTick = await bus.execute(
        InsertNotesCommand([_note(id: 'bad-t', rawStart: -1)]),
      );
      expect(
        (badTick as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.invalidTickRange,
      );

      final missingNote = await bus.execute(
        const DeleteNotesCommand([NoteId('does-not-exist')]),
      );
      expect(
        (missingNote as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.entityNotFound,
      );

      final emptyTitle = await bus.execute(
        const UpdateProjectSettingsCommand(title: '   '),
      );
      expect(
        (emptyTitle as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.invalidTickRange,
      );
      expect(repo.commitCallCount, 0);
    });

    test('repository Err leaves currentState, stacks, and stateStream untouched', () async {
      final repo = _FakeProjectRepository(_initialAggregate());
      final bus = _createBus(repo: repo);
      addTearDown(bus.dispose);

      final emitted = <ScoreWorkspaceState>[];
      final sub = bus.stateStream.listen(emitted.add);
      addTearDown(sub.cancel);

      final beforeState = bus.currentState;
      repo.nextCommitError = const MuseError(
        MuseErrorCode.revisionConflict,
        'Simulated DB failure',
      );

      final res = await bus.execute(
        InsertNotesCommand([_note(id: 'n-fail', rawStart: 1920, quantStart: 1920)]),
      );
      expect((res as Err<ScoreWorkspaceState>).error.code, MuseErrorCode.revisionConflict);
      expect(identical(bus.currentState, beforeState), isTrue);
      expect(bus.canUndo, isFalse);
      expect(bus.canRedo, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(emitted, isEmpty);
    });

    test('serializes concurrent execute/undo/redo cleanly without revision conflicts', () async {
      final repo = _FakeProjectRepository(_initialAggregate())
        ..commitDelay = const Duration(milliseconds: 5);
      final bus = _createBus(repo: repo);
      addTearDown(bus.dispose);

      final results = await Future.wait([
        bus.execute(InsertNotesCommand([_note(id: 'c-1', rawStart: 1920, quantStart: 1920)])),
        bus.execute(InsertNotesCommand([_note(id: 'c-2', rawStart: 2880, quantStart: 2880)])),
        bus.undo(),
      ]);

      for (final r in results) {
        expect(r, isA<Ok<ScoreWorkspaceState>>());
      }
      expect(bus.currentState.aggregate.project.revision, 4);
      expect(bus.currentState.aggregate.notes.any((n) => n.noteId == const NoteId('c-1')), isTrue);
      expect(bus.currentState.aggregate.notes.any((n) => n.noteId == const NoteId('c-2')), isFalse);
      expect(bus.canRedo, isTrue);
    });

    test('bounds undo history depth and syncCommittedTake / syncRealignedTakes keep revisions in sync', () async {
      final repo = _FakeProjectRepository(_initialAggregate());
      final bus = _createBus(repo: repo, maxHistoryDepth: 2);
      addTearDown(bus.dispose);

      await bus.execute(InsertNotesCommand([_note(id: 'h-1', rawStart: 1920, quantStart: 1920)]));
      await bus.execute(InsertNotesCommand([_note(id: 'h-2', rawStart: 2880, quantStart: 2880)]));
      await bus.execute(InsertNotesCommand([_note(id: 'h-3', rawStart: 3840, quantStart: 3840)]));

      // Only h-2 and h-3 fit within maxHistoryDepth == 2.
      expect(await bus.undo(), isA<Ok<ScoreWorkspaceState>>());
      expect(await bus.undo(), isA<Ok<ScoreWorkspaceState>>());
      expect(bus.canUndo, isFalse);
      expect(bus.currentState.aggregate.notes.any((n) => n.noteId == const NoteId('h-1')), isTrue);

      // Simulate RecordingSessionCoordinator committing a recorded take directly into SQLite (rev bumped +1).
      const recordedTake = AudioTakeEntity(
        takeId: TakeId('take-2'),
        projectId: ProjectId('proj-1'),
        partId: PartId('part-2'),
        blobSha256: Sha256Digest(
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
        startTick: Tick(480),
        sampleRate: 48000,
        channelCount: 1,
        durationFrames: 24000,
        capturedPlayheadFrame: SampleFrame(24000),
        capturedSampleClock: SampleFrame(24000),
        outputBufferFrames: 256,
        inputBufferFrames: 256,
        calibrationOffsetFrames: 0,
        createdAtMs: 3000,
        updatedAtMs: 3000,
      );
      await repo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-1'),
          expectedRevision: bus.currentState.aggregate.project.revision,
          upsertAudioTakes: const [recordedTake],
        ),
      );
      await bus.syncCommittedTake(recordedTake);
      expect(
        bus.currentState.aggregate.audioTakes.any((t) => t.takeId == const TakeId('take-2')),
        isTrue,
      );

      // Simulate recalibration update
      const realignedTake = AudioTakeEntity(
        takeId: TakeId('take-2'),
        projectId: ProjectId('proj-1'),
        partId: PartId('part-2'),
        blobSha256: Sha256Digest(
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
        startTick: Tick(240),
        sampleRate: 48000,
        channelCount: 1,
        durationFrames: 24000,
        capturedPlayheadFrame: SampleFrame(24000),
        capturedSampleClock: SampleFrame(24000),
        outputBufferFrames: 256,
        inputBufferFrames: 256,
        calibrationOffsetFrames: 512,
        createdAtMs: 3000,
        updatedAtMs: 4000,
      );
      await repo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: const ProjectId('proj-1'),
          expectedRevision: bus.currentState.aggregate.project.revision,
          upsertAudioTakes: const [realignedTake],
        ),
      );
      await bus.syncRealignedTakes(const [realignedTake]);
      expect(
        bus.currentState.aggregate.audioTakes
            .firstWhere((t) => t.takeId == const TakeId('take-2'))
            .startTick,
        const Tick(240),
      );

      // Redo of h-2 still succeeds cleanly using the updated revision!
      expect(await bus.redo(), isA<Ok<ScoreWorkspaceState>>());
    });

    test('concurrent syncCommittedTake, syncRealignedTakes, and runSerialized serialize cleanly behind in-flight execute()', () async {
      final repo = _FakeProjectRepository(_initialAggregate())
        ..commitDelay = const Duration(milliseconds: 25);
      final playback = _RecordingPlaybackCoordinator();
      final bus = _createBus(repo: repo, coordinator: playback);
      addTearDown(bus.dispose);

      // Fire an async execute() that takes 25ms in SQLite.
      final insertFuture = bus.execute(
        InsertNotesCommand(<TimelineNote>[
          _note(
            id: 'concurrent-note',
            quantStart: 1920,
            quantDuration: 480,
          ),
        ]),
      );

      // Immediately interleave a serialized recording commit + syncCommittedTake while execute() is in flight!
      const committedTake = AudioTakeEntity(
        takeId: TakeId('take-concurrent'),
        projectId: ProjectId('proj-1'),
        partId: PartId('part-2'),
        blobSha256: Sha256Digest(
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        ),
        startTick: Tick(960),
        sampleRate: 48000,
        channelCount: 1,
        durationFrames: 24000,
        capturedPlayheadFrame: SampleFrame(48000),
        capturedSampleClock: SampleFrame(48000),
        outputBufferFrames: 256,
        inputBufferFrames: 256,
        calibrationOffsetFrames: 0,
        createdAtMs: 5000,
        updatedAtMs: 5000,
      );

      final commitSyncFuture = bus.runSerialized<Result<AudioTakeEntity>>(() async {
        final rev = bus.currentState.aggregate.project.revision;
        final dbRes = await repo.commitScoreMutationBatch(
          ScoreMutationBatch(
            projectId: const ProjectId('proj-1'),
            expectedRevision: rev,
            upsertAudioTakes: const [committedTake],
          ),
        );
        expect(dbRes, isA<Ok<int>>());
        await bus.syncCommittedTake(committedTake);
        return const Ok<AudioTakeEntity>(committedTake);
      });

      final realignedTake = AudioTakeEntity(
        takeId: committedTake.takeId,
        projectId: committedTake.projectId,
        partId: committedTake.partId,
        blobSha256: committedTake.blobSha256,
        startTick: const Tick(720),
        sampleRate: committedTake.sampleRate,
        channelCount: committedTake.channelCount,
        durationFrames: committedTake.durationFrames,
        capturedPlayheadFrame: committedTake.capturedPlayheadFrame,
        capturedSampleClock: committedTake.capturedSampleClock,
        outputBufferFrames: committedTake.outputBufferFrames,
        inputBufferFrames: committedTake.inputBufferFrames,
        calibrationOffsetFrames: 256,
        createdAtMs: committedTake.createdAtMs,
        updatedAtMs: 6000,
      );

      final realignFuture = bus.runSerialized<Result<void>>(() async {
        final rev = bus.currentState.aggregate.project.revision;
        final dbRes = await repo.commitScoreMutationBatch(
          ScoreMutationBatch(
            projectId: const ProjectId('proj-1'),
            expectedRevision: rev,
            upsertAudioTakes: <AudioTakeEntity>[realignedTake],
          ),
        );
        expect(dbRes, isA<Ok<int>>());
        await bus.syncRealignedTakes(<AudioTakeEntity>[realignedTake]);
        return const Ok<void>(null);
      });

      final insertRes = await insertFuture;
      final commitSyncRes = await commitSyncFuture;
      final realignRes = await realignFuture;

      expect(insertRes, isA<Ok<ScoreWorkspaceState>>());
      expect(commitSyncRes, isA<Ok<AudioTakeEntity>>());
      expect(realignRes, isA<Ok<void>>());

      // Zero lost mutations: both concurrent-note AND realigned take exist, and DB + bus revisions match!
      expect(
        bus.currentState.aggregate.notes.any(
          (n) => n.noteId == const NoteId('concurrent-note'),
        ),
        isTrue,
      );
      final liveTake = bus.currentState.aggregate.audioTakes.firstWhere(
        (t) => t.takeId == committedTake.takeId,
      );
      expect(liveTake.startTick, const Tick(720));
      expect(
        bus.currentState.aggregate.project.revision,
        repo.storedAggregate.project.revision,
      );
    });

    test('cross-part UpdateNotesCommand rebuilds source & target staves/spatial indices and migrates or splits spanners across Do/Undo/Redo', () async {
      final initial = _initialAggregate();
      final aggWithMultiNotes = ProjectWorkspaceAggregate(
        project: initial.project,
        parts: initial.parts,
        tempoEvents: initial.tempoEvents,
        timeSignatureEvents: initial.timeSignatureEvents,
        keySignatureEvents: initial.keySignatureEvents,
        clefEvents: initial.clefEvents,
        notes: <TimelineNote>[
          ...initial.notes,
          _note(
            id: 'n-3',
            partId: 'part-1',
            pitch: 65,
            rawStart: 960,
            rawDuration: 480,
            quantStart: 960,
            quantDuration: 480,
          ),
          _note(
            id: 'n-4',
            partId: 'part-1',
            pitch: 67,
            rawStart: 1440,
            rawDuration: 480,
            quantStart: 1440,
            quantDuration: 480,
          ),
        ],
        spanners: <NoteSpannerEntity>[
          // sp-1 links n-1 and n-2 (both move together to part-2 => migrates partId to part-2)
          ...initial.spanners,
          // sp-split links n-3 (moves to part-2) and n-4 (stays on part-1 => deleted on forward, restored on Undo)
          const NoteSpannerEntity(
            spannerId: SpannerId('sp-split'),
            projectId: ProjectId('proj-1'),
            partId: PartId('part-1'),
            spannerType: SpannerType.slur,
            startNoteId: NoteId('n-3'),
            endNoteId: NoteId('n-4'),
            spannerLevel: 1,
            placement: SpannerPlacement.above,
            updatedAtMs: 1000,
          ),
        ],
        audioTakes: initial.audioTakes,
      );

      final repo = _FakeProjectRepository(aggWithMultiNotes);
      final service = DualModelScoreService();
      final bus = _createBus(repo: repo);
      addTearDown(bus.dispose);

      // Move n-1, n-2, n-3 from part-1 -> part-2 while n-4 stays on part-1.
      final movedNotes = <TimelineNote>[
        _note(
          id: 'n-1',
          partId: 'part-2',
          pitch: 60,
          rawStart: 0,
          rawDuration: 960,
          quantStart: 0,
          quantDuration: 960,
        ),
        _note(
          id: 'n-2',
          partId: 'part-2',
          pitch: 64,
          rawStart: 960,
          rawDuration: 960,
          quantStart: 960,
          quantDuration: 960,
        ),
        _note(
          id: 'n-3',
          partId: 'part-2',
          pitch: 65,
          rawStart: 960,
          rawDuration: 480,
          quantStart: 960,
          quantDuration: 480,
        ),
      ];

      final moveRes = await bus.execute(UpdateNotesCommand(movedNotes));
      expect(moveRes, isA<Ok<ScoreWorkspaceState>>());
      final stateAfterMove = (moveRes as Ok<ScoreWorkspaceState>).value;

      // Co-moved sp-1 migrates to part-2; cross-part split sp-split is deleted.
      final migratedSp1 = stateAfterMove.aggregate.spanners.firstWhere(
        (s) => s.spannerId == const SpannerId('sp-1'),
      );
      expect(migratedSp1.partId, const PartId('part-2'));
      expect(
        stateAfterMove.aggregate.spanners.any(
          (s) => s.spannerId == const SpannerId('sp-split'),
        ),
        isFalse,
      );

      // Both source (part-1) and destination (part-2) spatial indices & crisp StaffSystem rebuild!
      final part1Visible = service
          .queryNotesInViewport(
            state: stateAfterMove,
            partId: const PartId('part-1'),
            startTick: const Tick(0),
            endTick: const Tick(1920),
            minPitchMidi: 0,
            maxPitchMidi: 127,
            timingMode: PlaybackTimingMode.quantized,
          )
          .map((n) => n.noteId.value)
          .toList();
      expect(part1Visible, <String>['n-4']);

      final part2Visible = service
          .queryNotesInViewport(
            state: stateAfterMove,
            partId: const PartId('part-2'),
            startTick: const Tick(0),
            endTick: const Tick(1920),
            minPitchMidi: 0,
            maxPitchMidi: 127,
            timingMode: PlaybackTimingMode.quantized,
          )
          .map((n) => n.noteId.value)
          .toSet();
      expect(part2Visible, <String>{'n-1', 'n-2', 'n-3', 'n-p2'});

      Set<String> staffNoteIds(StaffSystem sys, int staffIndex) => <String>{
        for (final m in sys.staves[staffIndex].measures)
          for (final el in <Object?>[...m.elements, ...m.voice2])
            if (el is NoteElement && el.id != null) el.id!,
      };

      int staffPitchedHeadCount(StaffSystem sys, int staffIndex) => sys
          .staves[staffIndex]
          .measures
          .expand((m) => <Object?>[...m.elements, ...m.voice2])
          .whereType<NoteElement>()
          .fold<int>(0, (sum, el) => sum + el.pitches.length);

      expect(
        staffNoteIds(stateAfterMove.renderSnapshot.crispScoreModel, 0),
        <String>{'n-4'},
      );
      expect(
        staffNoteIds(stateAfterMove.renderSnapshot.crispScoreModel, 2),
        <String>{'n-1', 'n-2', 'n-3'},
      );
      // n-1 and n-p2 share tick 0 + duration 960 on part-2, merging into a 2-note chord under id 'n-1'.
      expect(staffPitchedHeadCount(stateAfterMove.renderSnapshot.crispScoreModel, 2), 4);

      // Undo restores both parts, sp-1 back on part-1, and split sp-split intact!
      final undoRes = await bus.undo();
      expect(undoRes, isA<Ok<ScoreWorkspaceState>>());
      final stateAfterUndo = (undoRes as Ok<ScoreWorkspaceState>).value;
      expect(
        stateAfterUndo.aggregate.spanners
            .firstWhere((s) => s.spannerId == const SpannerId('sp-1'))
            .partId,
        const PartId('part-1'),
      );
      expect(
        stateAfterUndo.aggregate.spanners.any(
          (s) => s.spannerId == const SpannerId('sp-split'),
        ),
        isTrue,
      );
      expect(
        service
            .queryNotesInViewport(
              state: stateAfterUndo,
              partId: const PartId('part-2'),
              startTick: const Tick(0),
              endTick: const Tick(1920),
              minPitchMidi: 0,
              maxPitchMidi: 127,
              timingMode: PlaybackTimingMode.quantized,
            )
            .map((n) => n.noteId.value)
            .toList(),
        <String>['n-p2'],
      );
      expect(
        service
            .queryNotesInViewport(
              state: stateAfterUndo,
              partId: const PartId('part-1'),
              startTick: const Tick(0),
              endTick: const Tick(1920),
              minPitchMidi: 0,
              maxPitchMidi: 127,
              timingMode: PlaybackTimingMode.quantized,
            )
            .map((n) => n.noteId.value)
            .toSet(),
        <String>{'n-1', 'n-2', 'n-3', 'n-4'},
      );
      expect(
        staffNoteIds(stateAfterUndo.renderSnapshot.crispScoreModel, 0),
        <String>{'n-1', 'n-2', 'n-3', 'n-4'},
      );
      expect(
        staffNoteIds(stateAfterUndo.renderSnapshot.crispScoreModel, 2),
        <String>{'n-p2'},
      );

      // Redo re-applies migration + split deletion cleanly!
      final redoRes = await bus.redo();
      expect(redoRes, isA<Ok<ScoreWorkspaceState>>());
      final stateAfterRedo = (redoRes as Ok<ScoreWorkspaceState>).value;
      expect(
        stateAfterRedo.aggregate.spanners
            .firstWhere((s) => s.spannerId == const SpannerId('sp-1'))
            .partId,
        const PartId('part-2'),
      );
      expect(
        stateAfterRedo.aggregate.spanners.any(
          (s) => s.spannerId == const SpannerId('sp-split'),
        ),
        isFalse,
      );
    });
  });
}

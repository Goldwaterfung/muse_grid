import 'dart:async';

import 'package:crisp_notation/crisp_notation.dart'
    show MusicFonts, RenderStaffSystemView, StaffSystemView;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/domain/notation/crisp_score_mapper.dart';
import 'package:muse_grid/domain/notation/dual_model_score_service.dart';
import 'package:muse_grid/domain/playback/lookahead_playback_coordinator.dart';
import 'package:muse_grid/domain/recording/recording_session_coordinator.dart';
import 'package:muse_grid/domain/repositories/storage_contracts.dart';
import 'package:muse_grid/presentation/controllers/audio_session_contract.dart';
import 'package:muse_grid/presentation/controllers/transport_and_telemetry_controller.dart';
import 'package:muse_grid/presentation/controllers/workspace_shell_controller.dart';
import 'package:muse_grid/presentation/notation/staff_notation_panel.dart';
import 'package:muse_grid/presentation/notation/staff_notation_view_controller.dart';
import 'package:muse_grid/presentation/piano_roll/piano_roll_panel.dart';
import 'package:muse_grid/presentation/piano_roll/piano_roll_viewport_controller.dart';
import 'package:muse_grid/presentation/theme/muse_presentation_constants.dart';

final class _FakeAudioSessionController implements IAudioSessionController {
  @override
  CalibrationPlatform get currentPlatform => CalibrationPlatform.macos;

  @override
  final ValueNotifier<AudioSessionStatus> audioSessionStatus = ValueNotifier(
    const AudioSessionStatus(
      phase: AudioSessionPhase.ready,
      hardwareInfo: AudioHardwareInfo(
        sampleRate: 48000,
        outputBufferFrames: 256,
        inputBufferFrames: 256,
        inputChannels: 1,
        outputChannels: 2,
        deviceFingerprint: 'mac-coreaudio-0',
      ),
    ),
  );

  @override
  Future<Result<AudioHardwareInfo>> ensureAudioInitialized() async =>
      Ok(audioSessionStatus.value.hardwareInfo!);

  void dispose() => audioSessionStatus.dispose();
}

final class _InMemoryProjectRepo implements IProjectRepository {
  final Map<ProjectId, ProjectWorkspaceAggregate> _projects =
      <ProjectId, ProjectWorkspaceAggregate>{};
  int commitCalls = 0;
  int _clock = 1000;

  void seed(ProjectWorkspaceAggregate aggregate) {
    _projects[aggregate.project.projectId] = aggregate;
  }

  @override
  Future<Result<ProjectSummary>> createProject(CreateProjectInput input) async {
    throw UnimplementedError();
  }

  @override
  Future<Result<void>> deletePartAudioTake({
    required ProjectId projectId,
    required PartId partId,
  }) async => const Ok(null);

  @override
  Future<Result<List<ProjectSummary>>> listActiveProjects({
    int limit = 25,
    int offset = 0,
  }) async => Ok(
    _projects.values.map((e) => e.project).toList(growable: false),
  );

  @override
  Future<Result<ProjectWorkspaceAggregate>> loadProjectAggregate(
    ProjectId projectId,
  ) async {
    final agg = _projects[projectId];
    if (agg == null) {
      return Err(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Missing project ${projectId.value}',
        ),
      );
    }
    return Ok(agg);
  }

  @override
  Future<Result<int>> commitScoreMutationBatch(ScoreMutationBatch batch) async {
    commitCalls += 1;
    final current = _projects[batch.projectId];
    if (current == null) {
      return const Err(
        MuseError(MuseErrorCode.entityNotFound, 'Project not found'),
      );
    }
    if (current.project.revision != batch.expectedRevision) {
      return const Err(
        MuseError(MuseErrorCode.revisionConflict, 'Revision mismatch'),
      );
    }

    _clock += 10;
    final nextRevision = current.project.revision + 1;
    final meta = batch.projectMetadataUpdate;
    final project = ProjectSummary(
      projectId: current.project.projectId,
      title: meta?.title ?? current.project.title,
      ppqn: current.project.ppqn,
      gridSnapTicks: meta?.gridSnapTicks ?? current.project.gridSnapTicks,
      pickupTicks: meta?.pickupTicks ?? current.project.pickupTicks,
      playbackTimingMode:
          meta?.playbackTimingMode ?? current.project.playbackTimingMode,
      revision: nextRevision,
      createdAtMs: current.project.createdAtMs,
      updatedAtMs: _clock,
    );

    final parts = _applyUpsertsAndDeletes<PartId, ProjectPartEntity>(
      current.parts,
      keyOf: (p) => p.partId,
      upserts: batch.upsertParts,
      deletes: batch.deletePartIds,
    );
    final tempos = _applyUpsertsAndDeletes<TempoEventId, TempoEventEntity>(
      current.tempoEvents,
      keyOf: (t) => t.tempoEventId,
      upserts: batch.upsertTempoEvents,
      deletes: batch.deleteTempoEventIds,
    );
    final timeSigs =
        _applyUpsertsAndDeletes<TimeSigEventId, TimeSignatureEventEntity>(
          current.timeSignatureEvents,
          keyOf: (t) => t.tsEventId,
          upserts: batch.upsertTimeSignatureEvents,
          deletes: batch.deleteTimeSignatureEventIds,
        );
    final keys =
        _applyUpsertsAndDeletes<KeySigEventId, KeySignatureEventEntity>(
          current.keySignatureEvents,
          keyOf: (k) => k.keyEventId,
          upserts: batch.upsertKeySignatureEvents,
          deletes: batch.deleteKeySignatureEventIds,
        );
    final clefs = _applyUpsertsAndDeletes<ClefEventId, ClefEventEntity>(
      current.clefEvents,
      keyOf: (c) => c.clefEventId,
      upserts: batch.upsertClefEvents,
      deletes: batch.deleteClefEventIds,
    );
    final notes = _applyUpsertsAndDeletes<NoteId, TimelineNote>(
      current.notes,
      keyOf: (n) => n.noteId,
      upserts: batch.upsertNotes,
      deletes: batch.deleteNoteIds,
    );
    final spanners = _applyUpsertsAndDeletes<SpannerId, NoteSpannerEntity>(
      current.spanners,
      keyOf: (s) => s.spannerId,
      upserts: batch.upsertSpanners,
      deletes: batch.deleteSpannerIds,
    );

    _projects[batch.projectId] = ProjectWorkspaceAggregate(
      project: project,
      parts: parts,
      tempoEvents: tempos,
      timeSignatureEvents: timeSigs,
      keySignatureEvents: keys,
      clefEvents: clefs,
      notes: notes,
      spanners: spanners,
      audioTakes: current.audioTakes,
    );
    return Ok(nextRevision);
  }

  static List<T> _applyUpsertsAndDeletes<K, T>(
    List<T> source, {
    required K Function(T item) keyOf,
    required List<T> upserts,
    required List<K> deletes,
  }) {
    final map = <K, T>{for (final item in source) keyOf(item): item};
    for (final d in deletes) {
      map.remove(d);
    }
    for (final u in upserts) {
      map[keyOf(u)] = u;
    }
    return List<T>.unmodifiable(map.values);
  }

  @override
  Future<Result<AudioTakeEntity>> promoteAndCommitRecordedTake({
    required RecordingCaptureReceipt receipt,
    required ProjectId projectId,
    required PartId partId,
    required Tick alignedStartTick,
    required int calibrationOffsetFrames,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Result<List<AudioTakeEntity>>> realignAudioTakesCalibration({
    required ProjectId projectId,
    required List<AudioTakeRealignmentUpdate> updates,
  }) async => const Ok(<AudioTakeEntity>[]);

  @override
  Future<Result<void>> softDeleteProject(
    ProjectId projectId, {
    required int deletedAtMs,
  }) async => const Ok(null);

  @override
  Future<Result<ProjectSummary>> updateProjectMetadata(
    UpdateProjectMetadataInput input,
  ) async {
    throw UnimplementedError();
  }
}

typedef AuditionLogEntry = ({
  PartId partId,
  int pitchMidi,
  int velocity,
  bool isNoteOn,
});

final class _FakePlaybackCoordinator implements ILookaheadPlaybackCoordinator {
  final StreamController<MuseError> _errors =
      StreamController<MuseError>.broadcast();
  final List<AuditionLogEntry> auditionCalls = <AuditionLogEntry>[];
  Tick seekedTick = const Tick(0);
  bool loopEnabled = false;
  Tick loopStart = const Tick(0);
  Tick loopEnd = const Tick(0);

  @override
  bool get isAttached => true;

  @override
  bool get isPlaying => false;

  @override
  bool get isLoopEnabled => loopEnabled;

  @override
  ({Tick startTick, Tick endTick})? get loopTickRange =>
      (startTick: loopStart, endTick: loopEnd);

  @override
  SoundFontHandle? get preferredPercussionSoundFontHandle => null;

  @override
  Stream<MuseError> get asyncErrors => _errors.stream;

  @override
  Stream<PlaybackLoopStateSnapshot> get loopStateChanges =>
      const Stream<PlaybackLoopStateSnapshot>.empty();

  @override
  Stream<PlaybackPlayheadReanchorEvent> get playheadReanchored =>
      const Stream<PlaybackPlayheadReanchorEvent>.empty();

  @override
  Future<Result<void>> attachProject(ScoreWorkspaceState workspace) async =>
      const Ok(null);

  @override
  Future<Result<void>> setArmedRecordingPartSuppression(
    PartId? partId, {
    ScoreWorkspaceState? updatedWorkspace,
  }) async => const Ok(null);

  @override
  Future<Result<void>> refreshActiveTakeRegionsIfAttached(
    ProjectId projectId, {
    ScoreWorkspaceState? updatedWorkspace,
  }) async => const Ok(null);

  @override
  Result<void> restoreChannelPatches() => const Ok(null);

  @override
  Result<void> auditionNote({
    required PartId partId,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  }) {
    auditionCalls.add((
      partId: partId,
      pitchMidi: pitchMidi,
      velocity: velocity,
      isNoteOn: isNoteOn,
    ));
    return const Ok(null);
  }

  @override
  Future<void> detachProject() async {}

  @override
  Future<void> dispose() async {
    await _errors.close();
  }

  @override
  void notifyScoreMutatedInRange({
    required Tick affectedStartTick,
    required Tick affectedEndTick,
  }) {}

  @override
  Result<void> pause() => const Ok(null);

  @override
  Future<Result<void>> play() async => const Ok(null);

  @override
  Result<void> seekToTick(Tick targetTick) {
    seekedTick = targetTick;
    return const Ok(null);
  }

  @override
  Result<void> setLoopTickRange({
    required bool enabled,
    required Tick startTick,
    required Tick endTick,
  }) {
    loopEnabled = enabled;
    loopStart = startTick;
    loopEnd = endTick;
    return const Ok(null);
  }

  @override
  Result<void> stop() => const Ok(null);

  @override
  Future<Result<void>> unloadUnusedSoundFont(SoundFontId sfId) async =>
      const Ok(null);
}

final class _FakeRecordingCoordinator implements IRecordingSessionCoordinator {
  @override
  Result<void> setInputMonitorGain(double gainLinear) => const Ok(null);

  @override
  Future<Result<AudioTakeEntity>> stopAndCommitRecording() async {
    throw UnimplementedError();
  }

  @override
  Future<Result<List<AudioTakeEntity>>> realignProjectTakesForCalibration({
    required ProjectId projectId,
    required int newCalibrationOffsetFrames,
  }) async => const Ok(<AudioTakeEntity>[]);

  @override
  Future<Result<TakeId>> startRecordingOnPart({
    required PartId partId,
    required Tick countInStartTick,
    int? countInMeasuresOverride,
  }) async => const Ok(TakeId('take-rec'));
}

final class _FakeTelemetryBridge implements ITelemetryBridge {
  @override
  TelemetrySnapshot? get latestSnapshot => null;

  @override
  List<TelemetrySnapshot> drainTelemetry({
    int maxFrames = MuseConstants.maxTelemetryDrainFrames,
  }) => const <TelemetrySnapshot>[];
}

final class _FakeSynthEventBridge implements ISynthEventBridge {
  EpochId _epoch = const EpochId(1);

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
  }) => Ok(events.length);

  @override
  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  }) => const Ok(null);

  @override
  Result<void> setChannelMix({
    required int midiChannel,
    required double gainDb,
    required double pan,
  }) => const Ok(null);

  @override
  Result<void> silenceChannel(int midiChannel) => const Ok(null);

  @override
  Result<void> triggerLiveAuditionNote({
    required int midiChannel,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  }) => const Ok(null);
}

final class _SpyDualModelScoreService implements IDualModelScoreService {
  final DualModelScoreService _inner = DualModelScoreService();
  final List<
    ({
      PartId partId,
      Tick startTick,
      Tick endTick,
      int minPitchMidi,
      int maxPitchMidi,
      PlaybackTimingMode timingMode,
      int returnedCount,
    })
  >
  viewportQueries = [];

  @override
  Result<ScoreWorkspaceState> buildWorkspaceState(
    ProjectWorkspaceAggregate aggregate,
  ) => _inner.buildWorkspaceState(aggregate);

  @override
  Result<ScoreWorkspaceState> applyMutationToDualModel(
    ScoreWorkspaceState currentState,
    ScoreMutationBatch mutation,
  ) => _inner.applyMutationToDualModel(currentState, mutation);

  @override
  Result<List<int>> exportToMusicXmlBytes({
    required ProjectWorkspaceAggregate aggregate,
    required bool compressAsMxl,
  }) => _inner.exportToMusicXmlBytes(
    aggregate: aggregate,
    compressAsMxl: compressAsMxl,
  );

  @override
  Result<ProjectWorkspaceAggregate> importFromMusicXmlBytes({
    required List<int> bytes,
    required bool isCompressedMxl,
    required String fallbackTitle,
    SoundFontId? defaultSoundFontId,
  }) => _inner.importFromMusicXmlBytes(
    bytes: bytes,
    isCompressedMxl: isCompressedMxl,
    fallbackTitle: fallbackTitle,
    defaultSoundFontId: defaultSoundFontId,
  );

  @override
  List<TimelineNote> queryNotesInViewport({
    required ScoreWorkspaceState state,
    required PartId partId,
    required Tick startTick,
    required Tick endTick,
    required int minPitchMidi,
    required int maxPitchMidi,
    required PlaybackTimingMode timingMode,
  }) {
    final result = _inner.queryNotesInViewport(
      state: state,
      partId: partId,
      startTick: startTick,
      endTick: endTick,
      minPitchMidi: minPitchMidi,
      maxPitchMidi: maxPitchMidi,
      timingMode: timingMode,
    );
    viewportQueries.add((
      partId: partId,
      startTick: startTick,
      endTick: endTick,
      minPitchMidi: minPitchMidi,
      maxPitchMidi: maxPitchMidi,
      timingMode: timingMode,
      returnedCount: result.length,
    ));
    return result;
  }
}

ProjectWorkspaceAggregate _buildTestAggregate({
  List<TimelineNote> notes = const <TimelineNote>[],
  List<TempoEventEntity>? tempoEvents,
  List<TimeSignatureEventEntity>? timeSignatureEvents,
  List<KeySignatureEventEntity>? keySignatureEvents,
  List<ClefEventEntity>? clefEvents,
  List<AudioTakeEntity> audioTakes = const <AudioTakeEntity>[],
  int gridSnapTicks = MuseConstants.sixteenthNoteTicks,
}) {
  const projectId = ProjectId('proj-1');
  const partId = PartId('part-1');
  const sfId = SoundFontId('sf-1');
  return ProjectWorkspaceAggregate(
    project: ProjectSummary(
      projectId: projectId,
      title: 'Test Score',
      ppqn: MuseConstants.ppqn,
      gridSnapTicks: gridSnapTicks,
      pickupTicks: 0,
      playbackTimingMode: PlaybackTimingMode.quantized,
      revision: 1,
      createdAtMs: 1000,
      updatedAtMs: 1000,
    ),
    parts: const <ProjectPartEntity>[
      ProjectPartEntity(
        partId: partId,
        projectId: projectId,
        musicXmlPartId: 'P1',
        sortOrder: 0,
        name: 'Piano',
        stavesCount: 1,
        midiChannel: 0,
        sfId: sfId,
        bankNum: 0,
        programNum: 0,
        gainDb: 0.0,
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
            tempoEventId: TempoEventId('tempo-0'),
            projectId: projectId,
            tick: Tick(0),
            usPerQuarter: 500000,
            updatedAtMs: 1000,
          ),
        ],
    timeSignatureEvents:
        timeSignatureEvents ??
        const <TimeSignatureEventEntity>[
          TimeSignatureEventEntity(
            tsEventId: TimeSigEventId('ts-0'),
            projectId: projectId,
            tick: Tick(0),
            numerator: 4,
            denominator: 4,
            updatedAtMs: 1000,
          ),
        ],
    keySignatureEvents:
        keySignatureEvents ??
        const <KeySignatureEventEntity>[
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
    clefEvents:
        clefEvents ??
        const <ClefEventEntity>[
          ClefEventEntity(
            clefEventId: ClefEventId('clef-0'),
            projectId: projectId,
            partId: partId,
            staffNumber: 1,
            tick: Tick(0),
            sign: ClefSign.G,
            line: 2,
            octaveChange: 0,
            updatedAtMs: 1000,
          ),
        ],
    notes: notes,
    spanners: const <NoteSpannerEntity>[],
    audioTakes: audioTakes,
  );
}

TimelineNote _makeNote({
  required String id,
  required int startTick,
  required int durationTicks,
  required int pitchMidi,
  int voiceNumber = 1,
  EnharmonicStep step = EnharmonicStep.C,
  int alter = 0,
  int velocity = 96,
}) => TimelineNote(
  noteId: NoteId(id),
  projectId: const ProjectId('proj-1'),
  partId: const PartId('part-1'),
  staffNumber: 1,
  voiceNumber: voiceNumber,
  pitchMidi: pitchMidi,
  enharmonicStep: step,
  enharmonicAlter: alter,
  rawStartTick: Tick(startTick),
  rawDurationTicks: durationTicks,
  quantizedStartTick: Tick(startTick),
  quantizedDurationTicks: durationTicks,
  velocity: velocity,
  updatedAtMs: 1000,
);

final class _ManualTicker extends Ticker {
  _ManualTicker(super.onTick);

  @override
  TickerFuture start() => TickerFuture.complete();

  @override
  void stop({bool canceled = false}) {}
}

Future<void> _ensureBravuraLoaded(WidgetTester tester) async {
  if (MusicFonts.metadataOrNull(
        MusePresentationConstants.defaultNotationTheme.musicFont,
      ) !=
      null) {
    return;
  }
  await tester.runAsync(
    () => MusicFonts.load(
      MusePresentationConstants.defaultNotationTheme.musicFont,
    ),
  );
}

Future<
  ({
    _InMemoryProjectRepo repo,
    _SpyDualModelScoreService scoreService,
    _FakeAudioSessionController audioSession,
    _FakePlaybackCoordinator playback,
    WorkspaceShellController shell,
    TransportAndTelemetryController transport,
    StaffNotationViewController staffCtrl,
    PianoRollViewportController pianoCtrl,
  })
>
_createHarness({
  required ProjectWorkspaceAggregate aggregate,
  AuditionReleaseDelay? auditionReleaseDelay,
}) async {
  final repo = _InMemoryProjectRepo()..seed(aggregate);
  final scoreService = _SpyDualModelScoreService();
  final audioSession = _FakeAudioSessionController();
  final playback = _FakePlaybackCoordinator();
  var seq = 0;
  String nextUuid() => 'id-${++seq}';
  var clock = 5000;
  int nextClock() => ++clock;

  final shell = WorkspaceShellController(
    projectRepository: repo,
    dualModelScoreService: scoreService,
    playbackCoordinator: playback,
    audioSessionController: audioSession,
    uuidV7Generator: nextUuid,
    nowEpochMs: nextClock,
  );

  final transport = TransportAndTelemetryController(
    workspaceShellController: shell,
    audioSessionController: audioSession,
    playbackCoordinator: playback,
    recordingCoordinator: _FakeRecordingCoordinator(),
    synthEventBridge: _FakeSynthEventBridge(),
    telemetryBridge: _FakeTelemetryBridge(),
    tickerFactory: (onTick) => _ManualTicker(onTick),
  );

  await shell.openProject(aggregate.project.projectId);

  final staffCtrl = StaffNotationViewController(
    workspaceShellController: shell,
    playbackCoordinator: playback,
    uuidV7Generator: nextUuid,
    nowEpochMs: nextClock,
    auditionReleaseDelay: auditionReleaseDelay,
  );
  final pianoCtrl = PianoRollViewportController(
    workspaceShellController: shell,
    dualModelScoreService: scoreService,
    playbackCoordinator: playback,
    uuidV7Generator: nextUuid,
    nowEpochMs: nextClock,
  );

  return (
    repo: repo,
    scoreService: scoreService,
    audioSession: audioSession,
    playback: playback,
    shell: shell,
    transport: transport,
    staffCtrl: staffCtrl,
    pianoCtrl: pianoCtrl,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '1. Multi-voice detection sets hasMultiVoiceMeasures and gridAlign false',
    (tester) async {
      await _ensureBravuraLoaded(tester);
      final harness = await _createHarness(
        aggregate: _buildTestAggregate(
          notes: <TimelineNote>[
            _makeNote(
              id: 'v1-n1',
              startTick: 0,
              durationTicks: MuseConstants.quarterNoteTicks,
              pitchMidi: 60,
              voiceNumber: 1,
            ),
          ],
        ),
        auditionReleaseDelay: (_) async {},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StaffNotationPanel(
              controller: harness.staffCtrl,
              workspaceController: harness.shell,
              transportController: harness.transport,
            ),
          ),
        ),
      );

      expect(harness.staffCtrl.hasMultiVoiceMeasures, isFalse);
      final singleVoiceView = tester.widget<StaffSystemView>(
        find.byType(StaffSystemView),
      );
      expect(singleVoiceView.gridAlign, isTrue);

      harness.staffCtrl.setActiveVoiceNumber(2);
      await harness.staffCtrl.insertNoteAtCursor(pitchMidi: 64);
      await tester.pump();

      expect(harness.staffCtrl.hasMultiVoiceMeasures, isTrue);
      final multiVoiceView = tester.widget<StaffSystemView>(
        find.byType(StaffSystemView),
      );
      expect(multiVoiceView.gridAlign, isFalse);

      harness.pianoCtrl.dispose();
      harness.staffCtrl.dispose();
      harness.transport.dispose();
      harness.shell.dispose();
      harness.audioSession.dispose();
    },
  );

  test(
    '2. Chord bucket & __cont_ continuation IDs resolve to canonical NoteIds, highlight siblings, and audition',
    () async {
      final chordLow = _makeNote(
        id: 'a-c4',
        startTick: 0,
        durationTicks: MuseConstants.quarterNoteTicks,
        pitchMidi: 60,
      );
      final chordHigh = _makeNote(
        id: 'b-e4',
        startTick: 0,
        durationTicks: MuseConstants.quarterNoteTicks,
        pitchMidi: 64,
        step: EnharmonicStep.E,
      );
      final tiedAcrossBar = _makeNote(
        id: 'cross-bar',
        startTick: 3360,
        durationTicks: 960,
        pitchMidi: 67,
        step: EnharmonicStep.G,
      );

      final harness = await _createHarness(
        aggregate: _buildTestAggregate(
          notes: <TimelineNote>[chordHigh, chordLow, tiedAcrossBar],
        ),
        auditionReleaseDelay: (_) async {},
      );

      final contId =
          '${tiedAcrossBar.noteId.value}${CrispScoreMapperConstants.continuationIdDelimiter}1_0';
      await harness.staffCtrl.onCrispElementTapped(contId);

      expect(harness.staffCtrl.cursorTick, const Tick(3360));
      expect(harness.staffCtrl.selectedNoteIds, contains(tiedAcrossBar.noteId));
      expect(
        harness.staffCtrl.highlightedCrispElementIds,
        containsAll(<String>{'cross-bar', contId}),
      );
      expect(harness.playback.auditionCalls.length, 2);
      expect(harness.playback.auditionCalls.first.pitchMidi, 67);
      expect(harness.playback.auditionCalls.first.isNoteOn, isTrue);
      expect(harness.playback.auditionCalls.last.isNoteOn, isFalse);
      expect(
        harness.playback.auditionCalls.last.velocity,
        LookaheadPlaybackConstants.noteOffReleaseVelocity,
      );

      // Chord select resolves all chord siblings cleanly from anchorId.
      harness.staffCtrl.setChordSelectMode(true);
      await harness.staffCtrl.onCrispElementTapped('a-c4');
      expect(
        harness.staffCtrl.selectedNoteIds,
        containsAll(<NoteId>{chordLow.noteId, chordHigh.noteId}),
      );
      expect(
        harness.staffCtrl.highlightedCrispElementIds,
        containsAll(<String>{'a-c4', 'b-e4'}),
      );

      harness.pianoCtrl.dispose();
      harness.staffCtrl.dispose();
      harness.transport.dispose();
      harness.shell.dispose();
      harness.audioSession.dispose();
    },
  );

  testWidgets(
    '3. Empty-bar hit-testing, Pitch.fromMidi transposition, and Measure & Score Events delete/tick-0 guard',
    (tester) async {
      await _ensureBravuraLoaded(tester);
      final harness = await _createHarness(
        aggregate: _buildTestAggregate(
          notes: <TimelineNote>[
            _makeNote(
              id: 'm1-c4',
              startTick: 0,
              durationTicks: MuseConstants.quarterNoteTicks,
              pitchMidi: 60,
            ),
            _makeNote(
              id: 'm2-g4',
              startTick: 3840,
              durationTicks: MuseConstants.quarterNoteTicks,
              pitchMidi: 67,
              step: EnharmonicStep.G,
            ),
          ],
          tempoEvents: const <TempoEventEntity>[
            TempoEventEntity(
              tempoEventId: TempoEventId('t0'),
              projectId: ProjectId('proj-1'),
              tick: Tick(0),
              usPerQuarter: 500000,
              updatedAtMs: 1000,
            ),
            TempoEventEntity(
              tempoEventId: TempoEventId('t3840'),
              projectId: ProjectId('proj-1'),
              tick: Tick(3840),
              usPerQuarter: 400000,
              updatedAtMs: 1000,
            ),
          ],
        ),
        auditionReleaseDelay: (_) async {},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StaffNotationPanel(
              controller: harness.staffCtrl,
              workspaceController: harness.shell,
              transportController: harness.transport,
            ),
          ),
        ),
      );

      final layout = harness.staffCtrl.cachedLayout!;
      expect(layout.staves.first.measureRegions.length, greaterThanOrEqualTo(2));
      final m2Region = layout.staves.first.measureRegions[1];
      final staffSpace =
          NotationViewConstants.baseStaffSpacePx * harness.staffCtrl.zoomScale;
      final tapX =
          (RenderStaffSystemView.leftInset +
              (m2Region.startX + m2Region.endX) / 2.0) *
          staffSpace;
      final tapY = (layout.staffTop(0) - layout.top + 2.0) * staffSpace;

      harness.staffCtrl.onStaffCanvasTapped(Offset(tapX, tapY));
      expect(harness.staffCtrl.cursorTick.value, greaterThanOrEqualTo(3840));
      expect(harness.staffCtrl.cursorTick.value, lessThan(7680));

      // Chromatic transposition via Pitch.fromMidi.
      await harness.staffCtrl.onCrispElementTapped('m1-c4');
      await harness.staffCtrl.transposeSelectedNotesChromatic(1);
      final transposed = harness.staffCtrl.activeWorkspace!.aggregate.notes
          .firstWhere((n) => n.noteId == const NoteId('m1-c4'));
      expect(transposed.pitchMidi, 61);
      expect(transposed.enharmonicStep, EnharmonicStep.C);
      expect(transposed.enharmonicAlter, 1);

      // Respelling 61 as Db matches, while natural on 61 fails closed.
      final flatRes = await harness.staffCtrl.respellSelectedWithPreferredAlter(
        -1,
      );
      expect(flatRes.isOk, isTrue);
      final respelled = harness.staffCtrl.activeWorkspace!.aggregate.notes
          .firstWhere((n) => n.noteId == const NoteId('m1-c4'));
      expect(respelled.enharmonicStep, EnharmonicStep.D);
      expect(respelled.enharmonicAlter, -1);

      final natRes = await harness.staffCtrl.respellSelectedWithPreferredAlter(
        0,
      );
      expect(natRes.isErr, isTrue);
      expect(
        (natRes as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      // Measure & Score Events inspector deletes tick 3840 tempo event.
      await tester.pump();
      await tester.tap(find.byKey(const Key('delete_tempo_t3840')));
      await tester.pumpAndSettle();
      expect(
        harness.staffCtrl.activeWorkspace!.aggregate.tempoEvents
            .any((t) => t.tempoEventId == const TempoEventId('t3840')),
        isFalse,
      );

      // Protected tick-0 event fails closed with protectedInitialMapEvent.
      final delTick0Res = await harness.staffCtrl.removeTempoEvent(
        const TempoEventId('t0'),
      );
      expect(delTick0Res.isErr, isTrue);
      expect(
        (delTick0Res as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.protectedInitialMapEvent,
      );

      harness.pianoCtrl.dispose();
      harness.staffCtrl.dispose();
      harness.transport.dispose();
      harness.shell.dispose();
      harness.audioSession.dispose();
    },
  );

  testWidgets(
    '4. StaffNotationPanel fails closed with error card when Bravura metadata is unloaded',
    (tester) async {
      MusicFonts.debugReset();
      final harness = await _createHarness(aggregate: _buildTestAggregate());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StaffNotationPanel(
              controller: harness.staffCtrl,
              workspaceController: harness.shell,
              transportController: harness.transport,
            ),
          ),
        ),
      );

      expect(
        find.byKey(const Key('notation_font_missing_error_card')),
        findsOneWidget,
      );
      expect(find.byType(StaffSystemView), findsNothing);

      harness.pianoCtrl.dispose();
      harness.staffCtrl.dispose();
      harness.transport.dispose();
      harness.shell.dispose();
      harness.audioSession.dispose();
    },
  );

  test(
    '5. PianoRollViewportController dynamic LOD classifies straight vs triplet via exact set membership & syncs snap on Undo/Redo',
    () async {
      final harness = await _createHarness(
        aggregate: _buildTestAggregate(
          gridSnapTicks: MuseConstants.quarterNoteTicks,
        ),
      );

      expect(
        harness.pianoCtrl.selectedSnapTicks,
        MuseConstants.quarterNoteTicks,
      );

      // Zoom out tightly so 240/480 must step along straight ladder only (never 320/640!).
      harness.pianoCtrl.setPixelsPerTick(0.02);
      harness.pianoCtrl.setSelectedSnapTicksLocal(MuseConstants.eighthNoteTicks);
      expect(harness.pianoCtrl.computeEffectiveGridSubdivisionTicks(), 960);

      harness.pianoCtrl.setSelectedSnapTicksLocal(
        MuseConstants.quarterNoteTicks,
      );
      expect(harness.pianoCtrl.computeEffectiveGridSubdivisionTicks(), 960);

      harness.pianoCtrl.setSelectedSnapTicksLocal(
        MuseConstants.tripletSixteenthNoteTicks,
      );
      expect(
        harness.pianoCtrl.computeEffectiveGridSubdivisionTicks(),
        MuseConstants.tripletHalfNoteTicks,
      );

      harness.pianoCtrl.setSelectedSnapTicksLocal(
        MuseConstants.tripletEighthNoteTicks,
      );
      expect(
        harness.pianoCtrl.computeEffectiveGridSubdivisionTicks(),
        MuseConstants.tripletHalfNoteTicks,
      );

      // Reactive snap synchronization on UpdateProjectSettingsCommand + Undo/Redo.
      await harness.pianoCtrl.updateProjectSnapTicks(
        MuseConstants.dottedQuarterNoteTicks,
      );
      expect(
        harness.pianoCtrl.selectedSnapTicks,
        MuseConstants.dottedQuarterNoteTicks,
      );

      await harness.shell.undo();
      expect(
        harness.pianoCtrl.selectedSnapTicks,
        MuseConstants.quarterNoteTicks,
      );

      await harness.shell.redo();
      expect(
        harness.pianoCtrl.selectedSnapTicks,
        MuseConstants.dottedQuarterNoteTicks,
      );

      harness.pianoCtrl.dispose();
      harness.staffCtrl.dispose();
      harness.transport.dispose();
      harness.shell.dispose();
      harness.audioSession.dispose();
    },
  );

  test(
    '6. Viewport culling queries only [visibleStart, visibleEnd] & pitch range out of >=2000 notes and computes multi-tempo take span',
    () async {
      final notes = <TimelineNote>[
        for (var i = 0; i < 2200; i++)
          _makeNote(
            id: 'bulk-$i',
            startTick: i * 240,
            durationTicks: 180,
            pitchMidi: 24 + (i % 84),
          ),
      ];
      // Multi-tempo: 120 BPM (500,000 us/qtr) @ tick 0 -> 60 BPM (1,000,000 us/qtr) @ tick 1920.
      // 48,000 frames @ 48 kHz = 1.0s covers tick 0..1920.
      // Remaining 72,000 frames (1.5s @ 60 BPM) = 1.5 beats = 1440 ticks -> end tick 3360!
      const take = AudioTakeEntity(
        takeId: TakeId('take-1'),
        projectId: ProjectId('proj-1'),
        partId: PartId('part-1'),
        blobSha256: Sha256Digest('abc'),
        startTick: Tick(0),
        sampleRate: 48000,
        channelCount: 1,
        durationFrames: 120000,
        capturedPlayheadFrame: SampleFrame(0),
        capturedSampleClock: SampleFrame(0),
        outputBufferFrames: 256,
        inputBufferFrames: 256,
        calibrationOffsetFrames: 0,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      );

      final harness = await _createHarness(
        aggregate: _buildTestAggregate(
          notes: notes,
          tempoEvents: const <TempoEventEntity>[
            TempoEventEntity(
              tempoEventId: TempoEventId('t0'),
              projectId: ProjectId('proj-1'),
              tick: Tick(0),
              usPerQuarter: 500000,
              updatedAtMs: 1000,
            ),
            TempoEventEntity(
              tempoEventId: TempoEventId('t1920'),
              projectId: ProjectId('proj-1'),
              tick: Tick(1920),
              usPerQuarter: 1000000,
              updatedAtMs: 1000,
            ),
          ],
          audioTakes: const <AudioTakeEntity>[take],
        ),
      );

      harness.scoreService.viewportQueries.clear();
      harness.pianoCtrl.setPixelsPerTick(0.1);
      harness.pianoCtrl.setRowHeightPx(18.0);
      harness.pianoCtrl.updateViewportGeometry(
        scrollXpx: 1000.0, // tick 10,000
        scrollYpx: (127 - 72) * 18.0, // max pitch 72
        viewportWidthPx: 400.0, // +4,000 ticks -> 14,000
        viewportHeightPx: 180.0, // -10 rows -> min pitch 62
      );

      final slice = harness.pianoCtrl.computeVisibleSlice();
      expect(slice.visibleStartTick, const Tick(10000));
      expect(slice.visibleEndTick, const Tick(14000));
      expect(slice.visibleMinPitchMidi, 62);
      expect(slice.visibleMaxPitchMidi, 72);
      expect(slice.visibleNotes.length, lessThan(20));
      expect(harness.scoreService.viewportQueries, hasLength(1));
      expect(
        harness.scoreService.viewportQueries.single.startTick,
        const Tick(10000),
      );
      expect(
        harness.scoreService.viewportQueries.single.endTick,
        const Tick(14000),
      );
      expect(slice.takeStartTick, const Tick(0));
      expect(slice.takeDurationTicks, const Tick(3360));

      harness.pianoCtrl.dispose();
      harness.staffCtrl.dispose();
      harness.transport.dispose();
      harness.shell.dispose();
      harness.audioSession.dispose();
    },
  );

  testWidgets(
    '7. Draw/move/resize/erase/velocity gestures emit exact L4 commands only on release and normalize reversed loop drags',
    (tester) async {
      final harness = await _createHarness(
        aggregate: _buildTestAggregate(
          gridSnapTicks: MuseConstants.quarterNoteTicks,
        ),
      );
      harness.pianoCtrl.setPixelsPerTick(0.1);
      harness.pianoCtrl.setRowHeightPx(20.0);
      harness.pianoCtrl.updateViewportGeometry(
        scrollXpx: 0.0,
        scrollYpx: (127 - 70) * 20.0,
        viewportWidthPx: 800.0,
        viewportHeightPx: 400.0,
      );

      final baseCommits = harness.repo.commitCalls;

      // Draw C4 (pitch 60 -> y = (70 - 60) * 20 + 5 = 205) from tick 960 (x=96) to 1920 (x=192).
      harness.pianoCtrl.setToolMode(PianoRollToolMode.draw);
      harness.pianoCtrl.onCanvasPointerDown(const Offset(96.0, 205.0));
      expect(harness.repo.commitCalls, baseCommits);
      expect(harness.playback.auditionCalls.last.isNoteOn, isTrue);

      harness.pianoCtrl.onCanvasPointerMove(const Offset(192.0, 205.0));
      expect(harness.repo.commitCalls, baseCommits);

      await harness.pianoCtrl.onCanvasPointerUp();
      expect(harness.repo.commitCalls, baseCommits + 1);
      expect(harness.playback.auditionCalls.last.isNoteOn, isFalse);

      final inserted = harness.pianoCtrl.activeWorkspace!.aggregate.notes.single;
      expect(inserted.pitchMidi, 60);
      expect(inserted.quantizedStartTick, const Tick(960));
      expect(inserted.quantizedDurationTicks, 960);
      expect(inserted.rawStartTick, const Tick(960));
      expect(inserted.rawDurationTicks, 960);

      // Select + move up 2 rows (pitch 62) & right +480 ticks (dx +48 -> quantized +960 at 1/4 snap).
      harness.pianoCtrl.setToolMode(PianoRollToolMode.select);
      harness.pianoCtrl.onCanvasPointerDown(const Offset(110.0, 205.0));
      harness.pianoCtrl.onCanvasPointerMove(const Offset(158.0, 165.0));
      await harness.pianoCtrl.onCanvasPointerUp();

      final moved = harness.pianoCtrl.activeWorkspace!.aggregate.notes.single;
      expect(moved.pitchMidi, 62);
      expect(moved.enharmonicStep, EnharmonicStep.D);
      expect(moved.quantizedStartTick, const Tick(1920));
      expect(moved.rawDurationTicks, greaterThan(0));
      expect(moved.quantizedDurationTicks, greaterThan(0));

      // Trailing-edge resize: right edge is at (1920 + 960) * 0.1 = 288.0, top is (70-62)*20 = 160.
      harness.pianoCtrl.onCanvasPointerDown(const Offset(285.0, 165.0));
      harness.pianoCtrl.onCanvasPointerMove(const Offset(384.0, 165.0));
      await harness.pianoCtrl.onCanvasPointerUp();
      final resized = harness.pianoCtrl.activeWorkspace!.aggregate.notes.single;
      expect(resized.quantizedDurationTicks, 1920);
      expect(resized.rawDurationTicks, 1920);

      // Velocity update clamps and commits UpdateNotesCommand.
      await harness.pianoCtrl.updateNotesVelocity(
        noteId: resized.noteId,
        velocity: 115,
      );
      expect(
        harness.pianoCtrl.activeWorkspace!.aggregate.notes.single.velocity,
        115,
      );

      // Reversed loop drag on PianoRollRulerHeader normalizes endTick > startTick.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PianoRollPanel(
              controller: harness.pianoCtrl,
              workspaceController: harness.shell,
              transportController: harness.transport,
            ),
          ),
        ),
      );
      final loopToggle = find.byKey(const Key('piano_roll_loop_drag_toggle'));
      await tester.ensureVisible(loopToggle);
      await tester.tap(loopToggle);
      await tester.pump();

      final rulerBox = tester.getRect(
        find.byKey(const Key('piano_roll_ruler_header')),
      );
      final gesture = await tester.startGesture(
        Offset(rulerBox.left + 384.0, rulerBox.center.dy),
      );
      await gesture.moveTo(Offset(rulerBox.left + 96.0, rulerBox.center.dy));
      await gesture.up();
      await tester.pump();

      expect(harness.playback.loopEnabled, isTrue);
      expect(harness.playback.loopStart, const Tick(960));
      expect(harness.playback.loopEnd, const Tick(3840));
      expect(
        harness.playback.loopEnd.value,
        greaterThan(harness.playback.loopStart.value),
      );

      // Erase mode click deletes the note cleanly (note starts at 1920 -> x=192, y=165).
      harness.pianoCtrl.setToolMode(PianoRollToolMode.erase);
      harness.pianoCtrl.onCanvasPointerDown(const Offset(210.0, 165.0));
      await tester.pump();
      expect(harness.pianoCtrl.activeWorkspace!.aggregate.notes, isEmpty);

      harness.pianoCtrl.dispose();
      harness.staffCtrl.dispose();
      harness.transport.dispose();
      harness.shell.dispose();
      harness.audioSession.dispose();
    },
  );

  testWidgets(
    '8. Advancing playheadTick repaints StaffPlayheadAndCaretPainter and PianoRollPlayheadPainter without relayouting StaffSystemView or repainting PianoRollGridPainter',
    (tester) async {
      await _ensureBravuraLoaded(tester);
      final harness = await _createHarness(
        aggregate: _buildTestAggregate(
          notes: <TimelineNote>[
            _makeNote(
              id: 'p1',
              startTick: 0,
              durationTicks: 1920,
              pitchMidi: 60,
            ),
          ],
        ),
      );

      var staffOverlayPaints = 0;
      var pianoGridPaints = 0;
      var pianoPlayheadPaints = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                Expanded(
                  child: StaffNotationPanel(
                    controller: harness.staffCtrl,
                    workspaceController: harness.shell,
                    transportController: harness.transport,
                    onPlayheadPaintForTest: () => staffOverlayPaints += 1,
                  ),
                ),
                Expanded(
                  child: PianoRollPanel(
                    controller: harness.pianoCtrl,
                    workspaceController: harness.shell,
                    transportController: harness.transport,
                    onGridPaintForTest: () => pianoGridPaints += 1,
                    onPlayheadPaintForTest: () => pianoPlayheadPaints += 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final initialCachedLayout = harness.staffCtrl.cachedLayout;
      final renderStaffSystem = tester.renderObject<RenderStaffSystemView>(
        find.byType(StaffSystemView),
      );
      final initialSystemLayout = renderStaffSystem.systemLayout;
      final initialGridPaints = pianoGridPaints;
      final initialStaffOverlayPaints = staffOverlayPaints;
      final initialPianoPlayheadPaints = pianoPlayheadPaints;

      harness.transport.playheadTick.value = const Tick(960);
      await tester.pump();
      harness.transport.playheadTick.value = const Tick(1440);
      await tester.pump();

      expect(staffOverlayPaints, greaterThan(initialStaffOverlayPaints));
      expect(pianoPlayheadPaints, greaterThan(initialPianoPlayheadPaints));
      expect(pianoGridPaints, equals(initialGridPaints));
      expect(identical(harness.staffCtrl.cachedLayout, initialCachedLayout), isTrue);
      expect(
        identical(renderStaffSystem.systemLayout, initialSystemLayout),
        isTrue,
      );
      expect(find.textContaining('Bar 1 : Beat 2'), findsOneWidget);

      harness.pianoCtrl.dispose();
      harness.staffCtrl.dispose();
      harness.transport.dispose();
      harness.shell.dispose();
      harness.audioSession.dispose();
    },
  );

  test(
    '9. PianoRollViewportController clamps scroll offsets to canvas bounds on pan, scrollTo, and zoom-out',
    () async {
      final harness = await _createHarness(aggregate: _buildTestAggregate());
      addTearDown(() {
        harness.pianoCtrl.dispose();
        harness.staffCtrl.dispose();
        harness.transport.dispose();
        harness.shell.dispose();
        harness.audioSession.dispose();
      });

      harness.pianoCtrl.updateViewportGeometry(
        viewportWidthPx: 400.0,
        viewportHeightPx: 300.0,
      );
      final maxX = harness.pianoCtrl.maxScrollXpx;
      final maxY = harness.pianoCtrl.maxScrollYpx;
      expect(maxX, greaterThan(0.0));
      expect(maxY, greaterThan(0.0));

      harness.pianoCtrl.scrollTo(scrollXpx: maxX + 5000.0, scrollYpx: maxY + 5000.0);
      expect(harness.pianoCtrl.scrollXpx, equals(maxX));
      expect(harness.pianoCtrl.scrollYpx, equals(maxY));

      harness.pianoCtrl.panBy(dxPx: -999999.0, dyPx: -999999.0);
      expect(harness.pianoCtrl.scrollXpx, equals(0.0));
      expect(harness.pianoCtrl.scrollYpx, equals(0.0));

      // Zooming out from max scroll clamps offsets to the new smaller bounds.
      harness.pianoCtrl.setPixelsPerTick(PianoRollLayoutConstants.maxPixelsPerTick);
      harness.pianoCtrl.setRowHeightPx(PianoRollLayoutConstants.maxRowHeightPx);
      harness.pianoCtrl.scrollTo(
        scrollXpx: harness.pianoCtrl.maxScrollXpx,
        scrollYpx: harness.pianoCtrl.maxScrollYpx,
      );
      harness.pianoCtrl.setPixelsPerTick(PianoRollLayoutConstants.minPixelsPerTick);
      harness.pianoCtrl.setRowHeightPx(PianoRollLayoutConstants.minRowHeightPx);
      expect(harness.pianoCtrl.scrollXpx, lessThanOrEqualTo(harness.pianoCtrl.maxScrollXpx));
      expect(harness.pianoCtrl.scrollYpx, lessThanOrEqualTo(harness.pianoCtrl.maxScrollYpx));
    },
  );

  testWidgets(
    '10. PianoRollPanel centers C4, pans via Pan tool, middle-mouse, wheel, trackpad & scrollbars without SingleChildScrollView occlusion, and clips painters',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = await _createHarness(aggregate: _buildTestAggregate());
      addTearDown(() {
        harness.pianoCtrl.dispose();
        harness.staffCtrl.dispose();
        harness.transport.dispose();
        harness.shell.dispose();
        harness.audioSession.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PianoRollPanel(
              controller: harness.pianoCtrl,
              workspaceController: harness.shell,
              transportController: harness.transport,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Only the top toolbar retains a SingleChildScrollView; all 6 viewport/gutter scrollers are gone.
      expect(find.byType(SingleChildScrollView), findsOneWidget);

      // Every painter surface is clipped with ClipRect.
      for (final key in const <Key>[
        Key('piano_roll_ruler_header'),
        Key('piano_key_gutter'),
        Key('piano_roll_grid_canvas'),
        Key('piano_roll_velocity_lane'),
      ]) {
        expect(
          find.descendant(of: find.byKey(key), matching: find.byType(ClipRect)),
          findsOneWidget,
        );
      }
      for (final key in const <Key>[
        Key('piano_roll_take_strip'),
        Key('piano_roll_playhead_overlay'),
      ]) {
        expect(
          find.ancestor(of: find.byKey(key), matching: find.byType(ClipRect)),
          findsOneWidget,
        );
      }

      // Initial layout centers vertically around C4 (MIDI 60).
      expect(harness.pianoCtrl.hasInitializedScrollY, isTrue);
      expect(
        harness.pianoCtrl.visibleMinPitchMidi,
        lessThanOrEqualTo(PianoRollLayoutConstants.initialScrollCenterPitchMidi),
      );
      expect(
        harness.pianoCtrl.visibleMaxPitchMidi,
        greaterThanOrEqualTo(
          PianoRollLayoutConstants.initialScrollCenterPitchMidi,
        ),
      );
      final initialCenterScrollY = harness.pianoCtrl.scrollYpx;

      // Scroll via mouse wheel over grid canvas (vertical & horizontal delta).
      final canvasCenter = tester.getCenter(
        find.byKey(const Key('piano_roll_grid_canvas')),
      );
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: canvasCenter,
          scrollDelta: const Offset(120.0, -90.0),
        ),
      );
      await tester.pump();
      expect(harness.pianoCtrl.scrollXpx, closeTo(120.0, 0.01));
      expect(
        harness.pianoCtrl.scrollYpx,
        closeTo(initialCenterScrollY - 90.0, 0.01),
      );

      // Trackpad two-finger pan updates both axes smoothly.
      tester.binding.handlePointerEvent(
        PointerPanZoomStartEvent(position: canvasCenter, pointer: 42),
      );
      tester.binding.handlePointerEvent(
        PointerPanZoomUpdateEvent(
          position: canvasCenter,
          pointer: 42,
          pan: const Offset(-40.0, -30.0),
          panDelta: const Offset(-40.0, -30.0),
        ),
      );
      tester.binding.handlePointerEvent(
        PointerPanZoomEndEvent(position: canvasCenter, pointer: 42),
      );
      await tester.pump();
      expect(harness.pianoCtrl.scrollXpx, closeTo(160.0, 0.01));
      expect(
        harness.pianoCtrl.scrollYpx,
        closeTo(initialCenterScrollY - 60.0, 0.01),
      );

      // Middle-mouse drag pans in Select mode without committing commands or auditioning.
      final commitsBeforePan = harness.repo.commitCalls;
      final auditionsBeforePan = harness.playback.auditionCalls.length;
      final middleDrag = await tester.startGesture(
        canvasCenter,
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await middleDrag.moveBy(const Offset(-50.0, -40.0));
      await middleDrag.up();
      await tester.pump();
      expect(harness.pianoCtrl.scrollXpx, closeTo(210.0, 0.01));
      expect(
        harness.pianoCtrl.scrollYpx,
        closeTo(initialCenterScrollY - 20.0, 0.01),
      );
      expect(harness.repo.commitCalls, equals(commitsBeforePan));
      expect(harness.playback.auditionCalls.length, equals(auditionsBeforePan));

      // Pan tool segment pans on primary drag without modifying notes.
      await tester.tap(find.text('Pan'));
      await tester.pump();
      expect(harness.pianoCtrl.activeTool, PianoRollToolMode.pan);
      final toolDrag = await tester.startGesture(canvasCenter);
      await toolDrag.moveBy(const Offset(40.0, 30.0));
      await toolDrag.up();
      await tester.pump();
      expect(harness.pianoCtrl.scrollXpx, closeTo(170.0, 0.01));
      expect(
        harness.pianoCtrl.scrollYpx,
        closeTo(initialCenterScrollY - 50.0, 0.01),
      );

      // Clicking/dragging vertical & horizontal scrollbars updates controller offsets.
      final vBarRect = tester.getRect(
        find.byKey(const Key('piano_roll_vertical_scrollbar')),
      );
      final hBarRect = tester.getRect(
        find.byKey(const Key('piano_roll_horizontal_scrollbar')),
      );
      await tester.tapAt(Offset(vBarRect.center.dx, vBarRect.bottom - 10.0));
      await tester.pump();
      expect(harness.pianoCtrl.scrollYpx, greaterThan(initialCenterScrollY));

      await tester.tapAt(Offset(hBarRect.right - 20.0, hBarRect.center.dy));
      await tester.pump();
      expect(harness.pianoCtrl.scrollXpx, greaterThan(200.0));

      // Center C4 toolbar button restores vertical centering on MIDI 60.
      await tester.tap(find.byKey(const Key('piano_roll_center_c4')));
      await tester.pump();
      expect(harness.pianoCtrl.scrollYpx, closeTo(initialCenterScrollY, 0.01));
    },
  );
}

import 'dart:convert';

import 'package:crisp_notation_core/crisp_notation_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/domain/notation/crisp_score_mapper.dart';
import 'package:muse_grid/domain/notation/dual_model_score_service.dart';

const ProjectId _projectId = ProjectId('0193a8f0-0000-7000-8000-000000000010');
const PartId _part1Id = PartId('0193a8f0-0000-7000-8000-000000000101');
const PartId _part2Id = PartId('0193a8f0-0000-7000-8000-000000000102');

ProjectPartEntity _part(
  PartId partId, {
  int sortOrder = 0,
  String name = 'Piano',
  int stavesCount = 1,
  int midiChannel = 0,
}) {
  return ProjectPartEntity(
    partId: partId,
    projectId: _projectId,
    musicXmlPartId: 'P${sortOrder + 1}',
    sortOrder: sortOrder,
    name: name,
    stavesCount: stavesCount,
    midiChannel: midiChannel,
    sfId: const SoundFontId('sf-1'),
    bankNum: 0,
    programNum: 0,
    gainDb: 0.0,
    pan: 0.0,
    isMuted: false,
    isSolo: false,
    updatedAtMs: 0,
  );
}

TimelineNote _note({
  required String id,
  required PartId partId,
  int staffNumber = 1,
  int voiceNumber = 1,
  required int pitchMidi,
  EnharmonicStep step = EnharmonicStep.C,
  int alter = 0,
  required int startTick,
  required int durationTicks,
  int? rawStartTick,
  int? rawDurationTicks,
}) {
  return TimelineNote(
    noteId: NoteId(id),
    projectId: _projectId,
    partId: partId,
    staffNumber: staffNumber,
    voiceNumber: voiceNumber,
    pitchMidi: pitchMidi,
    enharmonicStep: step,
    enharmonicAlter: alter,
    rawStartTick: Tick(rawStartTick ?? startTick),
    rawDurationTicks: rawDurationTicks ?? durationTicks,
    quantizedStartTick: Tick(startTick),
    quantizedDurationTicks: durationTicks,
    velocity: 90,
    updatedAtMs: 0,
  );
}

ProjectWorkspaceAggregate _baseAggregate({
  String title = 'Test Score',
  int pickupTicks = 0,
  int revision = 1,
  List<ProjectPartEntity>? parts,
  List<TempoEventEntity>? tempoEvents,
  List<TimeSignatureEventEntity>? timeSignatureEvents,
  List<KeySignatureEventEntity> keySignatureEvents = const [],
  List<ClefEventEntity> clefEvents = const [],
  List<TimelineNote> notes = const [],
  List<NoteSpannerEntity> spanners = const [],
  List<AudioTakeEntity> audioTakes = const [],
}) {
  return ProjectWorkspaceAggregate(
    project: ProjectSummary(
      projectId: _projectId,
      title: title,
      ppqn: MuseConstants.ppqn,
      gridSnapTicks: MuseConstants.sixteenthNoteTicks,
      pickupTicks: pickupTicks,
      playbackTimingMode: PlaybackTimingMode.quantized,
      revision: revision,
      createdAtMs: 0,
      updatedAtMs: 0,
    ),
    parts: parts ?? <ProjectPartEntity>[_part(_part1Id)],
    tempoEvents:
        tempoEvents ??
        <TempoEventEntity>[
          TempoEventEntity(
            tempoEventId: const TempoEventId('tempo-0'),
            projectId: _projectId,
            tick: const Tick(0),
            usPerQuarter: 500000,
            updatedAtMs: 0,
          ),
        ],
    timeSignatureEvents:
        timeSignatureEvents ??
        <TimeSignatureEventEntity>[
          TimeSignatureEventEntity(
            tsEventId: const TimeSigEventId('ts-0'),
            projectId: _projectId,
            tick: const Tick(0),
            numerator: 4,
            denominator: 4,
            updatedAtMs: 0,
          ),
        ],
    keySignatureEvents: keySignatureEvents,
    clefEvents: clefEvents,
    notes: notes,
    spanners: spanners,
    audioTakes: audioTakes,
  );
}

void main() {
  final service = DualModelScoreService();

  group('DualModelScoreService viewport spatial index', () {
    test('queries >= 2000 notes accurately across raw/quantized modes, sustained notes, and pitch bounds', () {
      final notes = <TimelineNote>[
        // Long drone note starting at tick 0 overlapping far-right viewport.
        _note(
          id: 'drone-0',
          partId: _part1Id,
          pitchMidi: 48,
          step: EnharmonicStep.C,
          startTick: 0,
          durationTicks: 600000,
          rawStartTick: 0,
          rawDurationTicks: 600000,
        ),
      ];
      for (var i = 0; i < 2500; i++) {
        final qStart = i * 240;
        final rStart = qStart + 45; // shifted in raw mode
        notes.add(
          _note(
            id: 'n-$i',
            partId: _part1Id,
            pitchMidi: 60 + (i % 24),
            step: EnharmonicStep.C,
            startTick: qStart,
            durationTicks: 200,
            rawStartTick: rStart,
            rawDurationTicks: 200,
          ),
        );
      }

      final aggregate = _baseAggregate(notes: notes);
      final buildResult = service.buildWorkspaceState(aggregate);
      expect(buildResult, isA<Ok<ScoreWorkspaceState>>());
      final state = (buildResult as Ok<ScoreWorkspaceState>).value;

      // Quantized query covering [240000, 240480] with pitch 48..83 includes drone-0 + notes at 240000, 240240, 240480.
      final qHits = service.queryNotesInViewport(
        state: state,
        partId: _part1Id,
        startTick: const Tick(240000),
        endTick: const Tick(240480),
        minPitchMidi: 48,
        maxPitchMidi: 83,
        timingMode: PlaybackTimingMode.quantized,
      );
      expect(
        qHits.map((n) => n.noteId.value).toList(),
        <String>['drone-0', 'n-1000', 'n-1001', 'n-1002'],
      );

      // Narrow pitch window excludes drone-0 (MIDI 48).
      final qPitchFiltered = service.queryNotesInViewport(
        state: state,
        partId: _part1Id,
        startTick: const Tick(240000),
        endTick: const Tick(240480),
        minPitchMidi: 60,
        maxPitchMidi: 83,
        timingMode: PlaybackTimingMode.quantized,
      );
      expect(
        qPitchFiltered.map((n) => n.noteId.value).toList(),
        <String>['n-1000', 'n-1001', 'n-1002'],
      );

      // Raw mode shifts start by +45, so n-999 (rawStart=239805, rawEnd=240005) overlaps 240000,
      // while n-1002 (rawStart=240525) lies past endTick=240480.
      final rHits = service.queryNotesInViewport(
        state: state,
        partId: _part1Id,
        startTick: const Tick(240000),
        endTick: const Tick(240480),
        minPitchMidi: 60,
        maxPitchMidi: 83,
        timingMode: PlaybackTimingMode.raw,
      );
      expect(
        rHits.map((n) => n.noteId.value).toList(),
        <String>['n-999', 'n-1000', 'n-1001'],
      );

      // Unknown part or inverted bounds return empty list safely.
      expect(
        service.queryNotesInViewport(
          state: state,
          partId: const PartId('missing'),
          startTick: const Tick(0),
          endTick: const Tick(1000),
          minPitchMidi: 0,
          maxPitchMidi: 127,
          timingMode: PlaybackTimingMode.quantized,
        ),
        isEmpty,
      );
      expect(
        service.queryNotesInViewport(
          state: state,
          partId: _part1Id,
          startTick: const Tick(1000),
          endTick: const Tick(500),
          minPitchMidi: 0,
          maxPitchMidi: 127,
          timingMode: PlaybackTimingMode.quantized,
        ),
        isEmpty,
      );

      // Lazily indexes a bare const ScoreWorkspaceState not created by buildWorkspaceState.
      final bareState = ScoreWorkspaceState(
        aggregate: aggregate,
        renderSnapshot: state.renderSnapshot,
      );
      final bareHits = service.queryNotesInViewport(
        state: bareState,
        partId: _part1Id,
        startTick: const Tick(0),
        endTick: const Tick(240),
        minPitchMidi: 60,
        maxPitchMidi: 83,
        timingMode: PlaybackTimingMode.quantized,
      );
      expect(bareHits.map((n) => n.noteId.value).toList(), <String>['n-0', 'n-1']);
    });
  });

  group('CrispScoreMapper & DualModelScoreService notation mapping', () {
    test('maps chords (lowest-pitch id), enharmonics, cross-barline tie splits, multi-voice rests, triplets, and spanners', () {
      final aggregate = _baseAggregate(
        clefEvents: <ClefEventEntity>[
          const ClefEventEntity(
            clefEventId: ClefEventId('clef-0'),
            projectId: _projectId,
            partId: _part1Id,
            staffNumber: 1,
            tick: Tick(0),
            sign: ClefSign.G,
            line: 2,
            octaveChange: -1,
            updatedAtMs: 0,
          ),
        ],
        notes: <TimelineNote>[
          // Voice 1 chord at tick 0 (C#4=61 and Db4=61 intentionally spelled differently + G4=67).
          _note(
            id: 'chord-high',
            partId: _part1Id,
            voiceNumber: 1,
            pitchMidi: 67,
            step: EnharmonicStep.G,
            alter: 0,
            startTick: 0,
            durationTicks: 960,
          ),
          _note(
            id: 'chord-low',
            partId: _part1Id,
            voiceNumber: 1,
            pitchMidi: 61,
            step: EnharmonicStep.C,
            alter: 1,
            startTick: 0,
            durationTicks: 960,
          ),
          // Triplet eighths in beat 2 [960..1920): 3 * 320 ticks.
          _note(
            id: 'trip-0',
            partId: _part1Id,
            voiceNumber: 1,
            pitchMidi: 61,
            step: EnharmonicStep.D,
            alter: -1,
            startTick: 960,
            durationTicks: 320,
          ),
          _note(
            id: 'trip-1',
            partId: _part1Id,
            voiceNumber: 1,
            pitchMidi: 62,
            step: EnharmonicStep.D,
            alter: 0,
            startTick: 1280,
            durationTicks: 320,
          ),
          _note(
            id: 'trip-2',
            partId: _part1Id,
            voiceNumber: 1,
            pitchMidi: 64,
            step: EnharmonicStep.E,
            alter: 0,
            startTick: 1600,
            durationTicks: 320,
          ),
          // Cross-barline note starting on beat 4 of bar 1 (2880) lasting 1920 ticks -> ends at 4800 in bar 2.
          _note(
            id: 'cross-bar',
            partId: _part1Id,
            voiceNumber: 1,
            pitchMidi: 65,
            step: EnharmonicStep.F,
            alter: 0,
            startTick: 2880,
            durationTicks: 1920,
          ),
          // Voice 2 entry at beat 2 (960) -> synthesizes leading quarter rest in Voice 2.
          _note(
            id: 'v2-note',
            partId: _part1Id,
            voiceNumber: 2,
            pitchMidi: 55,
            step: EnharmonicStep.G,
            alter: 0,
            startTick: 960,
            durationTicks: 960,
          ),
        ],
        spanners: <NoteSpannerEntity>[
          const NoteSpannerEntity(
            spannerId: SpannerId('slur-1'),
            projectId: _projectId,
            partId: _part1Id,
            spannerType: SpannerType.slur,
            startNoteId: NoteId('chord-high'), // Resolves to chord anchor 'chord-low'!
            endNoteId: NoteId('trip-2'),
            spannerLevel: 1,
            placement: SpannerPlacement.above,
            updatedAtMs: 0,
          ),
          const NoteSpannerEntity(
            spannerId: SpannerId('beam-1'),
            projectId: _projectId,
            partId: _part1Id,
            spannerType: SpannerType.beam,
            startNoteId: NoteId('trip-0'),
            endNoteId: NoteId('trip-2'),
            spannerLevel: 1,
            placement: SpannerPlacement.auto,
            updatedAtMs: 0,
          ),
        ],
      );

      final result = service.buildWorkspaceState(aggregate);
      expect(result, isA<Ok<ScoreWorkspaceState>>());
      final staff =
          (result as Ok<ScoreWorkspaceState>).value.renderSnapshot.crispScoreModel.staves.single;

      expect(staff.clef, Clef.treble8vb);
      expect(staff.measures.length, 2);

      final m1 = staff.measures[0];
      final m2 = staff.measures[1];

      // Chord at beat 1 keeps lowest pitch noteId 'chord-low' and C#4 + G4 spelling.
      final chord = m1.elements[0] as NoteElement;
      expect(chord.id, 'chord-low');
      expect(chord.pitches, <Pitch>[
        const Pitch(Step.c, alter: 1, octave: 4),
        const Pitch(Step.g, alter: 0, octave: 4),
      ]);

      // Triplet eighth Db4 keeps Db4 enharmonic spelling and is covered by TupletSpan(1..3, 3:2).
      final trip0 = m1.elements[1] as NoteElement;
      expect(trip0.pitches.single, const Pitch(Step.d, alter: -1, octave: 4));
      expect(m1.tuplets, contains(const TupletSpan(1, 3, actual: 3, normal: 2)));

      // Beat 3 gap [1920..2880) synthesized as quarter rest.
      expect(m1.elements[4], isA<RestElement>());
      expect(m1.elements[4].duration, NoteDuration.quarter);

      // Cross-barline split: m1 head tied to m2 continuation, and trailing rests fill m2.
      final crossHead = m1.elements[5] as NoteElement;
      expect(crossHead.id, 'cross-bar');
      expect(crossHead.duration, NoteDuration.quarter);
      expect(crossHead.tieToNext, isTrue);

      final crossCont = m2.elements[0] as NoteElement;
      expect(crossCont.id, startsWith('cross-bar${CrispScoreMapperConstants.continuationIdDelimiter}'));
      expect(crossCont.duration, NoteDuration.quarter);
      expect(crossCont.tieToNext, isFalse);

      // Voice 2 leading rest + note.
      expect(m1.voice2.length, 2);
      expect(m1.voice2[0], isA<RestElement>());
      expect((m1.voice2[1] as NoteElement).id, 'v2-note');

      // Slur resolved chord-high -> chord-low and explicit BeamSpan preserved.
      expect(staff.slurs, <Slur>[
        const Slur('chord-low', 'trip-2', placement: SlurPlacement.above),
      ]);
      expect(staff.beamsExplicit, isTrue);
      expect(staff.beamSpans, <BeamSpan>[const BeamSpan('trip-0', 'trip-2')]);
    });

    test('maps ClefSign variants bidirectionally with crisp_notation_core Clef', () {
      const cases = <(ClefSign, int, int, Clef)>[
        (ClefSign.G, 2, 0, Clef.treble),
        (ClefSign.G, 2, 1, Clef.treble8va),
        (ClefSign.G, 2, -1, Clef.treble8vb),
        (ClefSign.G, 1, 0, Clef.frenchViolin),
        (ClefSign.F, 4, 0, Clef.bass),
        (ClefSign.F, 4, -1, Clef.bass8vb),
        (ClefSign.F, 3, 0, Clef.baritone),
        (ClefSign.F, 5, 0, Clef.subbass),
        (ClefSign.C, 1, 0, Clef.soprano),
        (ClefSign.C, 2, 0, Clef.mezzoSoprano),
        (ClefSign.C, 3, 0, Clef.alto),
        (ClefSign.C, 4, 0, Clef.tenor),
        (ClefSign.percussion, 2, 0, Clef.percussion),
      ];

      for (final (sign, line, oct, crispClef) in cases) {
        expect(
          CrispScoreMapper.toCrispClef(
            sign: sign,
            line: line,
            octaveChange: oct,
          ),
          crispClef,
        );
        expect(
          CrispScoreMapper.fromCrispClef(crispClef),
          (sign: sign, line: line, octaveChange: oct),
        );
      }

      // ClefSign.tab maps safely to treble8vb for staff rendering.
      expect(
        CrispScoreMapper.toCrispClef(
          sign: ClefSign.tab,
          line: 5,
          octaveChange: 0,
        ),
        Clef.treble8vb,
      );
    });
  });

  group('MusicXML & .mxl import/export round-trip', () {
    test('round-trips multi-part score with grand-staff piano, pickup measure, ties, slurs, and fresh UUIDv7 IDs', () {
      final pianoPart = _part(_part1Id, sortOrder: 0, name: 'Piano', stavesCount: 2);
      final flutePart = _part(_part2Id, sortOrder: 1, name: 'Flute', stavesCount: 1);

      final source = _baseAggregate(
        title: 'Nocturne Draft',
        pickupTicks: 960, // 1-beat pickup
        parts: <ProjectPartEntity>[pianoPart, flutePart],
        clefEvents: <ClefEventEntity>[
          const ClefEventEntity(
            clefEventId: ClefEventId('c1'),
            projectId: _projectId,
            partId: _part1Id,
            staffNumber: 1,
            tick: Tick(0),
            sign: ClefSign.G,
            line: 2,
            octaveChange: 0,
            updatedAtMs: 0,
          ),
          const ClefEventEntity(
            clefEventId: ClefEventId('c2'),
            projectId: _projectId,
            partId: _part1Id,
            staffNumber: 2,
            tick: Tick(0),
            sign: ClefSign.F,
            line: 4,
            octaveChange: 0,
            updatedAtMs: 0,
          ),
        ],
        notes: <TimelineNote>[
          // Pickup beat [0..960) on Flute
          _note(
            id: 'flute-pickup',
            partId: _part2Id,
            pitchMidi: 72,
            step: EnharmonicStep.C,
            startTick: 0,
            durationTicks: 960,
          ),
          // Measure 1 [960..4800): tied half notes on Flute
          _note(
            id: 'flute-m1-a',
            partId: _part2Id,
            pitchMidi: 74,
            step: EnharmonicStep.D,
            startTick: 960,
            durationTicks: 1920,
          ),
          _note(
            id: 'flute-m1-b',
            partId: _part2Id,
            pitchMidi: 74,
            step: EnharmonicStep.D,
            startTick: 2880,
            durationTicks: 1920,
          ),
          // Piano RH and LH notes in Measure 1
          _note(
            id: 'piano-rh',
            partId: _part1Id,
            staffNumber: 1,
            pitchMidi: 61,
            step: EnharmonicStep.D,
            alter: -1,
            startTick: 960,
            durationTicks: 3840,
          ),
          _note(
            id: 'piano-lh',
            partId: _part1Id,
            staffNumber: 2,
            pitchMidi: 48,
            step: EnharmonicStep.C,
            startTick: 960,
            durationTicks: 3840,
          ),
        ],
        spanners: <NoteSpannerEntity>[
          const NoteSpannerEntity(
            spannerId: SpannerId('tie-1'),
            projectId: _projectId,
            partId: _part2Id,
            spannerType: SpannerType.tie,
            startNoteId: NoteId('flute-m1-a'),
            endNoteId: NoteId('flute-m1-b'),
            spannerLevel: 1,
            placement: SpannerPlacement.auto,
            updatedAtMs: 0,
          ),
          const NoteSpannerEntity(
            spannerId: SpannerId('slur-p'),
            projectId: _projectId,
            partId: _part2Id,
            spannerType: SpannerType.slur,
            startNoteId: NoteId('flute-pickup'),
            endNoteId: NoteId('flute-m1-a'),
            spannerLevel: 1,
            placement: SpannerPlacement.above,
            updatedAtMs: 0,
          ),
        ],
      );

      for (final compress in <bool>[false, true]) {
        final exported = service.exportToMusicXmlBytes(
          aggregate: source,
          compressAsMxl: compress,
        );
        expect(exported, isA<Ok<List<int>>>());
        final bytes = (exported as Ok<List<int>>).value;

        final imported = service.importFromMusicXmlBytes(
          bytes: bytes,
          isCompressedMxl: compress,
          fallbackTitle: 'Fallback',
          defaultSoundFontId: const SoundFontId('default-sf'),
        );
        expect(imported, isA<Ok<ProjectWorkspaceAggregate>>());
        final agg = (imported as Ok<ProjectWorkspaceAggregate>).value;

        expect(agg.project.title, 'Nocturne Draft');
        expect(agg.project.pickupTicks, 960);
        expect(agg.parts.length, 2);
        expect(agg.parts[0].name, 'Piano');
        expect(agg.parts[0].stavesCount, 2);
        expect(agg.parts[1].name, 'Flute');
        expect(agg.parts[1].stavesCount, 1);

        // Fresh UUIDv7 IDs generated (none of the source IDs or crisp 'e0' IDs).
        expect(agg.project.projectId, isNot(_projectId));
        for (final n in agg.notes) {
          expect(n.noteId.value.startsWith('e'), isFalse);
          expect(n.noteId.value.length, 36);
        }

        // Verify enharmonic Db4 on Piano RH survived round-trip.
        final pianoRhNotes = agg.notes
            .where((n) => n.partId == agg.parts[0].partId && n.staffNumber == 1)
            .toList();
        expect(pianoRhNotes.length, 1);
        expect(pianoRhNotes.single.enharmonicStep, EnharmonicStep.D);
        expect(pianoRhNotes.single.enharmonicAlter, -1);
        expect(pianoRhNotes.single.pitchMidi, 61);
        expect(pianoRhNotes.single.quantizedStartTick.value, 960);
        expect(pianoRhNotes.single.quantizedDurationTicks, 3840);

        // Verify Tie and Slur reconstructed as NoteSpannerEntity rows.
        expect(agg.spanners.any((s) => s.spannerType == SpannerType.tie), isTrue);
        expect(
          agg.spanners.any((s) => s.spannerType == SpannerType.slur),
          isTrue,
        );
      }
    });

    test('fails closed with invalidMusicXmlFormat on empty, corrupt XML, or corrupt .mxl bytes', () {
      final emptyRes = service.importFromMusicXmlBytes(
        bytes: const <int>[],
        isCompressedMxl: false,
        fallbackTitle: 'Empty',
      );
      expect(
        (emptyRes as Err<ProjectWorkspaceAggregate>).error.code,
        MuseErrorCode.invalidMusicXmlFormat,
      );

      final badXmlRes = service.importFromMusicXmlBytes(
        bytes: utf8.encode('<not-musicxml>'),
        isCompressedMxl: false,
        fallbackTitle: 'BadXml',
      );
      expect(
        (badXmlRes as Err<ProjectWorkspaceAggregate>).error.code,
        MuseErrorCode.invalidMusicXmlFormat,
      );

      final badMxlRes = service.importFromMusicXmlBytes(
        bytes: <int>[0x50, 0x4B, 0x03, 0x04, 0x00, 0x00],
        isCompressedMxl: true,
        fallbackTitle: 'BadMxl',
      );
      expect(
        (badMxlRes as Err<ProjectWorkspaceAggregate>).error.code,
        MuseErrorCode.invalidMusicXmlFormat,
      );
    });
  });

  group('DualModelScoreService incremental applyMutationToDualModel', () {
    test('selectively rebuilds affected part staves, cascades deletes, and rejects revision conflicts', () {
      final p1 = _part(_part1Id, sortOrder: 0, name: 'Part 1');
      final p2 = _part(_part2Id, sortOrder: 1, name: 'Part 2');
      final n1 = _note(
        id: 'n1',
        partId: _part1Id,
        pitchMidi: 60,
        startTick: 0,
        durationTicks: 960,
      );
      final n2 = _note(
        id: 'n2',
        partId: _part1Id,
        pitchMidi: 62,
        startTick: 960,
        durationTicks: 960,
      );
      final slur = const NoteSpannerEntity(
        spannerId: SpannerId('s1'),
        projectId: _projectId,
        partId: _part1Id,
        spannerType: SpannerType.slur,
        startNoteId: NoteId('n1'),
        endNoteId: NoteId('n2'),
        spannerLevel: 1,
        placement: SpannerPlacement.auto,
        updatedAtMs: 0,
      );

      final initState =
          (service.buildWorkspaceState(
                    _baseAggregate(
                      parts: <ProjectPartEntity>[p1, p2],
                      notes: <TimelineNote>[n1, n2],
                      spanners: <NoteSpannerEntity>[slur],
                    ),
                  )
                  as Ok<ScoreWorkspaceState>)
              .value;

      // Revision conflict fails closed.
      final conflictRes = service.applyMutationToDualModel(
        initState,
        const ScoreMutationBatch(
          projectId: _projectId,
          expectedRevision: 99,
        ),
      );
      expect(
        (conflictRes as Err<ScoreWorkspaceState>).error.code,
        MuseErrorCode.revisionConflict,
      );

      // Deleting n1 on Part 1 cascades to remove slur s1 while reusing Part 2's Score instance!
      final mutatedRes = service.applyMutationToDualModel(
        initState,
        const ScoreMutationBatch(
          projectId: _projectId,
          expectedRevision: 1,
          deleteNoteIds: <NoteId>[NoteId('n1')],
        ),
      );
      expect(mutatedRes, isA<Ok<ScoreWorkspaceState>>());
      final nextState = (mutatedRes as Ok<ScoreWorkspaceState>).value;

      expect(nextState.aggregate.project.revision, 2);
      expect(nextState.renderSnapshot.revision, 2);
      expect(nextState.aggregate.notes.map((n) => n.noteId.value), <String>['n2']);
      expect(nextState.aggregate.spanners, isEmpty);
      expect(
        identical(
          nextState.renderSnapshot.crispScoreModel.staves[1],
          initState.renderSnapshot.crispScoreModel.staves[1],
        ),
        isTrue,
      );
      expect(
        service.queryNotesInViewport(
          state: nextState,
          partId: _part1Id,
          startTick: const Tick(0),
          endTick: const Tick(2000),
          minPitchMidi: 0,
          maxPitchMidi: 127,
          timingMode: PlaybackTimingMode.quantized,
        ).map((n) => n.noteId.value),
        <String>['n2'],
      );
    });

    test('keeps aggregate.parts sorted by sortOrder across repeated part reorder mutations', () {
      final p1 = _part(_part1Id, sortOrder: 0, name: 'Part 1');
      final p2 = _part(_part2Id, sortOrder: 1, name: 'Part 2');
      final p3 = _part(const PartId('part-3'), sortOrder: 2, name: 'Part 3');

      final initState =
          (service.buildWorkspaceState(
                    _baseAggregate(parts: <ProjectPartEntity>[p1, p2, p3]),
                  )
                  as Ok<ScoreWorkspaceState>)
              .value;

      // Reorder 1: [Part 2, Part 1, Part 3]
      final firstRes = service.applyMutationToDualModel(
        initState,
        ScoreMutationBatch(
          projectId: _projectId,
          expectedRevision: 1,
          upsertParts: <ProjectPartEntity>[
            _part(_part2Id, sortOrder: 0, name: 'Part 2'),
            _part(_part1Id, sortOrder: 1, name: 'Part 1'),
            _part(const PartId('part-3'), sortOrder: 2, name: 'Part 3'),
          ],
        ),
      );
      expect(firstRes, isA<Ok<ScoreWorkspaceState>>());
      final firstState = (firstRes as Ok<ScoreWorkspaceState>).value;
      expect(
        firstState.aggregate.parts.map((p) => p.partId).toList(),
        <PartId>[_part2Id, _part1Id, const PartId('part-3')],
      );
      expect(
        firstState.renderSnapshot.crispScoreModel.staves
            .map((s) => s.metadata.instrument)
            .toList(),
        <String?>['Part 2', 'Part 1', 'Part 3'],
      );

      // Reorder 2: [Part 3, Part 2, Part 1]
      final secondRes = service.applyMutationToDualModel(
        firstState,
        ScoreMutationBatch(
          projectId: _projectId,
          expectedRevision: 2,
          upsertParts: <ProjectPartEntity>[
            _part(const PartId('part-3'), sortOrder: 0, name: 'Part 3'),
            _part(_part2Id, sortOrder: 1, name: 'Part 2'),
            _part(_part1Id, sortOrder: 2, name: 'Part 1'),
          ],
        ),
      );
      expect(secondRes, isA<Ok<ScoreWorkspaceState>>());
      final secondState = (secondRes as Ok<ScoreWorkspaceState>).value;
      expect(
        secondState.aggregate.parts.map((p) => p.partId).toList(),
        <PartId>[const PartId('part-3'), _part2Id, _part1Id],
      );
      expect(
        secondState.renderSnapshot.crispScoreModel.staves
            .map((s) => s.metadata.instrument)
            .toList(),
        <String?>['Part 3', 'Part 2', 'Part 1'],
      );
    });
  });

  group('CrispScoreMapper & DualModelScoreService boundary cases', () {
    test('preserves pickup-only scores and barline-aligned trailing point events in _computeMeasureSpans', () {
      // 1) Pickup-only score (pickupTicks=960, zero notes): must yield 1 pickup measure rather than dropping to empty.
      final pickupOnlyAgg = _baseAggregate(pickupTicks: 960);
      final pickupRes = service.buildWorkspaceState(pickupOnlyAgg);
      expect(pickupRes, isA<Ok<ScoreWorkspaceState>>());
      final pickupStaff = (pickupRes as Ok<ScoreWorkspaceState>)
          .value
          .renderSnapshot
          .crispScoreModel
          .staves
          .single;
      expect(pickupStaff.measures.length, 1);
      expect(pickupStaff.measures.single.pickup, isTrue);

      // 2) Barline-aligned trailing point event at tick 3840 (start of bar 2 in 4/4) with no notes there:
      // Bar 2 must NOT be dropped when computing measure spans.
      final barlinePointAgg = _baseAggregate(
        notes: <TimelineNote>[
          _note(
            id: 'n-bar1',
            partId: _part1Id,
            pitchMidi: 60,
            startTick: 0,
            durationTicks: 960,
          ),
        ],
        keySignatureEvents: const <KeySignatureEventEntity>[
          KeySignatureEventEntity(
            keyEventId: KeySigEventId('k-0'),
            projectId: _projectId,
            partId: null,
            staffNumber: 0,
            tick: Tick(0),
            fifths: 0,
            mode: KeyMode.major,
            updatedAtMs: 0,
          ),
          KeySignatureEventEntity(
            keyEventId: KeySigEventId('k-bar2'),
            projectId: _projectId,
            partId: null,
            staffNumber: 0,
            tick: Tick(3840),
            fifths: 2,
            mode: KeyMode.major,
            updatedAtMs: 0,
          ),
        ],
        tempoEvents: const <TempoEventEntity>[
          TempoEventEntity(
            tempoEventId: TempoEventId('t-0'),
            projectId: _projectId,
            tick: Tick(0),
            usPerQuarter: 500000,
            updatedAtMs: 0,
          ),
          TempoEventEntity(
            tempoEventId: TempoEventId('t-bar2'),
            projectId: _projectId,
            tick: Tick(3840),
            usPerQuarter: 400000, // 150 BPM at bar 2 barline
            updatedAtMs: 0,
          ),
        ],
      );
      final barlineRes = service.buildWorkspaceState(barlinePointAgg);
      expect(barlineRes, isA<Ok<ScoreWorkspaceState>>());
      final barlineStaff = (barlineRes as Ok<ScoreWorkspaceState>)
          .value
          .renderSnapshot
          .crispScoreModel
          .staves
          .single;
      expect(barlineStaff.measures.length, 2);
      expect(barlineStaff.measures[1].keyChange?.fifths, 2);
      expect(barlineStaff.measures[1].tempoChange?.bpm, 150);
    });

    test('sub-15-tick non-grid durations and gaps avoid Voice 2 spill, remainder drift, and orphan triplets', () {
      // Sequential notes with non-grid durations & <15-tick gaps:
      // n-1: [0..250) (10-tick remainder past 240-tick 16th)
      // n-2: [255..970) (5-tick sub-min gap after 250, 715-tick duration)
      // n-3: [1920..2880) (clean quarter at beat 3)
      final agg = _baseAggregate(
        notes: <TimelineNote>[
          _note(
            id: 'ng-1',
            partId: _part1Id,
            pitchMidi: 60,
            startTick: 0,
            durationTicks: 250,
          ),
          _note(
            id: 'ng-2',
            partId: _part1Id,
            pitchMidi: 62,
            startTick: 255,
            durationTicks: 715,
          ),
          _note(
            id: 'ng-3',
            partId: _part1Id,
            pitchMidi: 64,
            startTick: 1920,
            durationTicks: 960,
          ),
        ],
      );

      final res = service.buildWorkspaceState(agg);
      expect(res, isA<Ok<ScoreWorkspaceState>>());
      final m1 = (res as Ok<ScoreWorkspaceState>)
          .value
          .renderSnapshot
          .crispScoreModel
          .staves
          .single
          .measures
          .single;

      // None of these sequential non-grid notes should falsely spill into voice2!
      expect(m1.voice2, isEmpty);
      expect(
        m1.elements.whereType<NoteElement>().map((e) => e.id).toSet(),
        containsAll(<String>['ng-1', 'ng-2', 'ng-3']),
      );

      // Verify exact whole-note capacity in 4/4 (accounting for any TupletSpan scaling).
      var totalFraction = Fraction.zero;
      for (var i = 0; i < m1.elements.length; i++) {
        var f = m1.elements[i].duration.toFraction();
        for (final t in m1.tuplets) {
          if (i >= t.startIndex && i <= t.endIndex) {
            f = Fraction(
              f.numerator * t.normal,
              f.denominator * t.actual,
            );
          }
        }
        totalFraction = totalFraction + f;
      }
      expect(totalFraction, Fraction(1, 1));
    });

    test('surfaces mid-measure key and tempo transitions inside the containing measure', () {
      final agg = _baseAggregate(
        notes: <TimelineNote>[
          _note(
            id: 'm1-n1',
            partId: _part1Id,
            pitchMidi: 60,
            startTick: 0,
            durationTicks: 3840,
          ),
          _note(
            id: 'm2-n1',
            partId: _part1Id,
            pitchMidi: 66,
            startTick: 3840,
            durationTicks: 3840,
          ),
        ],
        keySignatureEvents: const <KeySignatureEventEntity>[
          KeySignatureEventEntity(
            keyEventId: KeySigEventId('k-0'),
            projectId: _projectId,
            partId: null,
            staffNumber: 0,
            tick: Tick(0),
            fifths: 0,
            mode: KeyMode.major,
            updatedAtMs: 0,
          ),
          KeySignatureEventEntity(
            keyEventId: KeySigEventId('k-mid'),
            projectId: _projectId,
            partId: null,
            staffNumber: 0,
            tick: Tick(5760), // beat 3 of Measure 2
            fifths: 3, // A major mid-measure
            mode: KeyMode.major,
            updatedAtMs: 0,
          ),
        ],
        tempoEvents: const <TempoEventEntity>[
          TempoEventEntity(
            tempoEventId: TempoEventId('t-0'),
            projectId: _projectId,
            tick: Tick(0),
            usPerQuarter: 500000, // 120 BPM
            updatedAtMs: 0,
          ),
          TempoEventEntity(
            tempoEventId: TempoEventId('t-mid'),
            projectId: _projectId,
            tick: Tick(5760), // beat 3 of Measure 2
            usPerQuarter: 625000, // 96 BPM mid-measure
            updatedAtMs: 0,
          ),
        ],
      );

      final res = service.buildWorkspaceState(agg);
      expect(res, isA<Ok<ScoreWorkspaceState>>());
      final measures = (res as Ok<ScoreWorkspaceState>)
          .value
          .renderSnapshot
          .crispScoreModel
          .staves
          .single
          .measures;
      expect(measures.length, 2);
      expect(measures[1].keyChange?.fifths, 3);
      expect(measures[1].tempoChange?.bpm, 96);
    });

    test('unsorted chord pitches select lowest pitch for primary noteId, and MusicXML import breaks tie chains across RestElements and empty voice bars', () {
      // 1) Aggregate -> StaffSystem: chord pitches given in high-to-low order [G4, E4, C4] must pick C4's NoteId!
      final chordAgg = _baseAggregate(
        notes: <TimelineNote>[
          _note(
            id: 'chord-top',
            partId: _part1Id,
            pitchMidi: 67, // G4
            startTick: 0,
            durationTicks: 3840,
          ),
          _note(
            id: 'chord-mid',
            partId: _part1Id,
            pitchMidi: 64, // E4
            startTick: 0,
            durationTicks: 3840,
          ),
          _note(
            id: 'chord-lowest',
            partId: _part1Id,
            pitchMidi: 60, // C4 (lowest)
            startTick: 0,
            durationTicks: 3840,
          ),
        ],
      );
      final chordRes = service.buildWorkspaceState(chordAgg);
      expect(chordRes, isA<Ok<ScoreWorkspaceState>>());
      final chordElem = (chordRes as Ok<ScoreWorkspaceState>)
          .value
          .renderSnapshot
          .crispScoreModel
          .staves
          .single
          .measures
          .single
          .elements
          .single as NoteElement;
      expect(chordElem.id, 'chord-lowest');
      expect(chordElem.pitches.length, 3);

      // 2) StaffSystem -> MusicXML -> importFromMusicXmlBytes (_staffSystemToAggregate):
      // Measure 1 Voice 1: C4 (tieToNext: true) -> Rest(quarter) -> C4 (no tie) -> Rest(quarter)
      // Measure 1 Voice 2: E4 (tieToNext: true), while Measure 2 Voice 2 is empty!
      final staff = Score(
        clef: Clef.treble,
        timeSignature: const TimeSignature(4, 4),
        keySignature: const KeySignature(0),
        measures: <Measure>[
          Measure(
            const <MusicElement>[
              NoteElement(
                pitches: <Pitch>[Pitch(Step.c, octave: 4)],
                duration: NoteDuration.quarter,
                tieToNext: true,
              ),
              RestElement(NoteDuration.quarter),
              NoteElement(
                pitches: <Pitch>[Pitch(Step.c, octave: 4)],
                duration: NoteDuration.quarter,
                tieToNext: false,
              ),
              RestElement(NoteDuration.quarter),
            ],
            voice2: const <MusicElement>[
              NoteElement(
                pitches: <Pitch>[Pitch(Step.e, octave: 4)],
                duration: NoteDuration.whole,
                tieToNext: true,
              ),
            ],
          ),
          const Measure(
            <MusicElement>[
              NoteElement(
                pitches: <Pitch>[Pitch(Step.c, octave: 4)],
                duration: NoteDuration.whole,
              ),
            ],
          ),
        ],
      );

      final xml = multiPartToMusicXml(
        MultiPartScore.fromStaffSystem(StaffSystem(<Score>[staff])),
        partNames: const ['Piano'],
      );
      final imported = service.importFromMusicXmlBytes(
        bytes: utf8.encode(xml),
        isCompressedMxl: false,
        fallbackTitle: 'Tie Chain Break',
        defaultSoundFontId: const SoundFontId('sf-1'),
      );
      expect(imported, isA<Ok<ProjectWorkspaceAggregate>>());
      final roundTripped = (imported as Ok<ProjectWorkspaceAggregate>).value;
      expect(
        roundTripped.spanners.where((s) => s.spannerType == SpannerType.tie),
        isEmpty,
      );
    });
  });
}

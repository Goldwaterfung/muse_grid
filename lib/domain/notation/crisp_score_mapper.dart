/// Pure Dart bidirectional mapper between MuseGrid `960 PPQN` aggregates and
/// `crisp_notation_core` `StaffSystem` / MusicXML (`.musicxml` / `.mxl`).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crisp_notation_core/crisp_notation_core.dart';
import 'package:uuid/uuid.dart';

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../models/score_models.dart';
import '../timeline/tempo_timeline_calculator.dart';

/// Centralized mapping defaults and MusicXML/notation constants for L4.
abstract final class CrispScoreMapperConstants {
  /// Default `120 BPM` (`500_000` us/quarter) when MusicXML omits tempo.
  static const int defaultInitialUsPerQuarter = 500000;

  /// Microseconds in one minute (`60_000_000`).
  static const int microsecondsPerMinute =
      60 * TempoTimelineCalculator.microsecondsPerSecond;

  /// Default initial `4/4` time signature when MusicXML omits `<time>`.
  static const int defaultTimeSigNumerator = 4;
  static const int defaultTimeSigDenominator = 4;

  /// Default grid snap (`1/16` note = `240` ticks) for imported projects.
  static const int minGridSnapTicks = MuseConstants.sixteenthNoteTicks;

  static const int singleStaffCount = 1;
  static const int grandStaffCount = 2;
  static const int defaultStaffNumber = 1;
  static const int lowerGrandStaffNumber = 2;
  static const int defaultVoiceNumber = 1;
  static const int minVoiceNumber = 1;
  static const int maxVoiceNumber = 4;
  static const int initialPartSortOrder = 0;
  static const int initialRevision = 1;
  static const double defaultGainDb = 0.0;
  static const double defaultPan = 0.0;
  static const int musicXmlElementIdStep = 1;
  static const String musicXmlDefaultPartPrefix = 'P';
  static const String defaultImportedPartNamePrefix = 'Part ';
  static const String continuationIdDelimiter = '__cont_';

  /// Default MIDI velocity when imported MusicXML omits `<sound dynamics>`.
  static const int defaultImportedVelocity = 80;
  static const int defaultKeySignatureFifths = 0;
  static const int minKeySignatureFifths = -7;
  static const int maxKeySignatureFifths = 7;
  static const int allStavesKeySigStaffNumber = 0;
  static const int defaultTieOrBeamLevel = 1;

  static const int semitonesPerOctave = 12;
  static const int midiOctaveOffset = 1;
  static const int zeroTick = 0;
  static const int singleMeasureCount = 1;
  static const int tripletActualNotes = 3;
  static const int tripletNormalNotes = 2;

  static const int defaultClefOctaveChange = 0;
  static const int octaveUpClefChange = 1;
  static const int octaveDownClefChange = -1;
  static const int trebleClefLine = 2;
  static const int frenchViolinClefLine = 1;
  static const int bassClefLine = 4;
  static const int baritoneFClefLine = 3;
  static const int subbassClefLine = 5;
  static const int sopranoClefLine = 1;
  static const int mezzoSopranoClefLine = 2;
  static const int altoClefLine = 3;
  static const int tenorClefLine = 4;
  static const int percussionClefLine = 2;

  /// Minimum `DurationBase` tick value mapped during rhythmic decomposition (`1/256` = 15 ticks).
  static const int twoHundredFiftySixthDenominator = 256;
  static const int oneHundredTwentyEighthDenominator = 128;
  static const int minDecomposableTicks =
      MuseConstants.wholeNoteTicks ~/ twoHundredFiftySixthDenominator; // 15
  static const int oneHundredTwentyEighthTicks =
      MuseConstants.wholeNoteTicks ~/ oneHundredTwentyEighthDenominator; // 30
  static const int dottedFactorNumerator = 3;
  static const int dottedFactorDenominator = 2;
  static const int doubleDottedFactorNumerator = 7;
  static const int doubleDottedFactorDenominator = 4;
  static const int tripletSixtyFourthRatioDivisor = 2;
  static const int minTripletDecomposableTicks =
      MuseConstants.tripletThirtySecondNoteTicks ~/
      tripletSixtyFourthRatioDivisor; // 40
  static const int minPositiveDurationTicks = 1;
  static const int minTempoUsPerQuarter = 1;
  static const int exclusiveEndAdjustmentTicks = 1;
  static const int firstStaffIndex = 0;
  static const int initialStaffCount = 0;
  static const int minEnharmonicAlter = -2;
  static const int maxEnharmonicAlter = 2;
  static const int keyResolutionUnassignedPriority = -1;
  static const int keyResolutionGlobalPriority = 1;
  static const int keyResolutionPartAllStavesPriority = 2;
  static const int keyResolutionExactStaffPriority = 3;

  static const int utf16BomBigEndianByte0 = 0xFE;
  static const int utf16BomBigEndianByte1 = 0xFF;
  static const int utf16BomLittleEndianByte0 = 0xFF;
  static const int utf16BomLittleEndianByte1 = 0xFE;
  static const int utf16CodeUnitByteCount = 2;
}

final class _MeasureSpan {
  final int index;
  final int measureNumber;
  final int startTick;
  final int endTick;
  final bool isPickup;
  final TimeSignature timeSignature;

  const _MeasureSpan({
    required this.index,
    required this.measureNumber,
    required this.startTick,
    required this.endTick,
    required this.isPickup,
    required this.timeSignature,
  });

  int get durationTicks => endTick - startTick;
}

final class _RhythmicPiece {
  final NoteDuration duration;
  final bool isTriplet;
  final int soundingTicks;

  const _RhythmicPiece({
    required this.duration,
    required this.isTriplet,
    required this.soundingTicks,
  });
}

final class _ChordBucket {
  final int startTick;
  final int durationTicks;
  final List<TimelineNote> notes;

  const _ChordBucket({
    required this.startTick,
    required this.durationTicks,
    required this.notes,
  });

  String get anchorId => notes.first.noteId.value;
  int get lowestPitchMidi => notes.first.pitchMidi;
}

final class _MutableVoiceBar {
  final List<MusicElement> elements = <MusicElement>[];
  final List<bool> isTripletElement = <bool>[];
  final List<int> elementSoundingTicks = <int>[];
  int cursorTick;

  _MutableVoiceBar(this.cursorTick);
}

final class _StaffElementRef {
  final int measureIndex;
  final int voiceIndex;
  final int elementIndex;
  final int readingOrder;

  const _StaffElementRef({
    required this.measureIndex,
    required this.voiceIndex,
    required this.elementIndex,
    required this.readingOrder,
  });
}

final class _StaffBuildOutput {
  final Score score;
  final Map<String, String> noteIdToHeadElementId;

  const _StaffBuildOutput({
    required this.score,
    required this.noteIdToHeadElementId,
  });
}

/// Maps MuseGrid `ProjectWorkspaceAggregate` <-> `crisp_notation_core` `StaffSystem` and MusicXML.
final class CrispScoreMapper {
  static const Uuid _uuid = Uuid();

  static const List<(int ticks, DurationBase base, int dots)>
  _straightAndDottedTable = <(int, DurationBase, int)>[
    (MuseConstants.wholeNoteTicks, DurationBase.whole, 0), // 3840
    (
      (MuseConstants.halfNoteTicks *
              CrispScoreMapperConstants.doubleDottedFactorNumerator) ~/
          CrispScoreMapperConstants.doubleDottedFactorDenominator,
      DurationBase.half,
      2,
    ), // double-dotted half (3360)
    (MuseConstants.dottedHalfNoteTicks, DurationBase.half, 1), // 2880
    (MuseConstants.halfNoteTicks, DurationBase.half, 0), // 1920
    (
      (MuseConstants.quarterNoteTicks *
              CrispScoreMapperConstants.doubleDottedFactorNumerator) ~/
          CrispScoreMapperConstants.doubleDottedFactorDenominator,
      DurationBase.quarter,
      2,
    ), // double-dotted quarter (1680)
    (MuseConstants.dottedQuarterNoteTicks, DurationBase.quarter, 1), // 1440
    (MuseConstants.quarterNoteTicks, DurationBase.quarter, 0), // 960
    (
      (MuseConstants.eighthNoteTicks *
              CrispScoreMapperConstants.doubleDottedFactorNumerator) ~/
          CrispScoreMapperConstants.doubleDottedFactorDenominator,
      DurationBase.eighth,
      2,
    ), // double-dotted eighth (840)
    (MuseConstants.dottedEighthNoteTicks, DurationBase.eighth, 1), // 720
    (MuseConstants.eighthNoteTicks, DurationBase.eighth, 0), // 480
    (
      (MuseConstants.sixteenthNoteTicks *
              CrispScoreMapperConstants.doubleDottedFactorNumerator) ~/
          CrispScoreMapperConstants.doubleDottedFactorDenominator,
      DurationBase.sixteenth,
      2,
    ), // double-dotted sixteenth (420)
    (MuseConstants.dottedSixteenthNoteTicks, DurationBase.sixteenth, 1), // 360
    (MuseConstants.sixteenthNoteTicks, DurationBase.sixteenth, 0), // 240
    (
      (MuseConstants.thirtySecondNoteTicks *
              CrispScoreMapperConstants.doubleDottedFactorNumerator) ~/
          CrispScoreMapperConstants.doubleDottedFactorDenominator,
      DurationBase.thirtySecond,
      2,
    ), // double-dotted 32nd (210)
    (MuseConstants.dottedThirtySecondNoteTicks, DurationBase.thirtySecond, 1),
    (MuseConstants.thirtySecondNoteTicks, DurationBase.thirtySecond, 0), // 120
    (
      (MuseConstants.sixtyFourthNoteTicks *
              CrispScoreMapperConstants.dottedFactorNumerator) ~/
          CrispScoreMapperConstants.dottedFactorDenominator,
      DurationBase.sixtyFourth,
      1,
    ), // dotted 64th (90)
    (MuseConstants.sixtyFourthNoteTicks, DurationBase.sixtyFourth, 0), // 60
    (
      CrispScoreMapperConstants.oneHundredTwentyEighthTicks,
      DurationBase.oneHundredTwentyEighth,
      0,
    ),
    (
      CrispScoreMapperConstants.minDecomposableTicks,
      DurationBase.twoHundredFiftySixth,
      0,
    ),
  ];

  static const List<(int soundingTicks, DurationBase notatedBase)>
  _tripletTable = <(int, DurationBase)>[
    (MuseConstants.tripletHalfNoteTicks, DurationBase.half), // 1280
    (MuseConstants.tripletQuarterNoteTicks, DurationBase.quarter), // 640
    (MuseConstants.tripletEighthNoteTicks, DurationBase.eighth), // 320
    (MuseConstants.tripletSixteenthNoteTicks, DurationBase.sixteenth), // 160
    (
      MuseConstants.tripletThirtySecondNoteTicks,
      DurationBase.thirtySecond,
    ), // 80
    (
      CrispScoreMapperConstants.minTripletDecomposableTicks,
      DurationBase.sixtyFourth,
    ), // 64th triplet (40)
  ];

  const CrispScoreMapper();

  /// Converts a full [ProjectWorkspaceAggregate] into a `crisp_notation_core` [StaffSystem].
  StaffSystem aggregateToStaffSystem(
    ProjectWorkspaceAggregate aggregate, {
    TempoTimelineCalculator? timelineCalculator,
  }) {
    final calc =
        timelineCalculator ??
        TempoTimelineCalculator(
          tempoEvents: aggregate.tempoEvents,
          timeSignatureEvents: aggregate.timeSignatureEvents,
          pickupTicks: aggregate.project.pickupTicks,
        );

    final measureSpans = _computeMeasureSpans(aggregate, calc);
    final sortedParts = List<ProjectPartEntity>.from(aggregate.parts)
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.partId.value.compareTo(b.partId.value);
      });

    if (sortedParts.isEmpty) {
      return StaffSystem(
        <Score>[_buildEmptyDefaultScore(aggregate, measureSpans)],
        connectBarlines: false,
      );
    }

    final sortedTempos = _sortedTempos(aggregate.tempoEvents);
    final sortedTimeSigs = _sortedTimeSigs(aggregate.timeSignatureEvents);
    final staves = <Score>[];
    final brackets = <StaffBracket>[];

    for (final part in sortedParts) {
      final stavesCount = part.stavesCount.clamp(
        CrispScoreMapperConstants.singleStaffCount,
        CrispScoreMapperConstants.grandStaffCount,
      );
      final firstStaffIdx = staves.length;

      for (var s = 1; s <= stavesCount; s++) {
        staves.add(
          _buildStaffScoreInternal(
            aggregate: aggregate,
            part: part,
            staffNumber: s,
            measureSpans: measureSpans,
            sortedTempos: sortedTempos,
            sortedTimeSigs: sortedTimeSigs,
          ).score,
        );
      }

      if (stavesCount == CrispScoreMapperConstants.grandStaffCount) {
        brackets.add(
          StaffBracket(
            firstStaffIdx,
            firstStaffIdx + CrispScoreMapperConstants.singleStaffCount,
            kind: StaffBracketKind.brace,
          ),
        );
      }
    }

    return StaffSystem(
      staves,
      brackets: brackets,
      connectBarlines: staves.length > CrispScoreMapperConstants.singleStaffCount,
      barlineGroups: staves.length > CrispScoreMapperConstants.singleStaffCount
          ? <BarlineGroup>[
              BarlineGroup(
                CrispScoreMapperConstants.firstStaffIndex,
                staves.length - CrispScoreMapperConstants.singleStaffCount,
              ),
            ]
          : const <BarlineGroup>[],
    );
  }

  /// Rebuilds only staves belonging to [affectedPartIds] while reusing unchanged
  /// `Score` staves from [previousSystem] when topology/global meter/tempo did not change.
  StaffSystem rebuildAffectedStaves({
    required ProjectWorkspaceAggregate nextAggregate,
    required StaffSystem previousSystem,
    required Set<PartId> affectedPartIds,
    TempoTimelineCalculator? timelineCalculator,
  }) {
    final calc =
        timelineCalculator ??
        TempoTimelineCalculator(
          tempoEvents: nextAggregate.tempoEvents,
          timeSignatureEvents: nextAggregate.timeSignatureEvents,
          pickupTicks: nextAggregate.project.pickupTicks,
        );
    final measureSpans = _computeMeasureSpans(nextAggregate, calc);
    final sortedParts = List<ProjectPartEntity>.from(nextAggregate.parts)
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.partId.value.compareTo(b.partId.value);
      });

    final expectedStaffCount = sortedParts.fold<int>(
      CrispScoreMapperConstants.initialStaffCount,
      (sum, p) =>
          sum +
          p.stavesCount.clamp(
            CrispScoreMapperConstants.singleStaffCount,
            CrispScoreMapperConstants.grandStaffCount,
          ),
    );

    if (sortedParts.isEmpty ||
        previousSystem.staves.length != expectedStaffCount ||
        previousSystem.staves.first.measures.length != measureSpans.length) {
      return aggregateToStaffSystem(
        nextAggregate,
        timelineCalculator: calc,
      );
    }

    final sortedTempos = _sortedTempos(nextAggregate.tempoEvents);
    final sortedTimeSigs = _sortedTimeSigs(nextAggregate.timeSignatureEvents);
    final staves = <Score>[];
    var staffCursor = 0;

    for (final part in sortedParts) {
      final stavesCount = part.stavesCount.clamp(
        CrispScoreMapperConstants.singleStaffCount,
        CrispScoreMapperConstants.grandStaffCount,
      );
      final isAffected = affectedPartIds.contains(part.partId);
      for (var s = 1; s <= stavesCount; s++) {
        if (isAffected) {
          staves.add(
            _buildStaffScoreInternal(
              aggregate: nextAggregate,
              part: part,
              staffNumber: s,
              measureSpans: measureSpans,
              sortedTempos: sortedTempos,
              sortedTimeSigs: sortedTimeSigs,
            ).score,
          );
        } else {
          staves.add(previousSystem.staves[staffCursor]);
        }
        staffCursor++;
      }
    }

    return StaffSystem(
      staves,
      brackets: previousSystem.brackets,
      connectBarlines: previousSystem.connectBarlines,
      barlineGroups: previousSystem.barlineGroups,
      systemBreaks: previousSystem.systemBreaks,
      partialStaves: previousSystem.partialStaves,
      crossStaffChords: previousSystem.crossStaffChords,
    );
  }

  Score _buildEmptyDefaultScore(
    ProjectWorkspaceAggregate aggregate,
    List<_MeasureSpan> measureSpans,
  ) {
    final sortedTempos = _sortedTempos(aggregate.tempoEvents);
    final sortedTimeSigs = _sortedTimeSigs(aggregate.timeSignatureEvents);
    final ts0 = sortedTimeSigs.first;
    final tempo0 = sortedTempos.first;
    final measures = <Measure>[
      for (final span in measureSpans)
        Measure(
          span.isPickup
              ? _synthesizeRestElements(span.durationTicks)
              : const <MusicElement>[RestElement(NoteDuration.whole)],
          pickup: span.isPickup,
        ),
    ];
    return Score(
      clef: Clef.treble,
      keySignature: const KeySignature(
        CrispScoreMapperConstants.defaultKeySignatureFifths,
      ),
      timeSignature: TimeSignature(ts0.numerator, ts0.denominator),
      measures: measures,
      metadata: ScoreMetadata(title: aggregate.project.title),
      tempo: _tempoEntityToCrispTempo(tempo0),
    );
  }

  _StaffBuildOutput _buildStaffScoreInternal({
    required ProjectWorkspaceAggregate aggregate,
    required ProjectPartEntity part,
    required int staffNumber,
    required List<_MeasureSpan> measureSpans,
    required List<TempoEventEntity> sortedTempos,
    required List<TimeSignatureEventEntity> sortedTimeSigs,
  }) {
    final staffClefs =
        aggregate.clefEvents
            .where(
              (c) => c.partId == part.partId && c.staffNumber == staffNumber,
            )
            .toList()
          ..sort((a, b) => a.tick.value.compareTo(b.tick.value));

    final defaultClef = _defaultClefForPartStaff(part, staffNumber);
    final initialClefEvent = staffClefs
        .where((c) => c.tick.value == CrispScoreMapperConstants.zeroTick)
        .lastOrNull;
    final initialClef = initialClefEvent == null
        ? defaultClef
        : toCrispClef(
            sign: initialClefEvent.sign,
            line: initialClefEvent.line,
            octaveChange: initialClefEvent.octaveChange,
          );

    final initialKeyEvent = _resolveKeySignatureAtTick(
      aggregate.keySignatureEvents,
      partId: part.partId,
      staffNumber: staffNumber,
      tick: CrispScoreMapperConstants.zeroTick,
    );
    final initialKey = KeySignature(
      (initialKeyEvent?.fifths ??
              CrispScoreMapperConstants.defaultKeySignatureFifths)
          .clamp(
            CrispScoreMapperConstants.minKeySignatureFifths,
            CrispScoreMapperConstants.maxKeySignatureFifths,
          ),
    );

    final ts0 = sortedTimeSigs.first;
    final initialTimeSig = TimeSignature(ts0.numerator, ts0.denominator);
    final initialTempo = _tempoEntityToCrispTempo(sortedTempos.first);

    // Filter notes belonging to this (part, staff), grouped into chord buckets per voice.
    final staffNotes = aggregate.notes
        .where((n) => n.partId == part.partId && n.staffNumber == staffNumber)
        .toList();
    final bucketsByVoice = _groupNotesIntoChordBuckets(staffNotes);

    // Collect explicit tie spanners keyed by startNoteId (or resolved chord head).
    final noteIdToHeadElementId = <String, String>{};
    final explicitTieStartNoteIds = <NoteId>{
      for (final s in aggregate.spanners)
        if (s.partId == part.partId && s.spannerType == SpannerType.tie)
          s.startNoteId,
    };

    // Prepare mutable voice buffers for every measure.
    final voiceBars = List<List<_MutableVoiceBar>>.generate(
      measureSpans.length,
      (mIdx) => List<_MutableVoiceBar>.generate(
        CrispScoreMapperConstants.maxVoiceNumber,
        (_) => _MutableVoiceBar(measureSpans[mIdx].startTick),
      ),
    );

    // Track last NoteElement coordinate for each chord head so cross-barline
    // splits and explicit NoteSpannerEntity ties patch the exact tail segment.
    final headIdToLastSegmentCoord =
        <String, (int mIdx, int vIdx, int elemIdx)>{};
    final headIdHasExplicitTie = <String>{};

    // Place each voice's chord buckets across measure boundaries.
    for (
      var vIdx = 0;
      vIdx < CrispScoreMapperConstants.maxVoiceNumber;
      vIdx++
    ) {
      final buckets = bucketsByVoice[vIdx];
      for (final bucket in buckets) {
        final headId = bucket.anchorId;
        for (final n in bucket.notes) {
          noteIdToHeadElementId[n.noteId.value] = headId;
          if (explicitTieStartNoteIds.contains(n.noteId)) {
            headIdHasExplicitTie.add(headId);
          }
        }

        final pitches = <Pitch>[
          for (final n in bucket.notes) _noteToCrispPitch(n),
        ];
        final velocity = bucket.notes.first.velocity.clamp(
          MuseConstants.minMidiVelocity,
          MuseConstants.maxMidiVelocity,
        );

        final bucketStart = bucket.startTick;
        final bucketEnd = bucketStart + bucket.durationTicks;
        var mIdx = _findMeasureIndexContaining(measureSpans, bucketStart);
        var segStart = bucketStart;
        var isFirstSegment = true;

        while (segStart < bucketEnd && mIdx < measureSpans.length) {
          final span = measureSpans[mIdx];
          final segEnd = math.min(bucketEnd, span.endTick);
          final segTicks = segEnd - segStart;
          final continuesToNextBar = segEnd < bucketEnd;

          if (segTicks > CrispScoreMapperConstants.zeroTick) {
            final targetVoiceIdx = _pickNonOverlappingVoice(
              voiceBars[mIdx],
              preferredVoiceIdx: vIdx,
              segStartTick: segStart,
            );
            final voiceBar = voiceBars[mIdx][targetVoiceIdx];

            if (segStart > voiceBar.cursorTick) {
              _appendRestGap(
                voiceBar,
                segStart - voiceBar.cursorTick,
                allowSubMinRest: false,
              );
            }

            final pieces = _decomposeDuration(segTicks);
            var emittedTicks = CrispScoreMapperConstants.zeroTick;
            for (var pIdx = 0; pIdx < pieces.length; pIdx++) {
              final piece = pieces[pIdx];
              emittedTicks += piece.soundingTicks;
              final isHead = isFirstSegment && pIdx == 0;
              final isLastInSeg = pIdx == pieces.length - 1;
              final tieToNext = !isLastInSeg || continuesToNextBar;

              final elemId = isHead
                  ? headId
                  : '$headId${CrispScoreMapperConstants.continuationIdDelimiter}'
                        '${mIdx}_$pIdx';

              final elemIndex = voiceBar.elements.length;
              voiceBar.elements.add(
                NoteElement(
                  pitches: pitches,
                  duration: piece.duration,
                  tieToNext: tieToNext,
                  velocity: velocity,
                  id: elemId,
                ),
              );
              voiceBar.isTripletElement.add(piece.isTriplet);
              voiceBar.elementSoundingTicks.add(piece.soundingTicks);
              headIdToLastSegmentCoord[headId] = (mIdx, targetVoiceIdx, elemIndex);
            }
            voiceBar.cursorTick += emittedTicks;
            isFirstSegment = false;
          }

          segStart = segEnd;
          mIdx++;
        }
      }
    }

    // Apply explicit SpannerType.tie flags onto the final segment of each tied note.
    for (final headId in headIdHasExplicitTie) {
      final coord = headIdToLastSegmentCoord[headId];
      if (coord == null) continue;
      final (mIdx, vIdx, elemIdx) = coord;
      final elem = voiceBars[mIdx][vIdx].elements[elemIdx];
      if (elem is NoteElement && !elem.tieToNext) {
        voiceBars[mIdx][vIdx].elements[elemIdx] = elem.copyWith(
          tieToNext: true,
        );
      }
    }

    // Fill trailing gaps in Voice 1 (and whole-bar rests for completely empty measures).
    for (var mIdx = 0; mIdx < measureSpans.length; mIdx++) {
      final span = measureSpans[mIdx];
      final bar = voiceBars[mIdx];
      final allVoicesEmpty = bar.every((v) => v.elements.isEmpty);
      if (allVoicesEmpty) {
        if (span.isPickup) {
          _appendRestGap(bar[0], span.durationTicks, allowSubMinRest: true);
        } else {
          bar[0].elements.add(const RestElement(NoteDuration.whole));
          bar[0].isTripletElement.add(false);
          bar[0].elementSoundingTicks.add(span.durationTicks);
          bar[0].cursorTick = span.endTick;
        }
      } else {
        final v1 = bar[0];
        if (v1.cursorTick < span.endTick) {
          _appendRestGap(
            v1,
            span.endTick - v1.cursorTick,
            allowSubMinRest: true,
          );
        }
      }
    }

    // Build Measures + record reading-order positions of every NoteElement id on this staff.
    final measures = <Measure>[];
    final elementRefs = <String, _StaffElementRef>{};
    var readingOrder = 0;
    var activeKeyFifths = initialKey.fifths;
    var activeTempoUs = sortedTempos.first.usPerQuarter;

    for (var mIdx = 0; mIdx < measureSpans.length; mIdx++) {
      final span = measureSpans[mIdx];
      final bar = voiceBars[mIdx];
      final tuplets = <TupletSpan>[];

      for (
        var vIdx = 0;
        vIdx < CrispScoreMapperConstants.maxVoiceNumber;
        vIdx++
      ) {
        final voiceBar = bar[vIdx];
        tuplets.addAll(_extractTripletSpans(voiceBar, voiceIndex: vIdx));
        for (var eIdx = 0; eIdx < voiceBar.elements.length; eIdx++) {
          final elem = voiceBar.elements[eIdx];
          if (elem is NoteElement && elem.id != null) {
            elementRefs[elem.id!] = _StaffElementRef(
              measureIndex: mIdx,
              voiceIndex: vIdx,
              elementIndex: eIdx,
              readingOrder: readingOrder++,
            );
          }
        }
      }

      Clef? clefChange;
      if (mIdx > 0) {
        final barClef = staffClefs
            .where((c) => c.tick.value == span.startTick)
            .lastOrNull;
        if (barClef != null) {
          clefChange = toCrispClef(
            sign: barClef.sign,
            line: barClef.line,
            octaveChange: barClef.octaveChange,
          );
        }
      }

      final inlineClefs = <InlineClefChange>[
        for (final c in staffClefs)
          if (c.tick.value > span.startTick && c.tick.value < span.endTick)
            InlineClefChange(
              Fraction(
                c.tick.value - span.startTick,
                MuseConstants.wholeNoteTicks,
              ),
              toCrispClef(
                sign: c.sign,
                line: c.line,
                octaveChange: c.octaveChange,
              ),
            ),
      ];

      final evalTick = math.max(
        span.startTick,
        span.endTick - CrispScoreMapperConstants.exclusiveEndAdjustmentTicks,
      );

      KeySignature? keyChange;
      if (mIdx > 0) {
        final resolvedKey = _resolveKeySignatureAtTick(
          aggregate.keySignatureEvents,
          partId: part.partId,
          staffNumber: staffNumber,
          tick: evalTick,
        );
        final resolvedFifths =
            (resolvedKey?.fifths ??
                    CrispScoreMapperConstants.defaultKeySignatureFifths)
                .clamp(
                  CrispScoreMapperConstants.minKeySignatureFifths,
                  CrispScoreMapperConstants.maxKeySignatureFifths,
                );
        final hasExplicitBarlineKey =
            resolvedKey != null && resolvedKey.tick.value == span.startTick;
        if (resolvedFifths != activeKeyFifths || hasExplicitBarlineKey) {
          keyChange = KeySignature(resolvedFifths);
          activeKeyFifths = resolvedFifths;
        }
      }

      TimeSignature? timeChange;
      if (mIdx > 0 && span.timeSignature != measureSpans[mIdx - 1].timeSignature) {
        timeChange = span.timeSignature;
      }

      Tempo? tempoChange;
      if (mIdx > 0) {
        final resolvedTempo = sortedTempos
            .where((t) => t.tick.value <= evalTick)
            .lastOrNull;
        if (resolvedTempo != null) {
          final hasExplicitBarlineTempo =
              resolvedTempo.tick.value == span.startTick;
          if (resolvedTempo.usPerQuarter != activeTempoUs ||
              hasExplicitBarlineTempo) {
            tempoChange = _tempoEntityToCrispTempo(resolvedTempo);
            activeTempoUs = resolvedTempo.usPerQuarter;
          }
        }
      }

      measures.add(
        Measure(
          List<MusicElement>.unmodifiable(bar[0].elements),
          voice2: List<MusicElement>.unmodifiable(bar[1].elements),
          voice3: List<MusicElement>.unmodifiable(bar[2].elements),
          voice4: List<MusicElement>.unmodifiable(bar[3].elements),
          tuplets: List<TupletSpan>.unmodifiable(tuplets),
          clefChange: clefChange,
          inlineClefs: List<InlineClefChange>.unmodifiable(inlineClefs),
          keyChange: keyChange,
          timeChange: timeChange,
          tempoChange: tempoChange,
          pickup: span.isPickup,
        ),
      );
    }

    // Map Slur, BeamSpan, and CrossMeasureBeam safely after verifying IDs and reading order.
    final slurs = <Slur>[];
    final beamSpans = <BeamSpan>[];
    final crossMeasureBeams = <CrossMeasureBeam>[];

    for (final spanner in aggregate.spanners) {
      if (spanner.partId != part.partId) continue;
      final startElId = noteIdToHeadElementId[spanner.startNoteId.value];
      final endElId = noteIdToHeadElementId[spanner.endNoteId.value];
      if (startElId == null || endElId == null || startElId == endElId) {
        continue;
      }
      final startRef = elementRefs[startElId];
      final endRef = elementRefs[endElId];
      if (startRef == null || endRef == null) continue;
      if (startRef.readingOrder >= endRef.readingOrder) continue;

      switch (spanner.spannerType) {
        case SpannerType.tie:
          // Already applied directly onto NoteElement.tieToNext above.
          break;
        case SpannerType.slur:
          slurs.add(
            Slur(
              startElId,
              endElId,
              placement: toCrispSlurPlacement(spanner.placement),
            ),
          );
        case SpannerType.beam:
          if (startRef.voiceIndex != endRef.voiceIndex) continue;
          if (startRef.measureIndex == endRef.measureIndex) {
            beamSpans.add(BeamSpan(startElId, endElId));
          } else {
            crossMeasureBeams.add(CrossMeasureBeam(startElId, endElId));
          }
      }
    }

    final hasExplicitBeams =
        beamSpans.isNotEmpty || crossMeasureBeams.isNotEmpty;

    final score = Score(
      clef: initialClef,
      keySignature: initialKey,
      timeSignature: initialTimeSig,
      measures: List<Measure>.unmodifiable(measures),
      slurs: List<Slur>.unmodifiable(slurs),
      beamSpans: List<BeamSpan>.unmodifiable(beamSpans),
      beamsExplicit: hasExplicitBeams,
      crossMeasureBeams: List<CrossMeasureBeam>.unmodifiable(crossMeasureBeams),
      metadata: ScoreMetadata(
        title: aggregate.project.title,
        instrument: part.name,
        midiProgram: part.programNum,
        isPercussion: part.midiChannel == MuseConstants.gmPercussionChannel,
      ),
      tempo: initialTempo,
    );

    return _StaffBuildOutput(
      score: score,
      noteIdToHeadElementId: noteIdToHeadElementId,
    );
  }

  /// Parses MusicXML or compressed `.mxl` bytes into a fresh [ProjectWorkspaceAggregate]
  /// with freshly generated UUIDv7 identifiers.
  Result<ProjectWorkspaceAggregate> importFromMusicXmlBytes({
    required List<int> bytes,
    required bool isCompressedMxl,
    required String fallbackTitle,
    SoundFontId? defaultSoundFontId,
  }) {
    if (bytes.isEmpty) {
      return const Err<ProjectWorkspaceAggregate>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'MusicXML input bytes are empty',
        ),
      );
    }

    final String xml;
    try {
      final rawBytes = Uint8List.fromList(bytes);
      xml = isCompressedMxl
          ? readMusicXmlFromMxl(rawBytes)
          : _decodeXmlBytes(rawBytes);
    } on FormatException catch (e) {
      return Err<ProjectWorkspaceAggregate>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Failed to decode MusicXML container/text',
          cause: e,
        ),
      );
    } on ArgumentError catch (e) {
      return Err<ProjectWorkspaceAggregate>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Invalid MusicXML archive payload',
          cause: e,
        ),
      );
    } on StateError catch (e) {
      return Err<ProjectWorkspaceAggregate>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Malformed MusicXML stream',
          cause: e,
        ),
      );
    }

    final StaffSystem staffSystem;
    try {
      staffSystem = staffSystemFromMusicXml(xml);
    } on FormatException catch (e) {
      return Err<ProjectWorkspaceAggregate>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Malformed MusicXML document: ${e.message}',
          cause: e,
        ),
      );
    } on ArgumentError catch (e) {
      return Err<ProjectWorkspaceAggregate>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Invalid MusicXML score attributes',
          cause: e,
        ),
      );
    } on StateError catch (e) {
      return Err<ProjectWorkspaceAggregate>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Inconsistent MusicXML structure',
          cause: e,
        ),
      );
    }

    return _staffSystemToAggregate(
      staffSystem: staffSystem,
      fallbackTitle: fallbackTitle,
      defaultSoundFontId: defaultSoundFontId,
    );
  }

  /// Exports [aggregate] to `.musicxml` or `.mxl` bytes.
  Result<List<int>> exportToMusicXmlBytes({
    required ProjectWorkspaceAggregate aggregate,
    required bool compressAsMxl,
  }) {
    try {
      final staffSystem = aggregateToStaffSystem(aggregate);
      final multiPart = MultiPartScore.fromStaffSystem(staffSystem);
      final partNames = <String>[
        for (final score in staffSystem.staves)
          score.metadata.instrument ?? aggregate.project.title,
      ];
      final xml = multiPartToMusicXml(
        multiPart,
        partNames: partNames.isEmpty ? null : partNames,
      );
      final Uint8List outBytes = compressAsMxl
          ? writeMusicXmlToMxl(xml)
          : Uint8List.fromList(utf8.encode(xml));
      return Ok<List<int>>(List<int>.unmodifiable(outBytes));
    } on ArgumentError catch (e) {
      return Err<List<int>>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Failed to serialize score to MusicXML',
          cause: e,
        ),
      );
    } on StateError catch (e) {
      return Err<List<int>>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Failed to serialize score to MusicXML',
          cause: e,
        ),
      );
    }
  }

  Result<ProjectWorkspaceAggregate> _staffSystemToAggregate({
    required StaffSystem staffSystem,
    required String fallbackTitle,
    SoundFontId? defaultSoundFontId,
  }) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final projectId = ProjectId(_uuid.v7());

    final staves = staffSystem.staves;
    final primaryStaff = staves.first;
    final rawTitle =
        primaryStaff.metadata.title ?? primaryStaff.metadata.subtitle;
    final title = (rawTitle != null && rawTitle.trim().isNotEmpty)
        ? rawTitle.trim()
        : fallbackTitle;

    // Group braced 2-staff parts (piano/organ) into single ProjectPartEntity(stavesCount: 2).
    final staffGroups = <List<int>>[];
    final bracedPairStarts = <int>{
      for (final b in staffSystem.brackets)
        if (b.kind == StaffBracketKind.brace &&
            b.last == b.first + CrispScoreMapperConstants.singleStaffCount)
          b.first,
    };

    var sIdx = 0;
    while (sIdx < staves.length) {
      if (bracedPairStarts.contains(sIdx) &&
          sIdx + CrispScoreMapperConstants.singleStaffCount < staves.length) {
        staffGroups.add(<int>[
          sIdx,
          sIdx + CrispScoreMapperConstants.singleStaffCount,
        ]);
        sIdx += CrispScoreMapperConstants.grandStaffCount;
      } else {
        staffGroups.add(<int>[sIdx]);
        sIdx += CrispScoreMapperConstants.singleStaffCount;
      }
    }

    // Compute measure timeline (startTick, durationTicks, pickupTicks) from the conductor staff.
    final conductorMeasures = primaryStaff.measures;
    final measureStartTicks = <int>[];
    final tempoEvents = <TempoEventEntity>[];
    final timeSignatureEvents = <TimeSignatureEventEntity>[];

    var currentTick = CrispScoreMapperConstants.zeroTick;
    var activeMeter =
        primaryStaff.timeSignature ??
        const TimeSignature(
          CrispScoreMapperConstants.defaultTimeSigNumerator,
          CrispScoreMapperConstants.defaultTimeSigDenominator,
        );
    if (!TempoTimelineCalculator.validTimeSigDenominators.contains(
      activeMeter.beatUnit,
    )) {
      return Err<ProjectWorkspaceAggregate>(
        MuseError(
          MuseErrorCode.invalidMusicXmlFormat,
          'Unsupported initial MusicXML time signature denominator: '
          '${activeMeter.beatUnit}',
        ),
      );
    }

    final initialUsPerQuarter = primaryStaff.tempo == null
        ? CrispScoreMapperConstants.defaultInitialUsPerQuarter
        : _crispTempoToUsPerQuarter(primaryStaff.tempo!);

    tempoEvents.add(
      TempoEventEntity(
        tempoEventId: TempoEventId(_uuid.v7()),
        projectId: projectId,
        tick: const Tick(CrispScoreMapperConstants.zeroTick),
        usPerQuarter: initialUsPerQuarter,
        updatedAtMs: nowMs,
      ),
    );
    timeSignatureEvents.add(
      TimeSignatureEventEntity(
        tsEventId: TimeSigEventId(_uuid.v7()),
        projectId: projectId,
        tick: const Tick(CrispScoreMapperConstants.zeroTick),
        numerator: activeMeter.beats,
        denominator: activeMeter.beatUnit,
        updatedAtMs: nowMs,
      ),
    );

    var pickupTicks = MuseConstants.defaultPickupTicks;

    for (var mIdx = 0; mIdx < conductorMeasures.length; mIdx++) {
      final measure = conductorMeasures[mIdx];
      measureStartTicks.add(currentTick);

      if (measure.timeChange != null) {
        final nextMeter = measure.timeChange!;
        if (!TempoTimelineCalculator.validTimeSigDenominators.contains(
          nextMeter.beatUnit,
        )) {
          return Err<ProjectWorkspaceAggregate>(
            MuseError(
              MuseErrorCode.invalidMusicXmlFormat,
              'Unsupported MusicXML time signature denominator at measure '
              '${mIdx + 1}: ${nextMeter.beatUnit}',
            ),
          );
        }
        activeMeter = nextMeter;
        if (currentTick == CrispScoreMapperConstants.zeroTick) {
          timeSignatureEvents[0] = TimeSignatureEventEntity(
            tsEventId: timeSignatureEvents[0].tsEventId,
            projectId: projectId,
            tick: const Tick(CrispScoreMapperConstants.zeroTick),
            numerator: activeMeter.beats,
            denominator: activeMeter.beatUnit,
            updatedAtMs: nowMs,
          );
        } else {
          timeSignatureEvents.add(
            TimeSignatureEventEntity(
              tsEventId: TimeSigEventId(_uuid.v7()),
              projectId: projectId,
              tick: Tick(currentTick),
              numerator: activeMeter.beats,
              denominator: activeMeter.beatUnit,
              updatedAtMs: nowMs,
            ),
          );
        }
      }

      if (measure.tempoChange != null) {
        final usPerQuarter = _crispTempoToUsPerQuarter(measure.tempoChange!);
        if (currentTick == CrispScoreMapperConstants.zeroTick) {
          tempoEvents[0] = TempoEventEntity(
            tempoEventId: tempoEvents[0].tempoEventId,
            projectId: projectId,
            tick: const Tick(CrispScoreMapperConstants.zeroTick),
            usPerQuarter: usPerQuarter,
            updatedAtMs: nowMs,
          );
        } else {
          tempoEvents.add(
            TempoEventEntity(
              tempoEventId: TempoEventId(_uuid.v7()),
              projectId: projectId,
              tick: Tick(currentTick),
              usPerQuarter: usPerQuarter,
              updatedAtMs: nowMs,
            ),
          );
        }
      }

      final int measureTicks;
      if (mIdx == 0 && measure.pickup) {
        final totalFrac = measure.totalDuration;
        final computedPickup = _fractionToTicks(totalFrac);
        measureTicks = computedPickup > CrispScoreMapperConstants.zeroTick
            ? computedPickup
            : (activeMeter.beats * MuseConstants.wholeNoteTicks) ~/
                  activeMeter.beatUnit;
        pickupTicks = measureTicks;
      } else if (measure.actualDuration != null) {
        measureTicks = _fractionToTicks(measure.actualDuration!);
      } else {
        final repeatSpan = measure.multiRest ?? 1;
        measureTicks =
            repeatSpan *
            ((activeMeter.beats * MuseConstants.wholeNoteTicks) ~/
                activeMeter.beatUnit);
      }
      currentTick += measureTicks;
    }

    final parts = <ProjectPartEntity>[];
    final keySignatureEvents = <KeySignatureEventEntity>[];
    final clefEvents = <ClefEventEntity>[];
    final notes = <TimelineNote>[];
    final spanners = <NoteSpannerEntity>[];

    var nextMelodicChannel = MuseConstants.minMidiChannel;

    for (var pIdx = 0; pIdx < staffGroups.length; pIdx++) {
      final group = staffGroups[pIdx];
      final partPrimaryScore = staves[group.first];
      final partId = PartId(_uuid.v7());

      final isPercussion =
          partPrimaryScore.metadata.isPercussion ||
          partPrimaryScore.clef == Clef.percussion;
      final int midiChannel;
      if (isPercussion) {
        midiChannel = MuseConstants.gmPercussionChannel;
      } else {
        midiChannel = nextMelodicChannel;
        nextMelodicChannel++;
        if (nextMelodicChannel == MuseConstants.gmPercussionChannel) {
          nextMelodicChannel++;
        }
        if (nextMelodicChannel > MuseConstants.maxMidiChannel) {
          nextMelodicChannel = MuseConstants.minMidiChannel;
        }
      }

      final rawPartName = partPrimaryScore.metadata.instrument?.trim();
      final partName = (rawPartName != null && rawPartName.isNotEmpty)
          ? rawPartName
          : '${CrispScoreMapperConstants.defaultImportedPartNamePrefix}'
                '${pIdx + 1}';

      final programNum = (partPrimaryScore.metadata.midiProgram ?? 0).clamp(
        MuseConstants.minProgramNum,
        MuseConstants.maxProgramNum,
      );

      parts.add(
        ProjectPartEntity(
          partId: partId,
          projectId: projectId,
          musicXmlPartId:
              '${CrispScoreMapperConstants.musicXmlDefaultPartPrefix}${pIdx + 1}',
          sortOrder: CrispScoreMapperConstants.initialPartSortOrder + pIdx,
          name: partName,
          stavesCount: group.length,
          midiChannel: midiChannel,
          sfId: defaultSoundFontId,
          bankNum: MuseConstants.minBankNum,
          programNum: programNum,
          gainDb: CrispScoreMapperConstants.defaultGainDb,
          pan: CrispScoreMapperConstants.defaultPan,
          isMuted: false,
          isSolo: false,
          updatedAtMs: nowMs,
        ),
      );

      for (var localStaffIdx = 0; localStaffIdx < group.length; localStaffIdx++) {
        final staffScore = staves[group[localStaffIdx]];
        final staffNumber = localStaffIdx + 1;

        final initialClefSpec = fromCrispClef(staffScore.clef);
        clefEvents.add(
          ClefEventEntity(
            clefEventId: ClefEventId(_uuid.v7()),
            projectId: projectId,
            partId: partId,
            staffNumber: staffNumber,
            tick: const Tick(CrispScoreMapperConstants.zeroTick),
            sign: initialClefSpec.sign,
            line: initialClefSpec.line,
            octaveChange: initialClefSpec.octaveChange,
            updatedAtMs: nowMs,
          ),
        );

        keySignatureEvents.add(
          KeySignatureEventEntity(
            keyEventId: KeySigEventId(_uuid.v7()),
            projectId: projectId,
            partId: partId,
            staffNumber: staffNumber,
            tick: const Tick(CrispScoreMapperConstants.zeroTick),
            fifths: staffScore.keySignature.fifths.clamp(
              CrispScoreMapperConstants.minKeySignatureFifths,
              CrispScoreMapperConstants.maxKeySignatureFifths,
            ),
            mode: KeyMode.none,
            updatedAtMs: nowMs,
          ),
        );

        final elementIdToPrimaryNoteId = <String, NoteId>{};
        // Per-voice ordered note/rest entries for tieToNext reconstruction:
        // null entries mark rests or empty measures that break ties.
        final voiceNoteChain = List<
          List<({String? elementId, bool tieToNext, List<(int, NoteId)> pitches})?>
        >.generate(CrispScoreMapperConstants.maxVoiceNumber, (_) => []);

        final staffMeasureCount = staffScore.measures.length;
        for (var mIdx = 0; mIdx < staffMeasureCount; mIdx++) {
          final measure = staffScore.measures[mIdx];
          final mStartTick = mIdx < measureStartTicks.length
              ? measureStartTicks[mIdx]
              : currentTick;

          if (mIdx > 0 && measure.clefChange != null) {
            final spec = fromCrispClef(measure.clefChange!);
            clefEvents.add(
              ClefEventEntity(
                clefEventId: ClefEventId(_uuid.v7()),
                projectId: projectId,
                partId: partId,
                staffNumber: staffNumber,
                tick: Tick(mStartTick),
                sign: spec.sign,
                line: spec.line,
                octaveChange: spec.octaveChange,
                updatedAtMs: nowMs,
              ),
            );
          }

          for (final inlineClef in measure.inlineClefs) {
            final spec = fromCrispClef(inlineClef.clef);
            clefEvents.add(
              ClefEventEntity(
                clefEventId: ClefEventId(_uuid.v7()),
                projectId: projectId,
                partId: partId,
                staffNumber: staffNumber,
                tick: Tick(mStartTick + _fractionToTicks(inlineClef.onset)),
                sign: spec.sign,
                line: spec.line,
                octaveChange: spec.octaveChange,
                updatedAtMs: nowMs,
              ),
            );
          }

          if (mIdx > 0 && measure.keyChange != null) {
            keySignatureEvents.add(
              KeySignatureEventEntity(
                keyEventId: KeySigEventId(_uuid.v7()),
                projectId: projectId,
                partId: partId,
                staffNumber: staffNumber,
                tick: Tick(mStartTick),
                fifths: measure.keyChange!.fifths.clamp(
                  CrispScoreMapperConstants.minKeySignatureFifths,
                  CrispScoreMapperConstants.maxKeySignatureFifths,
                ),
                mode: KeyMode.none,
                updatedAtMs: nowMs,
              ),
            );
          }

          for (
            var vIdx = 0;
            vIdx < CrispScoreMapperConstants.maxVoiceNumber;
            vIdx++
          ) {
            final voiceElements = measure.voiceAt(vIdx);
            if (voiceElements.isEmpty) {
              voiceNoteChain[vIdx].add(null);
              continue;
            }
            var voiceOffsetTicks = CrispScoreMapperConstants.zeroTick;
            for (var eIdx = 0; eIdx < voiceElements.length; eIdx++) {
              final element = voiceElements[eIdx];
              final effDuration = measure.effectiveDurationAt(
                eIdx,
                voice: vIdx,
              );
              final durationTicks = math.max(
                CrispScoreMapperConstants.minPositiveDurationTicks,
                _fractionToTicks(effDuration),
              );

              if (element is NoteElement) {
                final noteStartTick = mStartTick + voiceOffsetTicks;
                final velocity =
                    (element.velocity ??
                            CrispScoreMapperConstants.defaultImportedVelocity)
                        .clamp(
                          MuseConstants.minMidiVelocity,
                          MuseConstants.maxMidiVelocity,
                        );
                final pitchEntries = <(int, NoteId)>[];

                for (final pitch in element.pitches) {
                  final noteId = NoteId(_uuid.v7());
                  final midi = pitch.midiNumber.clamp(
                    MuseConstants.minMidiPitch,
                    MuseConstants.maxMidiPitch,
                  );
                  notes.add(
                    TimelineNote(
                      noteId: noteId,
                      projectId: projectId,
                      partId: partId,
                      staffNumber: staffNumber,
                      voiceNumber: vIdx + 1,
                      pitchMidi: midi,
                      enharmonicStep: _fromCrispStep(pitch.step),
                      enharmonicAlter: pitch.alter.clamp(
                        CrispScoreMapperConstants.minEnharmonicAlter,
                        CrispScoreMapperConstants.maxEnharmonicAlter,
                      ),
                      rawStartTick: Tick(noteStartTick),
                      rawDurationTicks: durationTicks,
                      quantizedStartTick: Tick(noteStartTick),
                      quantizedDurationTicks: durationTicks,
                      velocity: velocity,
                      updatedAtMs: nowMs,
                    ),
                  );
                  pitchEntries.add((midi, noteId));
                }

                if (element.id != null && pitchEntries.isNotEmpty) {
                  var lowestEntry = pitchEntries.first;
                  for (var i = 1; i < pitchEntries.length; i++) {
                    if (pitchEntries[i].$1 < lowestEntry.$1) {
                      lowestEntry = pitchEntries[i];
                    }
                  }
                  elementIdToPrimaryNoteId[element.id!] = lowestEntry.$2;
                }
                voiceNoteChain[vIdx].add((
                  elementId: element.id,
                  tieToNext: element.tieToNext,
                  pitches: pitchEntries,
                ));
              } else {
                voiceNoteChain[vIdx].add(null);
              }

              voiceOffsetTicks += durationTicks;
            }
          }
        }

        // Convert NoteElement.tieToNext into NoteSpannerEntity(SpannerType.tie).
        for (
          var vIdx = 0;
          vIdx < CrispScoreMapperConstants.maxVoiceNumber;
          vIdx++
        ) {
          final chain = voiceNoteChain[vIdx];
          for (var i = 0; i + 1 < chain.length; i++) {
            final current = chain[i];
            if (current == null || !current.tieToNext) continue;
            final next = chain[i + 1];
            if (next == null) continue;
            for (final (midi, startNoteId) in current.pitches) {
              NoteId? matchingEnd;
              for (final (nextMidi, endNoteId) in next.pitches) {
                if (nextMidi == midi) {
                  matchingEnd = endNoteId;
                  break;
                }
              }
              if (matchingEnd != null) {
                spanners.add(
                  NoteSpannerEntity(
                    spannerId: SpannerId(_uuid.v7()),
                    projectId: projectId,
                    partId: partId,
                    spannerType: SpannerType.tie,
                    startNoteId: startNoteId,
                    endNoteId: matchingEnd,
                    spannerLevel:
                        CrispScoreMapperConstants.defaultTieOrBeamLevel,
                    placement: SpannerPlacement.auto,
                    updatedAtMs: nowMs,
                  ),
                );
              }
            }
          }
        }

        // Convert Slur, BeamSpan, and CrossMeasureBeam into NoteSpannerEntity rows.
        for (final slur in staffScore.slurs) {
          final startId = elementIdToPrimaryNoteId[slur.startId];
          final endId = elementIdToPrimaryNoteId[slur.endId];
          if (startId == null || endId == null) continue;
          spanners.add(
            NoteSpannerEntity(
              spannerId: SpannerId(_uuid.v7()),
              projectId: projectId,
              partId: partId,
              spannerType: SpannerType.slur,
              startNoteId: startId,
              endNoteId: endId,
              spannerLevel: CrispScoreMapperConstants.defaultTieOrBeamLevel,
              placement: fromCrispSlurPlacement(slur.placement),
              updatedAtMs: nowMs,
            ),
          );
        }

        for (final beam in staffScore.beamSpans) {
          final startId = elementIdToPrimaryNoteId[beam.startId];
          final endId = elementIdToPrimaryNoteId[beam.endId];
          if (startId == null || endId == null) continue;
          spanners.add(
            NoteSpannerEntity(
              spannerId: SpannerId(_uuid.v7()),
              projectId: projectId,
              partId: partId,
              spannerType: SpannerType.beam,
              startNoteId: startId,
              endNoteId: endId,
              spannerLevel: CrispScoreMapperConstants.defaultTieOrBeamLevel,
              placement: SpannerPlacement.auto,
              updatedAtMs: nowMs,
            ),
          );
        }

        for (final beam in staffScore.crossMeasureBeams) {
          final startId = elementIdToPrimaryNoteId[beam.startId];
          final endId = elementIdToPrimaryNoteId[beam.endId];
          if (startId == null || endId == null) continue;
          spanners.add(
            NoteSpannerEntity(
              spannerId: SpannerId(_uuid.v7()),
              projectId: projectId,
              partId: partId,
              spannerType: SpannerType.beam,
              startNoteId: startId,
              endNoteId: endId,
              spannerLevel: CrispScoreMapperConstants.defaultTieOrBeamLevel,
              placement: SpannerPlacement.auto,
              updatedAtMs: nowMs,
            ),
          );
        }
      }
    }

    final project = ProjectSummary(
      projectId: projectId,
      title: title,
      ppqn: MuseConstants.ppqn,
      gridSnapTicks: CrispScoreMapperConstants.minGridSnapTicks,
      pickupTicks: pickupTicks,
      playbackTimingMode: PlaybackTimingMode.quantized,
      revision: CrispScoreMapperConstants.initialRevision,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
    );

    return Ok<ProjectWorkspaceAggregate>(
      ProjectWorkspaceAggregate(
        project: project,
        parts: List<ProjectPartEntity>.unmodifiable(parts),
        tempoEvents: List<TempoEventEntity>.unmodifiable(tempoEvents),
        timeSignatureEvents: List<TimeSignatureEventEntity>.unmodifiable(
          timeSignatureEvents,
        ),
        keySignatureEvents: List<KeySignatureEventEntity>.unmodifiable(
          keySignatureEvents,
        ),
        clefEvents: List<ClefEventEntity>.unmodifiable(clefEvents),
        notes: List<TimelineNote>.unmodifiable(notes),
        spanners: List<NoteSpannerEntity>.unmodifiable(spanners),
        audioTakes: const <AudioTakeEntity>[],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bidirectional Clef, Pitch, Tempo, Placement Helpers
  // ---------------------------------------------------------------------------

  static Clef toCrispClef({
    required ClefSign sign,
    required int line,
    required int octaveChange,
  }) {
    return switch (sign) {
      ClefSign.G =>
        octaveChange > CrispScoreMapperConstants.defaultClefOctaveChange
            ? Clef.treble8va
            : octaveChange < CrispScoreMapperConstants.defaultClefOctaveChange
            ? Clef.treble8vb
            : line == CrispScoreMapperConstants.frenchViolinClefLine
            ? Clef.frenchViolin
            : Clef.treble,
      ClefSign.F =>
        line == CrispScoreMapperConstants.subbassClefLine
            ? Clef.subbass
            : line == CrispScoreMapperConstants.baritoneFClefLine
            ? Clef.baritone
            : octaveChange < CrispScoreMapperConstants.defaultClefOctaveChange
            ? Clef.bass8vb
            : Clef.bass,
      ClefSign.C =>
        line == CrispScoreMapperConstants.sopranoClefLine
            ? Clef.soprano
            : line == CrispScoreMapperConstants.mezzoSopranoClefLine
            ? Clef.mezzoSoprano
            : line == CrispScoreMapperConstants.tenorClefLine
            ? Clef.tenor
            : Clef.alto,
      ClefSign.percussion => Clef.percussion,
      ClefSign.tab => Clef.treble8vb,
      ClefSign.none => Clef.treble,
    };
  }

  static ({ClefSign sign, int line, int octaveChange}) fromCrispClef(
    Clef clef,
  ) {
    return switch (clef) {
      Clef.treble => (
        sign: ClefSign.G,
        line: CrispScoreMapperConstants.trebleClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
      Clef.treble8va => (
        sign: ClefSign.G,
        line: CrispScoreMapperConstants.trebleClefLine,
        octaveChange: CrispScoreMapperConstants.octaveUpClefChange,
      ),
      Clef.treble8vb => (
        sign: ClefSign.G,
        line: CrispScoreMapperConstants.trebleClefLine,
        octaveChange: CrispScoreMapperConstants.octaveDownClefChange,
      ),
      Clef.frenchViolin => (
        sign: ClefSign.G,
        line: CrispScoreMapperConstants.frenchViolinClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
      Clef.bass => (
        sign: ClefSign.F,
        line: CrispScoreMapperConstants.bassClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
      Clef.bass8vb => (
        sign: ClefSign.F,
        line: CrispScoreMapperConstants.bassClefLine,
        octaveChange: CrispScoreMapperConstants.octaveDownClefChange,
      ),
      Clef.baritone => (
        sign: ClefSign.F,
        line: CrispScoreMapperConstants.baritoneFClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
      Clef.subbass => (
        sign: ClefSign.F,
        line: CrispScoreMapperConstants.subbassClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
      Clef.alto => (
        sign: ClefSign.C,
        line: CrispScoreMapperConstants.altoClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
      Clef.tenor => (
        sign: ClefSign.C,
        line: CrispScoreMapperConstants.tenorClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
      Clef.soprano => (
        sign: ClefSign.C,
        line: CrispScoreMapperConstants.sopranoClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
      Clef.mezzoSoprano => (
        sign: ClefSign.C,
        line: CrispScoreMapperConstants.mezzoSopranoClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
      Clef.percussion => (
        sign: ClefSign.percussion,
        line: CrispScoreMapperConstants.percussionClefLine,
        octaveChange: CrispScoreMapperConstants.defaultClefOctaveChange,
      ),
    };
  }

  static SlurPlacement toCrispSlurPlacement(SpannerPlacement placement) {
    return switch (placement) {
      SpannerPlacement.auto => SlurPlacement.auto,
      SpannerPlacement.above => SlurPlacement.above,
      SpannerPlacement.below => SlurPlacement.below,
    };
  }

  static SpannerPlacement fromCrispSlurPlacement(SlurPlacement placement) {
    return switch (placement) {
      SlurPlacement.auto => SpannerPlacement.auto,
      SlurPlacement.above => SpannerPlacement.above,
      SlurPlacement.below => SpannerPlacement.below,
    };
  }

  static Clef _defaultClefForPartStaff(
    ProjectPartEntity part,
    int staffNumber,
  ) {
    if (part.midiChannel == MuseConstants.gmPercussionChannel) {
      return Clef.percussion;
    }
    if (part.stavesCount == CrispScoreMapperConstants.grandStaffCount &&
        staffNumber == CrispScoreMapperConstants.lowerGrandStaffNumber) {
      return Clef.bass;
    }
    return Clef.treble;
  }

  static Step _toCrispStep(EnharmonicStep step) => switch (step) {
    EnharmonicStep.C => Step.c,
    EnharmonicStep.D => Step.d,
    EnharmonicStep.E => Step.e,
    EnharmonicStep.F => Step.f,
    EnharmonicStep.G => Step.g,
    EnharmonicStep.A => Step.a,
    EnharmonicStep.B => Step.b,
  };

  static EnharmonicStep _fromCrispStep(Step step) => switch (step) {
    Step.c => EnharmonicStep.C,
    Step.d => EnharmonicStep.D,
    Step.e => EnharmonicStep.E,
    Step.f => EnharmonicStep.F,
    Step.g => EnharmonicStep.G,
    Step.a => EnharmonicStep.A,
    Step.b => EnharmonicStep.B,
  };

  static Pitch _noteToCrispPitch(TimelineNote note) {
    final step = _toCrispStep(note.enharmonicStep);
    final alter = note.enharmonicAlter.clamp(
      CrispScoreMapperConstants.minEnharmonicAlter,
      CrispScoreMapperConstants.maxEnharmonicAlter,
    );
    final shifted = note.pitchMidi - step.semitonesFromC - alter;
    if (shifted % CrispScoreMapperConstants.semitonesPerOctave == 0) {
      final octave =
          (shifted ~/ CrispScoreMapperConstants.semitonesPerOctave) -
          CrispScoreMapperConstants.midiOctaveOffset;
      return Pitch(step, alter: alter, octave: octave);
    }
    return Pitch.fromMidi(
      note.pitchMidi.clamp(
        MuseConstants.minMidiPitch,
        MuseConstants.maxMidiPitch,
      ),
    );
  }

  static Tempo _tempoEntityToCrispTempo(TempoEventEntity event) {
    final bpm =
        CrispScoreMapperConstants.microsecondsPerMinute / event.usPerQuarter;
    return Tempo(bpm);
  }

  static int _crispTempoToUsPerQuarter(Tempo tempo) {
    final bpm = tempo.quarterBpm;
    if (!bpm.isFinite || bpm <= 0) {
      return CrispScoreMapperConstants.defaultInitialUsPerQuarter;
    }
    return math.max(
      CrispScoreMapperConstants.minTempoUsPerQuarter,
      (CrispScoreMapperConstants.microsecondsPerMinute / bpm).round(),
    );
  }

  static int _fractionToTicks(Fraction fraction) {
    return ((fraction.numerator * MuseConstants.wholeNoteTicks) /
            fraction.denominator)
        .round();
  }

  // ---------------------------------------------------------------------------
  // Internal Timeline, Grouping, Rhythmic Decomposition & Rest Synthesis
  // ---------------------------------------------------------------------------

  static List<TempoEventEntity> _sortedTempos(List<TempoEventEntity> events) =>
      List<TempoEventEntity>.from(events)
        ..sort((a, b) => a.tick.value.compareTo(b.tick.value));

  static List<TimeSignatureEventEntity> _sortedTimeSigs(
    List<TimeSignatureEventEntity> events,
  ) => List<TimeSignatureEventEntity>.from(events)
    ..sort((a, b) => a.tick.value.compareTo(b.tick.value));

  static KeySignatureEventEntity? _resolveKeySignatureAtTick(
    List<KeySignatureEventEntity> events, {
    required PartId partId,
    required int staffNumber,
    required int tick,
    bool exactTickOnly = false,
  }) {
    bool matchesTick(KeySignatureEventEntity e) =>
        exactTickOnly ? e.tick.value == tick : e.tick.value <= tick;

    KeySignatureEventEntity? best;
    var bestPriority = CrispScoreMapperConstants.keyResolutionUnassignedPriority;
    for (final e in events) {
      if (!matchesTick(e)) continue;
      final int priority;
      if (e.partId == partId && e.staffNumber == staffNumber) {
        priority = CrispScoreMapperConstants.keyResolutionExactStaffPriority;
      } else if (e.partId == partId &&
          e.staffNumber ==
              CrispScoreMapperConstants.allStavesKeySigStaffNumber) {
        priority = CrispScoreMapperConstants.keyResolutionPartAllStavesPriority;
      } else if (e.partId == null) {
        priority = CrispScoreMapperConstants.keyResolutionGlobalPriority;
      } else {
        continue;
      }

      if (best == null ||
          e.tick.value > best.tick.value ||
          (e.tick.value == best.tick.value && priority >= bestPriority)) {
        best = e;
        bestPriority = priority;
      }
    }
    return best;
  }

  static List<_MeasureSpan> _computeMeasureSpans(
    ProjectWorkspaceAggregate aggregate,
    TempoTimelineCalculator calculator,
  ) {
    var maxExclusiveEndTick = aggregate.project.pickupTicks;
    for (final n in aggregate.notes) {
      maxExclusiveEndTick = math.max(
        maxExclusiveEndTick,
        n.quantizedStartTick.value + n.quantizedDurationTicks,
      );
    }

    var maxInclusivePointTick = CrispScoreMapperConstants.zeroTick;
    for (final e in aggregate.tempoEvents) {
      maxInclusivePointTick = math.max(maxInclusivePointTick, e.tick.value);
    }
    for (final e in aggregate.timeSignatureEvents) {
      maxInclusivePointTick = math.max(maxInclusivePointTick, e.tick.value);
    }
    for (final e in aggregate.keySignatureEvents) {
      maxInclusivePointTick = math.max(maxInclusivePointTick, e.tick.value);
    }
    for (final e in aggregate.clefEvents) {
      maxInclusivePointTick = math.max(maxInclusivePointTick, e.tick.value);
    }

    final sortedTimeSigs = _sortedTimeSigs(aggregate.timeSignatureEvents);
    final queryEnd = math.max(
      maxInclusivePointTick,
      maxExclusiveEndTick -
          CrispScoreMapperConstants.exclusiveEndAdjustmentTicks,
    );
    final barlines = calculator
        .queryVisibleGridLines(
          startTick: const Tick(CrispScoreMapperConstants.zeroTick),
          endTick: Tick(queryEnd),
          subdivisionTicks: const Tick(MuseConstants.wholeNoteTicks),
        )
        .where((line) => line.isBarline)
        .toList();

    final spans = <_MeasureSpan>[];
    for (var i = 0; i < barlines.length; i++) {
      final line = barlines[i];
      final startTick = line.tick.value;
      final activeTs = _activeTimeSigAt(sortedTimeSigs, startTick);
      final isPickup =
          line.measureNumber == TempoTimelineCalculator.pickupMeasureNumber;
      final int endTick;
      if (i + 1 < barlines.length) {
        endTick = barlines[i + 1].tick.value;
      } else if (isPickup) {
        endTick = aggregate.project.pickupTicks;
      } else {
        endTick =
            startTick +
            ((activeTs.numerator * MuseConstants.wholeNoteTicks) ~/
                activeTs.denominator);
      }
      spans.add(
        _MeasureSpan(
          index: i,
          measureNumber: line.measureNumber,
          startTick: startTick,
          endTick: endTick,
          isPickup: isPickup,
          timeSignature: TimeSignature(
            activeTs.numerator,
            activeTs.denominator,
          ),
        ),
      );
    }
    return spans;
  }

  static TimeSignatureEventEntity _activeTimeSigAt(
    List<TimeSignatureEventEntity> sortedTimeSigs,
    int tick,
  ) {
    var active = sortedTimeSigs.first;
    for (final ts in sortedTimeSigs) {
      if (ts.tick.value <= tick) {
        active = ts;
      } else {
        break;
      }
    }
    return active;
  }

  static List<List<_ChordBucket>> _groupNotesIntoChordBuckets(
    List<TimelineNote> staffNotes,
  ) {
    final byVoice = List<Map<(int, int), List<TimelineNote>>>.generate(
      CrispScoreMapperConstants.maxVoiceNumber,
      (_) => <(int, int), List<TimelineNote>>{},
    );

    for (final note in staffNotes) {
      final vIdx =
          note.voiceNumber.clamp(
            CrispScoreMapperConstants.minVoiceNumber,
            CrispScoreMapperConstants.maxVoiceNumber,
          ) -
          1;
      final key = (note.quantizedStartTick.value, note.quantizedDurationTicks);
      byVoice[vIdx].putIfAbsent(key, () => <TimelineNote>[]).add(note);
    }

    return List<List<_ChordBucket>>.generate(
      CrispScoreMapperConstants.maxVoiceNumber,
      (vIdx) {
        final buckets = <_ChordBucket>[];
        for (final entry in byVoice[vIdx].entries) {
          final sortedChordNotes = List<TimelineNote>.from(entry.value)
            ..sort((a, b) {
              final byPitch = a.pitchMidi.compareTo(b.pitchMidi);
              if (byPitch != 0) return byPitch;
              final byStep = a.enharmonicStep.index.compareTo(
                b.enharmonicStep.index,
              );
              if (byStep != 0) return byStep;
              final byAlter = a.enharmonicAlter.compareTo(b.enharmonicAlter);
              if (byAlter != 0) return byAlter;
              return a.noteId.value.compareTo(b.noteId.value);
            });
          buckets.add(
            _ChordBucket(
              startTick: entry.key.$1,
              durationTicks: entry.key.$2,
              notes: sortedChordNotes,
            ),
          );
        }
        buckets.sort((a, b) {
          final byStart = a.startTick.compareTo(b.startTick);
          if (byStart != 0) return byStart;
          final byDur = a.durationTicks.compareTo(b.durationTicks);
          if (byDur != 0) return byDur;
          return a.anchorId.compareTo(b.anchorId);
        });
        return buckets;
      },
    );
  }

  static int _findMeasureIndexContaining(
    List<_MeasureSpan> spans,
    int tickValue,
  ) {
    var low = 0;
    var high = spans.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = (low + high) >>> 1;
      if (spans[mid].startTick <= tickValue) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  static int _pickNonOverlappingVoice(
    List<_MutableVoiceBar> voices, {
    required int preferredVoiceIdx,
    required int segStartTick,
  }) {
    if (voices[preferredVoiceIdx].cursorTick <= segStartTick) {
      return preferredVoiceIdx;
    }
    for (var v = 0; v < voices.length; v++) {
      if (voices[v].cursorTick <= segStartTick) {
        return v;
      }
    }
    return preferredVoiceIdx;
  }

  static void _appendRestGap(
    _MutableVoiceBar voiceBar,
    int gapTicks, {
    required bool allowSubMinRest,
  }) {
    if (gapTicks <= CrispScoreMapperConstants.zeroTick) return;
    if (!allowSubMinRest &&
        gapTicks < CrispScoreMapperConstants.minDecomposableTicks) {
      return;
    }
    final pieces = _decomposeDuration(gapTicks);
    var emittedTicks = CrispScoreMapperConstants.zeroTick;
    for (final piece in pieces) {
      emittedTicks += piece.soundingTicks;
      voiceBar.elements.add(RestElement(piece.duration));
      voiceBar.isTripletElement.add(piece.isTriplet);
      voiceBar.elementSoundingTicks.add(piece.soundingTicks);
    }
    voiceBar.cursorTick += emittedTicks;
  }

  static List<MusicElement> _synthesizeRestElements(int gapTicks) {
    if (gapTicks <= CrispScoreMapperConstants.zeroTick) {
      return const <MusicElement>[];
    }
    final pieces = _decomposeDuration(gapTicks);
    return List<MusicElement>.unmodifiable(<MusicElement>[
      for (final p in pieces) RestElement(p.duration),
    ]);
  }

  static List<_RhythmicPiece> _decomposeDuration(int totalTicks) {
    final result = <_RhythmicPiece>[];
    var remaining = totalTicks;

    // Only peel triplets when remaining sits cleanly on the 40-tick triplet grid
    // so non-grid durations never generate malformed partial tuplet groups.
    if (remaining % CrispScoreMapperConstants.minDecomposableTicks != 0 &&
        remaining % CrispScoreMapperConstants.minTripletDecomposableTicks ==
            0) {
      for (final (tripletTicks, base) in _tripletTable) {
        while (remaining >= tripletTicks &&
            remaining % CrispScoreMapperConstants.minDecomposableTicks != 0) {
          result.add(
            _RhythmicPiece(
              duration: NoteDuration(base),
              isTriplet: true,
              soundingTicks: tripletTicks,
            ),
          );
          remaining -= tripletTicks;
        }
      }
    }

    for (final (straightTicks, base, dots) in _straightAndDottedTable) {
      while (remaining >= straightTicks) {
        result.add(
          _RhythmicPiece(
            duration: NoteDuration(base, dots: dots),
            isTriplet: false,
            soundingTicks: straightTicks,
          ),
        );
        remaining -= straightTicks;
      }
    }

    if (result.isEmpty && remaining > 0) {
      result.add(
        const _RhythmicPiece(
          duration: NoteDuration(DurationBase.twoHundredFiftySixth),
          isTriplet: false,
          soundingTicks: CrispScoreMapperConstants.minDecomposableTicks,
        ),
      );
    }
    return result;
  }

  static List<TupletSpan> _extractTripletSpans(
    _MutableVoiceBar voiceBar, {
    required int voiceIndex,
  }) {
    final spans = <TupletSpan>[];
    int? runStart;
    var runTicks = 0;

    void flushRun(int endIndex) {
      if (runStart == null) return;
      spans.add(
        TupletSpan(
          runStart!,
          endIndex,
          actual: CrispScoreMapperConstants.tripletActualNotes,
          normal: CrispScoreMapperConstants.tripletNormalNotes,
          voice: voiceIndex,
        ),
      );
      runStart = null;
      runTicks = 0;
    }

    for (var i = 0; i < voiceBar.elements.length; i++) {
      if (voiceBar.isTripletElement[i]) {
        runStart ??= i;
        runTicks += voiceBar.elementSoundingTicks[i];
        // Close once the triplet group's sounding ticks complete a standard power-of-two unit.
        if (runTicks > CrispScoreMapperConstants.zeroTick &&
            runTicks % CrispScoreMapperConstants.minDecomposableTicks ==
                CrispScoreMapperConstants.zeroTick &&
            _isPowerOfTwo(
              runTicks ~/ CrispScoreMapperConstants.minDecomposableTicks,
            )) {
          flushRun(i);
        }
      } else {
        flushRun(i - 1);
      }
    }
    flushRun(voiceBar.elements.length - 1);
    return spans;
  }

  static bool _isPowerOfTwo(int value) =>
      value > 0 && (value & (value - 1)) == 0;

  static String _decodeXmlBytes(Uint8List bytes) {
    if (bytes.length >= CrispScoreMapperConstants.utf16CodeUnitByteCount) {
      final isBe =
          bytes[0] == CrispScoreMapperConstants.utf16BomBigEndianByte0 &&
          bytes[1] == CrispScoreMapperConstants.utf16BomBigEndianByte1;
      final isLe =
          bytes[0] == CrispScoreMapperConstants.utf16BomLittleEndianByte0 &&
          bytes[1] == CrispScoreMapperConstants.utf16BomLittleEndianByte1;
      if (isBe || isLe) {
        final units = <int>[];
        for (
          var i = CrispScoreMapperConstants.utf16CodeUnitByteCount;
          i + 1 < bytes.length;
          i += CrispScoreMapperConstants.utf16CodeUnitByteCount
        ) {
          units.add(
            isBe
                ? (bytes[i] << 8) | bytes[i + 1]
                : (bytes[i + 1] << 8) | bytes[i],
          );
        }
        return String.fromCharCodes(units);
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return String.fromCharCodes(bytes);
    }
  }
}

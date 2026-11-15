/// Pure Dart segment-wise integer timeline calculator (`960 PPQN` <-> sample frames).
library;

import 'dart:math' as math;

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../models/score_models.dart';

/// Immutable bar, beat, or rhythmic subdivision grid line for notation and Piano Roll.
final class BarBeatGridLine {
  final Tick tick;

  /// `0` for pickup (anacrusis) when `pickupTicks > 0`; `1+` for full measures.
  final int measureNumber;
  final int beatIndex;
  final bool isBarline;
  final bool isBeatLine;

  const BarBeatGridLine({
    required this.tick,
    required this.measureNumber,
    required this.beatIndex,
    required this.isBarline,
    required this.isBeatLine,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BarBeatGridLine &&
          tick.value == other.tick.value &&
          measureNumber == other.measureNumber &&
          beatIndex == other.beatIndex &&
          isBarline == other.isBarline &&
          isBeatLine == other.isBeatLine;

  @override
  int get hashCode =>
      Object.hash(tick.value, measureNumber, beatIndex, isBarline, isBeatLine);

  @override
  String toString() =>
      'BarBeatGridLine(tick: ${tick.value}, measure: $measureNumber, '
      'beat: $beatIndex, barline: $isBarline, beatLine: $isBeatLine)';
}

/// Immutable bar-beat-tick breakdown for any non-negative timeline tick.
final class BarBeatTickPosition {
  /// `0` for pickup (anacrusis) when `pickupTicks > 0`; `1+` for full measures.
  final int measureNumber;

  /// Zero-based beat index within the measure.
  final int beatIndex;

  /// Remainder ticks within the current beat (`>= 0`).
  final int tickInBeat;

  /// Remainder ticks from [measureStartTick] (`0 <= tickInMeasure < measureDurationTicks`).
  final int tickInMeasure;

  /// Timeline start tick of the containing measure.
  final Tick measureStartTick;

  /// Total duration in ticks of the containing measure.
  final int measureDurationTicks;

  const BarBeatTickPosition({
    required this.measureNumber,
    required this.beatIndex,
    required this.tickInBeat,
    required this.tickInMeasure,
    required this.measureStartTick,
    required this.measureDurationTicks,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BarBeatTickPosition &&
          measureNumber == other.measureNumber &&
          beatIndex == other.beatIndex &&
          tickInBeat == other.tickInBeat &&
          tickInMeasure == other.tickInMeasure &&
          measureStartTick.value == other.measureStartTick.value &&
          measureDurationTicks == other.measureDurationTicks;

  @override
  int get hashCode => Object.hash(
    measureNumber,
    beatIndex,
    tickInBeat,
    tickInMeasure,
    measureStartTick.value,
    measureDurationTicks,
  );
}

/// Pure Dart contract for exact integer tick/sample-frame math and bar/beat queries.
abstract interface class ITempoTimelineCalculator {
  SampleFrame tickToSampleFrame(Tick tick, {required int sampleRate});

  Tick sampleFrameToTick(SampleFrame frame, {required int sampleRate});

  Tick quantizeTick(Tick rawTick, {required Tick snapSubdivisionTicks});

  Tick computeLatencyCompensatedStartTick({
    required SampleFrame capturedPlayheadFrame,
    required int outputBufferFrames,
    required int inputBufferFrames,
    required int calibrationOffsetFrames,
    required int sampleRate,
  });

  List<BarBeatGridLine> queryVisibleGridLines({
    required Tick startTick,
    required Tick endTick,
    required Tick subdivisionTicks,
  });

  BarBeatTickPosition tickToBarBeatTick(Tick tick);
}

final class _TempoSegment {
  final int startTick;
  final int usPerQuarter;

  const _TempoSegment({required this.startTick, required this.usPerQuarter});
}

final class _MeterSpan {
  final int startTick;
  final int? endTickExclusive;
  final int startMeasureNumber;
  final int measureDurationTicks;
  final int beatTicks;

  const _MeterSpan({
    required this.startTick,
    required this.endTickExclusive,
    required this.startMeasureNumber,
    required this.measureDurationTicks,
    required this.beatTicks,
  });
}

/// Exact `BigInt`-backed segment-wise timeline calculator for `960 PPQN` scores.
final class TempoTimelineCalculator implements ITempoTimelineCalculator {
  static const int minTick = 0;
  static const int minFrame = 0;
  static const int microsecondsPerSecond = 1000000;
  static const int ticksPerSecondDenominator =
      MuseConstants.ppqn * microsecondsPerSecond;
  static const int pickupMeasureNumber = 0;
  static const int firstFullMeasureNumber = 1;
  static const int firstBeatIndex = 0;
  static const int minValidTimeSigNumerator = 1;
  static const Set<int> validTimeSigDenominators = {1, 2, 4, 8, 16, 32, 64};

  static const int _initialMapTick = 0;
  static const int _measureOriginOffset = 0;
  static const int _minSampleRate = 1;
  static const int _minUsPerQuarter = 1;
  static const int _minSubdivisionTicks = 1;
  static const int _minBufferFrames = 0;
  static const int _halfRoundDivisor = 2;
  static const int _singleElementStep = 1;

  static final BigInt _bigTicksPerSecondDenominator = BigInt.from(
    ticksPerSecondDenominator,
  );
  static final BigInt _bigOne = BigInt.one;

  final int pickupTicks;
  final List<_TempoSegment> _tempoSegments;
  final List<_MeterSpan> _meterSpans;
  final _MeterSpan? _pickupMeterSpan;
  final Map<int, List<int>> _segmentStartFramesBySampleRate =
      <int, List<int>>{};

  factory TempoTimelineCalculator({
    required List<TempoEventEntity> tempoEvents,
    required List<TimeSignatureEventEntity> timeSignatureEvents,
    int pickupTicks = MuseConstants.defaultPickupTicks,
  }) {
    final validatedPickupTicks = _validatePickupTicks(pickupTicks);
    final tempoSegments = _buildTempoSegments(tempoEvents);
    final sortedTimeSigs = _validateAndSortTimeSignatures(timeSignatureEvents);
    return TempoTimelineCalculator._(
      validatedPickupTicks,
      tempoSegments,
      validatedPickupTicks > minTick
          ? _buildPickupMeterSpanFromSorted(
              sortedTimeSigs,
              validatedPickupTicks,
            )
          : null,
      _buildMeterSpansFromSorted(
        sortedTimeSigs,
        validatedPickupTicks,
      ),
    );
  }

  TempoTimelineCalculator._(
    this.pickupTicks,
    this._tempoSegments,
    this._pickupMeterSpan,
    this._meterSpans,
  );

  static int _validatePickupTicks(int pickupTicks) {
    if (pickupTicks < minTick) {
      throw ArgumentError.value(
        pickupTicks,
        'pickupTicks',
        'Must be >= $minTick',
      );
    }
    return pickupTicks;
  }

  static List<_TempoSegment> _buildTempoSegments(
    List<TempoEventEntity> tempoEvents,
  ) {
    if (tempoEvents.isEmpty) {
      throw ArgumentError.value(
        tempoEvents,
        'tempoEvents',
        'Must contain at least an initial tempo event at tick $_initialMapTick',
      );
    }

    final sorted = List<TempoEventEntity>.from(tempoEvents)
      ..sort((a, b) => a.tick.value.compareTo(b.tick.value));

    if (sorted.first.tick.value != _initialMapTick) {
      throw ArgumentError.value(
        sorted.first.tick.value,
        'tempoEvents',
        'Initial tempo event must occur at tick $_initialMapTick',
      );
    }

    final segments = <_TempoSegment>[];
    for (var i = 0; i < sorted.length; i++) {
      final event = sorted[i];
      if (event.tick.value < minTick) {
        throw ArgumentError.value(
          event.tick.value,
          'tempoEvents[$i].tick',
          'Must be >= $minTick',
        );
      }
      if (event.usPerQuarter < _minUsPerQuarter) {
        throw ArgumentError.value(
          event.usPerQuarter,
          'tempoEvents[$i].usPerQuarter',
          'Must be >= $_minUsPerQuarter',
        );
      }
      if (i > 0 && event.tick.value == sorted[i - 1].tick.value) {
        throw ArgumentError.value(
          event.tick.value,
          'tempoEvents[$i].tick',
          'Duplicate tempo event tick',
        );
      }
      segments.add(
        _TempoSegment(
          startTick: event.tick.value,
          usPerQuarter: event.usPerQuarter,
        ),
      );
    }
    return List<_TempoSegment>.unmodifiable(segments);
  }

  static List<TimeSignatureEventEntity> _validateAndSortTimeSignatures(
    List<TimeSignatureEventEntity> timeSignatureEvents,
  ) {
    if (timeSignatureEvents.isEmpty) {
      throw ArgumentError.value(
        timeSignatureEvents,
        'timeSignatureEvents',
        'Must contain at least an initial time signature event at tick $_initialMapTick',
      );
    }

    final sorted = List<TimeSignatureEventEntity>.from(timeSignatureEvents)
      ..sort((a, b) => a.tick.value.compareTo(b.tick.value));

    if (sorted.first.tick.value != _initialMapTick) {
      throw ArgumentError.value(
        sorted.first.tick.value,
        'timeSignatureEvents',
        'Initial time signature event must occur at tick $_initialMapTick',
      );
    }

    for (var i = 0; i < sorted.length; i++) {
      final event = sorted[i];
      if (event.tick.value < minTick) {
        throw ArgumentError.value(
          event.tick.value,
          'timeSignatureEvents[$i].tick',
          'Must be >= $minTick',
        );
      }
      if (event.numerator < minValidTimeSigNumerator) {
        throw ArgumentError.value(
          event.numerator,
          'timeSignatureEvents[$i].numerator',
          'Must be >= $minValidTimeSigNumerator',
        );
      }
      if (!validTimeSigDenominators.contains(event.denominator)) {
        throw ArgumentError.value(
          event.denominator,
          'timeSignatureEvents[$i].denominator',
          'Must be one of $validTimeSigDenominators',
        );
      }
      if (i > 0 && event.tick.value == sorted[i - 1].tick.value) {
        throw ArgumentError.value(
          event.tick.value,
          'timeSignatureEvents[$i].tick',
          'Duplicate time signature event tick',
        );
      }
    }
    return sorted;
  }

  static _MeterSpan _buildPickupMeterSpanFromSorted(
    List<TimeSignatureEventEntity> sorted,
    int pickupTicks,
  ) {
    final initialTs = sorted.first;
    final beatTicks = MuseConstants.wholeNoteTicks ~/ initialTs.denominator;
    return _MeterSpan(
      startTick: _initialMapTick,
      endTickExclusive: pickupTicks,
      startMeasureNumber: pickupMeasureNumber,
      measureDurationTicks: pickupTicks,
      beatTicks: beatTicks,
    );
  }

  static List<_MeterSpan> _buildMeterSpansFromSorted(
    List<TimeSignatureEventEntity> sorted,
    int pickupTicks,
  ) {
    final spans = <_MeterSpan>[];

    var currentTick = pickupTicks;
    var currentMeasure = firstFullMeasureNumber;

    // Advance to the latest time signature effective at or before Measure 1.
    var tsIndex = 0;
    while (tsIndex + _singleElementStep < sorted.length &&
        sorted[tsIndex + _singleElementStep].tick.value <= currentTick) {
      tsIndex++;
    }

    while (true) {
      final activeTs = sorted[tsIndex];
      final measureDurationTicks =
          (activeTs.numerator * MuseConstants.wholeNoteTicks) ~/
          activeTs.denominator;
      final beatTicks = MuseConstants.wholeNoteTicks ~/ activeTs.denominator;

      if (tsIndex + _singleElementStep >= sorted.length) {
        spans.add(
          _MeterSpan(
            startTick: currentTick,
            endTickExclusive: null,
            startMeasureNumber: currentMeasure,
            measureDurationTicks: measureDurationTicks,
            beatTicks: beatTicks,
          ),
        );
        break;
      }

      final nextTsTick = sorted[tsIndex + _singleElementStep].tick.value;
      final deltaToNextTs = nextTsTick - currentTick;
      // Meter changes take effect at the first measure boundary >= nextTsTick.
      final measureCountInSpan =
          (deltaToNextTs + measureDurationTicks - _singleElementStep) ~/
          measureDurationTicks;
      final spanEndTick =
          currentTick + measureCountInSpan * measureDurationTicks;

      if (measureCountInSpan > 0) {
        spans.add(
          _MeterSpan(
            startTick: currentTick,
            endTickExclusive: spanEndTick,
            startMeasureNumber: currentMeasure,
            measureDurationTicks: measureDurationTicks,
            beatTicks: beatTicks,
          ),
        );
        currentMeasure += measureCountInSpan;
        currentTick = spanEndTick;
      }

      while (tsIndex + _singleElementStep < sorted.length &&
          sorted[tsIndex + _singleElementStep].tick.value <= currentTick) {
        tsIndex++;
      }
    }

    return List<_MeterSpan>.unmodifiable(spans);
  }

  static void _validateSampleRate(int sampleRate) {
    if (sampleRate < _minSampleRate) {
      throw ArgumentError.value(
        sampleRate,
        'sampleRate',
        'Must be >= $_minSampleRate',
      );
    }
  }

  List<int> _segmentStartFramesFor(int sampleRate) {
    final cached = _segmentStartFramesBySampleRate[sampleRate];
    if (cached != null) {
      return cached;
    }

    final bigSr = BigInt.from(sampleRate);
    final startFrames = List<int>.filled(_tempoSegments.length, minFrame);
    for (var i = 1; i < _tempoSegments.length; i++) {
      final prev = _tempoSegments[i - 1];
      final curr = _tempoSegments[i];
      final deltaTicks = BigInt.from(curr.startTick - prev.startTick);
      final usPerQuarter = BigInt.from(prev.usPerQuarter);
      final deltaFrames =
          (deltaTicks * usPerQuarter * bigSr) ~/ _bigTicksPerSecondDenominator;
      startFrames[i] = startFrames[i - 1] + deltaFrames.toInt();
    }

    final unmodifiable = List<int>.unmodifiable(startFrames);
    _segmentStartFramesBySampleRate[sampleRate] = unmodifiable;
    return unmodifiable;
  }

  int _findTempoSegmentIndexForTick(int tickValue) {
    var low = 0;
    var high = _tempoSegments.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = (low + high) >>> 1;
      if (_tempoSegments[mid].startTick <= tickValue) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  int _findTempoSegmentIndexForFrame(List<int> segmentStartFrames, int frame) {
    var low = 0;
    var high = segmentStartFrames.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = (low + high) >>> 1;
      if (segmentStartFrames[mid] <= frame) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  int _findMeterSpanIndexForTick(int tickValue) {
    var low = 0;
    var high = _meterSpans.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = (low + high) >>> 1;
      if (_meterSpans[mid].startTick <= tickValue) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  /// Returns `true` when [other] has identical sorted tempo segments
  /// (`startTick` and `usPerQuarter`), so `tickToSampleFrame` and
  /// `sampleFrameToTick` produce identical mappings.
  bool hasEquivalentTempoMap(TempoTimelineCalculator other) {
    if (_tempoSegments.length != other._tempoSegments.length) {
      return false;
    }
    for (var i = 0; i < _tempoSegments.length; i++) {
      final a = _tempoSegments[i];
      final b = other._tempoSegments[i];
      if (a.startTick != b.startTick || a.usPerQuarter != b.usPerQuarter) {
        return false;
      }
    }
    return true;
  }

  @override
  SampleFrame tickToSampleFrame(Tick tick, {required int sampleRate}) {
    if (tick.value < minTick) {
      throw ArgumentError.value(tick.value, 'tick', 'Must be >= $minTick');
    }
    _validateSampleRate(sampleRate);

    final segmentStartFrames = _segmentStartFramesFor(sampleRate);
    final segIdx = _findTempoSegmentIndexForTick(tick.value);
    final seg = _tempoSegments[segIdx];
    final segStartFrame = segmentStartFrames[segIdx];

    final deltaTicks = tick.value - seg.startTick;
    if (deltaTicks == 0) {
      return SampleFrame(segStartFrame);
    }

    final deltaFrames =
        (BigInt.from(deltaTicks) *
            BigInt.from(seg.usPerQuarter) *
            BigInt.from(sampleRate)) ~/
        _bigTicksPerSecondDenominator;
    return SampleFrame(segStartFrame + deltaFrames.toInt());
  }

  @override
  Tick sampleFrameToTick(SampleFrame frame, {required int sampleRate}) {
    if (frame.value < minFrame) {
      throw ArgumentError.value(frame.value, 'frame', 'Must be >= $minFrame');
    }
    _validateSampleRate(sampleRate);

    final segmentStartFrames = _segmentStartFramesFor(sampleRate);
    final segIdx = _findTempoSegmentIndexForFrame(
      segmentStartFrames,
      frame.value,
    );
    final seg = _tempoSegments[segIdx];
    final deltaFrames = frame.value - segmentStartFrames[segIdx];

    // Exact inverse of floor((d * usPerQuarter * sampleRate) / D) <= deltaFrames:
    // d_max = floor(((deltaFrames + 1) * D - 1) / (usPerQuarter * sampleRate)).
    final numerator =
        (BigInt.from(deltaFrames) + _bigOne) * _bigTicksPerSecondDenominator -
        _bigOne;
    final denominator = BigInt.from(seg.usPerQuarter) * BigInt.from(sampleRate);
    final deltaTicks = (numerator ~/ denominator).toInt();

    var resolvedTick = seg.startTick + deltaTicks;
    if (segIdx + _singleElementStep < _tempoSegments.length) {
      final maxTickInSegment =
          _tempoSegments[segIdx + _singleElementStep].startTick -
          _singleElementStep;
      if (resolvedTick > maxTickInSegment) {
        resolvedTick = maxTickInSegment;
      }
    }
    return Tick(resolvedTick);
  }

  @override
  Tick quantizeTick(Tick rawTick, {required Tick snapSubdivisionTicks}) {
    if (rawTick.value < minTick) {
      throw ArgumentError.value(
        rawTick.value,
        'rawTick',
        'Must be >= $minTick',
      );
    }
    if (snapSubdivisionTicks.value < _minSubdivisionTicks) {
      throw ArgumentError.value(
        snapSubdivisionTicks.value,
        'snapSubdivisionTicks',
        'Must be >= $_minSubdivisionTicks',
      );
    }

    final step = snapSubdivisionTicks.value;
    final halfStep = step ~/ _halfRoundDivisor;
    return Tick(((rawTick.value + halfStep) ~/ step) * step);
  }

  @override
  Tick computeLatencyCompensatedStartTick({
    required SampleFrame capturedPlayheadFrame,
    required int outputBufferFrames,
    required int inputBufferFrames,
    required int calibrationOffsetFrames,
    required int sampleRate,
  }) {
    if (capturedPlayheadFrame.value < minFrame) {
      throw ArgumentError.value(
        capturedPlayheadFrame.value,
        'capturedPlayheadFrame',
        'Must be >= $minFrame',
      );
    }
    if (outputBufferFrames < _minBufferFrames) {
      throw ArgumentError.value(
        outputBufferFrames,
        'outputBufferFrames',
        'Must be >= $_minBufferFrames',
      );
    }
    if (inputBufferFrames < _minBufferFrames) {
      throw ArgumentError.value(
        inputBufferFrames,
        'inputBufferFrames',
        'Must be >= $_minBufferFrames',
      );
    }
    _validateSampleRate(sampleRate);

    final totalLatencyFrames =
        outputBufferFrames + inputBufferFrames + calibrationOffsetFrames;
    final compensatedFrame = math.max(
      minFrame,
      capturedPlayheadFrame.value - totalLatencyFrames,
    );
    return sampleFrameToTick(
      SampleFrame(compensatedFrame),
      sampleRate: sampleRate,
    );
  }

  @override
  List<BarBeatGridLine> queryVisibleGridLines({
    required Tick startTick,
    required Tick endTick,
    required Tick subdivisionTicks,
  }) {
    if (startTick.value < minTick) {
      throw ArgumentError.value(
        startTick.value,
        'startTick',
        'Must be >= $minTick',
      );
    }
    if (endTick.value < startTick.value) {
      throw ArgumentError.value(
        endTick.value,
        'endTick',
        'Must be >= startTick (${startTick.value})',
      );
    }
    if (subdivisionTicks.value < _minSubdivisionTicks) {
      throw ArgumentError.value(
        subdivisionTicks.value,
        'subdivisionTicks',
        'Must be >= $_minSubdivisionTicks',
      );
    }

    final lines = <BarBeatGridLine>[];
    final subStep = subdivisionTicks.value;

    final pickupSpan = _pickupMeterSpan;
    if (pickupSpan != null && startTick.value < pickupTicks) {
      _emitMeasureGridLines(
        lines: lines,
        measureStartTick: pickupSpan.startTick,
        measureEndTick: pickupTicks,
        measureNumber: pickupSpan.startMeasureNumber,
        beatTicks: pickupSpan.beatTicks,
        subdivisionStep: subStep,
        queryStartTick: startTick.value,
        queryEndTick: endTick.value,
      );
    }

    if (endTick.value < pickupTicks) {
      return List<BarBeatGridLine>.unmodifiable(lines);
    }

    final fullQueryStart = math.max(startTick.value, pickupTicks);
    var spanIdx = _findMeterSpanIndexForTick(fullQueryStart);

    while (spanIdx < _meterSpans.length) {
      final span = _meterSpans[spanIdx];
      if (span.startTick > endTick.value) {
        break;
      }

      final spanQueryStart = math.max(fullQueryStart, span.startTick);
      final spanEndExclusive = span.endTickExclusive;
      final spanQueryEnd = spanEndExclusive == null
          ? endTick.value
          : math.min(endTick.value, spanEndExclusive - _singleElementStep);

      if (spanQueryStart <= spanQueryEnd) {
        final firstMeasureOffset =
            (spanQueryStart - span.startTick) ~/ span.measureDurationTicks;
        final lastMeasureOffset =
            (spanQueryEnd - span.startTick) ~/ span.measureDurationTicks;

        for (
          var mOffset = firstMeasureOffset;
          mOffset <= lastMeasureOffset;
          mOffset++
        ) {
          final measureStartTick =
              span.startTick + mOffset * span.measureDurationTicks;
          final measureEndTick = measureStartTick + span.measureDurationTicks;
          _emitMeasureGridLines(
            lines: lines,
            measureStartTick: measureStartTick,
            measureEndTick: measureEndTick,
            measureNumber: span.startMeasureNumber + mOffset,
            beatTicks: span.beatTicks,
            subdivisionStep: subStep,
            queryStartTick: startTick.value,
            queryEndTick: endTick.value,
          );
        }
      }

      spanIdx++;
    }

    return List<BarBeatGridLine>.unmodifiable(lines);
  }

  @override
  BarBeatTickPosition tickToBarBeatTick(Tick tick) {
    if (tick.value < minTick) {
      throw ArgumentError.value(tick.value, 'tick', 'Must be >= $minTick');
    }

    final pickupSpan = _pickupMeterSpan;
    if (pickupSpan != null && tick.value < pickupTicks) {
      final tickInMeasure = tick.value - pickupSpan.startTick;
      return BarBeatTickPosition(
        measureNumber: pickupSpan.startMeasureNumber,
        beatIndex: tickInMeasure ~/ pickupSpan.beatTicks,
        tickInBeat: tickInMeasure % pickupSpan.beatTicks,
        tickInMeasure: tickInMeasure,
        measureStartTick: Tick(pickupSpan.startTick),
        measureDurationTicks: pickupSpan.measureDurationTicks,
      );
    }

    final spanIdx = _findMeterSpanIndexForTick(tick.value);
    final span = _meterSpans[spanIdx];
    final deltaFromSpan = tick.value - span.startTick;
    final measureOffset = deltaFromSpan ~/ span.measureDurationTicks;
    final tickInMeasure = deltaFromSpan % span.measureDurationTicks;
    return BarBeatTickPosition(
      measureNumber: span.startMeasureNumber + measureOffset,
      beatIndex: tickInMeasure ~/ span.beatTicks,
      tickInBeat: tickInMeasure % span.beatTicks,
      tickInMeasure: tickInMeasure,
      measureStartTick: Tick(tick.value - tickInMeasure),
      measureDurationTicks: span.measureDurationTicks,
    );
  }

  static void _emitMeasureGridLines({
    required List<BarBeatGridLine> lines,
    required int measureStartTick,
    required int measureEndTick,
    required int measureNumber,
    required int beatTicks,
    required int subdivisionStep,
    required int queryStartTick,
    required int queryEndTick,
  }) {
    final visibleStart = math.max(measureStartTick, queryStartTick);
    final visibleEnd = math.min(
      measureEndTick - _singleElementStep,
      queryEndTick,
    );
    if (visibleStart > visibleEnd) {
      return;
    }

    final minOffset = visibleStart - measureStartTick;
    final maxOffset = visibleEnd - measureStartTick;

    var nextBeatOffset =
        ((minOffset + beatTicks - _singleElementStep) ~/ beatTicks) * beatTicks;
    var nextSubOffset =
        ((minOffset + subdivisionStep - _singleElementStep) ~/
            subdivisionStep) *
        subdivisionStep;

    while (nextBeatOffset <= maxOffset || nextSubOffset <= maxOffset) {
      final int offset;
      final bool isBeatLine;
      if (nextBeatOffset < nextSubOffset) {
        offset = nextBeatOffset;
        isBeatLine = true;
        nextBeatOffset += beatTicks;
      } else if (nextSubOffset < nextBeatOffset) {
        offset = nextSubOffset;
        isBeatLine = false;
        nextSubOffset += subdivisionStep;
      } else {
        offset = nextBeatOffset;
        isBeatLine = true;
        nextBeatOffset += beatTicks;
        nextSubOffset += subdivisionStep;
      }

      final isBarline = offset == _measureOriginOffset;
      final beatIndex = isBarline ? firstBeatIndex : offset ~/ beatTicks;
      lines.add(
        BarBeatGridLine(
          tick: Tick(measureStartTick + offset),
          measureNumber: measureNumber,
          beatIndex: beatIndex,
          isBarline: isBarline,
          isBeatLine: isBeatLine,
        ),
      );
    }
  }
}

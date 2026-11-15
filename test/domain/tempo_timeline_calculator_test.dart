import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/domain/timeline/tempo_timeline_calculator.dart';

const ProjectId _testProjectId = ProjectId('0193a8f0-0000-7000-8000-000000000001');

TempoEventEntity _tempo(String id, int tick, int usPerQuarter) {
  return TempoEventEntity(
    tempoEventId: TempoEventId(id),
    projectId: _testProjectId,
    tick: Tick(tick),
    usPerQuarter: usPerQuarter,
    updatedAtMs: 0,
  );
}

TimeSignatureEventEntity _timeSig(String id, int tick, int num, int den) {
  return TimeSignatureEventEntity(
    tsEventId: TimeSigEventId(id),
    projectId: _testProjectId,
    tick: Tick(tick),
    numerator: num,
    denominator: den,
    updatedAtMs: 0,
  );
}

void main() {
  group('TempoTimelineCalculator tick <-> sampleFrame math', () {
    test('computes exact single-tempo conversions at 44100 Hz and 48000 Hz', () {
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
        timeSignatureEvents: <TimeSignatureEventEntity>[_timeSig('ts0', 0, 4, 4)],
      );

      expect(calc.tickToSampleFrame(const Tick(0), sampleRate: 44100).value, 0);
      expect(
        calc.tickToSampleFrame(const Tick(960), sampleRate: 44100).value,
        22050,
      );
      expect(
        calc.tickToSampleFrame(const Tick(3840), sampleRate: 44100).value,
        88200,
      );
      expect(
        calc.tickToSampleFrame(const Tick(960), sampleRate: 48000).value,
        24000,
      );

      expect(
        calc.sampleFrameToTick(const SampleFrame(0), sampleRate: 44100).value,
        0,
      );
      expect(
        calc
            .sampleFrameToTick(const SampleFrame(22050), sampleRate: 44100)
            .value,
        960,
      );
      expect(
        calc
            .sampleFrameToTick(const SampleFrame(24000), sampleRate: 48000)
            .value,
        960,
      );
    });

    test('preserves monotonic exact-inverse invariant at non-integer tempo (123 BPM @ 44100 Hz)', () {
      // 123 BPM -> round(60_000_000 / 123) = 487805 us/quarter.
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 487805)],
        timeSignatureEvents: <TimeSignatureEventEntity>[_timeSig('ts0', 0, 4, 4)],
      );

      for (var t = 0; t <= 1000; t++) {
        final frame = calc.tickToSampleFrame(Tick(t), sampleRate: 44100);
        final roundTrip = calc.sampleFrameToTick(frame, sampleRate: 44100);
        expect(
          roundTrip.value,
          t,
          reason: 'Round-trip failed for tick $t (frame ${frame.value})',
        );
      }

      // Check monotonicity across every consecutive sample frame around tick boundaries.
      var previousTick = -1;
      for (var f = 0; f <= 5000; f++) {
        final tick = calc.sampleFrameToTick(SampleFrame(f), sampleRate: 44100);
        expect(tick.value >= previousTick, isTrue);
        previousTick = tick.value;
      }
    });

    test('accumulates multi-tempo segments accurately regardless of input sort order', () {
      // Unsorted tempo events intentionally passed to verify defensive sorting.
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[
          _tempo('t2', 7680, 400000), // 150 BPM at bar 3
          _tempo('t0', 0, 500000), // 120 BPM at bar 1
          _tempo('t1', 3840, 600000), // 100 BPM at bar 2
        ],
        timeSignatureEvents: <TimeSignatureEventEntity>[_timeSig('ts0', 0, 4, 4)],
      );

      // Bar 1 [0..3840): 3840 ticks @ 120 BPM (2.0 s) @ 48000 Hz = 96000 frames.
      expect(
        calc.tickToSampleFrame(const Tick(3840), sampleRate: 48000).value,
        96000,
      );
      // Bar 2 [3840..7680): 3840 ticks @ 100 BPM (2.4 s) @ 48000 Hz = 115200 frames -> cumulative 211200.
      expect(
        calc.tickToSampleFrame(const Tick(7680), sampleRate: 48000).value,
        211200,
      );
      // 1 beat into Bar 3 (960 ticks @ 150 BPM = 0.4 s = 19200 frames) -> 230400.
      expect(
        calc.tickToSampleFrame(const Tick(8640), sampleRate: 48000).value,
        230400,
      );

      for (final tick in <int>[0, 1, 3839, 3840, 3841, 7679, 7680, 8640, 20000]) {
        final frame = calc.tickToSampleFrame(Tick(tick), sampleRate: 48000);
        expect(
          calc.sampleFrameToTick(frame, sampleRate: 48000).value,
          tick,
          reason: 'Multi-tempo round-trip mismatch at tick $tick',
        );
      }

      // Boundary frame just before tempo change maps strictly to previous segment.
      expect(
        calc
            .sampleFrameToTick(const SampleFrame(95999), sampleRate: 48000)
            .value,
        3839,
      );
    });

    test('handles long multi-million tick timelines without BigInt overflow', () {
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[
          _tempo('t0', 0, 500000),
          _tempo('t1', 1000000, 487805),
        ],
        timeSignatureEvents: <TimeSignatureEventEntity>[_timeSig('ts0', 0, 4, 4)],
      );

      const largeTick = Tick(100000000);
      final frame = calc.tickToSampleFrame(largeTick, sampleRate: 96000);
      expect(frame.value, greaterThan(0));
      expect(calc.sampleFrameToTick(frame, sampleRate: 96000).value, largeTick.value);
    });
  });

  group('TempoTimelineCalculator quantization & latency compensation', () {
    final calc = TempoTimelineCalculator(
      tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
      timeSignatureEvents: <TimeSignatureEventEntity>[_timeSig('ts0', 0, 4, 4)],
    );

    test('quantizeTick rounds half-up across straight, dotted, and triplet grids', () {
      expect(
        calc
            .quantizeTick(
              const Tick(120),
              snapSubdivisionTicks: const Tick(MuseConstants.sixteenthNoteTicks),
            )
            .value,
        240,
      );
      expect(
        calc
            .quantizeTick(
              const Tick(119),
              snapSubdivisionTicks: const Tick(MuseConstants.sixteenthNoteTicks),
            )
            .value,
        0,
      );
      expect(
        calc
            .quantizeTick(
              const Tick(360),
              snapSubdivisionTicks: const Tick(
                MuseConstants.dottedEighthNoteTicks,
              ),
            )
            .value,
        720,
      );
      expect(
        calc
            .quantizeTick(
              const Tick(479),
              snapSubdivisionTicks: const Tick(
                MuseConstants.tripletEighthNoteTicks,
              ),
            )
            .value,
        320,
      );
      expect(
        calc
            .quantizeTick(
              const Tick(480),
              snapSubdivisionTicks: const Tick(
                MuseConstants.tripletEighthNoteTicks,
              ),
            )
            .value,
        640,
      );
    });

    test('computeLatencyCompensatedStartTick clamps at frame 0 and applies positive/negative offsets', () {
      // Underflow clamps cleanly to Tick(0).
      expect(
        calc
            .computeLatencyCompensatedStartTick(
              capturedPlayheadFrame: const SampleFrame(500),
              outputBufferFrames: 512,
              inputBufferFrames: 512,
              calibrationOffsetFrames: 256,
              sampleRate: 48000,
            )
            .value,
        0,
      );

      // 48000 Hz @ 120 BPM: 24000 frames = 960 ticks.
      // 25280 - (512 + 512 + 256) = 24000 -> Tick(960).
      expect(
        calc
            .computeLatencyCompensatedStartTick(
              capturedPlayheadFrame: const SampleFrame(25280),
              outputBufferFrames: 512,
              inputBufferFrames: 512,
              calibrationOffsetFrames: 256,
              sampleRate: 48000,
            )
            .value,
        960,
      );

      // Negative calibration trim: 24500 - (512 + 512 - 524) = 24000 -> Tick(960).
      expect(
        calc
            .computeLatencyCompensatedStartTick(
              capturedPlayheadFrame: const SampleFrame(24500),
              outputBufferFrames: 512,
              inputBufferFrames: 512,
              calibrationOffsetFrames: -524,
              sampleRate: 48000,
            )
            .value,
        960,
      );
    });
  });

  group('TempoTimelineCalculator queryVisibleGridLines', () {
    test('emits Measure 1+ grid lines when pickupTicks == 0', () {
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
        timeSignatureEvents: <TimeSignatureEventEntity>[_timeSig('ts0', 0, 4, 4)],
      );

      final lines = calc.queryVisibleGridLines(
        startTick: const Tick(0),
        endTick: const Tick(3840),
        subdivisionTicks: const Tick(MuseConstants.eighthNoteTicks),
      );

      expect(lines.length, 9);
      expect(
        lines.first,
        const BarBeatGridLine(
          tick: Tick(0),
          measureNumber: 1,
          beatIndex: 0,
          isBarline: true,
          isBeatLine: true,
        ),
      );
      expect(
        lines[1],
        const BarBeatGridLine(
          tick: Tick(480),
          measureNumber: 1,
          beatIndex: 0,
          isBarline: false,
          isBeatLine: false,
        ),
      );
      expect(
        lines[2],
        const BarBeatGridLine(
          tick: Tick(960),
          measureNumber: 1,
          beatIndex: 1,
          isBarline: false,
          isBeatLine: true,
        ),
      );
      expect(
        lines.last,
        const BarBeatGridLine(
          tick: Tick(3840),
          measureNumber: 2,
          beatIndex: 0,
          isBarline: true,
          isBeatLine: true,
        ),
      );
    });

    test('emits Measure 0 anacrusis before Measure 1 when pickupTicks > 0', () {
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
        timeSignatureEvents: <TimeSignatureEventEntity>[_timeSig('ts0', 0, 4, 4)],
        pickupTicks: 1440, // 1.5 beats
      );

      final lines = calc.queryVisibleGridLines(
        startTick: const Tick(0),
        endTick: const Tick(2400),
        subdivisionTicks: const Tick(MuseConstants.eighthNoteTicks),
      );

      expect(lines.map((l) => (l.tick.value, l.measureNumber, l.beatIndex, l.isBarline, l.isBeatLine)).toList(), <
        (int, int, int, bool, bool)
      >[
        (0, 0, 0, true, true),
        (480, 0, 0, false, false),
        (960, 0, 1, false, true),
        (1440, 1, 0, true, true),
        (1920, 1, 0, false, false),
        (2400, 1, 1, false, true),
      ]);
    });

    test('handles meter changes (4/4 -> 3/4 -> 6/8) including mid-measure alignment', () {
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
        timeSignatureEvents: <TimeSignatureEventEntity>[
          _timeSig('ts0', 0, 4, 4), // M1 [0..3840)
          _timeSig('ts1', 2000, 3, 4), // Mid-M1 -> takes effect at M2 barline (3840)
          _timeSig('ts2', 6720, 6, 8), // M3 barline (3840 + 2880 = 6720), len = 2880, beat = 480
        ],
      );

      final barlines = calc
          .queryVisibleGridLines(
            startTick: const Tick(0),
            endTick: const Tick(10000),
            subdivisionTicks: const Tick(MuseConstants.quarterNoteTicks),
          )
          .where((l) => l.isBarline)
          .toList();

      expect(
        barlines.map((b) => (b.measureNumber, b.tick.value)).toList(),
        <(int, int)>[
          (1, 0),
          (2, 3840),
          (3, 6720),
          (4, 9600),
        ],
      );

      // In 6/8 (M3 starting at 6720), beat lines are every eighth note (480 ticks).
      final m3Beats = calc
          .queryVisibleGridLines(
            startTick: const Tick(6720),
            endTick: const Tick(9599),
            subdivisionTicks: const Tick(MuseConstants.quarterNoteTicks),
          )
          .where((l) => l.isBeatLine)
          .toList();
      expect(m3Beats.length, 6);
      expect(m3Beats.map((b) => b.beatIndex).toList(), <int>[0, 1, 2, 3, 4, 5]);
    });

    test('queries high tick offsets analytically without linear scan from tick 0', () {
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
        timeSignatureEvents: <TimeSignatureEventEntity>[_timeSig('ts0', 0, 4, 4)],
      );

      // Measure 100,001 starts at 100_000 * 3840 = 384_000_000.
      const start = Tick(384000000);
      const end = Tick(384003840);
      final lines = calc.queryVisibleGridLines(
        startTick: start,
        endTick: end,
        subdivisionTicks: const Tick(MuseConstants.quarterNoteTicks),
      );

      expect(lines.length, 5);
      expect(lines.first.measureNumber, 100001);
      expect(lines.first.isBarline, isTrue);
      expect(lines.last.measureNumber, 100002);
      expect(lines.last.isBarline, isTrue);
    });
  });

  group('TempoTimelineCalculator fail-closed validation', () {
    test('rejects invalid constructor inputs', () {
      expect(
        () => TempoTimelineCalculator(
          tempoEvents: const <TempoEventEntity>[],
          timeSignatureEvents: <TimeSignatureEventEntity>[
            _timeSig('ts0', 0, 4, 4),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => TempoTimelineCalculator(
          tempoEvents: <TempoEventEntity>[_tempo('t0', 960, 500000)],
          timeSignatureEvents: <TimeSignatureEventEntity>[
            _timeSig('ts0', 0, 4, 4),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => TempoTimelineCalculator(
          tempoEvents: <TempoEventEntity>[
            _tempo('t0', 0, 500000),
            _tempo('t1', 0, 400000),
          ],
          timeSignatureEvents: <TimeSignatureEventEntity>[
            _timeSig('ts0', 0, 4, 4),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => TempoTimelineCalculator(
          tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 0)],
          timeSignatureEvents: <TimeSignatureEventEntity>[
            _timeSig('ts0', 0, 4, 4),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => TempoTimelineCalculator(
          tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
          timeSignatureEvents: <TimeSignatureEventEntity>[
            _timeSig('ts0', 0, 4, 3), // Non-power-of-two denominator
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => TempoTimelineCalculator(
          tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
          timeSignatureEvents: <TimeSignatureEventEntity>[
            _timeSig('ts0', 0, 0, 4),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => TempoTimelineCalculator(
          tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
          timeSignatureEvents: <TimeSignatureEventEntity>[
            _timeSig('ts0', 0, 4, 4),
          ],
          pickupTicks: -1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects invalid method arguments', () {
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
        timeSignatureEvents: <TimeSignatureEventEntity>[_timeSig('ts0', 0, 4, 4)],
      );

      expect(
        () => calc.tickToSampleFrame(const Tick(-1), sampleRate: 44100),
        throwsArgumentError,
      );
      expect(
        () => calc.tickToSampleFrame(const Tick(0), sampleRate: 0),
        throwsArgumentError,
      );
      expect(
        () => calc.sampleFrameToTick(const SampleFrame(-1), sampleRate: 44100),
        throwsArgumentError,
      );
      expect(
        () => calc.quantizeTick(
          const Tick(0),
          snapSubdivisionTicks: const Tick(0),
        ),
        throwsArgumentError,
      );
      expect(
        () => calc.computeLatencyCompensatedStartTick(
          capturedPlayheadFrame: const SampleFrame(0),
          outputBufferFrames: -1,
          inputBufferFrames: 0,
          calibrationOffsetFrames: 0,
          sampleRate: 44100,
        ),
        throwsArgumentError,
      );
      expect(
        () => calc.queryVisibleGridLines(
          startTick: const Tick(960),
          endTick: const Tick(480),
          subdivisionTicks: const Tick(240),
        ),
        throwsArgumentError,
      );
      expect(() => calc.tickToBarBeatTick(const Tick(-1)), throwsArgumentError);
    });

    test('tickToBarBeatTick resolves pickup and multi-meter measures', () {
      final calc = TempoTimelineCalculator(
        tempoEvents: <TempoEventEntity>[_tempo('t0', 0, 500000)],
        timeSignatureEvents: <TimeSignatureEventEntity>[
          _timeSig('ts0', 0, 4, 4),
          _timeSig('ts1', 4800, 3, 4), // pickup 960 + 1 bar 4/4 (3840) = 4800
        ],
        pickupTicks: 960,
      );

      expect(
        calc.tickToBarBeatTick(const Tick(240)),
        const BarBeatTickPosition(
          measureNumber: 0,
          beatIndex: 0,
          tickInBeat: 240,
          tickInMeasure: 240,
          measureStartTick: Tick(0),
          measureDurationTicks: 960,
        ),
      );
      expect(
        calc.tickToBarBeatTick(const Tick(1920)),
        const BarBeatTickPosition(
          measureNumber: 1,
          beatIndex: 1,
          tickInBeat: 0,
          tickInMeasure: 960,
          measureStartTick: Tick(960),
          measureDurationTicks: 3840,
        ),
      );
      expect(
        calc.tickToBarBeatTick(const Tick(5760)),
        const BarBeatTickPosition(
          measureNumber: 2,
          beatIndex: 1,
          tickInBeat: 0,
          tickInMeasure: 960,
          measureStartTick: Tick(4800),
          measureDurationTicks: 2880,
        ),
      );
    });
  });
}

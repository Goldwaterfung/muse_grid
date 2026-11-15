/// Layer 5 controller owning the single 60 Hz telemetry drainer `Ticker`,
/// epoch-filtered playhead `ValueNotifier`s, circular live waveform buffer,
/// fail-closed overflow abort, and transport/recording controls.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ChangeNotifier, ValueNotifier;
import 'package:flutter/scheduler.dart' show Ticker, TickerCallback;

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../theme/muse_presentation_constants.dart';
import '../../domain/models/score_models.dart';
import '../../domain/playback/lookahead_playback_coordinator.dart';
import '../../domain/recording/recording_session_coordinator.dart';
import 'audio_session_contract.dart';
import 'workspace_shell_controller.dart';

/// Signature for injecting a custom [Ticker] in unit tests.
typedef TelemetryTickerFactory = Ticker Function(TickerCallback onTick);

/// Aggregated peak and RMS audio metering snapshot for UI meters.
final class TelemetryMeterSnapshot {
  final double outputPeakL;
  final double outputPeakR;
  final double outputRmsL;
  final double outputRmsR;
  final double inputPeak;
  final double inputRms;

  const TelemetryMeterSnapshot({
    required this.outputPeakL,
    required this.outputPeakR,
    required this.outputRmsL,
    required this.outputRmsR,
    required this.inputPeak,
    required this.inputRms,
  });

  const TelemetryMeterSnapshot.zero()
      : outputPeakL = TelemetryConstants.minLinearAmplitude,
        outputPeakR = TelemetryConstants.minLinearAmplitude,
        outputRmsL = TelemetryConstants.minLinearAmplitude,
        outputRmsR = TelemetryConstants.minLinearAmplitude,
        inputPeak = TelemetryConstants.minLinearAmplitude,
        inputRms = TelemetryConstants.minLinearAmplitude;
}

/// Bounded live microphone waveform sample emitted while capturing.
final class RecordingWaveformSample {
  final double inputPeak;
  final double inputRms;

  const RecordingWaveformSample({
    required this.inputPeak,
    required this.inputRms,
  });
}

/// Single 60 Hz telemetry drainer and transport/recording coordinator for L5.
final class TransportAndTelemetryController extends ChangeNotifier {
  static const int _targetDrainIntervalUs =
      Duration.microsecondsPerSecond ~/ MuseConstants.telemetryPollHz;

  /// Allows 60 Hz vsync jitter (e.g. 16 ms frames) while skipping 120 Hz half-frames.
  static const int _drainIntervalToleranceNumerator = 3;
  static const int _drainIntervalToleranceDenominator = 4;
  static const int _minDrainIntervalUs =
      (_targetDrainIntervalUs * _drainIntervalToleranceNumerator) ~/
      _drainIntervalToleranceDenominator;

  final ILookaheadPlaybackCoordinator _playbackCoordinator;
  final IRecordingSessionCoordinator _recordingCoordinator;
  final ISynthEventBridge _synthEventBridge;
  final ITelemetryBridge _telemetryBridge;
  final IAudioSessionController _audioSessionController;
  final WorkspaceShellController _workspaceShellController;

  final ValueNotifier<Tick> playheadTick = ValueNotifier<Tick>(
    const Tick(MusePresentationConstants.initialTick),
  );
  final ValueNotifier<SampleFrame> playheadSampleFrame =
      ValueNotifier<SampleFrame>(
        const SampleFrame(MusePresentationConstants.initialTick),
      );
  final ValueNotifier<TelemetryMeterSnapshot> meters =
      ValueNotifier<TelemetryMeterSnapshot>(
        const TelemetryMeterSnapshot.zero(),
      );
  final ValueNotifier<List<RecordingWaveformSample>> liveRecordingWaveform =
      ValueNotifier<List<RecordingWaveformSample>>(
        const <RecordingWaveformSample>[],
      );

  final ListQueue<RecordingWaveformSample> _waveformRing =
      ListQueue<RecordingWaveformSample>();

  late final Ticker _ticker;
  StreamSubscription<MuseError>? _asyncErrorSub;
  StreamSubscription<PlaybackLoopStateSnapshot>? _loopStateSub;
  StreamSubscription<PlaybackPlayheadReanchorEvent>? _playheadReanchoredSub;
  Duration? _lastDrainElapsed;

  bool _isPlaying = false;
  bool _isRecording = false;
  bool _isLoopEnabled = false;
  ({Tick startTick, Tick endTick})? _loopTickRange;
  ProjectId? _trackedProjectId;
  ({ProjectId projectId, bool enabled, Tick startTick, Tick endTick})?
  _pendingPreAttachLoop;
  PartId? _armedPartId;
  bool _countInEnabled = true;
  double _monitorGainLinear = TelemetryConstants.monitorGainDefaultLinear;
  MuseError? _activeAlert;
  bool _overflowTerminationInFlight = false;
  bool _isDisposed = false;

  TransportAndTelemetryController({
    required this._playbackCoordinator,
    required this._recordingCoordinator,
    required this._synthEventBridge,
    required this._telemetryBridge,
    required this._audioSessionController,
    required this._workspaceShellController,
    TelemetryTickerFactory? tickerFactory,
  }) {
    _trackedProjectId = _workspaceShellController
        .currentWorkspace
        ?.aggregate
        .project
        .projectId;
    _isLoopEnabled = _playbackCoordinator.isLoopEnabled;
    _loopTickRange = _playbackCoordinator.loopTickRange;

    _workspaceShellController.addListener(_onWorkspaceShellChanged);
    _asyncErrorSub = _playbackCoordinator.asyncErrors.listen((error) {
      if (_isDisposed) {
        return;
      }
      _activeAlert = error;
      notifyListeners();
    });
    _loopStateSub = _playbackCoordinator.loopStateChanges.listen(
      _onPlaybackLoopStateChanged,
    );
    _playheadReanchoredSub = _playbackCoordinator.playheadReanchored.listen(
      _onPlayheadReanchored,
    );

    final factory = tickerFactory ?? _defaultTickerFactory;
    _ticker = factory(_onTelemetryTick);
    _ticker.start();
  }

  static Ticker _defaultTickerFactory(TickerCallback onTick) => Ticker(onTick);

  bool get isPlaying => _isPlaying;
  bool get isRecording => _isRecording;
  bool get isLoopEnabled => _isLoopEnabled;
  ({Tick startTick, Tick endTick})? get loopTickRange => _loopTickRange;
  PartId? get armedPartId => _armedPartId;
  bool get countInEnabled => _countInEnabled;
  double get monitorGainLinear => _monitorGainLinear;
  MuseError? get activeAlert => _activeAlert;

  void dismissTelemetryAlert() {
    if (_activeAlert == null) {
      return;
    }
    _activeAlert = null;
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  Future<Result<void>> play() async {
    final sessionStatus = _audioSessionController.audioSessionStatus.value;
    if (sessionStatus.phase == AudioSessionPhase.requiresWebUserGesture ||
        sessionStatus.phase != AudioSessionPhase.ready ||
        !_playbackCoordinator.isAttached) {
      final attachRes = await _workspaceShellController
          .ensureAudioInitializedAndAttach();
      if (attachRes case Err<void>(:final error)) {
        _setAlert(error);
        return Err(error);
      }
    }
    _flushPendingPreAttachLoopIfNeeded();

    final result = await _playbackCoordinator.play();
    if (result case Err<void>(:final error)) {
      _setAlert(error);
      return Err(error);
    }
    _isPlaying = _playbackCoordinator.isPlaying;
    _notifySafe();
    return const Ok(null);
  }

  Result<void> pause() {
    final result = _playbackCoordinator.pause();
    _isPlaying = _playbackCoordinator.isPlaying;
    if (result case Err<void>(:final error)) {
      _setAlert(error);
      return Err(error);
    }
    _notifySafe();
    return const Ok(null);
  }

  Result<void> stop() {
    final result = _playbackCoordinator.stop();
    _isPlaying = _playbackCoordinator.isPlaying;
    if (result case Err<void>(:final error)) {
      _setAlert(error);
      return Err(error);
    }
    playheadTick.value = const Tick(MusePresentationConstants.initialTick);
    playheadSampleFrame.value = const SampleFrame(
      MusePresentationConstants.initialTick,
    );
    _notifySafe();
    return const Ok(null);
  }

  Result<void> seekToTick(Tick targetTick) {
    final result = _playbackCoordinator.seekToTick(targetTick);
    if (result case Err<void>(:final error)) {
      _setAlert(error);
      return Err(error);
    }
    playheadTick.value = targetTick;
    final hw = _audioSessionController.audioSessionStatus.value.hardwareInfo;
    final calc = _workspaceShellController
        .buildTimelineCalculatorForActiveWorkspace();
    if (hw != null && calc != null) {
      playheadSampleFrame.value = calc.tickToSampleFrame(
        targetTick,
        sampleRate: hw.sampleRate,
      );
    }
    _notifySafe();
    return const Ok(null);
  }

  Result<void> setLoopTickRange({
    required bool enabled,
    required Tick startTick,
    required Tick endTick,
  }) {
    if (startTick.value < MusePresentationConstants.initialTick ||
        endTick.value < MusePresentationConstants.initialTick ||
        (enabled && endTick.value <= startTick.value)) {
      const err = MuseError(
        MuseErrorCode.invalidTickRange,
        'Loop region requires non-negative ticks with endTick > startTick when enabled.',
      );
      _setAlert(err);
      return const Err(err);
    }

    final activeProjectId = _workspaceShellController
        .currentWorkspace
        ?.aggregate
        .project
        .projectId;
    final sessionPhase =
        _audioSessionController.audioSessionStatus.value.phase;
    if (activeProjectId != null &&
        (sessionPhase != AudioSessionPhase.ready ||
            !_playbackCoordinator.isAttached)) {
      _pendingPreAttachLoop = (
        projectId: activeProjectId,
        enabled: enabled,
        startTick: startTick,
        endTick: endTick,
      );
      _isLoopEnabled = enabled;
      _loopTickRange = enabled ? (startTick: startTick, endTick: endTick) : null;
      _notifySafe();
      return const Ok(null);
    }

    final result = _playbackCoordinator.setLoopTickRange(
      enabled: enabled,
      startTick: startTick,
      endTick: endTick,
    );
    if (result case Err<void>(:final error)) {
      _setAlert(error);
      return Err(error);
    }
    _pendingPreAttachLoop = null;
    _isLoopEnabled = _playbackCoordinator.isLoopEnabled;
    _loopTickRange = _playbackCoordinator.loopTickRange;
    _notifySafe();
    return const Ok(null);
  }

  void togglePartArmForRecording(PartId partId) {
    _armedPartId = _armedPartId == partId ? null : partId;
    _notifySafe();
  }

  void setCountInEnabled(bool enabled) {
    if (_countInEnabled == enabled) {
      return;
    }
    _countInEnabled = enabled;
    _notifySafe();
  }

  Result<void> setMonitorGain(double gainLinear) {
    if (!gainLinear.isFinite ||
        gainLinear < TelemetryConstants.minLinearAmplitude ||
        gainLinear > TelemetryConstants.monitorGainMaxLinear) {
      final err = MuseError(
        MuseErrorCode.invalidTickRange,
        'Monitor gain ($gainLinear) must be in ${TelemetryConstants.minLinearAmplitude}..${TelemetryConstants.monitorGainMaxLinear}.',
      );
      _setAlert(err);
      return Err(err);
    }
    final result = _recordingCoordinator.setInputMonitorGain(gainLinear);
    if (result case Err<void>(:final error)) {
      _setAlert(error);
      return Err(error);
    }
    _monitorGainLinear = gainLinear;
    _notifySafe();
    return const Ok(null);
  }

  Future<Result<TakeId>> startRecordingOnArmedPart({
    required Tick punchInTick,
  }) async {
    final partId = _armedPartId;
    if (partId == null) {
      const err = MuseError(
        MuseErrorCode.entityNotFound,
        'No part is armed for recording.',
      );
      _setAlert(err);
      return const Err(err);
    }

    _waveformRing.clear();
    liveRecordingWaveform.value = const <RecordingWaveformSample>[];

    final sessionStatus = _audioSessionController.audioSessionStatus.value;
    if (sessionStatus.phase == AudioSessionPhase.requiresWebUserGesture ||
        sessionStatus.phase != AudioSessionPhase.ready ||
        !_playbackCoordinator.isAttached) {
      final attachRes = await _workspaceShellController
          .ensureAudioInitializedAndAttach();
      if (attachRes case Err<void>(:final error)) {
        _setAlert(error);
        return Err(error);
      }
    }
    _flushPendingPreAttachLoopIfNeeded();

    final result = await _recordingCoordinator.startRecordingOnPart(
      partId: partId,
      countInStartTick: punchInTick,
      countInMeasuresOverride: _countInEnabled
          ? null
          : MusePresentationConstants.countInDisabledMeasures,
    );
    if (result case Err<TakeId>(:final error)) {
      _isRecording = false;
      _isPlaying = _playbackCoordinator.isPlaying;
      _setAlert(error);
      return Err(error);
    }
    _isRecording = true;
    _isPlaying = _playbackCoordinator.isPlaying;
    _notifySafe();
    return result;
  }

  Future<Result<AudioTakeEntity>> stopAndCommitRecording() async {
    final result = await _recordingCoordinator.stopAndCommitRecording();
    _isRecording = false;
    _isPlaying = _playbackCoordinator.isPlaying;
    if (result case Err<AudioTakeEntity>(:final error)) {
      if (_overflowTerminationInFlight) {
        _activeAlert ??= error;
      } else {
        _activeAlert = error;
      }
    }
    _notifySafe();
    return result;
  }

  void _onTelemetryTick(Duration elapsed) {
    if (_isDisposed) {
      return;
    }
    final last = _lastDrainElapsed;
    if (last != null && (elapsed - last).inMicroseconds < _minDrainIntervalUs) {
      return;
    }
    _lastDrainElapsed = elapsed;

    final status = _audioSessionController.audioSessionStatus.value;
    final hw = status.hardwareInfo;
    if (status.phase != AudioSessionPhase.ready || hw == null) {
      return;
    }

    final snapshots = _telemetryBridge.drainTelemetry(
      maxFrames: MuseConstants.maxTelemetryDrainFrames,
    );
    if (snapshots.isEmpty) {
      return;
    }

    final currentEpoch = _synthEventBridge.currentEpoch;
    var outPeakL = TelemetryConstants.minLinearAmplitude;
    var outPeakR = TelemetryConstants.minLinearAmplitude;
    var outRmsL = TelemetryConstants.minLinearAmplitude;
    var outRmsR = TelemetryConstants.minLinearAmplitude;
    var inPeak = TelemetryConstants.minLinearAmplitude;
    var inRms = TelemetryConstants.minLinearAmplitude;

    var sawOverflow = false;
    var sawEventUnderrun = false;
    var sawTakeUnderrun = false;
    var appendedWaveform = false;
    TelemetrySnapshot? latestEpochMatch;

    for (final snap in snapshots) {
      outPeakL = math.max(outPeakL, snap.outputPeakL);
      outPeakR = math.max(outPeakR, snap.outputPeakR);
      outRmsL = math.max(outRmsL, snap.outputRmsL);
      outRmsR = math.max(outRmsR, snap.outputRmsR);
      inPeak = math.max(inPeak, snap.inputPeak);
      inRms = math.max(inRms, snap.inputRms);

      if (snap.hasCaptureBufferOverflow) {
        sawOverflow = true;
      }
      if (snap.hasEventQueueUnderrun) {
        sawEventUnderrun = true;
      }
      if (snap.hasTakePlaybackUnderrun) {
        sawTakeUnderrun = true;
      }

      if (snap.isCapturing) {
        _waveformRing.addLast(
          RecordingWaveformSample(
            inputPeak: snap.inputPeak,
            inputRms: snap.inputRms,
          ),
        );
        while (_waveformRing.length > TelemetryConstants.maxWaveformSamples) {
          _waveformRing.removeFirst();
        }
        appendedWaveform = true;
      }

      if (snap.activeEpoch == currentEpoch) {
        latestEpochMatch = snap;
      }
    }

    meters.value = TelemetryMeterSnapshot(
      outputPeakL: outPeakL,
      outputPeakR: outPeakR,
      outputRmsL: outRmsL,
      outputRmsR: outRmsR,
      inputPeak: inPeak,
      inputRms: inRms,
    );

    if (appendedWaveform) {
      liveRecordingWaveform.value = List<RecordingWaveformSample>.unmodifiable(
        _waveformRing,
      );
    }

    if (sawOverflow) {
      _activeAlert = const MuseError(
        MuseErrorCode.captureBufferOverflow,
        'Capture ring buffer overflowed; recording aborted cleanly.',
      );
      _notifySafe();
      if (_isRecording && !_overflowTerminationInFlight) {
        _overflowTerminationInFlight = true;
        unawaited(_terminateOverflowedRecording());
      }
    } else if (sawEventUnderrun) {
      _setAlert(
        const MuseError(
          MuseErrorCode.eventQueueUnderrun,
          'Audio synth event queue underrun occurred.',
        ),
      );
    } else if (sawTakeUnderrun) {
      _setAlert(
        const MuseError(
          MuseErrorCode.takePlaybackBufferUnderrun,
          'Recorded take playback buffer underrun occurred.',
        ),
      );
    }

    if (latestEpochMatch != null) {
      playheadSampleFrame.value = latestEpochMatch.playheadSampleFrame;
      final calculator = _workspaceShellController
          .buildTimelineCalculatorForActiveWorkspace();
      if (calculator != null) {
        final nextTick = calculator.sampleFrameToTick(
          latestEpochMatch.playheadSampleFrame,
          sampleRate: hw.sampleRate,
        );
        playheadTick.value = nextTick;
      }
    }
  }

  Future<void> _terminateOverflowedRecording() async {
    try {
      await stopAndCommitRecording();
    } finally {
      _overflowTerminationInFlight = false;
    }
  }

  void _onWorkspaceShellChanged() {
    if (_isDisposed) {
      return;
    }
    final activeProjectId = _workspaceShellController
        .currentWorkspace
        ?.aggregate
        .project
        .projectId;
    if (activeProjectId == _trackedProjectId) {
      return;
    }
    _trackedProjectId = activeProjectId;
    _pendingPreAttachLoop = null;
    if (activeProjectId == null) {
      _isPlaying = false;
      _isLoopEnabled = false;
      _loopTickRange = null;
      playheadTick.value = const Tick(MusePresentationConstants.initialTick);
      playheadSampleFrame.value = const SampleFrame(
        MusePresentationConstants.initialTick,
      );
      _notifySafe();
    }
  }

  void _onPlaybackLoopStateChanged(PlaybackLoopStateSnapshot state) {
    if (_isDisposed) {
      return;
    }
    if (state.isAttached && _pendingPreAttachLoop != null) {
      _flushPendingPreAttachLoopIfNeeded();
      return;
    }
    if (_pendingPreAttachLoop != null && !state.isAttached) {
      return;
    }
    if (_isLoopEnabled == state.isLoopEnabled &&
        _loopTickRange == state.loopTickRange) {
      return;
    }
    _isLoopEnabled = state.isLoopEnabled;
    _loopTickRange = state.loopTickRange;
    _notifySafe();
  }

  void _onPlayheadReanchored(PlaybackPlayheadReanchorEvent reanchored) {
    if (_isDisposed) {
      return;
    }
    playheadSampleFrame.value = reanchored.sampleFrame;
    playheadTick.value = reanchored.tick;
  }

  void _flushPendingPreAttachLoopIfNeeded() {
    final pending = _pendingPreAttachLoop;
    final activeProjectId = _workspaceShellController
        .currentWorkspace
        ?.aggregate
        .project
        .projectId;
    if (pending == null ||
        activeProjectId == null ||
        pending.projectId != activeProjectId ||
        !_playbackCoordinator.isAttached) {
      return;
    }
    _pendingPreAttachLoop = null;
    final res = _playbackCoordinator.setLoopTickRange(
      enabled: pending.enabled,
      startTick: pending.startTick,
      endTick: pending.endTick,
    );
    if (res case Err<void>(:final error)) {
      _setAlert(error);
      return;
    }
    _isLoopEnabled = _playbackCoordinator.isLoopEnabled;
    _loopTickRange = _playbackCoordinator.loopTickRange;
    _notifySafe();
  }

  void _setAlert(MuseError error) {
    _activeAlert = error;
    _notifySafe();
  }

  void _notifySafe() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _workspaceShellController.removeListener(_onWorkspaceShellChanged);
    unawaited(_asyncErrorSub?.cancel());
    _asyncErrorSub = null;
    unawaited(_loopStateSub?.cancel());
    _loopStateSub = null;
    unawaited(_playheadReanchoredSub?.cancel());
    _playheadReanchoredSub = null;
    _ticker.stop();
    _ticker.dispose();
    playheadTick.dispose();
    playheadSampleFrame.dispose();
    meters.dispose();
    liveRecordingWaveform.dispose();
    super.dispose();
  }
}

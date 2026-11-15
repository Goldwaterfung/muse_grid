/// Narrow L5 audio session contract decoupling `lib/presentation/` from
/// `lib/app/` and platform-specific audio lifecycle implementations.
library;

import 'package:flutter/foundation.dart' show ValueListenable;

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';

/// Lifecycle phase of the platform audio engine session.
enum AudioSessionPhase {
  initializing,
  requiresWebUserGesture,
  ready,
  failed,
}

/// Immutable status snapshot emitted by [IAudioSessionController].
final class AudioSessionStatus {
  final AudioSessionPhase phase;
  final AudioHardwareInfo? hardwareInfo;
  final MuseError? error;

  const AudioSessionStatus({
    required this.phase,
    this.hardwareInfo,
    this.error,
  });
}

/// Pure presentation-layer contract implemented in `lib/app/muse_grid_app_bootstrap.dart`.
abstract interface class IAudioSessionController {
  ValueListenable<AudioSessionStatus> get audioSessionStatus;
  CalibrationPlatform get currentPlatform;

  /// Native calls `IAudioLifecycleBridge.initialize` at bootstrap; Web calls it
  /// strictly inside an explicit user gesture. Never falls back to mock audio.
  Future<Result<AudioHardwareInfo>> ensureAudioInitialized();
}

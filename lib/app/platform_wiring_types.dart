/// Shared platform-wiring contract connecting `lib/app/` bootstrap to
/// platform-specific storage (`Native` / `Web`) and audio bridges (`FFI` / `Worklet`).
library;

import '../bridge/contracts/audio_bridge_contracts.dart';
import '../domain/models/score_models.dart';
import '../domain/repositories/storage_contracts.dart';

/// Platform-specific repository factories, file exchange, and audio bridges
/// resolved strictly downward by conditional imports in `lib/app/`.
final class MuseGridPlatformWiring {
  final IStorageMaintenanceRepository storageMaintenance;
  final IProjectRepository Function() createProjectRepository;
  final IAssetLibraryRepository Function() createAssetLibraryRepository;
  final IExternalFileExchange externalFileExchange;
  final IAudioLifecycleBridge audioLifecycleBridge;
  final ITransportBridge transportBridge;
  final ISynthEventBridge synthEventBridge;
  final IRecordingBridge recordingBridge;
  final ITelemetryBridge telemetryBridge;
  final CalibrationPlatform currentPlatform;
  final bool requiresExplicitAudioUserGesture;

  const MuseGridPlatformWiring({
    required this.storageMaintenance,
    required this.createProjectRepository,
    required this.createAssetLibraryRepository,
    required this.externalFileExchange,
    required this.audioLifecycleBridge,
    required this.transportBridge,
    required this.synthEventBridge,
    required this.recordingBridge,
    required this.telemetryBridge,
    required this.currentPlatform,
    required this.requiresExplicitAudioUserGesture,
  });
}

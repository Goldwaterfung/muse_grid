/// Web (`WasmGC` / JS) platform wiring (`dart.library.js_interop`):
/// `WebOpfsStorageAdapter`, `SqlProjectRepository`, `SqlAssetLibraryRepository`,
/// `WebExternalFileExchange`, and `WebAudioWorkletBridge`.
library;

import '../bridge/web/web_audio_worklet_bridge.dart';
import '../domain/models/score_models.dart';
import '../storage/common/sql_asset_library_repository.dart';
import '../storage/common/sql_project_repository.dart';
import '../storage/web/web_external_file_exchange.dart';
import '../storage/web/web_opfs_storage_adapter.dart';
import 'platform_wiring_types.dart';

/// Constructs Web OPFS storage and `AudioWorklet` bridge wiring with explicit
/// browser user-gesture gating and deferred SQLite DB handle access.
MuseGridPlatformWiring createPlatformWiring() {
  final storageAdapter = WebOpfsStorageAdapter();
  final externalFileExchange = WebExternalFileExchange(
    storageLocator: storageAdapter,
  );
  final audioBridge = WebAudioWorkletBridge(storageLocator: storageAdapter);

  return MuseGridPlatformWiring(
    storageMaintenance: storageAdapter,
    createProjectRepository: () => SqlProjectRepository(
      db: storageAdapter.database,
      casStore: storageAdapter,
    ),
    createAssetLibraryRepository: () => SqlAssetLibraryRepository(
      db: storageAdapter.database,
      casStore: storageAdapter,
    ),
    externalFileExchange: externalFileExchange,
    audioLifecycleBridge: audioBridge,
    transportBridge: audioBridge,
    synthEventBridge: audioBridge,
    recordingBridge: audioBridge,
    telemetryBridge: audioBridge,
    currentPlatform: CalibrationPlatform.web,
    requiresExplicitAudioUserGesture: true,
  );
}

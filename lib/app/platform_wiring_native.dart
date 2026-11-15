/// Native platform wiring (`dart.library.io`): `NativeStorageAdapter`,
/// `SqlProjectRepository`, `SqlAssetLibraryRepository`, `NativeExternalFileExchange`,
/// and FFI `NativeAudioBridge`.
library;

import 'dart:io' show Platform;

import '../bridge/native/native_audio_bridge.dart';
import '../domain/models/score_models.dart';
import '../storage/common/sql_asset_library_repository.dart';
import '../storage/common/sql_project_repository.dart';
import '../storage/native/native_external_file_exchange.dart';
import '../storage/native/native_storage_adapter.dart';
import 'platform_wiring_types.dart';

CalibrationPlatform _resolveNativePlatform() {
  if (Platform.isIOS) {
    return CalibrationPlatform.ios;
  }
  if (Platform.isAndroid) {
    return CalibrationPlatform.android;
  }
  if (Platform.isMacOS) {
    return CalibrationPlatform.macos;
  }
  if (Platform.isWindows) {
    return CalibrationPlatform.windows;
  }
  if (Platform.isLinux) {
    return CalibrationPlatform.linux;
  }
  throw UnsupportedError(
    'Unsupported native operating system: ${Platform.operatingSystem}',
  );
}

/// Constructs native storage and FFI audio wiring with deferred SQLite DB
/// handle resolution evaluated only after `initializeAndVerifyStorage()`.
MuseGridPlatformWiring createPlatformWiring() {
  final storageAdapter = NativeStorageAdapter();
  final externalFileExchange = NativeExternalFileExchange(
    storageLocator: storageAdapter,
  );
  final audioBridge = NativeAudioBridge(storageLocator: storageAdapter);

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
    currentPlatform: _resolveNativePlatform(),
    requiresExplicitAudioUserGesture: false,
  );
}

/// Composition Root assembling platform storage/audio bridges, L4 domain
/// services, bundled default SoundFont seeding, Bravura SMuFL preloading, and
/// L5 controllers with fail-closed startup & reverse-order shutdown.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:crisp_notation/crisp_notation.dart' show MusicFont, MusicFonts;
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;
import 'package:uuid/uuid.dart';

import '../bridge/contracts/audio_bridge_contracts.dart';
import '../bridge/contracts/engine_constants.dart';
import '../bridge/contracts/ids_and_units.dart';
import '../bridge/contracts/result.dart';
import '../domain/assets/soundfont_preset_parser.dart';
import '../domain/models/score_models.dart';
import '../domain/notation/dual_model_score_service.dart';
import '../domain/playback/lookahead_playback_coordinator.dart';
import '../domain/recording/recording_session_coordinator.dart';
import '../domain/repositories/storage_contracts.dart';
import '../presentation/controllers/audio_session_contract.dart';
import '../presentation/controllers/project_catalog_controller.dart';
import '../presentation/controllers/transport_and_telemetry_controller.dart';
import '../presentation/controllers/workspace_shell_controller.dart';
import '../presentation/notation/staff_notation_view_controller.dart';
import '../presentation/piano_roll/piano_roll_viewport_controller.dart';
import '../presentation/theme/muse_presentation_constants.dart';
import 'platform_wiring_stub.dart'
    if (dart.library.io) 'platform_wiring_native.dart'
    if (dart.library.js_interop) 'platform_wiring_web.dart'
    as platform_wiring;
import 'platform_wiring_types.dart';

/// Fully initialized L4 + L5 controller bundle returned by [MuseGridAppBootstrap.initialize].
final class MuseGridControllerBundle {
  final MuseGridAppBootstrap bootstrap;
  final IAudioSessionController audioSessionController;
  final ILookaheadPlaybackCoordinator playbackCoordinator;
  final IRecordingSessionCoordinator recordingCoordinator;
  final ProjectCatalogController projectCatalogController;
  final WorkspaceShellController workspaceShellController;
  final StaffNotationViewController staffNotationViewController;
  final PianoRollViewportController pianoRollViewportController;
  final TransportAndTelemetryController transportAndTelemetryController;

  const MuseGridControllerBundle({
    required this.bootstrap,
    required this.audioSessionController,
    required this.playbackCoordinator,
    required this.recordingCoordinator,
    required this.projectCatalogController,
    required this.workspaceShellController,
    required this.staffNotationViewController,
    required this.pianoRollViewportController,
    required this.transportAndTelemetryController,
  });
}

/// Coordinates fail-closed application startup, platform audio initialization,
/// SoundFont seeding, and reverse-order disposal.
final class MuseGridAppBootstrap implements IAudioSessionController {
  final MuseGridPlatformWiring? _platformWiringOverride;
  final Future<Result<void>> Function(MusicFont font) _loadNotationFontHook;
  final Future<ByteData> Function(String assetPath) _loadAssetByteDataHook;
  final int Function() _nowEpochMs;
  final String Function() _uuidV7Generator;
  final TelemetryTickerFactory? _telemetryTickerFactory;
  final PeriodicTimerFactory? _playbackPeriodicTimerFactory;
  final CountInDelayFn? _countInDelay;
  final AuditionReleaseDelay? _auditionReleaseDelay;

  final ValueNotifier<AudioSessionStatus> _audioSessionStatus =
      ValueNotifier<AudioSessionStatus>(
        const AudioSessionStatus(phase: AudioSessionPhase.initializing),
      );

  MuseGridPlatformWiring? _wiring;
  MuseGridControllerBundle? _bundle;
  Future<Result<AudioHardwareInfo>>? _inFlightAudioInit;
  bool _storageInitialized = false;
  bool _isDisposed = false;

  MuseGridAppBootstrap({
    this._platformWiringOverride,
    Future<Result<void>> Function(MusicFont font)? loadNotationFontHook,
    Future<ByteData> Function(String assetPath)? loadAssetByteDataHook,
    int Function()? nowEpochMs,
    String Function()? uuidV7Generator,
    this._telemetryTickerFactory,
    this._playbackPeriodicTimerFactory,
    this._countInDelay,
    this._auditionReleaseDelay,
  }) : _loadNotationFontHook =
           loadNotationFontHook ?? _defaultLoadNotationFont,
       _loadAssetByteDataHook = loadAssetByteDataHook ?? rootBundle.load,
       _nowEpochMs =
           nowEpochMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _uuidV7Generator = uuidV7Generator ?? (() => const Uuid().v7());

  static Future<Result<void>> _defaultLoadNotationFont(MusicFont font) async {
    try {
      await MusicFonts.load(font);
      if (MusicFonts.metadataOrNull(font) == null) {
        return const Err<void>(
          MuseError(
            MuseErrorCode.casBlobMissing,
            BootstrapConstants.missingBravuraFontMessage,
          ),
        );
      }
      return const Ok<void>(null);
    } catch (err) {
      return Err<void>(
        MuseError(
          MuseErrorCode.casBlobMissing,
          '${BootstrapConstants.missingBravuraFontMessage} ($err)',
        ),
      );
    }
  }

  MuseGridPlatformWiring _resolveWiring() {
    final existing = _wiring;
    if (existing != null) {
      return existing;
    }
    final created =
        _platformWiringOverride ?? platform_wiring.createPlatformWiring();
    _wiring = created;
    return created;
  }

  @override
  ValueListenable<AudioSessionStatus> get audioSessionStatus =>
      _audioSessionStatus;

  @override
  CalibrationPlatform get currentPlatform => _resolveWiring().currentPlatform;

  @override
  Future<Result<AudioHardwareInfo>> ensureAudioInitialized() {
    if (_isDisposed) {
      return Future<Result<AudioHardwareInfo>>.value(
        const Err<AudioHardwareInfo>(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'MuseGridAppBootstrap has already been disposed.',
          ),
        ),
      );
    }

    final current = _audioSessionStatus.value;
    if (current.phase == AudioSessionPhase.ready &&
        current.hardwareInfo != null) {
      return Future<Result<AudioHardwareInfo>>.value(
        Ok<AudioHardwareInfo>(current.hardwareInfo!),
      );
    }

    final existingFuture = _inFlightAudioInit;
    if (existingFuture != null) {
      return existingFuture;
    }

    final initFuture = _runAudioInitialize();
    _inFlightAudioInit = initFuture;
    return initFuture;
  }

  Future<Result<AudioHardwareInfo>> _runAudioInitialize() async {
    try {
      final wiring = _resolveWiring();
      _setSessionStatus(
        const AudioSessionStatus(phase: AudioSessionPhase.initializing),
      );
      final res = await wiring.audioLifecycleBridge.initialize();
      if (_isDisposed) {
        return const Err<AudioHardwareInfo>(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'Audio initialization aborted during bootstrap disposal.',
          ),
        );
      }
      switch (res) {
        case Ok<AudioHardwareInfo>(:final value):
          _setSessionStatus(
            AudioSessionStatus(
              phase: AudioSessionPhase.ready,
              hardwareInfo: value,
            ),
          );
          return Ok<AudioHardwareInfo>(value);
        case Err<AudioHardwareInfo>(:final error):
          _setSessionStatus(
            AudioSessionStatus(phase: AudioSessionPhase.failed, error: error),
          );
          return Err<AudioHardwareInfo>(error);
      }
    } finally {
      _inFlightAudioInit = null;
    }
  }

  /// Runs the 7-step fail-closed initialization sequence and wires all L4/L5 components.
  Future<Result<MuseGridControllerBundle>> initialize() async {
    if (_isDisposed) {
      return const Err<MuseGridControllerBundle>(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Cannot initialize a disposed MuseGridAppBootstrap instance.',
        ),
      );
    }
    final existingBundle = _bundle;
    if (existingBundle != null) {
      return Ok<MuseGridControllerBundle>(existingBundle);
    }

    late final MuseGridPlatformWiring wiring;
    try {
      wiring = _resolveWiring();
    } catch (err) {
      return Err<MuseGridControllerBundle>(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Platform wiring initialization failed: $err',
        ),
      );
    }

    // Step 1: Preload Engraving Font & Register SMuFL Metadata
    final fontResult = await _loadNotationFontHook(
      MusePresentationConstants.defaultMusicFont,
    );
    if (fontResult case Err<void>(:final error)) {
      return Err<MuseGridControllerBundle>(error);
    }

    // Step 2: Initialize & Verify SQLite/CAS/OPFS Storage
    final storageResult = await wiring.storageMaintenance
        .initializeAndVerifyStorage();
    if (storageResult case Err<void>(:final error)) {
      await _rollbackPartialStorage(wiring);
      return Err<MuseGridControllerBundle>(error);
    }
    _storageInitialized = true;

    // Step 3: Startup Mark-and-Sweep CAS GC
    final gcResult = await wiring.storageMaintenance.runGarbageCollection(
      olderThanEpochMs:
          _nowEpochMs() - MusePresentationConstants.softDeleteRetentionMs,
    );
    if (gcResult case Err<int>(:final error)) {
      await _rollbackPartialStorage(wiring);
      return Err<MuseGridControllerBundle>(error);
    }

    // Step 4: Create SQL Repositories (strictly post-verification) & Seed Default SF2
    final projectRepository = wiring.createProjectRepository();
    final assetLibraryRepository = wiring.createAssetLibraryRepository();
    const soundFontPresetParser = SoundFontPresetParser();
    final dualModelScoreService = DualModelScoreService();

    final seedResult = await _seedBundledDefaultSoundFontIfMissing(
      assetLibraryRepository: assetLibraryRepository,
      presetParser: soundFontPresetParser,
    );
    if (seedResult case Err<void>(:final error)) {
      await _rollbackPartialStorage(wiring);
      return Err<MuseGridControllerBundle>(error);
    }

    // Step 5: Assemble L4 Coordinators with Late-Bound Workspace Delegation
    late WorkspaceShellController workspaceShellController;

    final playbackCoordinator = LookaheadPlaybackCoordinator(
      lifecycleBridge: wiring.audioLifecycleBridge,
      transportBridge: wiring.transportBridge,
      synthEventBridge: wiring.synthEventBridge,
      telemetryBridge: wiring.telemetryBridge,
      assetLibraryRepository: assetLibraryRepository,
      workspaceStateProvider: () => workspaceShellController.currentWorkspace,
      periodicTimerFactory: _playbackPeriodicTimerFactory,
    );

    final recordingCoordinator = RecordingSessionCoordinator(
      currentPlatform: wiring.currentPlatform,
      storageMaintenance: wiring.storageMaintenance,
      assetLibrary: assetLibraryRepository,
      projectRepository: projectRepository,
      lifecycleBridge: wiring.audioLifecycleBridge,
      transportBridge: wiring.transportBridge,
      synthEventBridge: wiring.synthEventBridge,
      recordingBridge: wiring.recordingBridge,
      telemetryBridge: wiring.telemetryBridge,
      playbackCoordinator: playbackCoordinator,
      activeWorkspaceProvider: () => workspaceShellController.currentWorkspace,
      onTakeCommitted: (take) =>
          workspaceShellController.syncCommittedTake(take),
      onTakesRealigned: (takes) =>
          workspaceShellController.syncRealignedTakes(takes),
      serializedProjectWrite: <T>(action) =>
          workspaceShellController.runSerializedIfActive<T>(action),
      countInDelay: _countInDelay,
    );

    workspaceShellController = WorkspaceShellController(
      projectRepository: projectRepository,
      dualModelScoreService: dualModelScoreService,
      playbackCoordinator: playbackCoordinator,
      audioSessionController: this,
      uuidV7Generator: _uuidV7Generator,
      nowEpochMs: _nowEpochMs,
    );

    // Step 6: Platform Audio HAL Initialization / Web User-Gesture Gate
    if (!wiring.requiresExplicitAudioUserGesture) {
      await ensureAudioInitialized();
    } else {
      _setSessionStatus(
        const AudioSessionStatus(
          phase: AudioSessionPhase.requiresWebUserGesture,
        ),
      );
    }

    // Step 7: Instantiate All 5 L5 Controllers & Preload Catalog
    final projectCatalogController = ProjectCatalogController(
      projectRepository: projectRepository,
      assetLibraryRepository: assetLibraryRepository,
      externalFileExchange: wiring.externalFileExchange,
      storageMaintenanceRepository: wiring.storageMaintenance,
      dualModelScoreService: dualModelScoreService,
      soundFontPresetParser: soundFontPresetParser,
      playbackCoordinator: playbackCoordinator,
      recordingCoordinator: recordingCoordinator,
      audioSessionController: this,
      activeProjectIdProvider: () =>
          workspaceShellController.currentWorkspace?.aggregate.project.projectId,
      activeProjectSoundFontIdsProvider: () =>
          workspaceShellController.activeUsedSoundFontIds,
      detachActiveProjectHook: () async {
        await workspaceShellController.closeProject();
        return const Ok<void>(null);
      },
      reopenProjectHook: workspaceShellController.reloadProjectById,
      uuidV7Generator: _uuidV7Generator,
      nowEpochMs: _nowEpochMs,
    );

    final staffNotationViewController = StaffNotationViewController(
      workspaceShellController: workspaceShellController,
      playbackCoordinator: playbackCoordinator,
      uuidV7Generator: _uuidV7Generator,
      nowEpochMs: _nowEpochMs,
      auditionReleaseDelay: _auditionReleaseDelay,
    );

    final pianoRollViewportController = PianoRollViewportController(
      workspaceShellController: workspaceShellController,
      dualModelScoreService: dualModelScoreService,
      playbackCoordinator: playbackCoordinator,
      uuidV7Generator: _uuidV7Generator,
      nowEpochMs: _nowEpochMs,
    );

    final transportAndTelemetryController = TransportAndTelemetryController(
      playbackCoordinator: playbackCoordinator,
      recordingCoordinator: recordingCoordinator,
      synthEventBridge: wiring.synthEventBridge,
      telemetryBridge: wiring.telemetryBridge,
      audioSessionController: this,
      workspaceShellController: workspaceShellController,
      tickerFactory: _telemetryTickerFactory,
    );

    final catalogLoadResult = await projectCatalogController
        .loadCatalogInitial();
    if (catalogLoadResult case Err<void>(:final error)) {
      transportAndTelemetryController.dispose();
      pianoRollViewportController.dispose();
      staffNotationViewController.dispose();
      projectCatalogController.dispose();
      workspaceShellController.dispose();
      await playbackCoordinator.dispose();
      await _rollbackPartialStorage(wiring);
      return Err<MuseGridControllerBundle>(error);
    }

    final bundle = MuseGridControllerBundle(
      bootstrap: this,
      audioSessionController: this,
      playbackCoordinator: playbackCoordinator,
      recordingCoordinator: recordingCoordinator,
      projectCatalogController: projectCatalogController,
      workspaceShellController: workspaceShellController,
      staffNotationViewController: staffNotationViewController,
      pianoRollViewportController: pianoRollViewportController,
      transportAndTelemetryController: transportAndTelemetryController,
    );
    _bundle = bundle;
    return Ok<MuseGridControllerBundle>(bundle);
  }

  Future<Result<void>> _seedBundledDefaultSoundFontIfMissing({
    required IAssetLibraryRepository assetLibraryRepository,
    required ISoundFontPresetParser presetParser,
  }) async {
    final existingResult = await assetLibraryRepository.listActiveSoundFonts();
    if (existingResult case Err<List<SoundFontCatalogEntry>>(:final error)) {
      return Err<void>(error);
    }
    final existing = (existingResult as Ok<List<SoundFontCatalogEntry>>).value;
    const expectedSha = Sha256Digest(MuseConstants.defaultSoundFontSha256);
    if (existing.any((entry) => entry.blobSha256 == expectedSha)) {
      return const Ok<void>(null);
    }

    final ByteData assetData;
    try {
      assetData = await _loadAssetByteDataHook(
        MuseConstants.defaultSoundFontAssetPath,
      );
    } catch (err) {
      return Err<void>(
        MuseError(
          MuseErrorCode.casBlobMissing,
          'Failed to load bundled default SoundFont asset (${MuseConstants.defaultSoundFontAssetPath}): $err',
        ),
      );
    }

    final rawBytes = assetData.buffer.asUint8List(
      assetData.offsetInBytes,
      assetData.lengthInBytes,
    );
    if (rawBytes.length != MuseConstants.defaultSoundFontByteSize) {
      return Err<void>(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          '${BootstrapConstants.defaultSoundFontSizeMismatchMessage} '
          'Expected ${MuseConstants.defaultSoundFontByteSize} bytes, got ${rawBytes.length}.',
        ),
      );
    }

    final presetsResult = await presetParser.parsePresetsFromSf2Stream(
      byteStream: Stream<List<int>>.value(rawBytes),
      byteLength: rawBytes.length,
    );
    if (presetsResult case Err<List<SoundFontPresetInfo>>(:final error)) {
      return Err<void>(error);
    }
    final presets = (presetsResult as Ok<List<SoundFontPresetInfo>>).value;

    final importResult = await assetLibraryRepository.importSoundFontBytes(
      displayName: MuseConstants.defaultSoundFontDisplayName,
      byteStream: Stream<List<int>>.value(rawBytes),
      byteLength: rawBytes.length,
      extractedPresets: presets,
    );
    if (importResult case Err<SoundFontCatalogEntry>(:final error)) {
      return Err<void>(error);
    }
    return const Ok<void>(null);
  }

  Future<void> _rollbackPartialStorage(MuseGridPlatformWiring wiring) async {
    if (_storageInitialized) {
      _storageInitialized = false;
      await wiring.storageMaintenance.close();
    }
  }

  void _setSessionStatus(AudioSessionStatus next) {
    if (!_isDisposed) {
      _audioSessionStatus.value = next;
    }
  }

  /// Disposes L5 controllers, L4 playback coordinator, platform audio HAL,
  /// and storage connections strictly in reverse initialization order.
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;

    final bundle = _bundle;
    _bundle = null;
    if (bundle != null) {
      bundle.transportAndTelemetryController.dispose();
      bundle.pianoRollViewportController.dispose();
      bundle.staffNotationViewController.dispose();
      bundle.projectCatalogController.dispose();
      bundle.workspaceShellController.dispose();
      await bundle.playbackCoordinator.dispose();
    }

    final wiring = _wiring;
    if (wiring != null) {
      await wiring.audioLifecycleBridge.dispose();
      if (_storageInitialized) {
        _storageInitialized = false;
        await wiring.storageMaintenance.close();
      }
    }

    _audioSessionStatus.dispose();
  }
}

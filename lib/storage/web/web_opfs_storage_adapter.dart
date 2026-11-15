/// Web OPFS + `sqlite3.wasm` (`SimpleOpfsFileSystem` / `IndexedDbFileSystem`)
/// storage adapter implementing maintenance, locator, and CAS contracts.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart' as web;

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/repositories/storage_contracts.dart';
import '../common/sqlite_schema_ddl.dart';

/// Host browser/worker boundary for `sqlite3.wasm` VFS and OPFS operations.
abstract interface class WebStorageHostBackend {
  Future<CommonDatabase> openWasmDatabase({required Uri wasmUri});

  Future<bool> requestPersistentStorage();

  Future<({int usageBytes, int quotaBytes})?> estimateStorageQuota();

  Future<bool> opfsFileExists(List<String> segments);

  Future<Uint8List?> readOpfsFile(List<String> segments);

  Future<void> writeOpfsFile(List<String> segments, Uint8List bytes);

  Future<bool> deleteOpfsFile(List<String> segments);

  Future<List<String>> listOpfsDirectoryEntries(List<String> segments);

  Future<void> flushDatabaseVfs();

  Future<void> closeDatabaseVfs();
}

final class _BrowserWebStorageHostBackend implements WebStorageHostBackend {
  static const String _sqliteDatabaseVirtualPath = '/database';
  static const String _domNotFoundError = 'NotFoundError';
  static const String _domTypeMismatchError = 'TypeMismatchError';

  final void Function(String warning) _onWarning;

  WasmSqlite3? _sqlite;
  VirtualFileSystem? _activeVfs;
  SimpleOpfsFileSystem? _opfsVfs;
  IndexedDbFileSystem? _idbVfs;

  _BrowserWebStorageHostBackend({required this._onWarning});

  @override
  Future<CommonDatabase> openWasmDatabase({required Uri wasmUri}) async {
    final sqlite = await WasmSqlite3.loadFromUrl(wasmUri);
    _sqlite = sqlite;

    final opfsPath = '${MuseConstants.dbDirName}/${MuseConstants.dbFileName}';
    try {
      final opfsVfs = await SimpleOpfsFileSystem.loadFromStorage(opfsPath);
      sqlite.registerVirtualFileSystem(opfsVfs, makeDefault: true);
      _activeVfs = opfsVfs;
      _opfsVfs = opfsVfs;
      _idbVfs = null;
      return sqlite.open(_sqliteDatabaseVirtualPath, vfs: opfsVfs.name);
    } catch (opfsError) {
      _onWarning(
        'SimpleOpfsFileSystem unavailable in current browser context '
        '(requires DedicatedWorkerGlobalScope for createSyncAccessHandle); '
        'falling back to IndexedDbFileSystem: $opfsError',
      );
      final idbVfs = await IndexedDbFileSystem.open(
        dbName: MuseConstants.dbFileName,
      );
      sqlite.registerVirtualFileSystem(idbVfs, makeDefault: true);
      _activeVfs = idbVfs;
      _opfsVfs = null;
      _idbVfs = idbVfs;
      return sqlite.open(_sqliteDatabaseVirtualPath, vfs: idbVfs.name);
    }
  }

  @override
  Future<bool> requestPersistentStorage() async {
    final storage = _tryGetStorageManager();
    if (storage == null) {
      return false;
    }
    try {
      final granted = await storage.persist().toDart;
      return granted.toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<({int usageBytes, int quotaBytes})?> estimateStorageQuota() async {
    final storage = _tryGetStorageManager();
    if (storage == null) {
      return null;
    }
    try {
      final estimate = await storage.estimate().toDart;
      final estimateObj = estimate as JSObject;
      if (!estimateObj.has('quota') || !estimateObj.has('usage')) {
        return null;
      }
      return (usageBytes: estimate.usage, quotaBytes: estimate.quota);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> opfsFileExists(List<String> segments) async =>
      (await _getOpfsFileHandle(segments)) != null;

  @override
  Future<Uint8List?> readOpfsFile(List<String> segments) async {
    try {
      final fileHandle = await _getOpfsFileHandle(segments);
      if (fileHandle == null) {
        return null;
      }
      final file = await fileHandle.getFile().toDart;
      final buffer = await file.arrayBuffer().toDart;
      return buffer.toDart.asUint8List();
    } catch (error) {
      if (_isDomMissingError(error)) {
        return null;
      }
      rethrow;
    }
  }

  Future<web.FileSystemFileHandle?> _getOpfsFileHandle(
    List<String> segments,
  ) async {
    if (segments.isEmpty) {
      return null;
    }
    try {
      final parentDir = await _resolveDirectory(
        segments.sublist(0, segments.length - 1),
        create: false,
      );
      if (parentDir == null) {
        return null;
      }
      return await parentDir.getFileHandle(segments.last).toDart;
    } catch (error) {
      if (_isDomMissingError(error)) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<void> writeOpfsFile(List<String> segments, Uint8List bytes) async {
    if (segments.isEmpty) {
      throw ArgumentError('OPFS file path segments must not be empty.');
    }
    final parentDir = (await _resolveDirectory(
      segments.sublist(0, segments.length - 1),
      create: true,
    ))!;
    final fileHandle = await parentDir
        .getFileHandle(
          segments.last,
          web.FileSystemGetFileOptions(create: true),
        )
        .toDart;
    final writable = await fileHandle.createWritable().toDart;
    try {
      await writable.write(bytes.toJS).toDart;
      await writable.close().toDart;
    } catch (_) {
      try {
        await writable.abort().toDart;
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<bool> deleteOpfsFile(List<String> segments) async {
    if (segments.isEmpty) {
      return false;
    }
    try {
      final parentDir = await _resolveDirectory(
        segments.sublist(0, segments.length - 1),
        create: false,
      );
      if (parentDir == null) {
        return false;
      }
      await parentDir.removeEntry(segments.last).toDart;
      return true;
    } catch (error) {
      if (_isDomMissingError(error)) {
        return false;
      }
      rethrow;
    }
  }

  @override
  Future<List<String>> listOpfsDirectoryEntries(List<String> segments) async {
    final dir = await _resolveDirectory(segments, create: false);
    if (dir == null) {
      return const <String>[];
    }

    final names = <String>[];
    final iterator = dir.callMethod<JSObject>('keys'.toJS);
    while (true) {
      final nextPromise =
          iterator.callMethod<JSPromise<JSObject>>('next'.toJS);
      final step = await nextPromise.toDart;
      final done = (step.getProperty('done'.toJS) as JSBoolean?)?.toDart ?? true;
      if (done) {
        break;
      }
      final value = (step.getProperty('value'.toJS) as JSString?)?.toDart;
      if (value != null && value.isNotEmpty) {
        names.add(value);
      }
    }
    return names;
  }

  @override
  Future<void> flushDatabaseVfs() async {
    await _idbVfs?.flush();
  }

  @override
  Future<void> closeDatabaseVfs() async {
    final opfsVfs = _opfsVfs;
    final idbVfs = _idbVfs;
    final vfs = _activeVfs;
    final sqlite = _sqlite;
    _opfsVfs = null;
    _idbVfs = null;
    _activeVfs = null;
    _sqlite = null;

    try {
      if (idbVfs != null) {
        await idbVfs.flush();
        await idbVfs.close();
      }
    } finally {
      if (vfs != null && sqlite != null) {
        try {
          sqlite.unregisterVirtualFileSystem(vfs);
        } catch (_) {
          // Ignore unregister failure if module is tearing down.
        }
      }
      try {
        // Close OPFS sync access handles explicitly because unregisterVirtualFileSystem
        // does not close the underlying SimpleOpfsFileSystem.
        opfsVfs?.close();
      } catch (_) {
        // Ignore handle close failures during teardown.
      }
    }
  }

  web.StorageManager? _tryGetStorageManager() {
    if (!globalContext.has('navigator')) {
      return null;
    }
    final nav = globalContext.getProperty('navigator'.toJS);
    if (!nav.isDefinedAndNotNull || !nav.typeofEquals('object')) {
      return null;
    }
    final navObj = nav as JSObject;
    if (!navObj.has('storage')) {
      return null;
    }
    final storage = navObj.getProperty('storage'.toJS);
    if (!storage.isDefinedAndNotNull || !storage.typeofEquals('object')) {
      return null;
    }
    return storage as web.StorageManager;
  }

  Future<web.FileSystemDirectoryHandle?> _resolveDirectory(
    List<String> segments, {
    required bool create,
  }) async {
    final storage = _tryGetStorageManager();
    if (storage == null) {
      return null;
    }
    try {
      var current = await storage.getDirectory().toDart;
      for (final segment in segments) {
        if (segment.isEmpty) {
          continue;
        }
        current = await current
            .getDirectoryHandle(
              segment,
              web.FileSystemGetDirectoryOptions(create: create),
            )
            .toDart;
      }
      return current;
    } catch (error) {
      if (!create && _isDomMissingError(error)) {
        return null;
      }
      rethrow;
    }
  }

  bool _isDomMissingError(Object error) {
    final text = error.toString();
    return text.contains(_domNotFoundError) ||
        text.contains(_domTypeMismatchError);
  }
}

/// Web implementation of [IStorageMaintenanceRepository],
/// [IInternalStorageLocator], and [ICasBlobStore] backed by OPFS + `sqlite3.wasm`.
final class WebOpfsStorageAdapter
    implements
        IStorageMaintenanceRepository,
        IInternalStorageLocator,
        ICasBlobStore {
  static const String _defaultWasmAssetName = 'sqlite3.wasm';

  /// `dart:developer` severity threshold corresponding to warning logs.
  static const int _warningLogLevel = 900;

  final WebStorageHostBackend _backend;
  final Uri _sqliteWasmUri;
  final int Function() _nowEpochMs;
  final void Function(String warning) _onWarning;

  CommonDatabase? _db;
  bool _initialized = false;

  WebOpfsStorageAdapter({
    WebStorageHostBackend? backend,
    Uri? sqliteWasmUri,
    int Function()? nowEpochMs,
    void Function(String warning)? onWarning,
  })  : _onWarning = onWarning ?? _defaultLogWarning,
        _sqliteWasmUri = sqliteWasmUri ?? Uri.parse(_defaultWasmAssetName),
        _nowEpochMs =
            nowEpochMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
        _backend = backend ??
            _BrowserWebStorageHostBackend(
              onWarning: onWarning ?? _defaultLogWarning,
            );

  static void _defaultLogWarning(String warning) {
    developer.log(
      warning,
      name: 'MuseGrid.WebOpfsStorageAdapter',
      level: _warningLogLevel,
    );
  }

  /// Active SQLite database handle; throws [StateError] if uninitialized.
  CommonDatabase get database {
    final db = _db;
    if (db == null || !_initialized) {
      throw StateError('WebOpfsStorageAdapter is not initialized.');
    }
    return db;
  }

  @override
  Future<Result<void>> initializeAndVerifyStorage() async {
    if (_initialized && _db != null) {
      return const Ok(null);
    }

    CommonDatabase? openedDb;
    try {
      final persisted = await _backend.requestPersistentStorage();
      if (!persisted) {
        _onWarning(
          'Browser denied navigator.storage.persist(); OPFS/IDB storage '
          'remains best-effort.',
        );
      }

      openedDb = await _backend.openWasmDatabase(wasmUri: _sqliteWasmUri);

      final pragmaResult = SqliteSchemaDdl.configureAndVerifyPragmas(
        openedDb,
        isWeb: true,
      );
      if (pragmaResult case Err(:final error)) {
        openedDb.close();
        await _backend.closeDatabaseVfs();
        return Err(error);
      }

      final migrateResult = SqliteSchemaDdl.applyMigrations(
        openedDb,
        nowEpochMs: _nowEpochMs,
      );
      if (migrateResult case Err(:final error)) {
        openedDb.close();
        await _backend.closeDatabaseVfs();
        return Err(error);
      }

      await _backend.flushDatabaseVfs();
      await _sweepOrphanStagingPartFiles();

      _db = openedDb;
      _initialized = true;
      return const Ok(null);
    } catch (error) {
      try {
        openedDb?.close();
      } catch (_) {}
      try {
        await _backend.closeDatabaseVfs();
      } catch (_) {}
      return Err(
        SqliteErrorMapper.mapException(
          error,
          contextMessage: 'Failed to initialize WebOpfsStorageAdapter',
        ),
      );
    }
  }

  @override
  Future<Result<int>> verifyAvailableQuotaBytes({
    required int requiredBytes,
  }) async {
    if (requiredBytes < 0) {
      return Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'requiredBytes must be >= 0 (got $requiredBytes).',
        ),
      );
    }

    try {
      final estimate = await _backend.estimateStorageQuota();
      if (estimate == null) {
        return const Err(
          MuseError(
            MuseErrorCode.insufficientStorageQuota,
            'Browser storage quota estimation is unavailable.',
          ),
        );
      }

      final availableBytes = math.max(
        0,
        estimate.quotaBytes - estimate.usageBytes,
      );
      if (availableBytes < requiredBytes) {
        return Err(
          MuseError(
            MuseErrorCode.insufficientStorageQuota,
            'Insufficient browser OPFS quota: available=$availableBytes bytes, '
            'required=$requiredBytes bytes.',
          ),
        );
      }
      return Ok(availableBytes);
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.insufficientStorageQuota,
          'Failed to estimate browser storage quota: $error',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<int>> runGarbageCollection({
    required int olderThanEpochMs,
  }) async {
    if (!_initialized || _db == null) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'WebOpfsStorageAdapter is not initialized.',
        ),
      );
    }

    final gcResult = await SqliteGarbageCollector.runGarbageCollection(
      db: database,
      casStore: this,
      olderThanEpochMs: olderThanEpochMs,
    );
    if (gcResult.isOk) {
      await _backend.flushDatabaseVfs();
    }
    return gcResult;
  }

  @override
  Future<void> close() async {
    final db = _db;
    _db = null;
    _initialized = false;
    try {
      await _backend.flushDatabaseVfs();
    } finally {
      try {
        db?.close();
      } finally {
        await _backend.closeDatabaseVfs();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // IInternalStorageLocator
  // ---------------------------------------------------------------------------

  @override
  String? resolveNativeCasPosixPath(
    Sha256Digest sha256, {
    required String ext,
  }) =>
      null;

  @override
  String resolveRecordingStagingPath(TakeId takeId) {
    final rawId = takeId.value;
    if (rawId.trim().isEmpty ||
        rawId.contains('/') ||
        rawId.contains('\\') ||
        rawId.contains('..')) {
      throw ArgumentError.value(
        rawId,
        'takeId',
        'TakeId must be non-empty and free of path separators or "..".',
      );
    }
    return '/${MuseConstants.stagingDirName}/'
        '${SqliteSchemaDdl.recordingFilePrefix}$rawId.'
        '${SqliteSchemaDdl.wavExtension}${SqliteSchemaDdl.partFileSuffix}';
  }

  @override
  Future<Result<List<int>>> readCasBlobBytes(
    Sha256Digest sha256, {
    required String ext,
  }) async {
    final shaCheck = SqliteValueCodec.validateSha256Hex(sha256);
    if (shaCheck case Err(:final error)) {
      return Err(error);
    }
    final extCheck = SqliteValueCodec.validateCasExt(ext);
    if (extCheck case Err(:final error)) {
      return Err(error);
    }

    try {
      final bytes = await _backend.readOpfsFile(_casSegments(sha256, ext));
      if (bytes == null) {
        return Err(
          MuseError(
            MuseErrorCode.casBlobMissing,
            'OPFS CAS blob missing for ${sha256.value}.$ext.',
          ),
        );
      }
      return Ok(bytes);
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.casBlobMissing,
          'Failed to read OPFS CAS blob ${sha256.value}.$ext: $error',
          cause: error,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // ICasBlobStore
  // ---------------------------------------------------------------------------

  @override
  Future<Result<int>> promoteStagingFileToCas({
    required String stagingPath,
    required Sha256Digest expectedSha256,
    required String ext,
  }) async {
    final shaCheck = SqliteValueCodec.validateSha256Hex(expectedSha256);
    if (shaCheck case Err(:final error)) {
      return Err(error);
    }
    final extCheck = SqliteValueCodec.validateCasExt(ext);
    if (extCheck case Err(:final error)) {
      return Err(error);
    }

    final segments = _parseOpfsSegments(stagingPath);
    if (segments == null) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Invalid OPFS staging path "$stagingPath".',
        ),
      );
    }

    try {
      final bytes = await _backend.readOpfsFile(segments);
      if (bytes == null || bytes.isEmpty) {
        await _safeDeleteOpfsFile(segments);
        return Err(
          MuseError(
            MuseErrorCode.casPromotionFailed,
            'Missing or empty OPFS staging artifact "$stagingPath".',
          ),
        );
      }

      final actualSha = sha256.convert(bytes).toString();
      if (actualSha != expectedSha256.value) {
        await _safeDeleteOpfsFile(segments);
        return Err(
          MuseError(
            MuseErrorCode.casPromotionFailed,
            'OPFS staging artifact SHA-256 mismatch: '
            'expected=${expectedSha256.value}, actual=$actualSha.',
          ),
        );
      }

      final casSegs = _casSegments(expectedSha256, ext);
      if (!await _backend.opfsFileExists(casSegs)) {
        await _backend.writeOpfsFile(casSegs, bytes);
      }
      await _safeDeleteOpfsFile(segments);
      return Ok(bytes.length);
    } catch (error) {
      await _safeDeleteOpfsFile(segments);
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to promote OPFS staging artifact "$stagingPath": $error',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<({Sha256Digest sha256, int byteSize})>> writeStreamToCas({
    required Stream<List<int>> byteStream,
    required int expectedByteLength,
    required String ext,
  }) async {
    final extCheck = SqliteValueCodec.validateCasExt(ext);
    if (extCheck case Err(:final error)) {
      return Err(error);
    }
    if (expectedByteLength <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Expected byte length must be > 0.',
        ),
      );
    }
    if (ext == SqliteSchemaDdl.sf2Extension &&
        expectedByteLength > MuseConstants.maxWebSoundFontBytes) {
      return Err(
        MuseError(
          MuseErrorCode.soundFontTooLargeForWeb,
          'SoundFont size $expectedByteLength bytes exceeds Web cap '
          '${MuseConstants.maxWebSoundFontBytes} bytes.',
        ),
      );
    }

    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in byteStream) {
        if (chunk.isEmpty) {
          continue;
        }
        builder.add(chunk);
        if (ext == SqliteSchemaDdl.sf2Extension &&
            builder.length > MuseConstants.maxWebSoundFontBytes) {
          return Err(
            MuseError(
              MuseErrorCode.soundFontTooLargeForWeb,
              'SoundFont stream exceeded Web cap '
              '${MuseConstants.maxWebSoundFontBytes} bytes.',
            ),
          );
        }
        if (builder.length > expectedByteLength) {
          return Err(
            MuseError(
              MuseErrorCode.casPromotionFailed,
              'Stream exceeded expectedByteLength=$expectedByteLength.',
            ),
          );
        }
      }

      final bytes = builder.takeBytes();
      if (bytes.length != expectedByteLength || bytes.isEmpty) {
        return Err(
          MuseError(
            MuseErrorCode.casPromotionFailed,
            'Stream byte length mismatch: expected=$expectedByteLength, '
            'actual=${bytes.length}.',
          ),
        );
      }

      final digest = Sha256Digest(sha256.convert(bytes).toString());
      final casSegs = _casSegments(digest, ext);
      if (!await _backend.opfsFileExists(casSegs)) {
        await _backend.writeOpfsFile(casSegs, bytes);
      }
      return Ok((sha256: digest, byteSize: bytes.length));
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to write stream into OPFS CAS: $error',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> deleteCasBlob(
    Sha256Digest sha256, {
    required String ext,
  }) async {
    final shaCheck = SqliteValueCodec.validateSha256Hex(sha256);
    if (shaCheck case Err(:final error)) {
      return Err(error);
    }
    final extCheck = SqliteValueCodec.validateCasExt(ext);
    if (extCheck case Err(:final error)) {
      return Err(error);
    }

    try {
      await _backend.deleteOpfsFile(_casSegments(sha256, ext));
      return const Ok(null);
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to delete OPFS CAS blob ${sha256.value}.$ext: $error',
          cause: error,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Private Helpers
  // ---------------------------------------------------------------------------

  Future<void> _sweepOrphanStagingPartFiles() async {
    final entries = await _backend.listOpfsDirectoryEntries(
      const [MuseConstants.stagingDirName],
    );
    for (final entry in entries) {
      if (entry.endsWith(SqliteSchemaDdl.partFileSuffix)) {
        await _safeDeleteOpfsFile([MuseConstants.stagingDirName, entry]);
      }
    }
  }

  Future<void> _safeDeleteOpfsFile(List<String> segments) async {
    try {
      await _backend.deleteOpfsFile(segments);
    } catch (_) {
      // Ignore cleanup failures for missing staging artifacts.
    }
  }

  static List<String> _casSegments(Sha256Digest sha256, String ext) => [
        MuseConstants.casDirName,
        SqliteValueCodec.casShardPrefix(sha256),
        SqliteValueCodec.casFileName(sha256, ext),
      ];

  static List<String>? _parseOpfsSegments(String path) {
    final segments = path
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty ||
        segments.any((s) => s == '.' || s == '..' || s.contains('\\'))) {
      return null;
    }
    return segments;
  }
}

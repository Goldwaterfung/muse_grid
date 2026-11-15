/// Native FFI SQLite (`WAL`), POSIX CAS, and storage maintenance adapter.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart' as native_sqlite;

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/repositories/storage_contracts.dart';
import '../common/sqlite_schema_ddl.dart';

/// Native implementation of [IStorageMaintenanceRepository],
/// [IInternalStorageLocator], and [ICasBlobStore] over
/// `ApplicationSupportDirectory/{db,cas,staging}` and `sqlite3` `WAL`.
final class NativeStorageAdapter
    implements
        IStorageMaintenanceRepository,
        IInternalStorageLocator,
        ICasBlobStore {
  static const String _iosStorageAttributesChannelName =
      'musegrid/storage_attributes';
  static const String _excludeFromBackupMethod = 'excludeFromBackup';

  /// Sequential read buffer size (64 KiB) for streaming SHA-256 verification.
  static const int _hashReadChunkBytes = 64 * MuseConstants.bytesPerKib;

  /// Win32 `BOOL` return value indicating API failure.
  static const int _win32BoolFalse = 0;

  /// Upper clamp when an unsigned 64-bit Win32 byte count exceeds signed 64-bit range.
  static const int _maxSignedInt64 = 0x7FFFFFFFFFFFFFFF;

  static final RegExp _dfPercentTokenRegex = RegExp(r'^\d+%$');

  final Future<Directory> Function() _resolveAppSupportDir;
  final Future<int?> Function(String directoryPath)? _queryFreeDiskBytes;
  final MethodChannel _iosBackupExclusionChannel;
  final int Function() _nowEpochMs;

  Directory? _rootDir;
  CommonDatabase? _db;
  int _importSeq = 0;

  NativeStorageAdapter({
    Future<Directory> Function()? resolveAppSupportDir,
    this._queryFreeDiskBytes,
    MethodChannel? iosBackupExclusionChannel,
    int Function()? nowEpochMs,
  })  : _resolveAppSupportDir =
            resolveAppSupportDir ?? getApplicationSupportDirectory,
        _iosBackupExclusionChannel = iosBackupExclusionChannel ??
            const MethodChannel(_iosStorageAttributesChannelName),
        _nowEpochMs =
            nowEpochMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  /// Active SQLite database connection; throws [StateError] if uninitialized.
  CommonDatabase get database {
    final db = _db;
    if (db == null) {
      throw StateError('NativeStorageAdapter is not initialized.');
    }
    return db;
  }

  /// Root storage directory (`ApplicationSupportDirectory` or injected temp dir).
  Directory get rootDirectory {
    final dir = _rootDir;
    if (dir == null) {
      throw StateError('NativeStorageAdapter is not initialized.');
    }
    return dir;
  }

  @override
  Future<Result<void>> initializeAndVerifyStorage() async {
    if (_db != null && _rootDir != null) {
      return const Ok(null);
    }

    CommonDatabase? openedDb;
    try {
      final rootDir = await _resolveAppSupportDir();
      final dbDir = Directory(p.join(rootDir.path, MuseConstants.dbDirName));
      final casDir = Directory(p.join(rootDir.path, MuseConstants.casDirName));
      final stagingDir = Directory(
        p.join(rootDir.path, MuseConstants.stagingDirName),
      );

      await dbDir.create(recursive: true);
      await casDir.create(recursive: true);
      await stagingDir.create(recursive: true);

      if (Platform.isIOS) {
        await _excludeIosBackupAttributes([casDir.path, stagingDir.path]);
      }

      final dbPath = p.join(dbDir.path, MuseConstants.dbFileName);
      openedDb = native_sqlite.sqlite3.open(dbPath);

      final pragmaResult = SqliteSchemaDdl.configureAndVerifyPragmas(
        openedDb,
        isWeb: false,
      );
      if (pragmaResult case Err(:final error)) {
        openedDb.close();
        return Err(error);
      }

      final migrateResult = SqliteSchemaDdl.applyMigrations(
        openedDb,
        nowEpochMs: _nowEpochMs,
      );
      if (migrateResult case Err(:final error)) {
        openedDb.close();
        return Err(error);
      }

      await _sweepOrphanStagingFiles(stagingDir);
      _rootDir = rootDir;
      _db = openedDb;
      return const Ok(null);
    } catch (error) {
      try {
        openedDb?.close();
      } catch (_) {}
      return Err(
        SqliteErrorMapper.mapException(
          error,
          contextMessage: 'Failed to initialize NativeStorageAdapter',
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
    final rootDir = _rootDir;
    if (rootDir == null) {
      return const Err(
        MuseError(
          MuseErrorCode.insufficientStorageQuota,
          'NativeStorageAdapter is not initialized.',
        ),
      );
    }

    try {
      final freeBytes = _queryFreeDiskBytes != null
          ? await _queryFreeDiskBytes(rootDir.path)
          : await _probeNativeFreeBytes(rootDir.path);

      if (freeBytes == null || freeBytes < 0) {
        return const Err(
          MuseError(
            MuseErrorCode.insufficientStorageQuota,
            'Unable to determine available native storage quota.',
          ),
        );
      }
      if (freeBytes < requiredBytes) {
        return Err(
          MuseError(
            MuseErrorCode.insufficientStorageQuota,
            'Insufficient storage space: available=$freeBytes bytes, '
            'required=$requiredBytes bytes.',
          ),
        );
      }
      return Ok(freeBytes);
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.insufficientStorageQuota,
          'Failed to probe available disk space: $error',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<int>> runGarbageCollection({
    required int olderThanEpochMs,
  }) async {
    final db = _db;
    if (_rootDir == null || db == null) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'NativeStorageAdapter is not initialized.',
        ),
      );
    }

    return SqliteGarbageCollector.runGarbageCollection(
      db: db,
      casStore: this,
      olderThanEpochMs: olderThanEpochMs,
    );
  }

  @override
  Future<void> close() async {
    final db = _db;
    _db = null;
    _rootDir = null;
    if (db == null) {
      return;
    }
    try {
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } catch (_) {
      // Best-effort checkpoint before closing handle.
    } finally {
      db.close();
    }
  }

  // ---------------------------------------------------------------------------
  // IInternalStorageLocator
  // ---------------------------------------------------------------------------

  @override
  String? resolveNativeCasPosixPath(
    Sha256Digest sha256, {
    required String ext,
  }) {
    final rootDir = rootDirectory;
    final shard = SqliteValueCodec.casShardPrefix(sha256);
    final fileName = SqliteValueCodec.casFileName(sha256, ext);
    return p.join(rootDir.path, MuseConstants.casDirName, shard, fileName);
  }

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
    final rootDir = rootDirectory;
    return p.join(
      rootDir.path,
      MuseConstants.stagingDirName,
      '${SqliteSchemaDdl.recordingFilePrefix}$rawId.'
      '${SqliteSchemaDdl.wavExtension}${SqliteSchemaDdl.partFileSuffix}',
    );
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
    if (_rootDir == null) {
      return const Err(
        MuseError(
          MuseErrorCode.casBlobMissing,
          'NativeStorageAdapter is not initialized.',
        ),
      );
    }

    try {
      final casPath = resolveNativeCasPosixPath(sha256, ext: ext)!;
      final file = File(casPath);
      if (!await file.exists()) {
        return Err(
          MuseError(
            MuseErrorCode.casBlobMissing,
            'CAS blob not found at "$casPath".',
          ),
        );
      }
      final bytes = await file.readAsBytes();
      return Ok(bytes);
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.casBlobMissing,
          'Failed to read CAS blob ${sha256.value}.$ext: $error',
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
    final rootDir = _rootDir;
    if (rootDir == null) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'NativeStorageAdapter is not initialized.',
        ),
      );
    }

    final stagingDir = Directory(
      p.join(rootDir.path, MuseConstants.stagingDirName),
    );
    final normalizedStagingDir = p.normalize(p.absolute(stagingDir.path));
    final normalizedStagingPath = p.normalize(p.absolute(stagingPath));
    if (!p.isWithin(normalizedStagingDir, normalizedStagingPath)) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Staging path "$stagingPath" is outside the adapter staging directory.',
        ),
      );
    }

    final stagingFile = File(normalizedStagingPath);
    if (!stagingFile.existsSync()) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Staging artifact does not exist at "$stagingPath".',
        ),
      );
    }

    final canonicalStagingDir = stagingDir.resolveSymbolicLinksSync();
    final canonicalStagingPath = stagingFile.resolveSymbolicLinksSync();
    if (!p.isWithin(canonicalStagingDir, canonicalStagingPath)) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Staging path "$stagingPath" resolves outside the adapter staging directory.',
        ),
      );
    }

    try {
      final hashed = await Isolate.run(() => _hashFileSync(canonicalStagingPath));
      if (hashed.byteSize <= 0 || hashed.sha256Hex != expectedSha256.value) {
        await _safeDeleteFile(stagingFile);
        return Err(
          MuseError(
            MuseErrorCode.casPromotionFailed,
            'Staging artifact failed SHA-256/size verification: '
            'expected=${expectedSha256.value}, actual=${hashed.sha256Hex}, '
            'bytes=${hashed.byteSize}.',
          ),
        );
      }

      final casPath = resolveNativeCasPosixPath(expectedSha256, ext: ext)!;
      await _promoteFileAtomically(stagingFile, File(casPath));
      return Ok(hashed.byteSize);
    } catch (error) {
      await _safeDeleteFile(stagingFile);
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to promote staging file "$stagingPath" to CAS: $error',
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
    final rootDir = _rootDir;
    if (rootDir == null) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'NativeStorageAdapter is not initialized.',
        ),
      );
    }

    final seq = _importSeq++;
    final tempPath = p.join(
      rootDir.path,
      MuseConstants.stagingDirName,
      'import_${_nowEpochMs()}_$seq.$ext${SqliteSchemaDdl.partFileSuffix}',
    );
    final tempFile = File(tempPath);

    IOSink? sink;
    try {
      await tempFile.parent.create(recursive: true);
      sink = tempFile.openWrite();
      final digestSink = _SingleDigestSink();
      final hashInput = sha256.startChunkedConversion(digestSink);

      var actualBytes = 0;
      await for (final chunk in byteStream) {
        if (chunk.isEmpty) {
          continue;
        }
        actualBytes += chunk.length;
        if (actualBytes > expectedByteLength) {
          throw FormatException(
            'Stream exceeded expectedByteLength=$expectedByteLength.',
          );
        }
        hashInput.add(chunk);
        sink.add(chunk);
      }

      hashInput.close();
      await sink.flush();
      await sink.close();
      sink = null;

      if (actualBytes != expectedByteLength || actualBytes <= 0) {
        await _safeDeleteFile(tempFile);
        return Err(
          MuseError(
            MuseErrorCode.casPromotionFailed,
            'Stream byte length mismatch: expected=$expectedByteLength, '
            'actual=$actualBytes.',
          ),
        );
      }

      final digest = Sha256Digest(digestSink.value.toString());
      final casPath = resolveNativeCasPosixPath(digest, ext: ext)!;
      await _promoteFileAtomically(tempFile, File(casPath));
      return Ok((sha256: digest, byteSize: actualBytes));
    } catch (error) {
      try {
        await sink?.close();
      } catch (_) {}
      await _safeDeleteFile(tempFile);
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to write stream into CAS: $error',
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
    if (_rootDir == null) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'NativeStorageAdapter is not initialized.',
        ),
      );
    }

    try {
      final casPath = resolveNativeCasPosixPath(sha256, ext: ext)!;
      final file = File(casPath);
      if (await file.exists()) {
        await file.delete();
      }
      return const Ok(null);
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to delete CAS blob ${sha256.value}.$ext: $error',
          cause: error,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Private Helpers
  // ---------------------------------------------------------------------------

  Future<void> _excludeIosBackupAttributes(List<String> paths) async {
    for (final path in paths) {
      try {
        await _iosBackupExclusionChannel.invokeMethod<void>(
          _excludeFromBackupMethod,
          <String, Object?>{'path': path, 'excluded': true},
        );
      } on MissingPluginException {
        // Headless/VM environments do not register native iOS attribute channels.
      }
    }
  }

  Future<void> _sweepOrphanStagingFiles(Directory stagingDir) async {
    if (!await stagingDir.exists()) {
      return;
    }
    await for (final entity in stagingDir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith(SqliteSchemaDdl.partFileSuffix)) {
        await _safeDeleteFile(entity);
      }
    }
  }

  Future<void> _promoteFileAtomically(File stagingFile, File casFile) async {
    await casFile.parent.create(recursive: true);
    if (await casFile.exists()) {
      await _safeDeleteFile(stagingFile);
      return;
    }
    await stagingFile.rename(casFile.path);
  }

  Future<void> _safeDeleteFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore cleanup failure for already-removed files.
    }
  }

  static ({String sha256Hex, int byteSize}) _hashFileSync(String path) {
    final file = File(path);
    final raf = file.openSync(mode: FileMode.read);
    try {
      final buffer = Uint8List(_hashReadChunkBytes);
      final digestSink = _SingleDigestSink();
      final hashInput = sha256.startChunkedConversion(digestSink);
      var totalBytes = 0;

      while (true) {
        final bytesRead = raf.readIntoSync(buffer);
        if (bytesRead <= 0) {
          break;
        }
        totalBytes += bytesRead;
        hashInput.add(
          bytesRead == buffer.length
              ? buffer
              : Uint8List.sublistView(buffer, 0, bytesRead),
        );
      }
      hashInput.close();
      return (sha256Hex: digestSink.value.toString(), byteSize: totalBytes);
    } finally {
      raf.closeSync();
    }
  }

  Future<int?> _probeNativeFreeBytes(String directoryPath) async {
    if (Platform.isWindows) {
      return _probeWindowsFreeBytes(directoryPath);
    }
    return _probePosixFreeBytes(directoryPath);
  }

  int? _probeWindowsFreeBytes(String directoryPath) {
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    final getDiskFreeSpaceExW = kernel32.lookupFunction<
        _GetDiskFreeSpaceExWNative, _GetDiskFreeSpaceExWDart>(
      'GetDiskFreeSpaceExW',
    );
    final dirPtr = directoryPath.toNativeUtf16(allocator: pkg_ffi.calloc);
    final freeBytesPtr = pkg_ffi.calloc<ffi.Uint64>();
    try {
      final ok = getDiskFreeSpaceExW(
        dirPtr,
        freeBytesPtr,
        ffi.nullptr,
        ffi.nullptr,
      );
      if (ok == _win32BoolFalse) {
        return null;
      }
      final available = freeBytesPtr.value;
      if (available < 0) {
        return _maxSignedInt64;
      }
      return available;
    } finally {
      pkg_ffi.calloc.free(dirPtr);
      pkg_ffi.calloc.free(freeBytesPtr);
    }
  }

  Future<int?> _probePosixFreeBytes(String directoryPath) async {
    if (!(Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isIOS ||
        Platform.isAndroid)) {
      return null;
    }
    final result = await Process.run('df', ['-Pk', directoryPath]);
    if (result.exitCode != 0) {
      return null;
    }
    final lines = result.stdout
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length < 2) {
      return null;
    }
    final tokens = lines.last.split(RegExp(r'\s+'));
    final percentIndex =
        tokens.indexWhere((token) => _dfPercentTokenRegex.hasMatch(token));
    if (percentIndex <= 0) {
      return null;
    }
    final availKib = int.tryParse(tokens[percentIndex - 1]);
    if (availKib == null || availKib < 0) {
      return null;
    }
    return availKib * MuseConstants.bytesPerKib;
  }
}

final class _SingleDigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get value {
    final digest = _digest;
    if (digest == null) {
      throw StateError('SHA-256 digest was not finalized.');
    }
    return digest;
  }

  @override
  void add(Digest data) {
    _digest = data;
  }

  @override
  void close() {}
}

typedef _GetDiskFreeSpaceExWNative = ffi.Int32 Function(
  ffi.Pointer<pkg_ffi.Utf16> lpDirectoryName,
  ffi.Pointer<ffi.Uint64> lpFreeBytesAvailableToCaller,
  ffi.Pointer<ffi.Uint64> lpTotalNumberOfBytes,
  ffi.Pointer<ffi.Uint64> lpTotalNumberOfFreeBytes,
);

typedef _GetDiskFreeSpaceExWDart = int Function(
  ffi.Pointer<pkg_ffi.Utf16> lpDirectoryName,
  ffi.Pointer<ffi.Uint64> lpFreeBytesAvailableToCaller,
  ffi.Pointer<ffi.Uint64> lpTotalNumberOfBytes,
  ffi.Pointer<ffi.Uint64> lpTotalNumberOfFreeBytes,
);

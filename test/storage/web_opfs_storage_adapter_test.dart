@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/storage/common/sqlite_schema_ddl.dart';
import 'package:muse_grid/storage/web/web_external_file_exchange.dart';
import 'package:muse_grid/storage/web/web_opfs_storage_adapter.dart';
import 'package:sqlite3/common.dart';

final class _FakeWebDatabase extends Fake implements CommonDatabase {
  String journalMode;
  int foreignKeys = 0;
  int schemaVersion = 0;
  bool isClosed = false;
  final List<String> executedStatements = <String>[];
  final List<({String sha256, String ext, int byteSize})> orphanBlobs =
      <({String sha256, String ext, int byteSize})>[];

  _FakeWebDatabase({this.journalMode = 'delete'});

  @override
  int get updatedRows => 0;

  @override
  void execute(String sql, [List<Object?> parameters = const []]) {
    executedStatements.add(sql);
    final normalized = sql.trim().toLowerCase();
    if (normalized.startsWith('pragma foreign_keys = on')) {
      foreignKeys = 1;
    } else if (normalized.startsWith('pragma journal_mode = wal')) {
      journalMode = 'wal';
    } else if (normalized.startsWith('insert into schema_migrations')) {
      schemaVersion = parameters.first as int;
    }
  }

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) {
    final normalized = sql.trim().toLowerCase();
    if (normalized.startsWith('pragma foreign_keys')) {
      return ResultSet(['foreign_keys'], null, [
        [foreignKeys],
      ]);
    }
    if (normalized.startsWith('pragma journal_mode')) {
      return ResultSet(['journal_mode'], null, [
        [journalMode],
      ]);
    }
    if (normalized.contains('from schema_migrations')) {
      return ResultSet(['current_version'], null, [
        [schemaVersion],
      ]);
    }
    if (normalized.startsWith('delete from content_blobs')) {
      final swept = orphanBlobs
          .map<List<Object?>>((b) => [b.sha256, b.ext, b.byteSize])
          .toList(growable: false);
      orphanBlobs.clear();
      return ResultSet(['sha256', 'ext', 'byte_size'], null, swept);
    }
    return ResultSet(const [], null, const []);
  }

  @override
  void close() {
    isClosed = true;
  }
}

final class _FakeWebStorageHostBackend implements WebStorageHostBackend {
  final _FakeWebDatabase fakeDb;
  final Map<String, Uint8List> opfsFiles = <String, Uint8List>{};

  bool persistentGranted = true;
  ({int usageBytes, int quotaBytes})? quotaEstimate = (
    usageBytes: 1024,
    quotaBytes: 100 * MuseConstants.bytesPerMib,
  );
  int flushCount = 0;
  int closeVfsCount = 0;
  int readOpfsCount = 0;
  int existsOpfsCount = 0;

  _FakeWebStorageHostBackend(this.fakeDb);

  String _key(List<String> segments) => segments.join('/');

  @override
  Future<CommonDatabase> openWasmDatabase({required Uri wasmUri}) async =>
      fakeDb;

  @override
  Future<bool> requestPersistentStorage() async => persistentGranted;

  @override
  Future<({int usageBytes, int quotaBytes})?> estimateStorageQuota() async =>
      quotaEstimate;

  @override
  Future<bool> opfsFileExists(List<String> segments) async {
    existsOpfsCount++;
    return opfsFiles.containsKey(_key(segments));
  }

  @override
  Future<Uint8List?> readOpfsFile(List<String> segments) async {
    readOpfsCount++;
    return opfsFiles[_key(segments)];
  }

  @override
  Future<void> writeOpfsFile(List<String> segments, Uint8List bytes) async {
    opfsFiles[_key(segments)] = bytes;
  }

  @override
  Future<bool> deleteOpfsFile(List<String> segments) async =>
      opfsFiles.remove(_key(segments)) != null;

  @override
  Future<List<String>> listOpfsDirectoryEntries(List<String> segments) async {
    final prefix = '${_key(segments)}/';
    return opfsFiles.keys
        .where((key) => key.startsWith(prefix))
        .map((key) => key.substring(prefix.length))
        .where((entry) => !entry.contains('/'))
        .toList(growable: false);
  }

  @override
  Future<void> flushDatabaseVfs() async {
    flushCount++;
  }

  @override
  Future<void> closeDatabaseVfs() async {
    closeVfsCount++;
  }
}

final class _FakeWebFileExchangeBackend implements WebFileExchangeBackend {
  PickedExternalFile? nextPickedFile;

  @override
  bool hasShowSaveFilePicker = true;

  Object? savePickerError;
  String? lastSavedName;
  Uint8List? lastSavedBytes;
  String? lastDownloadedName;
  Uint8List? lastDownloadedBytes;

  @override
  Future<PickedExternalFile?> pickCustomFile({
    required List<String> allowedExtensions,
  }) async =>
      nextPickedFile;

  @override
  Future<void> saveViaShowSaveFilePicker({
    required String suggestedFileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    if (savePickerError != null) {
      throw savePickerError!;
    }
    lastSavedName = suggestedFileName;
    lastSavedBytes = bytes;
  }

  @override
  void triggerAnchorDownload({
    required String suggestedFileName,
    required String mimeType,
    required Uint8List bytes,
  }) {
    lastDownloadedName = suggestedFileName;
    lastDownloadedBytes = bytes;
  }
}

void main() {
  group('WebOpfsStorageAdapter', () {
    test('initializeAndVerifyStorage requests persistence, verifies rollback journal, migrates & sweeps staging', () async {
      final fakeDb = _FakeWebDatabase(journalMode: 'truncate');
      final backend = _FakeWebStorageHostBackend(fakeDb)
        ..persistentGranted = false
        ..opfsFiles['${MuseConstants.stagingDirName}/rec_crashed.wav.part'] =
            Uint8List.fromList([1, 2, 3]);
      final warnings = <String>[];

      final adapter = WebOpfsStorageAdapter(
        backend: backend,
        nowEpochMs: () => 4000,
        onWarning: warnings.add,
      );

      final initResult = await adapter.initializeAndVerifyStorage();
      expect(initResult.isOk, isTrue);
      expect(warnings, hasLength(1));
      expect(fakeDb.foreignKeys, 1);
      expect(fakeDb.schemaVersion, 1);
      expect(backend.flushCount, 1);
      expect(
        backend.opfsFiles
            .containsKey('${MuseConstants.stagingDirName}/rec_crashed.wav.part'),
        isFalse,
      );

      await adapter.close();
      expect(fakeDb.isClosed, isTrue);
      expect(backend.closeVfsCount, 1);
      expect(() => adapter.database, throwsStateError);
    });

    test('initializeAndVerifyStorage fails closed when journal_mode reports wal', () async {
      final fakeDb = _FakeWebDatabase(journalMode: 'wal');
      final backend = _FakeWebStorageHostBackend(fakeDb);
      final adapter = WebOpfsStorageAdapter(backend: backend);

      final initResult = await adapter.initializeAndVerifyStorage();
      expect(initResult, isA<Err<void>>());
      expect(
        (initResult as Err<void>).error.code,
        MuseErrorCode.sqliteJournalModeMismatch,
      );
      expect(fakeDb.isClosed, isTrue);
      expect(backend.closeVfsCount, 1);
    });

    test('locator paths, OPFS CAS promotion, missing blob & 64 MiB Web SF2 limit', () async {
      final fakeDb = _FakeWebDatabase();
      final backend = _FakeWebStorageHostBackend(fakeDb);
      final adapter = WebOpfsStorageAdapter(backend: backend);
      expect((await adapter.initializeAndVerifyStorage()).isOk, isTrue);

      final wavBytes = Uint8List.fromList(utf8.encode('RIFF-web-opfs-wav'));
      final wavSha = Sha256Digest(sha256.convert(wavBytes).toString());

      expect(adapter.resolveNativeCasPosixPath(wavSha, ext: 'wav'), isNull);
      final stagingPath = adapter.resolveRecordingStagingPath(
        const TakeId('web-t1'),
      );
      expect(stagingPath, '/staging/rec_web-t1.wav.part');

      // Corrupt staging file deletes staging artifact and fails closed.
      backend.opfsFiles['staging/rec_web-t1.wav.part'] = wavBytes;
      final badPromote = await adapter.promoteStagingFileToCas(
        stagingPath: stagingPath,
        expectedSha256: Sha256Digest('a' * 64),
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((badPromote as Err<int>).error.code, MuseErrorCode.casPromotionFailed);
      expect(backend.opfsFiles.containsKey('staging/rec_web-t1.wav.part'), isFalse);

      // Valid staging promotion writes CAS and unlinks staging.
      backend.opfsFiles['staging/rec_web-t1.wav.part'] = wavBytes;
      final okPromote = await adapter.promoteStagingFileToCas(
        stagingPath: stagingPath,
        expectedSha256: wavSha,
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((okPromote as Ok<int>).value, wavBytes.length);
      expect(backend.opfsFiles.containsKey('staging/rec_web-t1.wav.part'), isFalse);

      final readOk = await adapter.readCasBlobBytes(
        wavSha,
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((readOk as Ok<List<int>>).value, equals(wavBytes));

      // Stream write deduplicates via opfsFileExists without reading CAS bytes.
      backend.readOpfsCount = 0;
      backend.existsOpfsCount = 0;
      final dedupWrite = await adapter.writeStreamToCas(
        byteStream: Stream.value(wavBytes),
        expectedByteLength: wavBytes.length,
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect(
        (dedupWrite as Ok<({Sha256Digest sha256, int byteSize})>).value.sha256,
        wavSha,
      );
      expect(backend.existsOpfsCount, 1);
      expect(backend.readOpfsCount, 0);

      final missing = await adapter.readCasBlobBytes(
        Sha256Digest('b' * 64),
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((missing as Err<List<int>>).error.code, MuseErrorCode.casBlobMissing);

      // SF2 exceeding 64 MiB cap rejects loudly before buffering.
      final tooLarge = await adapter.writeStreamToCas(
        byteStream: const Stream<List<int>>.empty(),
        expectedByteLength: MuseConstants.maxWebSoundFontBytes + 1,
        ext: SqliteSchemaDdl.sf2Extension,
      );
      expect(
        (tooLarge as Err<({Sha256Digest sha256, int byteSize})>).error.code,
        MuseErrorCode.soundFontTooLargeForWeb,
      );
    });

    test('verifyAvailableQuotaBytes & runGarbageCollection manage OPFS quota and blobs', () async {
      final fakeDb = _FakeWebDatabase();
      final backend = _FakeWebStorageHostBackend(fakeDb);
      final adapter = WebOpfsStorageAdapter(backend: backend);
      expect((await adapter.initializeAndVerifyStorage()).isOk, isTrue);

      backend.quotaEstimate = (usageBytes: 900, quotaBytes: 1000);
      final okQuota = await adapter.verifyAvailableQuotaBytes(requiredBytes: 100);
      expect((okQuota as Ok<int>).value, 100);

      final lowQuota = await adapter.verifyAvailableQuotaBytes(requiredBytes: 101);
      expect(
        (lowQuota as Err<int>).error.code,
        MuseErrorCode.insufficientStorageQuota,
      );

      final orphanBytes = Uint8List.fromList(utf8.encode('orphan-opfs-wav'));
      final orphanSha = Sha256Digest(sha256.convert(orphanBytes).toString());
      final casKey =
          'cas/${SqliteValueCodec.casShardPrefix(orphanSha)}/${orphanSha.value}.wav';
      backend.opfsFiles[casKey] = orphanBytes;
      fakeDb.orphanBlobs.add((
        sha256: orphanSha.value,
        ext: 'wav',
        byteSize: orphanBytes.length,
      ));

      final activeStagingKey =
          '${MuseConstants.stagingDirName}/rec_active.wav.part';
      backend.opfsFiles[activeStagingKey] = Uint8List.fromList([1, 2, 3, 4]);

      final flushesBeforeGc = backend.flushCount;
      final gcRes = await adapter.runGarbageCollection(olderThanEpochMs: 5000);
      expect((gcRes as Ok<int>).value, orphanBytes.length);
      expect(backend.opfsFiles.containsKey(casKey), isFalse);
      expect(backend.opfsFiles.containsKey(activeStagingKey), isTrue);
      expect(backend.flushCount, flushesBeforeGc + 1);
    });

    test('default warning logger handles degraded persistence without throwing', () async {
      final backend = _FakeWebStorageHostBackend(_FakeWebDatabase())
        ..persistentGranted = false;
      final adapter = WebOpfsStorageAdapter(backend: backend);
      final initRes = await adapter.initializeAndVerifyStorage();
      expect(initRes.isOk, isTrue);
      await adapter.close();
    });

    test('default browser host backend accesses navigator.storage via globalContext without window dependency', () async {
      final realAdapter = WebOpfsStorageAdapter();
      final quotaRes = await realAdapter.verifyAvailableQuotaBytes(requiredBytes: 1);
      expect(quotaRes, isA<Ok<int>>());
      expect((quotaRes as Ok<int>).value, greaterThanOrEqualTo(1));

      final missingRes = await realAdapter.readCasBlobBytes(
        Sha256Digest('e' * 64),
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((missingRes as Err<List<int>>).error.code, MuseErrorCode.casBlobMissing);
      await realAdapter.close();
    });
  });

  group('WebExternalFileExchange', () {
    late _FakeWebStorageHostBackend storageBackend;
    late WebOpfsStorageAdapter storageAdapter;
    late _FakeWebFileExchangeBackend fileBackend;
    late WebExternalFileExchange exchange;

    setUp(() async {
      storageBackend = _FakeWebStorageHostBackend(_FakeWebDatabase());
      storageAdapter = WebOpfsStorageAdapter(backend: storageBackend);
      expect((await storageAdapter.initializeAndVerifyStorage()).isOk, isTrue);
      fileBackend = _FakeWebFileExchangeBackend();
      exchange = WebExternalFileExchange(
        storageLocator: storageAdapter,
        backend: fileBackend,
      );
    });

    test('pickImportFile handles cancel, valid stream & invalid length/ext', () async {
      fileBackend.nextPickedFile = null;
      final cancel = await exchange.pickImportFile(
        allowedExtensions: const ['.sf2', 'musicxml'],
      );
      expect((cancel as Ok<PickedExternalFile?>).value, isNull);

      final sfBytes = Uint8List.fromList(utf8.encode('RIFFsfbk-web'));
      fileBackend.nextPickedFile = PickedExternalFile(
        fileName: 'WebPiano.sf2',
        extension: 'SF2',
        byteLength: sfBytes.length,
        byteStream: Stream.value(sfBytes),
      );
      final ok = await exchange.pickImportFile(allowedExtensions: const ['sf2']);
      final picked = (ok as Ok<PickedExternalFile?>).value!;
      expect(picked.extension, 'sf2');
      expect(picked.byteLength, sfBytes.length);
      expect(await picked.byteStream.first, equals(sfBytes));

      fileBackend.nextPickedFile = const PickedExternalFile(
        fileName: 'empty.sf2',
        extension: 'sf2',
        byteLength: 0,
        byteStream: Stream.empty(),
      );
      final emptyErr = await exchange.pickImportFile(
        allowedExtensions: const ['sf2'],
      );
      expect(
        (emptyErr as Err<PickedExternalFile?>).error.code,
        MuseErrorCode.invalidSoundFontFormat,
      );
    });

    test('exportFileToUser & exportCasWavTakeToUser handle showSaveFilePicker, AbortError, anchor fallback & missing CAS', () async {
      final wavBytes = Uint8List.fromList(utf8.encode('RIFF-web-export'));
      final wavSha = Sha256Digest(sha256.convert(wavBytes).toString());
      final casKey =
          'cas/${SqliteValueCodec.casShardPrefix(wavSha)}/${wavSha.value}.wav';
      storageBackend.opfsFiles[casKey] = wavBytes;

      // Chromium showSaveFilePicker path.
      fileBackend.hasShowSaveFilePicker = true;
      final okPicker = await exchange.exportCasWavTakeToUser(
        wavSha256: wavSha,
        suggestedFileName: 'folder/web_take.wav',
      );
      expect(okPicker.isOk, isTrue);
      expect(fileBackend.lastSavedName, 'web_take.wav');
      expect(fileBackend.lastSavedBytes, equals(wavBytes));

      // AbortError from showSaveFilePicker maps to Ok(null) cancellation.
      fileBackend.savePickerError = StateError('AbortError: user aborted');
      final aborted = await exchange.exportFileToUser(
        suggestedFileName: 'score.musicxml',
        mimeType: 'application/vnd.recordare.musicxml+xml',
        bytes: utf8.encode('<score-partwise/>'),
      );
      expect(aborted.isOk, isTrue);

      // Non-abort error from showSaveFilePicker fails closed.
      fileBackend.savePickerError = StateError('QuotaExceededError: full');
      final failed = await exchange.exportFileToUser(
        suggestedFileName: 'score.musicxml',
        mimeType: 'application/vnd.recordare.musicxml+xml',
        bytes: utf8.encode('<score-partwise/>'),
      );
      expect((failed as Err<void>).error.code, MuseErrorCode.casPromotionFailed);

      // Safari/Firefox <a download> fallback.
      fileBackend.hasShowSaveFilePicker = false;
      fileBackend.savePickerError = null;
      final fallbackOk = await exchange.exportCasWavTakeToUser(
        wavSha256: wavSha,
        suggestedFileName: 'safari_take.wav',
      );
      expect(fallbackOk.isOk, isTrue);
      expect(fileBackend.lastDownloadedName, 'safari_take.wav');
      expect(fileBackend.lastDownloadedBytes, equals(wavBytes));

      // Missing CAS blob fails closed.
      final missingErr = await exchange.exportCasWavTakeToUser(
        wavSha256: Sha256Digest('0' * 64),
        suggestedFileName: 'missing.wav',
      );
      expect((missingErr as Err<void>).error.code, MuseErrorCode.casBlobMissing);
    });
  });
}

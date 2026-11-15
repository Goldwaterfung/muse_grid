import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/storage/common/sql_asset_library_repository.dart';
import 'package:muse_grid/storage/common/sql_project_repository.dart';
import 'package:muse_grid/storage/common/sqlite_schema_ddl.dart';
import 'package:muse_grid/storage/native/native_external_file_exchange.dart';
import 'package:muse_grid/storage/native/native_storage_adapter.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

final class _FakePlatformFile extends PlatformFile {
  final String _name;
  final Uint8List _bytes;
  final int? _overrideLength;
  final Uri? _overrideUri;

  _FakePlatformFile({
    required this._name,
    required this._bytes,
    this._overrideLength,
    this._overrideUri,
  });

  @override
  String get name => _name;

  @override
  Uri get uri => _overrideUri ?? Uri.file('/tmp/$_name');

  @override
  XFile get xFile => XFile.fromData(_bytes, name: _name);

  @override
  int? lengthSync() => _overrideLength;

  @override
  Future<int?> length() async => _overrideLength ?? _bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => _bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(_bytes);
}

final class _FakeNativeFileExchangeBackend
    implements NativeFileExchangeBackend {
  final Directory tempDir;

  @override
  bool isDesktopPlatform = true;

  PlatformFile? nextPickedFile;
  bool throwOnSaveOrShare = false;
  String? savedFileName;
  Uint8List? savedBytes;
  String? sharedFilePath;
  bool sharedFileExistedDuringCall = false;

  _FakeNativeFileExchangeBackend(this.tempDir);

  @override
  Future<PlatformFile?> pickCustomFile({
    required List<String> allowedExtensions,
  }) async =>
      nextPickedFile;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (throwOnSaveOrShare) {
      throw const FileSystemException('Simulated save failure');
    }
    savedFileName = fileName;
    savedBytes = bytes;
    return Uri.file('/saved/$fileName');
  }

  @override
  Future<ShareResult> shareFile({
    required String filePath,
    required String fileName,
    required String mimeType,
  }) async {
    sharedFilePath = filePath;
    sharedFileExistedDuringCall = File(filePath).existsSync();
    if (throwOnSaveOrShare) {
      throw const FileSystemException('Simulated share sheet failure');
    }
    return const ShareResult('shared', ShareResultStatus.success);
  }

  @override
  Future<Directory> getTempDirectory() async => tempDir;
}

void main() {
  group('NativeStorageAdapter', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('muse_native_storage_');
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('initializeAndVerifyStorage opens WAL DB, creates dirs & sweeps orphan .part files', () async {
      final stagingDir = Directory(p.join(tempRoot.path, MuseConstants.stagingDirName));
      await stagingDir.create(recursive: true);
      final orphanFile = File(p.join(stagingDir.path, 'rec_crashed.wav.part'));
      await orphanFile.writeAsBytes([1, 2, 3, 4]);
      expect(await orphanFile.exists(), isTrue);

      final adapter = NativeStorageAdapter(
        resolveAppSupportDir: () async => tempRoot,
        nowEpochMs: () => 1000,
      );
      final initResult = await adapter.initializeAndVerifyStorage();
      expect(initResult.isOk, isTrue);

      expect(
        Directory(p.join(tempRoot.path, MuseConstants.dbDirName)).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(tempRoot.path, MuseConstants.casDirName)).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(tempRoot.path, MuseConstants.dbDirName, MuseConstants.dbFileName))
            .existsSync(),
        isTrue,
      );
      expect(await orphanFile.exists(), isFalse);

      final mode = adapter.database.select('PRAGMA journal_mode;').first.values.first;
      expect(mode.toString().toLowerCase(), 'wal');
      final fk = adapter.database.select('PRAGMA foreign_keys;').first.values.first;
      expect(fk, 1);

      await adapter.close();
      expect(() => adapter.database, throwsStateError);
    });

    test('CAS promotion, stream hashing, corruption rejection & missing blob fail-closed', () async {
      final adapter = NativeStorageAdapter(
        resolveAppSupportDir: () async => tempRoot,
        nowEpochMs: () => 2000,
      );
      expect((await adapter.initializeAndVerifyStorage()).isOk, isTrue);

      final wavBytes = Uint8List.fromList(utf8.encode('RIFF-native-wav-payload'));
      final wavSha = Sha256Digest(sha256.convert(wavBytes).toString());

      // Corrupt digest deletes staging .part and fails closed.
      final badStaging = adapter.resolveRecordingStagingPath(const TakeId('t-bad'));
      await File(badStaging).writeAsBytes(wavBytes);
      final badPromote = await adapter.promoteStagingFileToCas(
        stagingPath: badStaging,
        expectedSha256: Sha256Digest('a' * 64),
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((badPromote as Err<int>).error.code, MuseErrorCode.casPromotionFailed);
      expect(await File(badStaging).exists(), isFalse);

      // Valid staging promotion moves file into cas/<aa>/<sha256>.wav.
      final goodStaging = adapter.resolveRecordingStagingPath(const TakeId('t-ok'));
      await File(goodStaging).writeAsBytes(wavBytes);
      final okPromote = await adapter.promoteStagingFileToCas(
        stagingPath: goodStaging,
        expectedSha256: wavSha,
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((okPromote as Ok<int>).value, wavBytes.length);
      expect(await File(goodStaging).exists(), isFalse);

      final casPosixPath = adapter.resolveNativeCasPosixPath(
        wavSha,
        ext: SqliteSchemaDdl.wavExtension,
      )!;
      expect(await File(casPosixPath).exists(), isTrue);

      final readOk = await adapter.readCasBlobBytes(
        wavSha,
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((readOk as Ok<List<int>>).value, equals(wavBytes));

      // Absent blob fails closed.
      final missing = await adapter.readCasBlobBytes(
        Sha256Digest('f' * 64),
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((missing as Err<List<int>>).error.code, MuseErrorCode.casBlobMissing);

      // Stream write deduplicates existing CAS blob without leaving staging files.
      final streamWrite = await adapter.writeStreamToCas(
        byteStream: Stream.fromIterable([wavBytes.sublist(0, 5), wavBytes.sublist(5)]),
        expectedByteLength: wavBytes.length,
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect((streamWrite as Ok<({Sha256Digest sha256, int byteSize})>).value.sha256, wavSha);
      final stagingEntries = Directory(
        p.join(tempRoot.path, MuseConstants.stagingDirName),
      ).listSync();
      expect(stagingEntries, isEmpty);

      // Invalid takeId traversal rejected.
      expect(
        () => adapter.resolveRecordingStagingPath(const TakeId('../escape')),
        throwsArgumentError,
      );

      await adapter.close();
    });

    test('End-to-end integration with SqlProjectRepository, SqlAssetLibraryRepository & physical GC', () async {
      var now = 10000;
      var seq = 0;
      final adapter = NativeStorageAdapter(
        resolveAppSupportDir: () async => tempRoot,
        nowEpochMs: () => ++now,
      );
      expect((await adapter.initializeAndVerifyStorage()).isOk, isTrue);

      final projectRepo = SqlProjectRepository(
        db: adapter.database,
        casStore: adapter,
        nowEpochMs: () => ++now,
        generateUuidV7: () => '01970000-0000-7000-8000-${(++seq).toString().padLeft(12, '0')}',
      );
      final assetRepo = SqlAssetLibraryRepository(
        db: adapter.database,
        casStore: adapter,
        nowEpochMs: () => ++now,
        generateUuidV7: () => '01970000-0000-7000-9000-${(++seq).toString().padLeft(12, '0')}',
      );

      final sfBytes = Uint8List.fromList(utf8.encode('SF2-active-binary'));
      final sfResult = await assetRepo.importSoundFontBytes(
        displayName: 'Active SF2',
        byteStream: Stream.value(sfBytes),
        byteLength: sfBytes.length,
        extractedPresets: const [
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Piano'),
        ],
      );
      final sfEntry = (sfResult as Ok<SoundFontCatalogEntry>).value;
      final sfPath = adapter.resolveNativeCasPosixPath(sfEntry.blobSha256, ext: 'sf2')!;
      expect(await File(sfPath).exists(), isTrue);

      await projectRepo.createProject(
        const CreateProjectInput(
          projectId: ProjectId('proj-e2e'),
          title: 'E2E',
          gridSnapTicks: 240,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      );
      final partId = (await projectRepo.loadProjectAggregate(const ProjectId('proj-e2e'))
              as Ok<ProjectWorkspaceAggregate>)
          .value
          .parts
          .single
          .partId;

      final wavBytes = Uint8List.fromList(utf8.encode('WAV-recorded-take-data'));
      final wavSha = Sha256Digest(sha256.convert(wavBytes).toString());
      final stagingPath = adapter.resolveRecordingStagingPath(const TakeId('take-e2e'));
      await File(stagingPath).writeAsBytes(wavBytes);

      final takeRes = await projectRepo.promoteAndCommitRecordedTake(
        receipt: RecordingCaptureReceipt(
          takeId: const TakeId('take-e2e'),
          stagingPath: stagingPath,
          sha256: wavSha,
          capturedSampleClock: const SampleFrame(0),
          capturedPlayheadFrame: const SampleFrame(0),
          durationFrames: 48000,
          sampleRate: 48000,
          channelCount: 1,
          outputBufferFrames: 128,
          inputBufferFrames: 128,
        ),
        projectId: const ProjectId('proj-e2e'),
        partId: partId,
        alignedStartTick: const Tick(0),
        calibrationOffsetFrames: 0,
      );
      expect(takeRes.isOk, isTrue);

      final wavPath = adapter.resolveNativeCasPosixPath(wavSha, ext: 'wav')!;
      expect(await File(wavPath).exists(), isTrue);

      // Soft-delete project and run GC with threshold > deletedAtMs.
      final activeStagingPart = File(
        adapter.resolveRecordingStagingPath(const TakeId('t-active-gc')),
      );
      await activeStagingPart.writeAsBytes([9, 8, 7, 6]);

      await projectRepo.softDeleteProject(
        const ProjectId('proj-e2e'),
        deletedAtMs: now + 100,
      );
      final gcRes = await adapter.runGarbageCollection(
        olderThanEpochMs: now + 500,
      );
      expect((gcRes as Ok<int>).value, wavBytes.length);
      expect(await File(wavPath).exists(), isFalse);
      expect(await File(sfPath).exists(), isTrue);
      // In-flight staging/*.part files must survive mid-session GC.
      expect(await activeStagingPart.exists(), isTrue);

      await adapter.close();
    });

    test('promoteStagingFileToCas rejects paths outside staging without deleting them', () async {
      final adapter = NativeStorageAdapter(
        resolveAppSupportDir: () async => tempRoot,
        nowEpochMs: () => 2500,
      );
      expect((await adapter.initializeAndVerifyStorage()).isOk, isTrue);

      final payload = Uint8List.fromList(utf8.encode('outside-staging-secret'));
      final payloadSha = Sha256Digest(sha256.convert(payload).toString());

      final outsideFile = File(p.join(tempRoot.path, 'outside.wav.part'));
      await outsideFile.writeAsBytes(payload);

      final traversalPath = p.join(
        tempRoot.path,
        MuseConstants.stagingDirName,
        '..',
        'outside.wav.part',
      );
      final traversalRes = await adapter.promoteStagingFileToCas(
        stagingPath: traversalPath,
        expectedSha256: payloadSha,
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect(
        (traversalRes as Err<int>).error.code,
        MuseErrorCode.casPromotionFailed,
      );
      expect(await outsideFile.exists(), isTrue);

      final symlinkInStaging = Link(
        p.join(tempRoot.path, MuseConstants.stagingDirName, 'escape.wav.part'),
      );
      await symlinkInStaging.create(outsideFile.path);
      final symlinkRes = await adapter.promoteStagingFileToCas(
        stagingPath: symlinkInStaging.path,
        expectedSha256: payloadSha,
        ext: SqliteSchemaDdl.wavExtension,
      );
      expect(
        (symlinkRes as Err<int>).error.code,
        MuseErrorCode.casPromotionFailed,
      );
      expect(await outsideFile.exists(), isTrue);
      expect(
        adapter.resolveNativeCasPosixPath(
          payloadSha,
          ext: SqliteSchemaDdl.wavExtension,
        ),
        isNotNull,
      );
      expect(
        await File(
          adapter.resolveNativeCasPosixPath(
            payloadSha,
            ext: SqliteSchemaDdl.wavExtension,
          )!,
        ).exists(),
        isFalse,
      );

      await adapter.close();
    });

    test('verifyAvailableQuotaBytes validates real POSIX df & insufficient quota fail-closed', () async {
      final realAdapter = NativeStorageAdapter(
        resolveAppSupportDir: () async => tempRoot,
      );
      expect((await realAdapter.initializeAndVerifyStorage()).isOk, isTrue);
      final realQuota = await realAdapter.verifyAvailableQuotaBytes(requiredBytes: 1024);
      expect(realQuota, isA<Ok<int>>());
      expect((realQuota as Ok<int>).value, greaterThanOrEqualTo(1024));
      await realAdapter.close();

      final lowQuotaAdapter = NativeStorageAdapter(
        resolveAppSupportDir: () async => tempRoot,
        queryFreeDiskBytes: (_) async => 100,
      );
      expect((await lowQuotaAdapter.initializeAndVerifyStorage()).isOk, isTrue);
      final insufficient = await lowQuotaAdapter.verifyAvailableQuotaBytes(
        requiredBytes: 1024,
      );
      expect(
        (insufficient as Err<int>).error.code,
        MuseErrorCode.insufficientStorageQuota,
      );
      await lowQuotaAdapter.close();
    });
  });

  group('NativeExternalFileExchange', () {
    late Directory tempRoot;
    late Directory exportTempDir;
    late NativeStorageAdapter storageAdapter;
    late _FakeNativeFileExchangeBackend backend;
    late NativeExternalFileExchange exchange;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('muse_native_fx_');
      exportTempDir = Directory(p.join(tempRoot.path, 'export_tmp'));
      await exportTempDir.create(recursive: true);
      storageAdapter = NativeStorageAdapter(
        resolveAppSupportDir: () async => tempRoot,
        nowEpochMs: () => 5000,
      );
      expect((await storageAdapter.initializeAndVerifyStorage()).isOk, isTrue);
      backend = _FakeNativeFileExchangeBackend(exportTempDir);
      exchange = NativeExternalFileExchange(
        storageLocator: storageAdapter,
        backend: backend,
        nowEpochMs: () => 9999,
      );
    });

    tearDown(() async {
      await storageAdapter.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('pickImportFile handles cancellation, valid stream & disallowed extension/zero length', () async {
      backend.nextPickedFile = null;
      final cancelled = await exchange.pickImportFile(
        allowedExtensions: const ['.SF2', 'musicxml'],
      );
      expect((cancelled as Ok<PickedExternalFile?>).value, isNull);

      final payload = Uint8List.fromList(utf8.encode('RIFFsfbk-picked'));
      backend.nextPickedFile = _FakePlatformFile(
        name: 'Piano.SF2',
        bytes: payload,
        overrideLength: payload.length,
      );
      final picked = await exchange.pickImportFile(
        allowedExtensions: const ['sf2'],
      );
      final pickedFile = (picked as Ok<PickedExternalFile?>).value!;
      expect(pickedFile.fileName, 'Piano.SF2');
      expect(pickedFile.extension, 'sf2');
      expect(pickedFile.byteLength, payload.length);
      expect(await pickedFile.byteStream.first, equals(payload));

      // Zero-byte picked file fails closed.
      backend.nextPickedFile = _FakePlatformFile(
        name: 'Empty.sf2',
        bytes: Uint8List(0),
        overrideLength: 0,
      );
      final emptyResult = await exchange.pickImportFile(
        allowedExtensions: const ['sf2'],
      );
      expect(
        (emptyResult as Err<PickedExternalFile?>).error.code,
        MuseErrorCode.invalidSoundFontFormat,
      );

      // Existing OS file provides replayable byteStreamFactory for O(1) RAM SF2 import.
      final diskFile = File(p.join(tempRoot.path, 'DiskPiano.sf2'));
      await diskFile.writeAsBytes(payload);
      backend.nextPickedFile = _FakePlatformFile(
        name: 'DiskPiano.sf2',
        bytes: payload,
        overrideLength: payload.length,
        overrideUri: diskFile.uri,
      );
      final diskPicked =
          (await exchange.pickImportFile(allowedExtensions: const ['sf2'])
                  as Ok<PickedExternalFile?>)
              .value!;
      expect(diskPicked.byteStreamFactory, isNotNull);
      final pass1 = await diskPicked.byteStream.expand((c) => c).toList();
      final pass2 = await diskPicked
          .byteStreamFactory!()
          .expand((c) => c)
          .toList();
      expect(pass1, equals(payload));
      expect(pass2, equals(payload));
    });

    test('exportFileToUser & exportCasWavTakeToUser handle desktop save, mobile share & temp cleanup', () async {
      final wavBytes = Uint8List.fromList(utf8.encode('RIFF-export-wav'));
      final wavSha = Sha256Digest(sha256.convert(wavBytes).toString());
      final stagingPath = storageAdapter.resolveRecordingStagingPath(
        const TakeId('t-export'),
      );
      await File(stagingPath).writeAsBytes(wavBytes);
      expect(
        (await storageAdapter.promoteStagingFileToCas(
          stagingPath: stagingPath,
          expectedSha256: wavSha,
          ext: SqliteSchemaDdl.wavExtension,
        ))
            .isOk,
        isTrue,
      );

      // Desktop export via saveFile.
      backend.isDesktopPlatform = true;
      final desktopOk = await exchange.exportCasWavTakeToUser(
        wavSha256: wavSha,
        suggestedFileName: '../unsafe/take_export.wav',
      );
      expect(desktopOk.isOk, isTrue);
      expect(backend.savedFileName, 'take_export.wav');
      expect(backend.savedBytes, equals(wavBytes));

      // Mobile export stages temp file and deletes it in finally even if share throws.
      backend.isDesktopPlatform = false;
      backend.throwOnSaveOrShare = true;
      final mobileErr = await exchange.exportFileToUser(
        suggestedFileName: 'score.musicxml',
        mimeType: 'application/vnd.recordare.musicxml+xml',
        bytes: utf8.encode('<score-partwise/>'),
      );
      expect((mobileErr as Err<void>).error.code, MuseErrorCode.casPromotionFailed);
      expect(backend.sharedFileExistedDuringCall, isTrue);
      expect(File(backend.sharedFilePath!).existsSync(), isFalse);
      expect(exportTempDir.listSync(), isEmpty);

      // Missing CAS WAV blob fails closed.
      final missingWav = await exchange.exportCasWavTakeToUser(
        wavSha256: Sha256Digest('0' * 64),
        suggestedFileName: 'missing.wav',
      );
      expect((missingWav as Err<void>).error.code, MuseErrorCode.casBlobMissing);
    });
  });
}

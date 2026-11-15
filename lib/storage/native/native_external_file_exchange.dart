/// Native external file picker, desktop save dialog, and mobile share sheet.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import '../../domain/repositories/storage_contracts.dart';
import '../common/external_file_exchange_support.dart';

/// Injectable platform backend for [NativeExternalFileExchange].
abstract interface class NativeFileExchangeBackend {
  Future<PlatformFile?> pickCustomFile({
    required List<String> allowedExtensions,
  });

  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  });

  Future<ShareResult> shareFile({
    required String filePath,
    required String fileName,
    required String mimeType,
  });

  Future<Directory> getTempDirectory();

  bool get isDesktopPlatform;
}

final class _DefaultNativeFileExchangeBackend
    implements NativeFileExchangeBackend {
  const _DefaultNativeFileExchangeBackend();

  @override
  bool get isDesktopPlatform =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Future<PlatformFile?> pickCustomFile({
    required List<String> allowedExtensions,
  }) =>
      FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
      );

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) =>
      FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
      );

  @override
  Future<ShareResult> shareFile({
    required String filePath,
    required String fileName,
    required String mimeType,
  }) =>
      SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath, mimeType: mimeType, name: fileName)],
          fileNameOverrides: [fileName],
        ),
      );

  @override
  Future<Directory> getTempDirectory() => getTemporaryDirectory();
}

/// Native implementation of [IExternalFileExchange] using `file_picker` on
/// import/desktop-export and `share_plus` + `TemporaryDirectory` staging on mobile.
final class NativeExternalFileExchange implements IExternalFileExchange {
  static const String _exportTempPrefix = 'muse_export_';

  final IInternalStorageLocator _storageLocator;
  final NativeFileExchangeBackend _backend;
  final int Function() _nowEpochMs;

  NativeExternalFileExchange({
    required this._storageLocator,
    NativeFileExchangeBackend? backend,
    int Function()? nowEpochMs,
  })  : _backend = backend ?? const _DefaultNativeFileExchangeBackend(),
        _nowEpochMs =
            nowEpochMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  @override
  Future<Result<PickedExternalFile?>> pickImportFile({
    required List<String> allowedExtensions,
  }) async {
    final extCheck =
        ExternalFileExchangeSupport.normalizeAllowedExtensions(allowedExtensions);
    if (extCheck case Err(:final error)) {
      return Err(error);
    }
    final normalized = (extCheck as Ok<List<String>>).value;

    try {
      final picked = await _backend.pickCustomFile(
        allowedExtensions: normalized,
      );
      if (picked == null) {
        return const Ok(null);
      }

      final byteLength = picked.lengthSync() ?? await picked.length();
      final pickedPath = picked.path;
      Stream<List<int>> Function()? byteStreamFactory;
      if (pickedPath != null && pickedPath.isNotEmpty) {
        final localFile = File(pickedPath);
        if (localFile.existsSync()) {
          byteStreamFactory = () => localFile.openRead();
        }
      }
      return ExternalFileExchangeSupport.validatePickedFile(
        fileName: picked.name,
        rawExtension: picked.extension,
        byteLength: byteLength,
        byteStream: picked.readAsByteStream(),
        normalizedExtensions: normalized,
        byteStreamFactory: byteStreamFactory,
      );
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to pick external import file: $error',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> exportFileToUser({
    required String suggestedFileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final prepared = ExternalFileExchangeSupport.prepareExportPayload(
      suggestedFileName: suggestedFileName,
      mimeType: mimeType,
      bytes: bytes,
    );
    if (prepared case Err(:final error)) {
      return Err(error);
    }
    final (fileName: fileName, bytes: data) =
        (prepared as Ok<({String fileName, Uint8List bytes})>).value;
    File? tempFile;

    try {
      if (_backend.isDesktopPlatform) {
        await _backend.saveFile(
          fileName: fileName,
          bytes: data,
          mimeType: mimeType,
        );
        return const Ok(null);
      }

      final tempDir = await _backend.getTempDirectory();
      tempFile = File(
        p.join(tempDir.path, '$_exportTempPrefix${_nowEpochMs()}_$fileName'),
      );
      await tempFile.writeAsBytes(data, flush: true);
      await _backend.shareFile(
        filePath: tempFile.path,
        fileName: fileName,
        mimeType: mimeType,
      );
      return const Ok(null);
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to export "$fileName": $error',
          cause: error,
        ),
      );
    } finally {
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {
          // Ignore temp cleanup failures after export completes or throws.
        }
      }
    }
  }

  @override
  Future<Result<void>> exportCasWavTakeToUser({
    required Sha256Digest wavSha256,
    required String suggestedFileName,
  }) =>
      ExternalFileExchangeSupport.exportCasWavTake(
        storageLocator: _storageLocator,
        exchange: this,
        wavSha256: wavSha256,
        suggestedFileName: suggestedFileName,
      );
}

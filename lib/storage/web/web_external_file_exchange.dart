/// Web external file picker and download/File System Access export exchange.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:web/web.dart' as web;

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import '../../domain/repositories/storage_contracts.dart';
import '../common/external_file_exchange_support.dart';

/// Injectable browser boundary for [WebExternalFileExchange].
abstract interface class WebFileExchangeBackend {
  Future<PickedExternalFile?> pickCustomFile({
    required List<String> allowedExtensions,
  });

  bool get hasShowSaveFilePicker;

  Future<void> saveViaShowSaveFilePicker({
    required String suggestedFileName,
    required String mimeType,
    required Uint8List bytes,
  });

  void triggerAnchorDownload({
    required String suggestedFileName,
    required String mimeType,
    required Uint8List bytes,
  });
}

final class _BrowserWebFileExchangeBackend implements WebFileExchangeBackend {
  const _BrowserWebFileExchangeBackend();

  @override
  Future<PickedExternalFile?> pickCustomFile({
    required List<String> allowedExtensions,
  }) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    if (picked == null) {
      return null;
    }

    final ext = (picked.extension ??
            ExternalFileExchangeSupport.extensionWithoutDot(picked.name) ??
            '')
        .trim()
        .toLowerCase();
    final byteLength = picked.lengthSync() ?? await picked.length() ?? 0;
    return PickedExternalFile(
      fileName: picked.name,
      extension: ext,
      byteLength: byteLength,
      byteStream: picked.readAsByteStream(),
    );
  }

  @override
  bool get hasShowSaveFilePicker => globalContext.has('showSaveFilePicker');

  @override
  Future<void> saveViaShowSaveFilePicker({
    required String suggestedFileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final options = JSObject()
      ..setProperty('suggestedName'.toJS, suggestedFileName.toJS);
    final handle = await globalContext
        .callMethod<JSPromise<web.FileSystemFileHandle>>(
          'showSaveFilePicker'.toJS,
          options,
        )
        .toDart;
    final writable = await handle.createWritable().toDart;
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
  void triggerAnchorDownload({
    required String suggestedFileName,
    required String mimeType,
    required Uint8List bytes,
  }) {
    final blobParts = <web.BlobPart>[bytes.toJS].toJS;
    final blob = web.Blob(blobParts, web.BlobPropertyBag(type: mimeType));
    final url = web.URL.createObjectURL(blob);
    try {
      final anchor = web.HTMLAnchorElement()
        ..href = url
        ..download = suggestedFileName
        ..style.display = 'none';
      web.document.body?.append(anchor);
      try {
        anchor.click();
      } finally {
        anchor.remove();
      }
    } finally {
      web.URL.revokeObjectURL(url);
    }
  }
}

/// Web implementation of [IExternalFileExchange] using `file_picker` streams on
/// import and `showSaveFilePicker` with `<a download>` Blob fallback on export.
final class WebExternalFileExchange implements IExternalFileExchange {
  static const String _domAbortError = 'AbortError';

  final IInternalStorageLocator _storageLocator;
  final WebFileExchangeBackend _backend;

  WebExternalFileExchange({
    required this._storageLocator,
    WebFileExchangeBackend? backend,
  }) : _backend = backend ?? const _BrowserWebFileExchangeBackend();

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

      return ExternalFileExchangeSupport.validatePickedFile(
        fileName: picked.fileName,
        rawExtension: picked.extension,
        byteLength: picked.byteLength,
        byteStream: picked.byteStream,
        normalizedExtensions: normalized,
      );
    } catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to pick external Web file: $error',
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

    try {
      if (_backend.hasShowSaveFilePicker) {
        await _backend.saveViaShowSaveFilePicker(
          suggestedFileName: fileName,
          mimeType: mimeType,
          bytes: data,
        );
        return const Ok(null);
      }

      _backend.triggerAnchorDownload(
        suggestedFileName: fileName,
        mimeType: mimeType,
        bytes: data,
      );
      return const Ok(null);
    } catch (error) {
      if (_isAbortError(error)) {
        return const Ok(null);
      }
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to export "$fileName" on Web: $error',
          cause: error,
        ),
      );
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

  static bool _isAbortError(Object error) =>
      error.toString().contains(_domAbortError);
}

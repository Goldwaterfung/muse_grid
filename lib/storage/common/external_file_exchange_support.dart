/// Pure-Dart validation, sanitization, and CAS WAV export helpers shared
/// across native and Web [IExternalFileExchange] implementations.
library;

import 'dart:typed_data';

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import '../../domain/repositories/storage_contracts.dart';
import 'sqlite_schema_ddl.dart';

/// Shared validation and export helpers for [IExternalFileExchange] adapters.
abstract final class ExternalFileExchangeSupport {
  static final RegExp _leadingDotsRegex = RegExp(r'^\.+');
  static final RegExp _pathSeparatorRegex = RegExp(r'[/\\]');

  /// Trims, lowercases, strips leading dots, and deduplicates [allowedExtensions].
  static Result<List<String>> normalizeAllowedExtensions(
    List<String> allowedExtensions,
  ) {
    final normalized = <String>[];
    for (final ext in allowedExtensions) {
      final clean = ext.trim().toLowerCase().replaceFirst(_leadingDotsRegex, '');
      if (clean.isEmpty) {
        return const Err(
          MuseError(
            MuseErrorCode.sqliteConstraintViolation,
            'allowedExtensions entries must not be empty.',
          ),
        );
      }
      if (!normalized.contains(clean)) {
        normalized.add(clean);
      }
    }
    if (normalized.isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'allowedExtensions must not be empty.',
        ),
      );
    }
    return Ok(normalized);
  }

  /// Validates a picked external file's extension and byte length against
  /// [normalizedExtensions] and returns a domain [PickedExternalFile].
  static Result<PickedExternalFile> validatePickedFile({
    required String fileName,
    required String? rawExtension,
    required int? byteLength,
    required Stream<List<int>> byteStream,
    required List<String> normalizedExtensions,
    Stream<List<int>> Function()? byteStreamFactory,
  }) {
    final fallbackExt = rawExtension ?? extensionWithoutDot(fileName);
    final normalizedExt =
        fallbackExt?.trim().toLowerCase().replaceFirst(_leadingDotsRegex, '') ??
            '';
    if (normalizedExt.isEmpty ||
        !normalizedExtensions.contains(normalizedExt)) {
      return Err(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          'Picked file "$fileName" has disallowed extension '
          '"$normalizedExt" (expected $normalizedExtensions).',
        ),
      );
    }

    if (byteLength == null || byteLength <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          'Picked file has unreadable or zero byte length.',
        ),
      );
    }

    return Ok(
      PickedExternalFile(
        fileName: fileName,
        extension: normalizedExt,
        byteLength: byteLength,
        byteStream: byteStream,
        byteStreamFactory: byteStreamFactory,
      ),
    );
  }

  /// Validates [suggestedFileName] and [mimeType], returning a sanitized basename
  /// and canonical [Uint8List] buffer ready for platform export.
  static Result<({String fileName, Uint8List bytes})> prepareExportPayload({
    required String suggestedFileName,
    required String mimeType,
    required List<int> bytes,
  }) {
    final safeName = sanitizeExportFileName(suggestedFileName);
    if (safeName == null) {
      return Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Invalid export file name "$suggestedFileName".',
        ),
      );
    }
    if (mimeType.trim().isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Export mimeType must not be empty.',
        ),
      );
    }

    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return Ok((fileName: safeName, bytes: data));
  }

  /// Extracts a safe single-segment basename from [rawName], or `null` if empty
  /// or traversal-like (`.` / `..`).
  static String? sanitizeExportFileName(String rawName) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final segments = trimmed.split(_pathSeparatorRegex);
    final base = segments.last.trim();
    if (base.isEmpty || base == '.' || base == '..') {
      return null;
    }
    return base;
  }

  /// Returns the lowercase-ready trailing extension without `.` if present.
  static String? extensionWithoutDot(String fileName) {
    final lastDot = fileName.lastIndexOf('.');
    if (lastDot <= 0 || lastDot == fileName.length - 1) {
      return null;
    }
    return fileName.substring(lastDot + 1);
  }

  /// Reads a WAV blob from [storageLocator] and delegates user export to
  /// [exchange.exportFileToUser].
  static Future<Result<void>> exportCasWavTake({
    required IInternalStorageLocator storageLocator,
    required IExternalFileExchange exchange,
    required Sha256Digest wavSha256,
    required String suggestedFileName,
  }) async {
    final bytesResult = await storageLocator.readCasBlobBytes(
      wavSha256,
      ext: SqliteSchemaDdl.wavExtension,
    );
    if (bytesResult case Err(:final error)) {
      return Err(error);
    }
    final bytes = (bytesResult as Ok<List<int>>).value;
    return exchange.exportFileToUser(
      suggestedFileName: suggestedFileName,
      mimeType: SqliteSchemaDdl.wavMimeType,
      bytes: bytes,
    );
  }
}

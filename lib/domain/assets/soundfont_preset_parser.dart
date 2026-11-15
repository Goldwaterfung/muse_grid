/// Pure Dart streaming SF2 (`RIFF/sfbk/LIST:pdta/phdr`) preset header parser.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/result.dart';

/// Pure Dart contract for extracting SoundFont preset metadata without loading audio waveforms.
abstract interface class ISoundFontPresetParser {
  Future<Result<List<SoundFontPresetInfo>>> parsePresetsFromSf2Stream({
    required Stream<List<int>> byteStream,
    required int byteLength,
  });
}

final class _ChunkedByteCursor {
  final StreamIterator<List<int>> _iterator;
  List<int> _currentChunk = const <int>[];
  int _chunkOffset = 0;
  int _totalBytesRead = 0;

  _ChunkedByteCursor(Stream<List<int>> stream)
    : _iterator = StreamIterator<List<int>>(stream);

  int get totalBytesRead => _totalBytesRead;

  Future<bool> _ensureChunk() async {
    while (_chunkOffset >= _currentChunk.length) {
      if (!await _iterator.moveNext()) {
        return false;
      }
      _currentChunk = _iterator.current;
      _chunkOffset = 0;
    }
    return true;
  }

  Future<Uint8List?> readExact(int count) async {
    if (count == 0) {
      return Uint8List(0);
    }
    final out = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (!await _ensureChunk()) {
        return null;
      }
      final available = _currentChunk.length - _chunkOffset;
      final needed = count - written;
      final step = available < needed ? available : needed;
      out.setRange(written, written + step, _currentChunk, _chunkOffset);
      _chunkOffset += step;
      _totalBytesRead += step;
      written += step;
    }
    return out;
  }

  Future<bool> skipExact(int count) async {
    var remaining = count;
    while (remaining > 0) {
      if (!await _ensureChunk()) {
        return false;
      }
      final available = _currentChunk.length - _chunkOffset;
      final step = available < remaining ? available : remaining;
      _chunkOffset += step;
      _totalBytesRead += step;
      remaining -= step;
    }
    return true;
  }

  Future<bool> hasMoreBytes() => _ensureChunk();

  Future<void> cancel() => _iterator.cancel();
}

/// Streaming SoundFont 2.x preset parser that skips `sdta` sample payloads in O(1) memory.
final class SoundFontPresetParser implements ISoundFontPresetParser {
  static const String riffChunkId = 'RIFF';
  static const String sfbkFormType = 'sfbk';
  static const String listChunkId = 'LIST';
  static const String pdtaListType = 'pdta';
  static const String phdrChunkId = 'phdr';
  static const int riffHeaderByteCount = 12;
  static const int chunkHeaderByteCount = 8;
  static const int fourCcByteCount = 4;
  static const int phdrRecordByteCount = 38;
  static const int phdrPresetNameByteCount = 20;
  static const int phdrPresetNumOffset = 20;
  static const int phdrBankNumOffset = 22;
  static const String terminalSentinelPresetName = 'EOP';

  static const int _riffSizeOffset = 4;
  static const int _riffFormTypeOffset = 8;
  static const int _chunkSizeOffset = 4;
  static const int _zeroOffset = 0;
  static const int _nullTerminatorByte = 0;
  static const int _oddPadByteCount = 1;
  static const int _evenPadByteCount = 0;
  static const int _sentinelRecordCount = 1;

  const SoundFontPresetParser();

  @override
  Future<Result<List<SoundFontPresetInfo>>> parsePresetsFromSf2Stream({
    required Stream<List<int>> byteStream,
    required int byteLength,
  }) async {
    if (byteLength < riffHeaderByteCount + chunkHeaderByteCount) {
      return Err<List<SoundFontPresetInfo>>(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          'SF2 byteLength ($byteLength) is smaller than minimum RIFF/sfbk size',
        ),
      );
    }

    final cursor = _ChunkedByteCursor(byteStream);
    try {
      final riffHeader = await cursor.readExact(riffHeaderByteCount);
      if (riffHeader == null) {
        return const Err<List<SoundFontPresetInfo>>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'Unexpected EOF reading SF2 RIFF header',
          ),
        );
      }

      final riffId = _decodeAsciiStrict(riffHeader, _zeroOffset, fourCcByteCount);
      if (riffId != riffChunkId) {
        return Err<List<SoundFontPresetInfo>>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'Expected "$riffChunkId" chunk header, found "$riffId"',
          ),
        );
      }

      final riffView = ByteData.sublistView(riffHeader);
      final riffSize = riffView.getUint32(_riffSizeOffset, Endian.little);
      if (riffSize + chunkHeaderByteCount != byteLength) {
        return Err<List<SoundFontPresetInfo>>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'RIFF size ($riffSize) + $chunkHeaderByteCount does not match '
            'declared byteLength ($byteLength)',
          ),
        );
      }

      final formType = _decodeAsciiStrict(
        riffHeader,
        _riffFormTypeOffset,
        riffHeaderByteCount,
      );
      if (formType != sfbkFormType) {
        return Err<List<SoundFontPresetInfo>>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'Expected "$sfbkFormType" form type, found "$formType"',
          ),
        );
      }

      var remainingTopLevel = riffSize - fourCcByteCount;
      var foundPdta = false;
      List<SoundFontPresetInfo>? extractedPresets;
      var exceededPresetBuffer = false;

      while (remainingTopLevel > _zeroOffset) {
        if (remainingTopLevel < chunkHeaderByteCount) {
          return const Err<List<SoundFontPresetInfo>>(
            MuseError(
              MuseErrorCode.invalidSoundFontFormat,
              'Truncated top-level chunk header inside SF2 sfbk container',
            ),
          );
        }

        final chunkHeader = await cursor.readExact(chunkHeaderByteCount);
        if (chunkHeader == null) {
          return const Err<List<SoundFontPresetInfo>>(
            MuseError(
              MuseErrorCode.invalidSoundFontFormat,
              'Unexpected EOF reading SF2 top-level chunk header',
            ),
          );
        }
        remainingTopLevel -= chunkHeaderByteCount;

        final chunkId = _decodeAsciiStrict(
          chunkHeader,
          _zeroOffset,
          fourCcByteCount,
        );
        final chunkSize = ByteData.sublistView(
          chunkHeader,
        ).getUint32(_chunkSizeOffset, Endian.little);
        final padBytes = chunkSize.isOdd ? _oddPadByteCount : _evenPadByteCount;

        if (chunkSize + padBytes > remainingTopLevel) {
          return Err<List<SoundFontPresetInfo>>(
            MuseError(
              MuseErrorCode.invalidSoundFontFormat,
              'Chunk "$chunkId" size ($chunkSize + $padBytes pad) exceeds '
              'remaining sfbk bytes ($remainingTopLevel)',
            ),
          );
        }

        if (chunkId == listChunkId) {
          if (chunkSize < fourCcByteCount) {
            return const Err<List<SoundFontPresetInfo>>(
              MuseError(
                MuseErrorCode.invalidSoundFontFormat,
                'SF2 LIST chunk smaller than 4-byte list type',
              ),
            );
          }

          final listTypeBytes = await cursor.readExact(fourCcByteCount);
          if (listTypeBytes == null) {
            return const Err<List<SoundFontPresetInfo>>(
              MuseError(
                MuseErrorCode.invalidSoundFontFormat,
                'Unexpected EOF reading SF2 LIST type',
              ),
            );
          }

          final listType = _decodeAsciiStrict(
            listTypeBytes,
            _zeroOffset,
            fourCcByteCount,
          );
          final listPayloadBytes = chunkSize - fourCcByteCount;

          if (listType == pdtaListType) {
            if (foundPdta) {
              return const Err<List<SoundFontPresetInfo>>(
                MuseError(
                  MuseErrorCode.invalidSoundFontFormat,
                  'Duplicate "$pdtaListType" LIST chunk in SF2',
                ),
              );
            }
            foundPdta = true;

            final pdtaResult = await _parsePdtaList(
              cursor: cursor,
              pdtaPayloadBytes: listPayloadBytes,
            );
            switch (pdtaResult) {
              case Err(:final error):
                return Err<List<SoundFontPresetInfo>>(error);
              case Ok(:final value):
                extractedPresets = value.presets;
                exceededPresetBuffer = value.exceededPresetBuffer;
            }

            if (padBytes > _zeroOffset && !await cursor.skipExact(padBytes)) {
              return const Err<List<SoundFontPresetInfo>>(
                MuseError(
                  MuseErrorCode.invalidSoundFontFormat,
                  'Unexpected EOF skipping pdta alignment pad byte',
                ),
              );
            }
          } else {
            if (!await cursor.skipExact(listPayloadBytes + padBytes)) {
              return Err<List<SoundFontPresetInfo>>(
                MuseError(
                  MuseErrorCode.invalidSoundFontFormat,
                  'Unexpected EOF skipping LIST "$listType" payload',
                ),
              );
            }
          }
        } else {
          if (!await cursor.skipExact(chunkSize + padBytes)) {
            return Err<List<SoundFontPresetInfo>>(
              MuseError(
                MuseErrorCode.invalidSoundFontFormat,
                'Unexpected EOF skipping "$chunkId" chunk payload',
              ),
            );
          }
        }

        remainingTopLevel -= chunkSize + padBytes;
      }

      if (await cursor.hasMoreBytes() || cursor.totalBytesRead != byteLength) {
        return Err<List<SoundFontPresetInfo>>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'SF2 stream byte count (${cursor.totalBytesRead}) does not match '
            'declared byteLength ($byteLength)',
          ),
        );
      }

      if (!foundPdta || extractedPresets == null) {
        return const Err<List<SoundFontPresetInfo>>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'SF2 missing required "$pdtaListType/$phdrChunkId" preset chunk',
          ),
        );
      }

      if (exceededPresetBuffer) {
        return const Err<List<SoundFontPresetInfo>>(
          MuseError(
            MuseErrorCode.soundFontPresetBufferTooSmall,
            'SF2 preset count exceeds MuseConstants.maxSoundFontPresets '
            '(${MuseConstants.maxSoundFontPresets})',
          ),
        );
      }

      return Ok<List<SoundFontPresetInfo>>(
        List<SoundFontPresetInfo>.unmodifiable(extractedPresets),
      );
    } on FormatException catch (e) {
      return Err<List<SoundFontPresetInfo>>(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          'Invalid ASCII encoding inside SF2 metadata',
          cause: e,
        ),
      );
    } catch (e) {
      return Err<List<SoundFontPresetInfo>>(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          'Failed reading SF2 byte stream',
          cause: e,
        ),
      );
    } finally {
      await cursor.cancel();
    }
  }

  Future<Result<_PdtaParseOutcome>> _parsePdtaList({
    required _ChunkedByteCursor cursor,
    required int pdtaPayloadBytes,
  }) async {
    var remainingPdta = pdtaPayloadBytes;
    List<SoundFontPresetInfo>? presets;
    var exceededPresetBuffer = false;

    while (remainingPdta > _zeroOffset) {
      if (remainingPdta < chunkHeaderByteCount) {
        return const Err<_PdtaParseOutcome>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'Truncated subchunk header inside SF2 pdta LIST',
          ),
        );
      }

      final subHeader = await cursor.readExact(chunkHeaderByteCount);
      if (subHeader == null) {
        return const Err<_PdtaParseOutcome>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'Unexpected EOF reading SF2 pdta subchunk header',
          ),
        );
      }
      remainingPdta -= chunkHeaderByteCount;

      final subId = _decodeAsciiStrict(
        subHeader,
        _zeroOffset,
        fourCcByteCount,
      );
      final subSize = ByteData.sublistView(
        subHeader,
      ).getUint32(_chunkSizeOffset, Endian.little);
      final subPad = subSize.isOdd ? _oddPadByteCount : _evenPadByteCount;

      if (subSize + subPad > remainingPdta) {
        return Err<_PdtaParseOutcome>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'SF2 pdta subchunk "$subId" size ($subSize + $subPad pad) exceeds '
            'remaining pdta bytes ($remainingPdta)',
          ),
        );
      }

      if (subId == phdrChunkId) {
        if (presets != null) {
          return const Err<_PdtaParseOutcome>(
            MuseError(
              MuseErrorCode.invalidSoundFontFormat,
              'Duplicate "$phdrChunkId" subchunk in SF2 pdta',
            ),
          );
        }

        final phdrResult = await _parsePhdrRecords(
          cursor: cursor,
          phdrByteSize: subSize,
        );
        switch (phdrResult) {
          case Err(:final error):
            return Err<_PdtaParseOutcome>(error);
          case Ok(:final value):
            presets = value.presets;
            exceededPresetBuffer = value.exceededPresetBuffer;
        }

        if (subPad > _zeroOffset && !await cursor.skipExact(subPad)) {
          return const Err<_PdtaParseOutcome>(
            MuseError(
              MuseErrorCode.invalidSoundFontFormat,
              'Unexpected EOF skipping phdr alignment pad byte',
            ),
          );
        }
      } else {
        if (!await cursor.skipExact(subSize + subPad)) {
          return Err<_PdtaParseOutcome>(
            MuseError(
              MuseErrorCode.invalidSoundFontFormat,
              'Unexpected EOF skipping pdta subchunk "$subId"',
            ),
          );
        }
      }

      remainingPdta -= subSize + subPad;
    }

    if (presets == null) {
      return const Err<_PdtaParseOutcome>(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          'SF2 pdta LIST missing required "$phdrChunkId" subchunk',
        ),
      );
    }

    return Ok<_PdtaParseOutcome>(
      _PdtaParseOutcome(
        presets: presets,
        exceededPresetBuffer: exceededPresetBuffer,
      ),
    );
  }

  Future<Result<_PdtaParseOutcome>> _parsePhdrRecords({
    required _ChunkedByteCursor cursor,
    required int phdrByteSize,
  }) async {
    if (phdrByteSize < phdrRecordByteCount ||
        phdrByteSize % phdrRecordByteCount != _zeroOffset) {
      return Err<_PdtaParseOutcome>(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          'Invalid "$phdrChunkId" byte size ($phdrByteSize): must be a non-zero '
          'multiple of $phdrRecordByteCount bytes',
        ),
      );
    }

    final recordCount = phdrByteSize ~/ phdrRecordByteCount;
    final presetCount = recordCount - _sentinelRecordCount;
    final exceededPresetBuffer = presetCount > MuseConstants.maxSoundFontPresets;
    final presets = <SoundFontPresetInfo>[];

    for (var i = 0; i < recordCount; i++) {
      final recordBytes = await cursor.readExact(phdrRecordByteCount);
      if (recordBytes == null) {
        return Err<_PdtaParseOutcome>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'Unexpected EOF reading SF2 phdr record $i',
          ),
        );
      }

      final presetName = _decodePresetName(recordBytes);
      final isSentinelRecord = i == recordCount - _sentinelRecordCount;
      if (isSentinelRecord) {
        if (presetName != terminalSentinelPresetName) {
          return Err<_PdtaParseOutcome>(
            MuseError(
              MuseErrorCode.invalidSoundFontFormat,
              'Missing terminal "$terminalSentinelPresetName" sentinel at end of '
              '"$phdrChunkId" (found "$presetName")',
            ),
          );
        }
        continue;
      }

      final recordView = ByteData.sublistView(recordBytes);
      final programNum = recordView.getUint16(
        phdrPresetNumOffset,
        Endian.little,
      );
      final bankNum = recordView.getUint16(phdrBankNumOffset, Endian.little);

      if (programNum < MuseConstants.minProgramNum ||
          programNum > MuseConstants.maxProgramNum) {
        return Err<_PdtaParseOutcome>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'Preset "$presetName" programNum ($programNum) outside '
            '${MuseConstants.minProgramNum}..${MuseConstants.maxProgramNum}',
          ),
        );
      }
      if (bankNum < MuseConstants.minBankNum ||
          bankNum > MuseConstants.maxBankNum) {
        return Err<_PdtaParseOutcome>(
          MuseError(
            MuseErrorCode.invalidSoundFontFormat,
            'Preset "$presetName" bankNum ($bankNum) outside '
            '${MuseConstants.minBankNum}..${MuseConstants.maxBankNum}',
          ),
        );
      }

      if (presets.length < MuseConstants.maxSoundFontPresets) {
        presets.add(
          SoundFontPresetInfo(
            bankNum: bankNum,
            programNum: programNum,
            presetName: presetName,
          ),
        );
      }
    }

    return Ok<_PdtaParseOutcome>(
      _PdtaParseOutcome(
        presets: presets,
        exceededPresetBuffer: exceededPresetBuffer,
      ),
    );
  }

  static String _decodeAsciiStrict(Uint8List bytes, int start, int end) {
    return ascii.decode(bytes.sublist(start, end), allowInvalid: false);
  }

  static String _decodePresetName(Uint8List recordBytes) {
    var length = phdrPresetNameByteCount;
    for (var i = 0; i < phdrPresetNameByteCount; i++) {
      if (recordBytes[i] == _nullTerminatorByte) {
        length = i;
        break;
      }
    }
    return latin1.decode(recordBytes.sublist(_zeroOffset, length)).trim();
  }
}

final class _PdtaParseOutcome {
  final List<SoundFontPresetInfo> presets;
  final bool exceededPresetBuffer;

  const _PdtaParseOutcome({
    required this.presets,
    required this.exceededPresetBuffer,
  });
}

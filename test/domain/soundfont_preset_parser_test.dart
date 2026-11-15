import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/assets/soundfont_preset_parser.dart';

Uint8List _asciiBytes(String text) => Uint8List.fromList(ascii.encode(text));

Uint8List _chunk(String fourCc, Uint8List payload) {
  final pad = payload.length.isOdd ? 1 : 0;
  final out = Uint8List(8 + payload.length + pad);
  out.setRange(0, 4, _asciiBytes(fourCc));
  ByteData.sublistView(out).setUint32(4, payload.length, Endian.little);
  out.setRange(8, 8 + payload.length, payload);
  return out;
}

Uint8List _listChunk(String listType, List<Uint8List> subchunks) {
  var bodyLength = 4;
  for (final sub in subchunks) {
    bodyLength += sub.length;
  }
  final body = Uint8List(bodyLength);
  body.setRange(0, 4, _asciiBytes(listType));
  var offset = 4;
  for (final sub in subchunks) {
    body.setRange(offset, offset + sub.length, sub);
    offset += sub.length;
  }
  return _chunk('LIST', body);
}

Uint8List _phdrRecord({
  required String name,
  required int programNum,
  required int bankNum,
}) {
  final rec = Uint8List(38);
  final nameBytes = latin1.encode(name);
  final copyLen = nameBytes.length > 20 ? 20 : nameBytes.length;
  rec.setRange(0, copyLen, nameBytes);
  final view = ByteData.sublistView(rec);
  view.setUint16(20, programNum, Endian.little);
  view.setUint16(22, bankNum, Endian.little);
  return rec;
}

Uint8List _buildSf2({
  int sdtaSampleBytes = 0,
  bool includeOddInfoChunk = true,
  bool includePdta = true,
  bool includePhdr = true,
  bool includeEop = true,
  int eopBank = 255,
  int eopProg = 255,
  List<SoundFontPresetInfo> presets = const <SoundFontPresetInfo>[
    SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Grand Piano'),
    SoundFontPresetInfo(bankNum: 128, programNum: 0, presetName: 'Standard Kit'),
  ],
}) {
  final topChunks = <Uint8List>[];

  if (includeOddInfoChunk) {
    // 5-byte payload triggers RIFF 1-byte odd padding.
    topChunks.add(
      _listChunk('INFO', <Uint8List>[_chunk('INAM', _asciiBytes('Muse!'))]),
    );
  }

  if (sdtaSampleBytes > 0) {
    topChunks.add(
      _listChunk('sdta', <Uint8List>[_chunk('smpl', Uint8List(sdtaSampleBytes))]),
    );
  }

  if (includePdta) {
    final pdtaSubs = <Uint8List>[];
    if (includePhdr) {
      final totalRecords = presets.length + (includeEop ? 1 : 0);
      final phdrBytes = Uint8List(totalRecords * 38);
      for (var i = 0; i < presets.length; i++) {
        final p = presets[i];
        phdrBytes.setRange(
          i * 38,
          (i + 1) * 38,
          _phdrRecord(
            name: p.presetName,
            programNum: p.programNum,
            bankNum: p.bankNum,
          ),
        );
      }
      if (includeEop) {
        phdrBytes.setRange(
          presets.length * 38,
          totalRecords * 38,
          _phdrRecord(name: 'EOP', programNum: eopProg, bankNum: eopBank),
        );
      }
      pdtaSubs.add(_chunk('phdr', phdrBytes));
    }
    pdtaSubs.add(_chunk('pbag', Uint8List(4)));
    topChunks.add(_listChunk('pdta', pdtaSubs));
  }

  var bodyBytes = 4;
  for (final c in topChunks) {
    bodyBytes += c.length;
  }
  final out = Uint8List(8 + bodyBytes);
  out.setRange(0, 4, _asciiBytes('RIFF'));
  ByteData.sublistView(out).setUint32(4, bodyBytes, Endian.little);
  out.setRange(8, 12, _asciiBytes('sfbk'));
  var offset = 12;
  for (final c in topChunks) {
    out.setRange(offset, offset + c.length, c);
    offset += c.length;
  }
  return out;
}

Stream<List<int>> _irregularChunkStream(Uint8List data) async* {
  const pattern = <int>[1, 0, 7, 3, 64, 0, 4096, 13, 512];
  var offset = 0;
  var stepIdx = 0;
  while (offset < data.length) {
    final size = pattern[stepIdx % pattern.length];
    stepIdx++;
    if (size == 0) {
      yield const <int>[];
      continue;
    }
    final end = offset + size > data.length ? data.length : offset + size;
    yield data.sublist(offset, end);
    offset = end;
  }
}

void main() {
  const parser = SoundFontPresetParser();

  group('SoundFontPresetParser valid SF2 streams', () {
    test('extracts presets across multi-megabyte sdta, odd-padded chunks, and irregular stream chunks', () async {
      final sf2 = _buildSf2(
        sdtaSampleBytes: 3 * 1024 * 1024 + 3,
        includeOddInfoChunk: true,
        presets: const <SoundFontPresetInfo>[
          SoundFontPresetInfo(
            bankNum: 0,
            programNum: 0,
            presetName: 'Yamaha Grand',
          ),
          SoundFontPresetInfo(
            bankNum: 8,
            programNum: 48,
            presetName: 'Slow Strings',
          ),
          SoundFontPresetInfo(
            bankNum: 128,
            programNum: 0,
            presetName: 'Standard Kit',
          ),
        ],
      );

      final result = await parser.parsePresetsFromSf2Stream(
        byteStream: _irregularChunkStream(sf2),
        byteLength: sf2.length,
      );

      expect(result, isA<Ok<List<SoundFontPresetInfo>>>());
      final presets = (result as Ok<List<SoundFontPresetInfo>>).value;
      expect(presets.length, 3);
      expect(presets[0].bankNum, 0);
      expect(presets[0].programNum, 0);
      expect(presets[0].presetName, 'Yamaha Grand');
      expect(presets[1].bankNum, 8);
      expect(presets[1].programNum, 48);
      expect(presets[1].presetName, 'Slow Strings');
      expect(presets[2].bankNum, 128);
      expect(presets[2].programNum, 0);
      expect(presets[2].presetName, 'Standard Kit');
      expect(() => presets.add(presets.first), throwsUnsupportedError);
    });

    test('returns empty list when phdr contains only EOP sentinel', () async {
      final sf2 = _buildSf2(presets: const <SoundFontPresetInfo>[]);
      final result = await parser.parsePresetsFromSf2Stream(
        byteStream: Stream<List<int>>.value(sf2),
        byteLength: sf2.length,
      );

      expect(result, isA<Ok<List<SoundFontPresetInfo>>>());
      expect((result as Ok<List<SoundFontPresetInfo>>).value, isEmpty);
    });
  });

  group('SoundFontPresetParser fail-closed validation', () {
    test('rejects non-RIFF and non-sfbk headers', () async {
      final badRiff = _buildSf2()..setRange(0, 4, _asciiBytes('RIFX'));
      final res1 = await parser.parsePresetsFromSf2Stream(
        byteStream: Stream<List<int>>.value(badRiff),
        byteLength: badRiff.length,
      );
      expect(res1, isA<Err<List<SoundFontPresetInfo>>>());
      expect(
        (res1 as Err<List<SoundFontPresetInfo>>).error.code,
        MuseErrorCode.invalidSoundFontFormat,
      );

      final badForm = _buildSf2()..setRange(8, 12, _asciiBytes('WAVE'));
      final res2 = await parser.parsePresetsFromSf2Stream(
        byteStream: Stream<List<int>>.value(badForm),
        byteLength: badForm.length,
      );
      expect(
        (res2 as Err<List<SoundFontPresetInfo>>).error.code,
        MuseErrorCode.invalidSoundFontFormat,
      );
    });

    test('rejects truncated or trailing-corrupt streams against byteLength', () async {
      final sf2 = _buildSf2();
      final resTruncated = await parser.parsePresetsFromSf2Stream(
        byteStream: Stream<List<int>>.value(sf2.sublist(0, sf2.length - 5)),
        byteLength: sf2.length,
      );
      expect(
        (resTruncated as Err<List<SoundFontPresetInfo>>).error.code,
        MuseErrorCode.invalidSoundFontFormat,
      );

      final resTooSmall = await parser.parsePresetsFromSf2Stream(
        byteStream: Stream<List<int>>.value(sf2),
        byteLength: 10,
      );
      expect(
        (resTooSmall as Err<List<SoundFontPresetInfo>>).error.code,
        MuseErrorCode.invalidSoundFontFormat,
      );
    });

    test('rejects missing pdta, missing phdr, unaligned phdr, and missing EOP', () async {
      final noPdta = _buildSf2(includePdta: false);
      expect(
        ((await parser.parsePresetsFromSf2Stream(
                  byteStream: Stream<List<int>>.value(noPdta),
                  byteLength: noPdta.length,
                ))
                as Err<List<SoundFontPresetInfo>>)
            .error
            .code,
        MuseErrorCode.invalidSoundFontFormat,
      );

      final noPhdr = _buildSf2(includePhdr: false);
      expect(
        ((await parser.parsePresetsFromSf2Stream(
                  byteStream: Stream<List<int>>.value(noPhdr),
                  byteLength: noPhdr.length,
                ))
                as Err<List<SoundFontPresetInfo>>)
            .error
            .code,
        MuseErrorCode.invalidSoundFontFormat,
      );

      final noEop = _buildSf2(includeEop: false);
      expect(
        ((await parser.parsePresetsFromSf2Stream(
                  byteStream: Stream<List<int>>.value(noEop),
                  byteLength: noEop.length,
                ))
                as Err<List<SoundFontPresetInfo>>)
            .error
            .code,
        MuseErrorCode.invalidSoundFontFormat,
      );

      // Corrupt phdr size by replacing phdr chunk length with non-multiple of 38.
      final badAlignedPhdr = _chunk('phdr', Uint8List(39));
      final pdta = _listChunk('pdta', <Uint8List>[badAlignedPhdr]);
      final badSf2 = Uint8List(12 + pdta.length);
      badSf2.setRange(0, 4, _asciiBytes('RIFF'));
      ByteData.sublistView(badSf2).setUint32(4, 4 + pdta.length, Endian.little);
      badSf2.setRange(8, 12, _asciiBytes('sfbk'));
      badSf2.setRange(12, 12 + pdta.length, pdta);
      expect(
        ((await parser.parsePresetsFromSf2Stream(
                  byteStream: Stream<List<int>>.value(badSf2),
                  byteLength: badSf2.length,
                ))
                as Err<List<SoundFontPresetInfo>>)
            .error
            .code,
        MuseErrorCode.invalidSoundFontFormat,
      );
    });

    test('rejects out-of-range programNum and preset count exceeding maxSoundFontPresets', () async {
      final invalidProgramSf2 = _buildSf2(
        presets: const <SoundFontPresetInfo>[
          SoundFontPresetInfo(bankNum: 0, programNum: 128, presetName: 'Bad'),
        ],
      );
      expect(
        ((await parser.parsePresetsFromSf2Stream(
                  byteStream: Stream<List<int>>.value(invalidProgramSf2),
                  byteLength: invalidProgramSf2.length,
                ))
                as Err<List<SoundFontPresetInfo>>)
            .error
            .code,
        MuseErrorCode.invalidSoundFontFormat,
      );

      final maxPresets = List<SoundFontPresetInfo>.generate(
        MuseConstants.maxSoundFontPresets,
        (i) => SoundFontPresetInfo(
          bankNum: i ~/ 128,
          programNum: i % 128,
          presetName: 'Preset $i',
        ),
      );
      final atLimitSf2 = _buildSf2(presets: maxPresets);
      final okResult = await parser.parsePresetsFromSf2Stream(
        byteStream: Stream<List<int>>.value(atLimitSf2),
        byteLength: atLimitSf2.length,
      );
      expect(okResult, isA<Ok<List<SoundFontPresetInfo>>>());
      expect(
        (okResult as Ok<List<SoundFontPresetInfo>>).value.length,
        MuseConstants.maxSoundFontPresets,
      );

      final overLimitSf2 = _buildSf2(
        presets: <SoundFontPresetInfo>[
          ...maxPresets,
          const SoundFontPresetInfo(
            bankNum: 0,
            programNum: 0,
            presetName: 'Overflow',
          ),
        ],
      );
      final errResult = await parser.parsePresetsFromSf2Stream(
        byteStream: Stream<List<int>>.value(overLimitSf2),
        byteLength: overLimitSf2.length,
      );
      expect(errResult, isA<Err<List<SoundFontPresetInfo>>>());
      expect(
        (errResult as Err<List<SoundFontPresetInfo>>).error.code,
        MuseErrorCode.soundFontPresetBufferTooSmall,
      );
    });

    test('decodes ISO-8859-1 (Latin-1) preset names cleanly without throwing', () async {
      final sf2 = _buildSf2(
        presets: const <SoundFontPresetInfo>[
          SoundFontPresetInfo(
            bankNum: 0,
            programNum: 0,
            presetName: 'Café Grand',
          ),
          SoundFontPresetInfo(
            bankNum: 8,
            programNum: 19,
            presetName: 'Übung Organ',
          ),
        ],
      );

      final result = await parser.parsePresetsFromSf2Stream(
        byteStream: Stream<List<int>>.value(sf2),
        byteLength: sf2.length,
      );

      expect(result, isA<Ok<List<SoundFontPresetInfo>>>());
      final presets = (result as Ok<List<SoundFontPresetInfo>>).value;
      expect(presets, hasLength(2));
      expect(presets[0].bankNum, 0);
      expect(presets[0].programNum, 0);
      expect(presets[0].presetName, 'Café Grand');
      expect(presets[1].bankNum, 8);
      expect(presets[1].programNum, 19);
      expect(presets[1].presetName, 'Übung Organ');
    });
  });
}

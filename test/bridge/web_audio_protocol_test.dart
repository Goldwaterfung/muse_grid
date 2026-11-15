import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/bridge/web/web_audio_protocol.dart';

Uint8List _encodePcm16Wav({
  required int sampleRate,
  required int channelCount,
  required List<int> interleavedSamples,
}) {
  final dataBytes = interleavedSamples.length * 2;
  final header = RiffWavCodec.buildPcm16Header(
    sampleRate: sampleRate,
    channelCount: channelCount,
    dataByteLength: dataBytes,
  );
  final out = Uint8List(header.length + dataBytes);
  out.setAll(0, header);
  final bd = ByteData.view(out.buffer);
  for (var i = 0; i < interleavedSamples.length; i++) {
    bd.setInt16(header.length + i * 2, interleavedSamples[i], Endian.little);
  }
  return out;
}

Uint8List _encodeFloat32Wav({
  required int sampleRate,
  required int channelCount,
  required List<double> interleavedSamples,
}) {
  final dataBytes = interleavedSamples.length * 4;
  final totalBytes = RiffWavCodec.riffHeaderByteLength + dataBytes;
  final out = Uint8List(totalBytes);
  final bd = ByteData.view(out.buffer);
  final blockAlign = channelCount * 4;
  final byteRate = sampleRate * blockAlign;

  bd.setUint32(0, 0x46464952, Endian.little); // RIFF
  bd.setUint32(4, 36 + dataBytes, Endian.little);
  bd.setUint32(8, 0x45564157, Endian.little); // WAVE
  bd.setUint32(12, 0x20746d66, Endian.little); // fmt
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 3, Endian.little); // IEEE float32
  bd.setUint16(22, channelCount, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, byteRate, Endian.little);
  bd.setUint16(32, blockAlign, Endian.little);
  bd.setUint16(34, 32, Endian.little);
  bd.setUint32(36, 0x61746164, Endian.little); // data
  bd.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < interleavedSamples.length; i++) {
    bd.setFloat32(44 + i * 4, interleavedSamples[i], Endian.little);
  }
  return out;
}

void main() {
  group('RiffWavCodec', () {
    test('buildPcm16Header round-trips canonical 44-byte RIFF header', () {
      final header = RiffWavCodec.buildPcm16Header(
        sampleRate: 48000,
        channelCount: 2,
        dataByteLength: 9600,
      );
      expect(header.length, RiffWavCodec.riffHeaderByteLength);
      final bd = ByteData.sublistView(header);
      expect(bd.getUint32(4, Endian.little), 36 + 9600);
      expect(bd.getUint16(20, Endian.little), 1);
      expect(bd.getUint16(22, Endian.little), 2);
      expect(bd.getUint32(24, Endian.little), 48000);
      expect(bd.getUint32(28, Endian.little), 48000 * 4);
      expect(bd.getUint16(32, Endian.little), 4);
      expect(bd.getUint16(34, Endian.little), 16);
      expect(bd.getUint32(40, Endian.little), 9600);
    });

    test('quantizeFloat32ToPcm16WithTpdf sanitizes non-finite & clamps bounds', () {
      final input = Float32List.fromList(<double>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
        2.5,
        -2.5,
        0.0,
        0.5,
        -0.5,
      ]);
      final pcm = RiffWavCodec.quantizeFloat32ToPcm16WithTpdf(
        input,
        math.Random(42),
      );
      expect(pcm.length, input.length);
      for (final s in pcm) {
        expect(s, inInclusiveRange(-32768, 32767));
      }
      // First three non-finite samples sanitize to 0 +/- 1 LSB dither.
      expect(pcm[0], inInclusiveRange(-1, 1));
      expect(pcm[1], inInclusiveRange(-1, 1));
      expect(pcm[2], inInclusiveRange(-1, 1));
      // Clipped full-scale signals remain bounded near extrema.
      expect(pcm[3], greaterThanOrEqualTo(32766));
      expect(pcm[4], lessThanOrEqualTo(-32766));
      expect(pcm[6], inInclusiveRange(16382, 16385));
      expect(pcm[7], inInclusiveRange(-16385, -16382));
    });

    test('decodeWavBytes decodes PCM16 & Float32 and fails closed on corrupt WAV', () {
      final pcmBytes = _encodePcm16Wav(
        sampleRate: 48000,
        channelCount: 1,
        interleavedSamples: const <int>[0, 16384, -16384, 32767],
      );
      final pcmRes = RiffWavCodec.decodeWavBytes(pcmBytes);
      expect(pcmRes.isOk, isTrue);
      final decodedPcm = (pcmRes as Ok<DecodedWavPcm>).value;
      expect(decodedPcm.sampleRate, 48000);
      expect(decodedPcm.channelCount, 1);
      expect(decodedPcm.frameCount, 4);
      expect(decodedPcm.interleavedSamples[1], closeTo(0.5, 1e-4));
      expect(decodedPcm.interleavedSamples[2], closeTo(-0.5, 1e-4));

      final f32Bytes = _encodeFloat32Wav(
        sampleRate: 44100,
        channelCount: 2,
        interleavedSamples: <double>[0.25, -0.25, double.nan, 0.75],
      );
      final f32Res = RiffWavCodec.decodeWavBytes(f32Bytes);
      expect(f32Res.isOk, isTrue);
      final decodedF32 = (f32Res as Ok<DecodedWavPcm>).value;
      expect(decodedF32.channelCount, 2);
      expect(decodedF32.frameCount, 2);
      expect(decodedF32.interleavedSamples[2], 0.0); // NaN sanitized
      expect(decodedF32.interleavedSamples[3], closeTo(0.75, 1e-6));

      // Corrupt magic & truncated chunk both fail closed cleanly.
      final badMagic = Uint8List.fromList(pcmBytes)..[0] = 0x58;
      final badRes = RiffWavCodec.decodeWavBytes(badMagic);
      expect(badRes.isErr, isTrue);
      expect((badRes as Err<DecodedWavPcm>).error.code, MuseErrorCode.takeLoadFailed);

      final truncated = Uint8List.sublistView(pcmBytes, 0, 20);
      final truncRes = RiffWavCodec.decodeWavBytes(truncated);
      expect(truncRes.isErr, isTrue);
      expect((truncRes as Err<DecodedWavPcm>).error.code, MuseErrorCode.takeLoadFailed);
    });

    test('resampleAndMixTakeToStereoF32 matches C++ gain/pan math and resamples', () {
      // Mono unit signal panned hard left vs hard right & +6 dB boost.
      final monoPcm = DecodedWavPcm(
        sampleRate: 48000,
        channelCount: 1,
        frameCount: 4,
        interleavedSamples: Float32List.fromList(<double>[0.5, 0.5, 0.5, 0.5]),
      );

      final hardLeft = RiffWavCodec.resampleAndMixTakeToStereoF32(
        pcm: monoPcm,
        targetSampleRate: 48000,
        gainDb: 6.0,
        pan: -1.0,
      );
      final expectedBoost = math.pow(10.0, 6.0 / 20.0).toDouble();
      expect(hardLeft.length, 8);
      expect(hardLeft[0], closeTo(0.5 * expectedBoost, 1e-5));
      expect(hardLeft[1], closeTo(0.0, 1e-5));

      final hardRight = RiffWavCodec.resampleAndMixTakeToStereoF32(
        pcm: monoPcm,
        targetSampleRate: 48000,
        gainDb: 0.0,
        pan: 1.0,
      );
      expect(hardRight[0], closeTo(0.0, 1e-5));
      expect(hardRight[1], closeTo(0.5, 1e-5));

      // Linear resampling from 24 kHz to 48 kHz doubles frame count & interpolates midpoint.
      final lowRatePcm = DecodedWavPcm(
        sampleRate: 24000,
        channelCount: 1,
        frameCount: 3,
        interleavedSamples: Float32List.fromList(<double>[0.0, 0.5, 1.0]),
      );
      final upsampled = RiffWavCodec.resampleAndMixTakeToStereoF32(
        pcm: lowRatePcm,
        targetSampleRate: 48000,
        gainDb: 0.0,
        pan: 0.0,
      );
      expect(upsampled.length, 6 * 2);
      final centerPanGain = math.cos(math.pi / 4.0);
      expect(upsampled[0], closeTo(0.0, 1e-5));
      expect(upsampled[2], closeTo(0.25 * centerPanGain, 1e-5));
      expect(upsampled[4], closeTo(0.5 * centerPanGain, 1e-5));
    });
  });

  group('WebBridgeErrorMapper & WebBridgeValidator', () {
    test('maps C status & DOM errors cleanly', () {
      expect(
        WebBridgeErrorMapper.mapMuseStatus(
          WebBridgeErrorMapper.museErrTransportNotStopped,
          context: WebBridgeOpContext.soundFontWeb,
        ).code,
        MuseErrorCode.webSoundFontLoadWhilePlaying,
      );
      expect(
        WebBridgeErrorMapper.mapMuseStatus(
          WebBridgeErrorMapper.museErrSfTooLarge,
          context: WebBridgeOpContext.soundFontWeb,
        ).code,
        MuseErrorCode.soundFontTooLargeForWeb,
      );
      expect(
        WebBridgeErrorMapper.mapMuseStatus(
          WebBridgeErrorMapper.museErrCaptureOverflow,
          context: WebBridgeOpContext.captureStorage,
        ).code,
        MuseErrorCode.captureBufferOverflow,
      );
      expect(
        WebBridgeErrorMapper.mapDomException(
          'NotAllowedError',
          context: WebBridgeOpContext.capturePermission,
        ).code,
        MuseErrorCode.microphonePermissionDenied,
      );
      expect(
        WebBridgeErrorMapper.mapDomException(
          'NotAllowedError',
          context: WebBridgeOpContext.lifecycle,
        ).code,
        MuseErrorCode.webAudioUserGestureRequired,
      );
      expect(
        WebBridgeErrorMapper.mapDomException(
          'QuotaExceededError',
          context: WebBridgeOpContext.captureStorage,
        ).code,
        MuseErrorCode.insufficientStorageQuota,
      );
    });

    test('validator rejects out-of-range parameters & oversized Web SF2', () {
      expect(
        WebBridgeValidator.checkInitialized<void>(
          isInitialized: false,
          errorCode: MuseErrorCode.audioDeviceInitFailed,
        )?.error.code,
        MuseErrorCode.audioDeviceInitFailed,
      );
      expect(
        WebBridgeValidator.checkMidiChannel<void>(16)?.error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        WebBridgeValidator.checkPitch<void>(128)?.error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        WebBridgeValidator.checkSevenBitVelocityOrCc<void>(
          128,
          'MIDI velocity',
        )?.error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        WebBridgeValidator.checkPitchBend<void>(8192)?.error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        WebBridgeValidator.checkMidiEventType<void>(99)?.error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        WebBridgeValidator.checkEventEpoch<void>(-1)?.error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        WebBridgeValidator.checkScheduledSampleFrame<void>(-2)?.error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        WebBridgeValidator.checkScheduledSampleFrame<void>(
          MuseConstants.immediateDispatchFrame,
        ),
        isNull,
      );
      expect(
        WebBridgeValidator.checkWebSoundFontSize<void>(
          MuseConstants.maxWebSoundFontBytes + 1,
        )?.error.code,
        MuseErrorCode.soundFontTooLargeForWeb,
      );
      expect(
        WebBridgeValidator.checkNotPlayingForWebSf2Load<void>(
          isPlaying: true,
        )?.error.code,
        MuseErrorCode.webSoundFontLoadWhilePlaying,
      );
      expect(
        WebBridgeValidator.checkTakeRegionCount<void>(
          MuseConstants.maxActiveTakeRegions + 1,
        )?.error.code,
        MuseErrorCode.takeLoadFailed,
      );
    });
  });
}

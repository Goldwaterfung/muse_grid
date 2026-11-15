/// Pure Dart Web audio protocol constants, RIFF/WAVE PCM16 & Float32 codecs,
/// error mapping, and fail-closed validation shared with [WebAudioWorkletBridge].
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../contracts/engine_constants.dart';
import '../contracts/result.dart';

/// Operation contexts used to disambiguate low-level engine/DOM failures.
enum WebBridgeOpContext {
  lifecycle,
  soundFontWeb,
  transport,
  synthEvent,
  capturePermission,
  captureStorage,
  takePlayback,
}

/// Decoded mono or stereo linear PCM audio payload extracted from a RIFF WAV.
final class DecodedWavPcm {
  final int sampleRate;
  final int channelCount;
  final int frameCount;
  final Float32List interleavedSamples;

  const DecodedWavPcm({
    required this.sampleRate,
    required this.channelCount,
    required this.frameCount,
    required this.interleavedSamples,
  });
}

/// Canonical RIFF/WAVE codecs, TPDF PCM16 dither quantization, and C++-aligned
/// constant-power stereo take resampling helpers.
abstract final class RiffWavCodec {
  /// Web Audio API hardware render quantum size (128 frames), matching
  /// `kWebRenderQuantumFrames` in `engine_constants.h`.
  static const int webRenderQuantumFrames = 128;

  /// Streaming chunk size when hashing finalized OPFS capture WAV files
  /// (`kSha256FileChunkBytes` in `engine_constants.h`).
  static const int sha256FileChunkBytes = 65536;

  /// Signed 14-bit MIDI pitch bend bounds (`kMinPitchBendSigned..kMaxPitchBendSigned`).
  static const int minPitchBendSigned = -8192;
  static const int maxPitchBendSigned = 8191;

  /// Event queue capacity mirrored from `engine_constants.h`.
  static const int eventQueueCapacity = 4096;

  static const int minSynthSampleRate = 8000;
  static const int maxSynthSampleRate = 96000;
  static const double decibelBase = 10.0;
  static const double amplitudeDbFactor = 20.0;
  static const double dac24BitDynamicRangeDb = 144.0;
  static const double minDbGainClamp = -dac24BitDynamicRangeDb;
  static const double maxDbGainClamp = 24.0;
  static const double minPan = -1.0;
  static const double centerPan = 0.0;
  static const double maxPan = 1.0;

  static const int riffHeaderByteLength = 44;
  static const int _riffFixedChunkOverhead = 36;
  static const int _pcmFmtChunkSize = 16;
  static const int _pcmFormatTag = 1;
  static const int _ieeeFloatFormatTag = 3;
  static const int _pcm16BitsPerSample = 16;
  static const int _float32BitsPerSample = 32;
  static const int _pcm16BytesPerSample = 2;
  static const int _float32BytesPerSample = 4;
  static const int _monoChannels = 1;
  static const int _stereoChannels = 2;
  static const int _minRiffContainerBytes = 12;
  static const int _chunkHeaderBytes = 8;
  static const int _pcm16Min = -32768;
  static const int _pcm16Max = 32767;
  static const double _pcm16FullScale = 32767.0;
  static const double _pcm16NormalizeScale = 32768.0;

  static const int _tagRiff = 0x46464952; // 'RIFF' in LE uint32
  static const int _tagWave = 0x45564157; // 'WAVE' in LE uint32
  static const int _tagFmt = 0x20746d66; // 'fmt ' in LE uint32
  static const int _tagData = 0x61746164; // 'data' in LE uint32

  /// Builds a canonical 44-byte RIFF/WAVE `fmt ` PCM16 little-endian header.
  static Uint8List buildPcm16Header({
    required int sampleRate,
    required int channelCount,
    required int dataByteLength,
  }) {
    if (sampleRate <= 0) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'Must be > 0.');
    }
    if (channelCount != _monoChannels && channelCount != _stereoChannels) {
      throw ArgumentError.value(
        channelCount,
        'channelCount',
        'Only mono or stereo WAV headers are supported.',
      );
    }
    if (dataByteLength < 0) {
      throw ArgumentError.value(
        dataByteLength,
        'dataByteLength',
        'Must be >= 0.',
      );
    }

    final bytes = Uint8List(riffHeaderByteLength);
    final bd = ByteData.view(bytes.buffer);
    final blockAlign = channelCount * _pcm16BytesPerSample;
    final byteRate = sampleRate * blockAlign;

    bd.setUint32(0, _tagRiff, Endian.little);
    bd.setUint32(4, _riffFixedChunkOverhead + dataByteLength, Endian.little);
    bd.setUint32(8, _tagWave, Endian.little);
    bd.setUint32(12, _tagFmt, Endian.little);
    bd.setUint32(16, _pcmFmtChunkSize, Endian.little);
    bd.setUint16(20, _pcmFormatTag, Endian.little);
    bd.setUint16(22, channelCount, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, _pcm16BitsPerSample, Endian.little);
    bd.setUint32(36, _tagData, Endian.little);
    bd.setUint32(40, dataByteLength, Endian.little);
    return bytes;
  }

  /// Quantizes [-1.0, 1.0] Float32 samples into signed 16-bit PCM using
  /// triangular PDF (TPDF) dithering `(rng.nextDouble() - rng.nextDouble())`
  /// and sanitizing non-finite samples to `0`.
  static Int16List quantizeFloat32ToPcm16WithTpdf(
    Float32List samples,
    math.Random rng,
  ) {
    final out = Int16List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      final raw = samples[i];
      final finite = raw.isFinite ? raw : 0.0;
      final clamped = finite.clamp(-1.0, 1.0);
      final tpdf = rng.nextDouble() - rng.nextDouble();
      final quantized = (clamped * _pcm16FullScale + tpdf).round();
      out[i] = quantized.clamp(_pcm16Min, _pcm16Max);
    }
    return out;
  }

  /// Validates and decodes canonical RIFF/WAVE PCM16 or IEEE Float32 audio into
  /// normalized interleaved Float32 samples, failing closed on malformed input.
  static Result<DecodedWavPcm> decodeWavBytes(Uint8List bytes) {
    if (bytes.length < riffHeaderByteLength) {
      return const Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'WAV byte buffer is shorter than 44-byte RIFF header.',
        ),
      );
    }

    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != _tagRiff ||
        bd.getUint32(8, Endian.little) != _tagWave) {
      return const Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'Invalid RIFF/WAVE header magic bytes.',
        ),
      );
    }

    int? audioFormat;
    int? channelCount;
    int? sampleRate;
    int? blockAlign;
    int? bitsPerSample;
    int? dataOffset;
    int? dataByteLength;

    var cursor = _minRiffContainerBytes;
    while (cursor + _chunkHeaderBytes <= bytes.length) {
      final chunkId = bd.getUint32(cursor, Endian.little);
      final chunkSize = bd.getUint32(cursor + 4, Endian.little);
      final payloadStart = cursor + _chunkHeaderBytes;
      final payloadEnd = payloadStart + chunkSize;
      if (payloadEnd > bytes.length) {
        return const Err(
          MuseError(
            MuseErrorCode.takeLoadFailed,
            'Truncated RIFF subchunk extends past WAV buffer length.',
          ),
        );
      }

      if (chunkId == _tagFmt) {
        if (chunkSize < _pcmFmtChunkSize) {
          return const Err(
            MuseError(
              MuseErrorCode.takeLoadFailed,
              'Malformed WAV fmt chunk (< 16 bytes).',
            ),
          );
        }
        audioFormat = bd.getUint16(payloadStart, Endian.little);
        channelCount = bd.getUint16(payloadStart + 2, Endian.little);
        sampleRate = bd.getUint32(payloadStart + 4, Endian.little);
        blockAlign = bd.getUint16(payloadStart + 12, Endian.little);
        bitsPerSample = bd.getUint16(payloadStart + 14, Endian.little);
      } else if (chunkId == _tagData) {
        dataOffset = payloadStart;
        dataByteLength = chunkSize;
        break;
      }

      // RIFF chunks are word-aligned (padded to even byte boundaries).
      cursor = payloadEnd + (chunkSize.isOdd ? 1 : 0);
    }

    if (audioFormat == null ||
        channelCount == null ||
        sampleRate == null ||
        blockAlign == null ||
        bitsPerSample == null ||
        dataOffset == null ||
        dataByteLength == null) {
      return const Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'WAV file missing required fmt or data chunk.',
        ),
      );
    }

    if (channelCount != _monoChannels && channelCount != _stereoChannels) {
      return Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'Unsupported WAV channel count: $channelCount.',
        ),
      );
    }
    if (sampleRate < minSynthSampleRate ||
        sampleRate > maxSynthSampleRate) {
      return Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'Unsupported WAV sample rate: $sampleRate Hz.',
        ),
      );
    }

    final isPcm16 =
        audioFormat == _pcmFormatTag && bitsPerSample == _pcm16BitsPerSample;
    final isFloat32 =
        audioFormat == _ieeeFloatFormatTag &&
        bitsPerSample == _float32BitsPerSample;
    if (!isPcm16 && !isFloat32) {
      return Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'Unsupported WAV encoding (format=$audioFormat, bits=$bitsPerSample).',
        ),
      );
    }

    final expectedBlockAlign = isPcm16
        ? channelCount * _pcm16BytesPerSample
        : channelCount * _float32BytesPerSample;
    if (blockAlign != expectedBlockAlign ||
        dataByteLength % expectedBlockAlign != 0) {
      return const Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'WAV block alignment or data byte count is inconsistent.',
        ),
      );
    }

    final frameCount = dataByteLength ~/ expectedBlockAlign;
    final totalSamples = frameCount * channelCount;
    final samples = Float32List(totalSamples);
    if (isPcm16) {
      for (var i = 0; i < totalSamples; i++) {
        final s16 = bd.getInt16(
          dataOffset + i * _pcm16BytesPerSample,
          Endian.little,
        );
        samples[i] = s16 / _pcm16NormalizeScale;
      }
    } else {
      for (var i = 0; i < totalSamples; i++) {
        final f32 = bd.getFloat32(
          dataOffset + i * _float32BytesPerSample,
          Endian.little,
        );
        samples[i] = f32.isFinite ? f32 : 0.0;
      }
    }

    return Ok(
      DecodedWavPcm(
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCount: frameCount,
        interleavedSamples: samples,
      ),
    );
  }

  /// Mirrors `muse::engine::dsp::dbToLinear` from `engine_constants.h`.
  static double dbToLinear(double gainDb) {
    if (!gainDb.isFinite) {
      return 0.0;
    }
    final clamped = gainDb.clamp(minDbGainClamp, maxDbGainClamp);
    return math.pow(decibelBase, clamped / amplitudeDbFactor).toDouble();
  }

  /// Mirrors `muse::engine::dsp::computeConstantPowerPan` from `engine_constants.h`.
  static ({double left, double right}) computeConstantPowerPan(double pan) {
    final safePan = pan.isFinite ? pan : centerPan;
    final clamped = safePan.clamp(minPan, maxPan);
    final normalized = (clamped - minPan) / (maxPan - minPan);
    final angle = normalized * (math.pi / 2.0);
    return (
      left: math.max(0.0, math.cos(angle)),
      right: math.max(0.0, math.sin(angle)),
    );
  }

  /// Resamples [pcm] via linear interpolation to [targetSampleRate] and mixes
  /// to interleaved stereo Float32 with C++-identical dB gain & constant-power pan.
  static Float32List resampleAndMixTakeToStereoF32({
    required DecodedWavPcm pcm,
    required int targetSampleRate,
    required double gainDb,
    required double pan,
  }) {
    if (targetSampleRate <= 0) {
      throw ArgumentError.value(
        targetSampleRate,
        'targetSampleRate',
        'Must be > 0.',
      );
    }
    if (pcm.sampleRate <= 0) {
      throw ArgumentError.value(
        pcm.sampleRate,
        'pcm.sampleRate',
        'Must be > 0.',
      );
    }
    if (pcm.channelCount != _monoChannels &&
        pcm.channelCount != _stereoChannels) {
      throw ArgumentError.value(
        pcm.channelCount,
        'pcm.channelCount',
        'Only mono or stereo takes are supported.',
      );
    }
    if (pcm.frameCount == 0) {
      return Float32List(0);
    }

    final linearGain = dbToLinear(gainDb);
    final panGains = computeConstantPowerPan(pan);
    final gainL = linearGain * panGains.left;
    final gainR = linearGain * panGains.right;

    final outFrameCount = pcm.sampleRate == targetSampleRate
        ? pcm.frameCount
        : math.max(
            1,
            ((pcm.frameCount * targetSampleRate) / pcm.sampleRate).round(),
          );
    final out = Float32List(outFrameCount * _stereoChannels);
    final src = pcm.interleavedSamples;
    final stepRatio = pcm.sampleRate / targetSampleRate;
    final lastSrcFrame = pcm.frameCount - 1;

    for (var outFrame = 0; outFrame < outFrameCount; outFrame++) {
      final srcPos = pcm.sampleRate == targetSampleRate
          ? outFrame.toDouble()
          : outFrame * stepRatio;
      final idx0 = srcPos.floor().clamp(0, lastSrcFrame);
      final idx1 = (idx0 + 1).clamp(0, lastSrcFrame);
      final frac = srcPos - idx0;

      final double leftSample;
      final double rightSample;
      if (pcm.channelCount == _monoChannels) {
        final s0 = src[idx0];
        final s1 = src[idx1];
        final mono = s0 + (s1 - s0) * frac;
        leftSample = mono;
        rightSample = mono;
      } else {
        final base0 = idx0 * _stereoChannels;
        final base1 = idx1 * _stereoChannels;
        leftSample = src[base0] + (src[base1] - src[base0]) * frac;
        rightSample = src[base0 + 1] + (src[base1 + 1] - src[base0 + 1]) * frac;
      }

      final dstBase = outFrame * _stereoChannels;
      out[dstBase] = (leftSample * gainL).toDouble();
      out[dstBase + 1] = (rightSample * gainR).toDouble();
    }

    return out;
  }
}

/// Centralized C/Wasm `MuseStatus` and Web DOM exception mapper.
abstract final class WebBridgeErrorMapper {
  static const int museOk = 0;
  static const int museErrDeviceInit = -1;
  static const int museErrPermissionDenied = -2;
  static const int museErrSfLoadFailed = -3;
  static const int museErrSfTooLarge = -4;
  static const int museErrTransportNotStopped = -5;
  static const int museErrQueueFull = -6;
  static const int museErrCaptureOverflow = -7;
  static const int museErrStorageIo = -8;
  static const int museErrBufferTooSmall = -9;
  static const int museErrTakeLoadFailed = -10;

  /// Translates a C/Wasm `MuseStatus` integer code into a domain [MuseError].
  static MuseError mapMuseStatus(
    int status, {
    required WebBridgeOpContext context,
  }) {
    return switch (status) {
      museErrDeviceInit => const MuseError(
        MuseErrorCode.audioDeviceInitFailed,
        'Web AudioWorklet or Wasm engine initialization failed.',
      ),
      museErrPermissionDenied => const MuseError(
        MuseErrorCode.microphonePermissionDenied,
        'Microphone capture permission denied.',
      ),
      museErrSfLoadFailed => const MuseError(
        MuseErrorCode.soundFontLoadFailed,
        'Failed to load or unload SoundFont bytes in Wasm FluidSynth.',
      ),
      museErrSfTooLarge => const MuseError(
        MuseErrorCode.soundFontTooLargeForWeb,
        'SoundFont asset exceeded the 64 MiB Web AudioWorklet limit.',
      ),
      museErrTransportNotStopped =>
        context == WebBridgeOpContext.soundFontWeb
            ? const MuseError(
                MuseErrorCode.webSoundFontLoadWhilePlaying,
                'SoundFont loading in Web AudioWorklet requires stopped transport.',
              )
            : const MuseError(
                MuseErrorCode.audioDeviceInitFailed,
                'Operation rejected while capture or playback is active.',
              ),
      museErrQueueFull => switch (context) {
        WebBridgeOpContext.synthEvent => const MuseError(
          MuseErrorCode.eventQueueOverflow,
          'Wasm EventQueue or AuditionQueue is full.',
        ),
        WebBridgeOpContext.takePlayback => const MuseError(
          MuseErrorCode.takePlaybackBufferUnderrun,
          'TakePlaybackRingBuffer is full or unavailable.',
        ),
        _ => const MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Wasm MutationQueue is full.',
        ),
      },
      museErrCaptureOverflow => const MuseError(
        MuseErrorCode.captureBufferOverflow,
        'Web CaptureRingBuffer overflowed before OPFS worker drained frames.',
      ),
      museErrStorageIo => const MuseError(
        MuseErrorCode.casPromotionFailed,
        'OPFS audio worker staging or finalization I/O failed.',
      ),
      museErrBufferTooSmall => const MuseError(
        MuseErrorCode.soundFontPresetBufferTooSmall,
        'SoundFont preset count exceeded fixed buffer capacity.',
      ),
      museErrTakeLoadFailed => const MuseError(
        MuseErrorCode.takeLoadFailed,
        'Failed to decode or register active take region.',
      ),
      _ => MuseError(
        MuseErrorCode.audioDeviceInitFailed,
        'Unexpected Wasm audio status code: $status.',
      ),
    };
  }

  /// Translates Web DOM / OPFS / MediaDevices exception names into [MuseError].
  static MuseError mapDomException(
    String? domExceptionName, {
    required WebBridgeOpContext context,
    String? detail,
  }) {
    final suffix = (detail == null || detail.isEmpty) ? '' : ' ($detail)';
    return switch (domExceptionName) {
      'NotAllowedError' =>
        context == WebBridgeOpContext.capturePermission
            ? MuseError(
                MuseErrorCode.microphonePermissionDenied,
                'Browser denied microphone capture permission$suffix.',
              )
            : MuseError(
                MuseErrorCode.webAudioUserGestureRequired,
                'Web AudioContext requires an explicit user gesture$suffix.',
              ),
      'SecurityError' => MuseError(
        MuseErrorCode.webAudioUserGestureRequired,
        'Web Audio / OPFS requires a secure HTTPS or localhost origin$suffix.',
      ),
      'QuotaExceededError' => MuseError(
        MuseErrorCode.insufficientStorageQuota,
        'Browser OPFS storage quota exceeded$suffix.',
      ),
      _ => MuseError(
        context == WebBridgeOpContext.captureStorage
            ? MuseErrorCode.casPromotionFailed
            : MuseErrorCode.audioDeviceInitFailed,
        'Browser Web API error (${domExceptionName ?? 'Unknown'})$suffix.',
      ),
    };
  }
}

/// Fail-closed parameter and lifecycle validators shared between VM tests and
/// `WebAudioWorkletBridge`.
abstract final class WebBridgeValidator {
  static Err<T>? checkInitialized<T>({
    required bool isInitialized,
    required MuseErrorCode errorCode,
  }) {
    if (!isInitialized) {
      return Err<T>(
        MuseError(errorCode, 'Web audio engine is not initialized.'),
      );
    }
    return null;
  }

  static Err<T>? checkMidiChannel<T>(int midiChannel) {
    if (midiChannel < MuseConstants.minMidiChannel ||
        midiChannel > MuseConstants.maxMidiChannel) {
      return Err<T>(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'MIDI channel $midiChannel out of range [0, 15].',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkPitch<T>(int pitchMidi) {
    if (pitchMidi < MuseConstants.minMidiPitch ||
        pitchMidi > MuseConstants.maxMidiPitch) {
      return Err<T>(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'MIDI pitch $pitchMidi out of range [0, 127].',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkSevenBitVelocityOrCc<T>(int value, String label) {
    if (value < MuseConstants.minMidiPitch ||
        value > MuseConstants.maxMidiPitch) {
      return Err<T>(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          '$label value $value out of range [0, 127].',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkBankAndProgram<T>(int bankNum, int programNum) {
    if (bankNum < MuseConstants.minBankNum ||
        bankNum > MuseConstants.maxBankNum ||
        programNum < MuseConstants.minProgramNum ||
        programNum > MuseConstants.maxProgramNum) {
      return Err<T>(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'Invalid MIDI bank ($bankNum) or program ($programNum).',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkPitchBend<T>(int pitchBend) {
    if (pitchBend < RiffWavCodec.minPitchBendSigned ||
        pitchBend > RiffWavCodec.maxPitchBendSigned) {
      return Err<T>(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'Pitch bend $pitchBend out of signed 14-bit range [-8192, 8191].',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkMidiEventType<T>(int eventType) {
    if (eventType < MuseConstants.midiEventNoteOn ||
        eventType > MuseConstants.midiEventPitchBend) {
      return Err<T>(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'MIDI event type $eventType is out of supported range.',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkEventEpoch<T>(int epoch) {
    if (epoch < 0) {
      return Err<T>(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'MIDI event epoch $epoch must be non-negative.',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkScheduledSampleFrame<T>(int targetSampleFrame) {
    if (targetSampleFrame != MuseConstants.immediateDispatchFrame &&
        targetSampleFrame < 0) {
      return Err<T>(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'MIDI target sample frame $targetSampleFrame must be non-negative or immediateDispatchFrame.',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkLoopRegion<T>({
    required bool enabled,
    required int startFrame,
    required int endFrame,
  }) {
    if (startFrame < 0 || (enabled && endFrame <= startFrame)) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid sample loop region bounds.',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkWebSoundFontSize<T>(int byteLength) {
    if (byteLength <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'SoundFont payload is empty.',
        ),
      );
    }
    if (byteLength > MuseConstants.maxWebSoundFontBytes) {
      return Err<T>(
        MuseError(
          MuseErrorCode.soundFontTooLargeForWeb,
          'SoundFont size $byteLength bytes exceeds 64 MiB Web cap.',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkNotPlayingForWebSf2Load<T>({required bool isPlaying}) {
    if (isPlaying) {
      return const Err(
        MuseError(
          MuseErrorCode.webSoundFontLoadWhilePlaying,
          'Web SoundFont loading is forbidden while transport is playing.',
        ),
      );
    }
    return null;
  }

  static Err<T>? checkTakeRegionCount<T>(int count) {
    if (count > MuseConstants.maxActiveTakeRegions) {
      return Err<T>(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'Active take count $count exceeds max ${MuseConstants.maxActiveTakeRegions}.',
        ),
      );
    }
    return null;
  }
}

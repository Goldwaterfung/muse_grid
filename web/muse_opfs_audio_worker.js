'use strict';

// Centralized RIFF/WAVE and TPDF PCM16 quantization constants.
const kWavHeaderBytes = 44;
const kRiffFixedOverheadBytes = 36;
const kFmtChunkSize = 16;
const kPcmAudioFormatTag = 1;
const kPcm16BitsPerSample = 16;
const kBytesPerPcm16Sample = 2;
const kBitsPerByte = 8;
const kPcm16Scale = 32767.0;
const kPcm16Min = -32768;
const kPcm16Max = 32767;
const kChunkSizeOffset = 4;
const kSubchunk2SizeOffset = 40;

let _syncHandle = null;
let _parentDirHandle = null;
let _partFileName = '';
let _stagingPath = '';
let _sampleRate = 0;
let _channelCount = 0;
let _byteCursor = 0;
let _totalWrittenFrames = 0;
let _firstSampleClock = null;
let _workerError = null;

function buildWavHeaderBytes(sampleRate, channelCount, dataBytes) {
  const buffer = new ArrayBuffer(kWavHeaderBytes);
  const dv = new DataView(buffer);
  const bytes = new Uint8Array(buffer);

  // "RIFF"
  bytes[0] = 0x52;
  bytes[1] = 0x49;
  bytes[2] = 0x46;
  bytes[3] = 0x46;
  dv.setUint32(kChunkSizeOffset, kRiffFixedOverheadBytes + dataBytes, true);
  // "WAVE"
  bytes[8] = 0x57;
  bytes[9] = 0x41;
  bytes[10] = 0x56;
  bytes[11] = 0x45;
  // "fmt "
  bytes[12] = 0x66;
  bytes[13] = 0x6d;
  bytes[14] = 0x74;
  bytes[15] = 0x20;
  dv.setUint32(16, kFmtChunkSize, true);
  dv.setUint16(20, kPcmAudioFormatTag, true);
  dv.setUint16(22, channelCount, true);
  dv.setUint32(24, sampleRate, true);
  const blockAlign = channelCount * kBytesPerPcm16Sample;
  const byteRate = sampleRate * blockAlign;
  dv.setUint32(28, byteRate, true);
  dv.setUint16(32, blockAlign, true);
  dv.setUint16(34, kPcm16BitsPerSample, true);
  // "data"
  bytes[36] = 0x64;
  bytes[37] = 0x61;
  bytes[38] = 0x74;
  bytes[39] = 0x61;
  dv.setUint32(kSubchunk2SizeOffset, dataBytes, true);

  return bytes;
}

function normalizePathSegments(stagingPath) {
  const raw = String(stagingPath || '').replace(/\\/g, '/');
  const parts = raw.split('/').filter((seg) => seg.length > 0 && seg !== '.');
  if (parts.length === 0 || parts.some((seg) => seg === '..')) {
    throw new Error('Invalid OPFS staging path: ' + String(stagingPath));
  }
  return parts;
}

function resetStagingState() {
  _syncHandle = null;
  _parentDirHandle = null;
  _partFileName = '';
  _stagingPath = '';
  _sampleRate = 0;
  _channelCount = 0;
  _byteCursor = 0;
  _totalWrittenFrames = 0;
  _firstSampleClock = null;
  _workerError = null;
}

async function closeActiveHandleQuietly() {
  if (_syncHandle !== null) {
    try {
      _syncHandle.close();
    } catch (_) {
      // Ignore secondary cleanup failure during teardown/abort.
    }
  }
  resetStagingState();
}

async function handlePrepareStagingFile(msg) {
  const { requestId, stagingPath, sampleRate, channelCount } = msg;
  try {
    if (
      typeof sampleRate !== 'number' ||
      sampleRate <= 0 ||
      typeof channelCount !== 'number' ||
      channelCount <= 0
    ) {
      throw new Error('Invalid WAV format parameters for OPFS staging.');
    }

    await closeActiveHandleQuietly();

    const segments = normalizePathSegments(stagingPath);
    let dir = await navigator.storage.getDirectory();
    for (let i = 0; i < segments.length - 1; i++) {
      dir = await dir.getDirectoryHandle(segments[i], { create: true });
    }
    const fileName = segments[segments.length - 1];
    const fileHandle = await dir.getFileHandle(fileName, { create: true });
    const syncHandle = await fileHandle.createSyncAccessHandle();
    syncHandle.truncate(0);

    const placeholderHeader = buildWavHeaderBytes(
      Math.round(sampleRate),
      Math.round(channelCount),
      0
    );
    const written = syncHandle.write(placeholderHeader, { at: 0 });
    if (written !== kWavHeaderBytes) {
      syncHandle.close();
      throw new Error('Failed to write full 44-byte RIFF WAV header.');
    }

    _syncHandle = syncHandle;
    _parentDirHandle = dir;
    _partFileName = fileName;
    _stagingPath = String(stagingPath);
    _sampleRate = Math.round(sampleRate);
    _channelCount = Math.round(channelCount);
    _byteCursor = kWavHeaderBytes;
    _totalWrittenFrames = 0;
    _firstSampleClock = null;
    _workerError = null;

    self.postMessage({ requestId, ok: true });
  } catch (err) {
    await closeActiveHandleQuietly();
    self.postMessage({
      requestId,
      ok: false,
      errorName: err && err.name ? String(err.name) : 'Error',
      message: err && err.message ? err.message : String(err),
    });
  }
}

function handleAppendCapturePcm(msg) {
  if (_syncHandle === null || _workerError !== null) {
    return;
  }
  const { samplesBuffer, firstSampleClock } = msg;
  if (!(samplesBuffer instanceof ArrayBuffer) || samplesBuffer.byteLength === 0) {
    return;
  }

  try {
    const f32 = new Float32Array(samplesBuffer);
    if (f32.length === 0) {
      return;
    }
    if (_firstSampleClock === null) {
      _firstSampleClock = Number(firstSampleClock) || 0;
    }

    const outBytes = new Uint8Array(f32.length * kBytesPerPcm16Sample);
    const outDv = new DataView(outBytes.buffer);
    for (let i = 0; i < f32.length; i++) {
      const sample = Number.isFinite(f32[i]) ? f32[i] : 0.0;
      const clampedNorm =
        sample < -1.0 ? -1.0 : sample > 1.0 ? 1.0 : sample;
      // Audio RT-Safety Rule 11: TPDF triangular dither in [-1, +1] LSB before PCM16 truncation.
      const dither = Math.random() - Math.random();
      const rounded = Math.round(clampedNorm * kPcm16Scale + dither);
      const pcm16 =
        rounded < kPcm16Min
          ? kPcm16Min
          : rounded > kPcm16Max
            ? kPcm16Max
            : rounded;
      outDv.setInt16(i * kBytesPerPcm16Sample, pcm16, true);
    }

    const written = _syncHandle.write(outBytes, { at: _byteCursor });
    if (written !== outBytes.byteLength) {
      throw new Error('Partial OPFS write during capture append.');
    }
    _byteCursor += written;
    _totalWrittenFrames += Math.trunc(f32.length / _channelCount);
  } catch (err) {
    _workerError = {
      errorName: err && err.name ? String(err.name) : 'Error',
      message: err && err.message ? err.message : String(err),
    };
  }
}

async function handleFinalizeStagingFile(msg) {
  const { requestId, cancelledOrOverflowed } = msg;
  if (_syncHandle === null) {
    self.postMessage({
      requestId,
      ok: false,
      errorName: 'InvalidStateError',
      message: 'No active OPFS capture staging handle.',
    });
    return;
  }

  const dirHandle = _parentDirHandle;
  const partFileName = _partFileName;
  const stagingPath = _stagingPath;
  const sampleRate = _sampleRate;
  const channelCount = _channelCount;
  const totalWrittenFrames = _totalWrittenFrames;
  const capturedSampleClock = _firstSampleClock !== null ? _firstSampleClock : 0;
  const dataBytes = Math.max(0, _byteCursor - kWavHeaderBytes);
  const existingError = _workerError;

  try {
    if (cancelledOrOverflowed || existingError !== null) {
      _syncHandle.close();
      if (dirHandle !== null && partFileName.length > 0) {
        try {
          await dirHandle.removeEntry(partFileName);
        } catch (_) {
          // Ignore cleanup error if file was already removed.
        }
      }
      resetStagingState();
      self.postMessage({
        requestId,
        ok: false,
        errorName: existingError ? existingError.errorName : 'AbortError',
        message: existingError
          ? existingError.message
          : 'Capture cancelled or CaptureRingBuffer overflowed.',
      });
      return;
    }

    const finalHeader = buildWavHeaderBytes(sampleRate, channelCount, dataBytes);
    const written = _syncHandle.write(finalHeader, { at: 0 });
    if (written !== kWavHeaderBytes) {
      throw new Error('Failed to patch final RIFF/data sizes.');
    }
    _syncHandle.flush();
    _syncHandle.close();
    resetStagingState();

    self.postMessage({
      requestId,
      ok: true,
      stagingPath,
      sampleRate,
      channelCount,
      durationFrames: totalWrittenFrames,
      capturedSampleClock,
      dataBytes,
    });
  } catch (err) {
    await closeActiveHandleQuietly();
    self.postMessage({
      requestId,
      ok: false,
      errorName: err && err.name ? String(err.name) : 'Error',
      message: err && err.message ? err.message : String(err),
    });
  }
}

self.onmessage = async (event) => {
  const msg = event.data;
  if (!msg || typeof msg !== 'object') {
    return;
  }
  switch (msg.type) {
    case 'prepareStagingFile':
      await handlePrepareStagingFile(msg);
      break;
    case 'appendCapturePcm':
      handleAppendCapturePcm(msg);
      break;
    case 'finalizeStagingFile':
      await handleFinalizeStagingFile(msg);
      break;
    default:
      if (msg.requestId !== undefined) {
        self.postMessage({
          requestId: msg.requestId,
          ok: false,
          errorName: 'InvalidStateError',
          message: 'Unknown OPFS audio worker command: ' + String(msg.type),
        });
      }
      break;
  }
};

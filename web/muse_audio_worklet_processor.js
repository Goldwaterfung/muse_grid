'use strict';

import createMuseAudioEngineModule from './muse_audio_engine.js';

// Centralized constants mirrored from engine_constants.h / rt_pods.h / hal_contract.h.
const kMonoChannels = 1;
const kStereoChannels = 2;
const kWebRenderQuantumFrames = 128;
const kMaxRenderBlockFrames = 4096;
const kWebCaptureBatchQuanta = 32;
const kTelemetryBatchQuanta = 6; // ~60 Hz at 48 kHz (48000 / 128 / 6 = 62.5 Hz)
const kMaxSoundFontBytes = 64 * 1024 * 1024;
const kMaxSoundFontPresets = 2048;
const kTakePrefetchFrames = 16384;
const kTelemetryDrainCapacity = 64;
const kMaxCaptureDrainIterations = 32;
const kOutPairByteSize = 8; // int32_t + uint32_t output result pair
const kInt64ByteSize = 8;
const kFloat32Size = 4;
const kStereoFoldDivisor = 2.0;

// C API MutationType enum (rt_pods.h)
const kMutSetPlaying = 1;
const kMutSetCaptureState = 9;

// C API MuseStatus codes (hal_contract.h)
const kMuseOk = 0;
const kMuseErrDeviceInit = -1;
const kMuseErrSfLoadFailed = -3;
const kMuseErrSfTooLarge = -4;
const kMuseErrTransportNotStopped = -5;
const kMuseErrBufferTooSmall = -9;

class MuseAudioWorkletProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();

    const procOpts = (options && options.processorOptions) || {};
    this._ready = false;
    this._disposed = false;
    this._isPlaying = false;
    this._capturing = false;
    this._wasm = null;
    this._engine = 0;

    // Invariant byte offsets inside Wasm linear memory (re-viewed dynamically).
    this._inPtr = 0;
    this._outPtr = 0;
    this._captureDrainPtr = 0;
    this._captureClockPtr = 0;
    this._takePcmPtr = 0;
    this._outU32PairPtr = 0;

    this._captureBatchQuanta =
      typeof procOpts.captureBatchQuanta === 'number' &&
      procOpts.captureBatchQuanta > 0
        ? Math.min(procOpts.captureBatchQuanta, kWebCaptureBatchQuanta)
        : kWebCaptureBatchQuanta;
    this._captureBatchFrames =
      this._captureBatchQuanta * kWebRenderQuantumFrames;
    this._captureAccumBuffer = new Float32Array(this._captureBatchFrames);
    this._captureAccumFrames = 0;
    this._captureChunkFirstClock = 0;
    this._pendingStopCaptureFlush = null;
    this._telemetryQuantumCounter = 0;

    this.port.onmessage = (event) => {
      this._handleMessage(event.data);
    };

    this._initWasm(procOpts);
  }

  _heapF32() {
    return this._wasm.HEAPF32;
  }

  _heapU8() {
    return this._wasm.HEAPU8;
  }

  _allocUtf8String(text) {
    const str = String(text);
    const maxBytes = this._wasm.lengthBytesUTF8(str) + 1;
    const ptr = this._wasm._muse_wasm_alloc_bytes(maxBytes);
    if (ptr === 0) {
      return 0;
    }
    this._wasm.stringToUTF8(str, ptr, maxBytes);
    return ptr;
  }

  async _initWasm(procOpts) {
    try {
      if (typeof createMuseAudioEngineModule !== 'function') {
        throw new Error(
          'createMuseAudioEngineModule is not defined in AudioWorkletGlobalScope.'
        );
      }
      const wasmBinary = procOpts.wasmBinary;
      if (!wasmBinary || wasmBinary.byteLength === 0) {
        throw new Error('Missing muse_audio_engine.wasm binary buffer.');
      }

      let rejectWasmInit = null;
      const wasmInitAbortPromise = new Promise((_, reject) => {
        rejectWasmInit = reject;
      });
      const wasmModule = await Promise.race([
        createMuseAudioEngineModule({
          onAbort(what) {
            rejectWasmInit(
              what instanceof Error
                ? what
                : new Error(String(what ?? 'Emscripten Wasm initialization aborted')),
            );
          },
          instantiateWasm(imports, successCallback) {
            WebAssembly.instantiate(wasmBinary, imports)
              .then((result) => successCallback(result.instance))
              .catch((err) => {
                rejectWasmInit(
                  err instanceof Error ? err : new Error(String(err)),
                );
              });
            return {};
          },
        }),
        wasmInitAbortPromise,
      ]);

      const requestedSampleRate =
        typeof procOpts.sampleRate === 'number' && procOpts.sampleRate > 0
          ? Math.round(procOpts.sampleRate)
          : Math.round(sampleRate);
      const outputBufferFrames =
        typeof procOpts.outputBufferFrames === 'number' &&
        procOpts.outputBufferFrames > 0
          ? Math.round(procOpts.outputBufferFrames)
          : kWebRenderQuantumFrames;
      const deviceFingerprint =
        typeof procOpts.deviceFingerprint === 'string' &&
        procOpts.deviceFingerprint.length > 0
          ? procOpts.deviceFingerprint
          : 'web-audioworklet-wasm';

      this._wasm = wasmModule;
      const fpPtr = this._allocUtf8String(deviceFingerprint);
      let engineHandle = 0;
      try {
        engineHandle = wasmModule._muse_wasm_create(
          requestedSampleRate,
          kMonoChannels,
          kStereoChannels,
          outputBufferFrames,
          outputBufferFrames,
          fpPtr
        );
      } finally {
        if (fpPtr !== 0) {
          wasmModule._muse_wasm_free_bytes(fpPtr);
        }
      }

      if (engineHandle === 0) {
        throw new Error('muse_wasm_create failed to initialize engine.');
      }

      this._engine = engineHandle;
      this._inPtr = wasmModule._muse_wasm_input_scratch_ptr();
      this._outPtr = wasmModule._muse_wasm_output_scratch_ptr();
      this._captureDrainPtr = wasmModule._muse_wasm_capture_drain_scratch_ptr();
      this._captureClockPtr = wasmModule._muse_wasm_capture_clock_ptr();
      this._takePcmPtr = wasmModule._muse_wasm_take_pcm_scratch_ptr();
      this._outU32PairPtr = wasmModule._muse_wasm_alloc_bytes(kOutPairByteSize);
      if (this._outU32PairPtr === 0) {
        throw new Error('Failed to allocate Wasm control result pair.');
      }

      this._ready = true;
      this.port.postMessage({
        type: 'ready',
        hardwareInfo: {
          sampleRate: requestedSampleRate,
          inputChannels: kMonoChannels,
          outputChannels: kStereoChannels,
          inputBufferFrames: outputBufferFrames,
          outputBufferFrames: outputBufferFrames,
          deviceFingerprint: deviceFingerprint,
        },
      });
    } catch (err) {
      this._ready = false;
      this.port.postMessage({
        type: 'initError',
        message: err && err.message ? err.message : String(err),
      });
    }
  }

  _postResponse(requestId, payload) {
    if (requestId === undefined || requestId === null) {
      return;
    }
    this.port.postMessage(
      Object.assign({ type: 'response', requestId }, payload)
    );
  }

  _postAsyncBridgeError(operation, status, error, extra = null) {
    if (this._disposed) {
      return;
    }
    this.port.postMessage(
      Object.assign(
        {
          type: 'bridgeError',
          operation,
          status,
          error,
        },
        extra || {}
      )
    );
  }

  _postWorkletFailure(requestId, operation, status, error, extra = null) {
    if (requestId !== undefined && requestId !== null) {
      this._postResponse(
        requestId,
        Object.assign({ status, error }, extra || {})
      );
      return;
    }
    if (status !== kMuseOk) {
      this._postAsyncBridgeError(operation, status, error, extra);
    }
  }

  _handleMessage(msg) {
    if (!msg || typeof msg !== 'object') {
      return;
    }
    const requestId = msg.requestId;

    if (msg.type === 'dispose') {
      this._disposed = true;
      this._ready = false;
      this._capturing = false;
      this._isPlaying = false;
      if (this._pendingStopCaptureFlush !== null) {
        this._postResponse(this._pendingStopCaptureFlush.requestId, {
          status: kMuseErrDeviceInit,
          error: 'AudioWorklet disposed before capture flush finished.',
        });
        this._pendingStopCaptureFlush = null;
      }
      if (this._wasm !== null) {
        if (this._outU32PairPtr !== 0) {
          this._wasm._muse_wasm_free_bytes(this._outU32PairPtr);
          this._outU32PairPtr = 0;
        }
        if (this._engine !== 0) {
          this._wasm._muse_wasm_destroy(this._engine);
          this._engine = 0;
        }
      }
      this._postResponse(requestId, { status: kMuseOk });
      return;
    }

    if (!this._ready || this._disposed || this._engine === 0) {
      this._postWorkletFailure(
        requestId,
        String(msg.type || 'unknown'),
        kMuseErrDeviceInit,
        'AudioWorklet engine is not ready.'
      );
      return;
    }

    switch (msg.type) {
      case 'loadSf2Bytes':
        this._handleLoadSf2Bytes(msg, requestId);
        break;
      case 'unloadSf2': {
        const status = this._wasm._muse_wasm_unload_sf2(
          this._engine,
          msg.sfHandle | 0
        );
        this._postResponse(requestId, { status });
        break;
      }
      case 'pushMutation': {
        const mutType = msg.mutationType | 0;
        const flagA = msg.flagA | 0;
        const status = this._wasm._muse_wasm_push_mutation(
          this._engine,
          mutType,
          msg.channel | 0,
          flagA,
          msg.intParamA | 0,
          msg.intParamB | 0,
          msg.intParamC | 0,
          Number(msg.floatParamA) || 0,
          Number(msg.floatParamB) || 0,
          BigInt(Math.trunc(Number(msg.targetEpoch) || 0)),
          BigInt(Math.trunc(Number(msg.sampleFrameA) || 0)),
          BigInt(Math.trunc(Number(msg.sampleFrameB) || 0))
        );
        if (status === kMuseOk && mutType === kMutSetPlaying) {
          this._isPlaying = flagA !== 0;
        }
        if (requestId !== undefined && requestId !== null) {
          this._postResponse(requestId, { status });
        } else if (status !== kMuseOk) {
          this._postAsyncBridgeError(
            'pushMutation',
            status,
            'AudioWorklet pushMutation failed with status ' + status + '.',
            { mutationType: mutType }
          );
        }
        break;
      }
      case 'pushEvents': {
        const events = Array.isArray(msg.events) ? msg.events : [];
        let pushedCount = 0;
        let lastStatus = kMuseOk;
        for (let i = 0; i < events.length; i++) {
          const e = events[i];
          const st = this._wasm._muse_wasm_push_single_event(
            this._engine,
            BigInt(Math.trunc(Number(e.epoch) || 0)),
            BigInt(Math.trunc(Number(e.targetSampleFrame) || 0)),
            e.type | 0,
            e.channel | 0,
            e.keyOrCc | 0,
            e.velocityOrVal | 0,
            e.pitchBend | 0,
            e.loopPass | 0
          );
          if (st !== kMuseOk) {
            lastStatus = st;
            break;
          }
          pushedCount++;
        }
        if (requestId !== undefined && requestId !== null) {
          this._postResponse(requestId, {
            status: lastStatus,
            pushedCount,
          });
        } else if (lastStatus !== kMuseOk) {
          this._postAsyncBridgeError(
            'pushEvents',
            lastStatus,
            'AudioWorklet pushEvents failed with status ' + lastStatus + '.',
            { pushedCount, requestedCount: events.length }
          );
        }
        break;
      }
      case 'registerActiveTake':
        this._handleRegisterActiveTake(msg, requestId);
        break;
      case 'pushTakePcm':
        this._handlePushTakePcm(msg, requestId);
        break;
      case 'clearActiveTakes': {
        const status = this._wasm._muse_wasm_clear_active_takes(this._engine);
        this._postResponse(requestId, { status });
        break;
      }
      case 'prepareCapture':
        this._handlePrepareCapture(msg, requestId);
        break;
      case 'startCapture': {
        const status = this._wasm._muse_wasm_start_capture(this._engine);
        if (status === kMuseOk) {
          this._capturing = true;
        }
        this._postResponse(requestId, { status });
        break;
      }
      case 'stopCaptureAndFlush': {
        this._capturing = false;
        this._wasm._muse_wasm_push_mutation(
          this._engine,
          kMutSetCaptureState,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0n,
          0n,
          0n
        );
        this._pendingStopCaptureFlush = { requestId };
        break;
      }
      default:
        this._postResponse(requestId, {
          status: kMuseErrDeviceInit,
          error: 'Unknown Worklet message type: ' + String(msg.type),
        });
        break;
    }
  }

  _handleLoadSf2Bytes(msg, requestId) {
    if (this._isPlaying) {
      this._postResponse(requestId, {
        status: kMuseErrTransportNotStopped,
        sfHandle: -1,
        presets: [],
      });
      return;
    }

    const buffer = msg.bytes;
    if (!(buffer instanceof ArrayBuffer) || buffer.byteLength === 0) {
      this._postResponse(requestId, {
        status: kMuseErrSfLoadFailed,
        sfHandle: -1,
        presets: [],
      });
      return;
    }
    if (buffer.byteLength > kMaxSoundFontBytes) {
      this._postResponse(requestId, {
        status: kMuseErrSfTooLarge,
        sfHandle: -1,
        presets: [],
      });
      return;
    }

    const byteLength = buffer.byteLength;
    const sfBytesPtr = this._wasm._muse_wasm_alloc_bytes(byteLength);
    if (sfBytesPtr === 0) {
      this._postResponse(requestId, {
        status: kMuseErrSfTooLarge,
        sfHandle: -1,
        presets: [],
      });
      return;
    }

    try {
      this._heapU8().set(new Uint8Array(buffer), sfBytesPtr);
      const outHandlePtr = this._outU32PairPtr;
      const outCountPtr = this._outU32PairPtr + kFloat32Size;
      const status = this._wasm._muse_wasm_load_sf2_bytes(
        this._engine,
        sfBytesPtr,
        byteLength,
        outHandlePtr,
        outCountPtr
      );

      const dv = new DataView(this._heapU8().buffer);
      const sfHandle = dv.getInt32(outHandlePtr, true);
      const presetCount = dv.getUint32(outCountPtr, true);

      const presets = [];
      if (status === kMuseOk) {
        const clampedCount = Math.min(presetCount, kMaxSoundFontPresets);
        for (let i = 0; i < clampedCount; i++) {
          const bankNum = this._wasm._muse_wasm_preset_bank(i);
          const programNum = this._wasm._muse_wasm_preset_program(i);
          const namePtr = this._wasm._muse_wasm_preset_name(i);
          const presetName = namePtr !== 0 ? this._wasm.UTF8ToString(namePtr) : '';
          presets.push({ bankNum, programNum, presetName });
        }
      }

      this._postResponse(requestId, { status, sfHandle, presets });
    } finally {
      this._wasm._muse_wasm_free_bytes(sfBytesPtr);
    }
  }

  _handleRegisterActiveTake(msg, requestId) {
    const idPtr = this._allocUtf8String(msg.takeId || '');
    const pathPtr = this._allocUtf8String(msg.casPath || '');
    try {
      if (idPtr === 0 || pathPtr === 0) {
        this._postResponse(requestId, { status: kMuseErrDeviceInit });
        return;
      }
      const status = this._wasm._muse_wasm_register_active_take(
        this._engine,
        idPtr,
        pathPtr,
        BigInt(Math.trunc(Number(msg.startSampleFrame) || 0)),
        BigInt(Math.trunc(Number(msg.durationFrames) || 0)),
        Number(msg.gainDb) || 0,
        Number(msg.pan) || 0
      );
      this._postResponse(requestId, { status });
    } finally {
      if (idPtr !== 0) {
        this._wasm._muse_wasm_free_bytes(idPtr);
      }
      if (pathPtr !== 0) {
        this._wasm._muse_wasm_free_bytes(pathPtr);
      }
    }
  }

  _handlePushTakePcm(msg, requestId) {
    const pcmBuffer = msg.pcmBuffer;
    const frameCount = msg.frameCount >>> 0;
    if (
      !(pcmBuffer instanceof ArrayBuffer) ||
      frameCount > kTakePrefetchFrames ||
      pcmBuffer.byteLength < frameCount * kStereoChannels * kFloat32Size
    ) {
      this._postResponse(requestId, {
        status: kMuseErrBufferTooSmall,
        pushedFrames: 0,
      });
      return;
    }

    const srcView = new Float32Array(
      pcmBuffer,
      0,
      frameCount * kStereoChannels
    );
    this._heapF32().set(srcView, this._takePcmPtr >> 2);

    const status = this._wasm._muse_wasm_push_take_pcm(
      this._engine,
      BigInt(Math.trunc(Number(msg.epoch) || 0)),
      BigInt(Math.trunc(Number(msg.startSampleFrame) || 0)),
      frameCount,
      this._outU32PairPtr
    );
    const dv = new DataView(this._heapU8().buffer);
    const pushedFrames = dv.getUint32(this._outU32PairPtr, true);
    this._postResponse(requestId, { status, pushedFrames });
  }

  _handlePrepareCapture(msg, requestId) {
    const pathPtr = this._allocUtf8String(msg.stagingPath || '');
    try {
      if (pathPtr === 0) {
        this._postResponse(requestId, { status: kMuseErrDeviceInit });
        return;
      }
      this._captureAccumFrames = 0;
      this._captureChunkFirstClock = 0;
      const status = this._wasm._muse_wasm_prepare_capture(
        this._engine,
        pathPtr
      );
      this._postResponse(requestId, { status });
    } finally {
      if (pathPtr !== 0) {
        this._wasm._muse_wasm_free_bytes(pathPtr);
      }
    }
  }

  _drainCaptureBatches(flushTail) {
    for (let iter = 0; iter < kMaxCaptureDrainIterations; iter++) {
      const drainedFrames = this._wasm._muse_wasm_drain_capture(
        this._engine,
        this._captureBatchFrames
      );
      if (drainedFrames === 0) {
        break;
      }

      const clockDv = new DataView(
        this._heapU8().buffer,
        this._captureClockPtr,
        kInt64ByteSize
      );
      const batchFirstClock = Number(clockDv.getBigInt64(0, true));
      const heapF32 = this._heapF32();
      const srcBase = this._captureDrainPtr >> 2;

      let readOffset = 0;
      while (readOffset < drainedFrames) {
        if (this._captureAccumFrames === 0) {
          this._captureChunkFirstClock = batchFirstClock + readOffset;
        }
        const remainingInBatch = this._captureBatchFrames - this._captureAccumFrames;
        const available = drainedFrames - readOffset;
        const toCopy = available < remainingInBatch ? available : remainingInBatch;

        this._captureAccumBuffer.set(
          heapF32.subarray(srcBase + readOffset, srcBase + readOffset + toCopy),
          this._captureAccumFrames
        );
        this._captureAccumFrames += toCopy;
        readOffset += toCopy;

        if (this._captureAccumFrames === this._captureBatchFrames) {
          const transferCopy = this._captureAccumBuffer.slice(0);
          this.port.postMessage(
            {
              type: 'captureChunk',
              firstSampleClock: this._captureChunkFirstClock,
              samples: transferCopy.buffer,
            },
            [transferCopy.buffer]
          );
          this._captureAccumFrames = 0;
        }
      }
    }

    if (flushTail && this._captureAccumFrames > 0) {
      const tailCopy = this._captureAccumBuffer.slice(
        0,
        this._captureAccumFrames
      );
      this.port.postMessage(
        {
          type: 'captureChunk',
          firstSampleClock: this._captureChunkFirstClock,
          samples: tailCopy.buffer,
        },
        [tailCopy.buffer]
      );
      this._captureAccumFrames = 0;
    }
  }

  process(inputs, outputs) {
    if (this._disposed) {
      return false;
    }

    const output = outputs[0];
    if (!output || output.length === 0) {
      return true;
    }
    const leftOut = output[0];
    const rightOut = output.length > 1 ? output[1] : null;
    const frameCount = leftOut.length;

    if (
      !this._ready ||
      this._engine === 0 ||
      frameCount === 0 ||
      frameCount > kMaxRenderBlockFrames
    ) {
      leftOut.fill(0.0);
      if (rightOut !== null) {
        rightOut.fill(0.0);
      }
      return true;
    }

    const inHeap = this._heapF32();
    const inOffset = this._inPtr >> 2;
    const input = inputs && inputs[0];
    if (this._capturing && input && input.length > 0 && input[0].length >= frameCount) {
      if (input.length === kMonoChannels) {
        inHeap.set(input[0].subarray(0, frameCount), inOffset);
      } else {
        const inL = input[0];
        const inR = input[1];
        for (let i = 0; i < frameCount; i++) {
          inHeap[inOffset + i] = (inL[i] + inR[i]) / kStereoFoldDivisor;
        }
      }
    } else {
      inHeap.fill(0.0, inOffset, inOffset + frameCount);
    }

    this._wasm._muse_wasm_process_quantum(this._engine, frameCount);

    const outHeap = this._heapF32();
    const outOffset = this._outPtr >> 2;
    for (let i = 0; i < frameCount; i++) {
      const base = outOffset + i * kStereoChannels;
      leftOut[i] = outHeap[base];
      if (rightOut !== null) {
        rightOut[i] = outHeap[base + 1];
      }
    }

    if (this._capturing) {
      this._drainCaptureBatches(false);
    }

    if (this._pendingStopCaptureFlush !== null) {
      const pending = this._pendingStopCaptureFlush;
      this._pendingStopCaptureFlush = null;
      this._drainCaptureBatches(true);
      const capturedPlayheadFrame = this._wasm._muse_wasm_captured_playhead_frame_f64(
        this._engine
      );
      const hasOverflowed =
        this._wasm._muse_wasm_did_capture_overflow(this._engine) !== 0;
      this.port.postMessage({
        type: 'captureFlushed',
        requestId: pending.requestId,
        capturedPlayheadFrame,
        hasOverflowed,
      });
    }

    this._telemetryQuantumCounter++;
    if (this._telemetryQuantumCounter >= kTelemetryBatchQuanta) {
      this._telemetryQuantumCounter = 0;
      const count = this._wasm._muse_wasm_drain_telemetry(
        this._engine,
        kTelemetryDrainCapacity
      );
      if (count > 0) {
        const frames = new Array(count);
        for (let i = 0; i < count; i++) {
          frames[i] = {
            playheadSampleFrame: this._wasm._muse_wasm_telemetry_playhead_f64(i),
            activeEpoch: this._wasm._muse_wasm_telemetry_epoch_f64(i),
            outputPeakL: this._wasm._muse_wasm_telemetry_meter_f32(i, 0),
            outputPeakR: this._wasm._muse_wasm_telemetry_meter_f32(i, 1),
            outputRmsL: this._wasm._muse_wasm_telemetry_meter_f32(i, 2),
            outputRmsR: this._wasm._muse_wasm_telemetry_meter_f32(i, 3),
            inputPeak: this._wasm._muse_wasm_telemetry_meter_f32(i, 4),
            inputRms: this._wasm._muse_wasm_telemetry_meter_f32(i, 5),
            flags: this._wasm._muse_wasm_telemetry_flags_u32(i),
          };
        }
        this.port.postMessage({ type: 'telemetry', frames });
      }
    }

    return true;
  }
}

registerProcessor('muse-audio-worklet-processor', MuseAudioWorkletProcessor);

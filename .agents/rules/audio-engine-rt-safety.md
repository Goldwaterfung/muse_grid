---
trigger: always_on
---

# Audio Engine Real-Time Safety Rules — MuseGrid

These rules govern **Layers 1–3** (`packages/muse_audio_engine/`: `miniaudio` full-duplex HAL, `FluidSynth` SF2 rendering, and Emscripten Wasm `AudioWorklet`). Every audio callback operates under a strict **Callback Deadline**—missing a buffer deadline causes audible pops, clicks, or capture dropouts.

## 1. Real-Time Execution Discipline (WCET)

1. **Meet the Callback CPU Budget:** Never execute operations inside `processAudio()` whose execution time can spike past the hardware buffer duration. Offload SoundFont loading (except on Web without `SharedArrayBuffer`, where `fluid_synth_sfload()` runs in the stopped `AudioWorklet` while outputting silence and capped by `kMaxWebSoundFontBytes`) and raw WAV encoding (`ma_encoder`) to the non-RT Butler/worker thread.
2. **Bounded Loops Only:** Restrict audio-thread loops to deterministic, bounded iteration counts. Never traverse unbounded dynamic containers or hash tables that can degrade to $O(n)$ spikes on the audio thread.
3. **3-Phase Cycle & Fixed Signal Graph:** Execute every hardware callback strictly in 3 phases (`startCycle` → `processAudio` → `endCycle`) over the deterministic signal graph (`FluidSynth` + `Mic Input` → `Monitor/Gain` → `Master Soft Limiter` → `Output` + `CaptureRingBuffer`).

## 2. Zero Allocation, Zero OS Calls, Zero Locks

4. **No Dynamic Memory Allocation or Deallocation:** Never call `malloc`, `free`, `new`, `delete`, `std::vector::push_back`, or release the last `std::shared_ptr` on the audio thread. Pre-allocate all voice pools, ring buffers, and scratch buffers during initialization.
5. **No OS, Disk, Network, or Console I/O:** Never read/write files, query blocking OS services, allocate threads, `sleep`/`wait`/`join`, or print logs (`printf`/`std::cout`) from the audio thread. Use a lock-free queue or the Butler worker thread.
6. **No Mutexes or Priority Inversion:** Never acquire mutexes or spinlocks on the audio thread. Use lock-free SPSC ring buffers (`MutationQueue`, `EventQueue`, `CaptureRingBuffer`, `TelemetryQueue`) and atomic primitives.
7. **Zero-Initialize All Context PODs:** Always zero-initialize C/C++ POD boundary structs (e.g., `TransportPosition pos = {};`) before populating fields to avoid propagating uninitialized values into timeline or synth math.

## 3. Lock-Free Communication & Buffering

8. **Bounded Lock-Free Queues:** Queues crossed by the audio thread must be fixed-capacity and pre-allocated. When full, return `false` or drop lossy telemetry rather than allocating on the heap. Wrap `compare_exchange_weak` loops properly for ARM targets.
9. **Atomic State & Telemetry Isolation:** Never mutate multi-field state structs on the UI/Dart thread while the audio thread reads them. Use double-buffered atomic pointer swaps for configuration updates and lossy atomic state / 30–60Hz `TelemetryFrame` snapshots for meters and playhead position.

## 4. Floating-Point & Mastering Math

10. **IEEE 754 Float Pipeline & Denormal Protection:** Process internal mixing and `FluidSynth` rendering in 32-bit IEEE 754 float (`f32`). Enable hardware Flush-To-Zero (FTZ) and Denormals-Are-Zero (DAZ) flags on the native RT audio thread to prevent CPU spikes on decaying reverb/synth tails.
11. **Soft Limiting & Dithering:** Apply a soft-clipping/brickwall limiter on the master bus to prevent polyphonic clipping. When exporting or converting internal float samples to 16-bit fixed-point PCM (e.g., 16-bit WAV), apply TPDF dither before truncation.

## 5. Transport, Time & Recording Invariants

12. **Transport-Aware Sequence Evaluation:** Always gate playback event scheduling on `isPlaying`. A paused or stopped playhead must not continuously trigger seek-reset / MIDI Panic (`CC 123`) storms that choke the event queue or cut off live key auditioning.
13. **Exact Integer Tick ↔ Sample Conversion:** Convert between `960 PPQN` musical ticks and 64-bit integer `sampleFrame` positions deterministically without accumulating floating-point drift.
14. **Pre-Allocated Recording Pipeline:** Pre-allocate `CaptureRingBuffer` and prepare recording file descriptors/encoders on the non-RT Butler/worker thread *before* starting capture. In `processAudio()`, only copy `pInput` frames and `sampleClock` into `CaptureRingBuffer`.

## 6. Cross-Platform HAL & Explicit Fallbacks

15. **No Hardcoded Hardware Parameters:** Never hardcode audio sample rates (e.g., 44100/48000 Hz) or buffer sizes; query the active OS/browser audio device and configure `FluidSynth` and resamplers accordingly.
16. **iOS (`AVAudioSession`):** Own the session exclusively in L1 via `ma_ios_session_category_play_and_record` with explicit speaker/Bluetooth routing options, and ensure `NSMicrophoneUsageDescription` is present in `ios/Runner/Info.plist`.
17. **Android (`AAudio` / `RECORD_AUDIO`):** Require runtime `RECORD_AUDIO` permission before `ma_device_init`. Target AAudio low-latency duplex at the device's native sample rate, with an explicit, logged fallback to shared mode if an OEM driver rejects exclusive duplex.
18. **Web (`AudioContext` + `AudioWorklet`):** Defer `AudioContext.resume()` and `getUserMedia` until an explicit user gesture over HTTPS/`localhost`. Support an explicit fallback to single-threaded `AudioWorklet` + `MessagePort` buffering when `SharedArrayBuffer` (`COOP`/`COEP` headers) is unavailable.

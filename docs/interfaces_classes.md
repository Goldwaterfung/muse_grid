### 1. Analysis of Cross-Document Gaps & Hidden Coupling

According to [requirements.md](file:///Users/goldenfung/Documents/muse_grid/requirements.md), [ARCHITECTURE.md](file:///Users/goldenfung/Documents/muse_grid/ARCHITECTURE.md), and [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md) together reveals five boundary gaps that must be resolved in the API design so that no database column or C++/Dart function becomes dead code:

1. **Recorded Audio Playback vs. Fixed Signal Graph**
   * **Evidence:** [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md#L277-L302) defines `audio_takes` with `UNIQUE (project_id, part_id)` (0 or 1 overwrite recording per part), `start_tick`, `duration_frames`, `sample_rate`, and `channel_count`, and states in [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md#L120) that a part may hold notation, recorded audio, or both. However, [ARCHITECTURE.md](file:///Users/goldenfung/Documents/muse_grid/ARCHITECTURE.md#L111-L119) originally only depicted `[MIDI EventQueue] -> [FluidSynth]` and `[Mic pInput] -> [Optional Monitor Gain]` in the L3 signal graph, and `ISynthEventBridge` only schedules MIDI events.
   * **API Resolution (Confirmed):** L3's Butler worker (Native C++ thread / Web OPFS Worker) streams active per-part recordings (`.wav` from `cas/`, up to `kMaxActiveTakeRegions = 16`) into a pre-allocated **`TakePlaybackRingBuffer`** in L2, resampled/channel-converted to the active device rate and mixed into the L3 Master Bus during timeline playback via `ITransportBridge.syncActiveTakeRegions()`.
2. **Runtime SoundFont Handle Mapping & Part Mixer State**
   * **Evidence:** [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md#L141-L159) stores `sf_id` (`UUIDv7`), `midi_channel (0..15)`, `bank_num`, `program_num`, `gain_db`, `pan`, `is_muted`, and `is_solo` in `project_parts`. In L3, `fluid_synth_sfload()` returns an integer `sfont_id` (`int32_t`), not a `UUIDv7`.
   * **API Resolution:** `IAudioLifecycleBridge.loadSoundFontFromCas()` must return a typed integer `SoundFontHandle` mapped in L4 to `SoundFontId` (`UUIDv7`). `ISynthEventBridge` must expose `assignChannelPatch(channel, sfHandle, bank, program)` and `setChannelMix(channel, gainDb, pan)` (pushed via `MutationQueue`), while L4's lookahead compiler gates note emission on `is_muted`/`is_solo` and sends `silenceChannel(channel)` when mute/solo toggles during active playback.
3. **Capture Provenance Handoff for Latency Compensation**
   * **Evidence:** [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md#L286-L290) requires `captured_playhead_frame`, `captured_sample_clock`, `output_buffer_frames`, `input_buffer_frames`, and `calibration_offset_frames` (`NOT NULL`) on `audio_takes` to compute `start_tick` accurately even when recording starts mid-song or after pauses/seeks.
   * **API Resolution:** `IRecordingBridge.stopAndFinalizeCapture()` returns `capturedPlayheadFrame` (timeline frame latched at first captured sample), `capturedSampleClock` (hardware clock provenance), `outputBufferFrames`, and `inputBufferFrames` inside `RecordingCaptureReceipt` so L4 deterministically computes `alignedSampleFrame = max(0, capturedPlayheadFrame - (outputBufferFrames + inputBufferFrames + calibrationOffsetFrames))` and populates all `NOT NULL` provenance columns in `audio_takes`. Capture is start/stop-only (no mid-recording pause) with loop-wrap suppressed while capturing.
4. **SoundFont Preset Extraction (`soundfont_presets`)**
   * **Evidence:** [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md#L317-L323) defines `soundfont_presets (sf_id, bank_num, program_num, preset_name)`, which L5 needs to populate instrument patch dropdowns.
   * **API Resolution:** A Pure Dart `ISoundFontPresetParser` reads SF2 `pdta`/`phdr` preset headers on import (safe on Web even while transport is playing, without touching `AudioWorklet`) so `IAssetLibraryRepository.importSoundFontBytes()` populates `soundfont_presets` atomically alongside `soundfonts`; `IAudioLifecycleBridge.loadSoundFontFromCas()` also returns runtime `List<SoundFontPresetInfo>` from `FluidSynth`.
5. **Device Latency Calibration Persistence (`latency_calibration_profiles`)**
   * **Evidence:** [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md#L325-L335) defines `latency_calibration_profiles` keyed by `(platform, device_fingerprint, sample_rate, buffer_size_frames)`, whereas [ARCHITECTURE.md](file:///Users/goldenfung/Documents/muse_grid/ARCHITECTURE.md#L176) only names `IProjectRepository` and `IAssetLibraryRepository`.
   * **API Resolution:** `IAudioLifecycleBridge.initialize()` / `currentHardwareInfo` exposes `deviceFingerprint`, `sampleRate`, `inputBufferFrames`, and `outputBufferFrames`, paired with `IAssetLibraryRepository` calibration methods to read/write `latency_calibration_profiles`. Because L4 (not L2/L3) applies `calibration_offset_frames` when computing `audio_takes.start_tick`, L2/L3 stores no calibration state (avoiding dead code), while `IProjectRepository.realignAudioTakesCalibration()` allows re-aligning existing takes if calibration changes later.

---

### 2. Cross-Layer Foundation: Error Semantics, Branded Types & Constants

Following **Contract-First Design**, **Consistent Error Semantics**, and the **Fail-Closed** rule (`coding-style.md`), all Dart layers share one zero-cost result union, branded ID/unit extension types, and centralized constants in `lib/bridge/contracts/`, mirrored in C++ by `packages/muse_audio_engine/engine_core/engine_constants.h`.

```dart
// lib/bridge/contracts/result.dart (Pure Dart — imported by Bridge, Storage, L4, L5)

enum MuseErrorCode {
  // Audio HAL & Engine (L1–L3)
  audioDeviceInitFailed,
  microphonePermissionDenied,
  webAudioUserGestureRequired,
  soundFontLoadFailed,
  soundFontTooLargeForWeb,      // Exceeds kMaxWebSoundFontBytes
  soundFontPresetBufferTooSmall,// Returned preset count exceeds max_presets
  webSoundFontLoadWhilePlaying, // Non-SAB Web requires stopped transport
  captureBufferOverflow,        // CaptureRingBuffer / Web batch overflow
  takeLoadFailed,               // Failed to open/decode/resample cas/*.wav take
  takePlaybackBufferUnderrun,   // TakePlaybackRingBuffer starved during active playback
  eventQueueOverflow,
  eventQueueUnderrun,
  missingSoundFontForPart,      // Part has timeline_notes but sf_id == null

  // Storage, SQLite & CAS
  sqliteJournalModeMismatch,    // WAL on Native, DELETE/TRUNCATE on Web
  sqliteConstraintViolation,
  insufficientStorageQuota,     // Web navigator.storage.estimate() / disk check failed
  casPromotionFailed,
  casBlobMissing,
  entityNotFound,
  revisionConflict,

  // Domain & Codec (L4)
  invalidMusicXmlFormat,
  invalidSoundFontFormat,       // SF2 RIFF/sfbk/pdta/phdr parse failed
  invalidTickRange,
  invalidMidiChannelOrPitch,
  protectedInitialMapEvent,     // Cannot delete tempo_events or time_signature_events at tick 0
}

final class MuseError {
  final MuseErrorCode code;
  final String message;
  final Object? cause;
  const MuseError(this.code, this.message, {this.cause});
}

sealed class Result<T> {
  const Result();
}

final class Ok<T> extends Result<T> {
  final T value;
  const Ok(this.value);
}

final class Err<T> extends Result<T> {
  final MuseError error;
  const Err(this.error);
}
```

```dart
// lib/bridge/contracts/ids_and_units.dart (Dart 3 zero-cost extension types)

extension type const ProjectId(String value) {}
extension type const PartId(String value) {}
extension type const NoteId(String value) {}
extension type const SpannerId(String value) {}
extension type const TempoEventId(String value) {}
extension type const TimeSigEventId(String value) {}
extension type const KeySigEventId(String value) {}
extension type const ClefEventId(String value) {}
extension type const TakeId(String value) {}
extension type const SoundFontId(String value) {}
extension type const CalibrationProfileId(String value) {}
extension type const Sha256Digest(String value) {}

extension type const Tick(int value) {}            // 960 PPQN canonical tick
extension type const SampleFrame(int value) {}     // 64-bit hardware sample frame
extension type const EpochId(int value) {}         // Monotonic schedule epoch
extension type const SoundFontHandle(int value) {} // L3 runtime FluidSynth sfont_id
```

```dart
// lib/bridge/contracts/engine_constants.dart (Centralized constants — no magic numbers)

abstract final class MuseConstants {
  static const int ppqn = 960;
  static const int wholeNoteTicks = 3840;
  static const int midiChannelCount = 16;
  static const int gmPercussionChannel = 9;
  static const int immediateDispatchFrame = -1; // Live audition sentinel (never collides with tick 0)
  static const int lookaheadWindowMs = 200;
  static const int lookaheadRefillIntervalMs = 25;
  static const int telemetryPollHz = 60;
  static const int maxTelemetryDrainFrames = 128;
  static const int maxWebSoundFontBytes = 64 * 1024 * 1024; // 64 MiB cap
  static const int minRecordingFreeQuotaBytes = 50 * 1024 * 1024;
  static const int sqliteBusyTimeoutMs = 5000;
  static const int webCaptureBatchQuanta = 32; // 32 * 128 = 4096 frames
  static const double limiterCeiling = 0.99;
  static const double limiterSoftKneeThreshold = 0.90;
  static const int butlerWakeWatermarkFrames = 2048;
  static const int takePrefetchFrames = 16384;
  static const int casShardHexLength = 2;
  static const String dbDirName = 'db';
  static const String casDirName = 'cas';
  static const String stagingDirName = 'staging';
  static const String dbFileName = 'musegrid.db';
  static const String headlessAudioEnvVar = 'MUSE_HEADLESS_AUDIO';
  static const int countInMidiChannel = 9;
  static const int countInBankNum = 0;
  static const int countInProgramNum = 0;
  static const int countInAccentKey = 76;
  static const int countInBeatKey = 77;
  static const int countInAccentVelocity = 110;
  static const int countInBeatVelocity = 80;
}
```

```c
// packages/muse_audio_engine/engine_core/engine_constants.h (C11/C++17 shared counterpart)
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
inline constexpr uint32_t kMidiChannelCount = 16;
inline constexpr uint32_t kLookaheadWindowMs = 200;
inline constexpr int64_t  kImmediateDispatchFrame = -1;
inline constexpr uint32_t kMaxWebSoundFontBytes = 64u * 1024u * 1024u;
inline constexpr uint32_t kWebCaptureBatchQuanta = 32;
inline constexpr uint32_t kMaxSoundFontPresets = 2048;
inline constexpr uint32_t kMaxActiveTakeRegions = 16; // 1 overwrite recording per part
inline constexpr uint32_t kMaxCaptureChannels = 2;
inline constexpr float    kLimiterCeiling = 0.99f;
inline constexpr float    kLimiterSoftKneeThreshold = 0.90f;
inline constexpr size_t   kButlerWakeWatermarkFrames = 2048;
inline constexpr size_t   kTakePrefetchFrames = 16384;
inline constexpr size_t   kMutationQueueCapacity = 256;
inline constexpr size_t   kEventQueueCapacity = 4096;
inline constexpr size_t   kCaptureRingCapacityFrames = 65536;
inline constexpr size_t   kTakePlaybackRingCapacityFrames = 65536;
inline constexpr size_t   kTelemetryQueueCapacity = 512;
#else
#define kLimiterCeiling 0.99f
#define kLimiterSoftKneeThreshold 0.90f
#define kImmediateDispatchFrame ((int64_t)-1)
enum {
  kMidiChannelCount = 16,
  kLookaheadWindowMs = 200,
  kMaxWebSoundFontBytes = 64 * 1024 * 1024,
  kWebCaptureBatchQuanta = 32,
  kMaxSoundFontPresets = 2048,
  kMaxActiveTakeRegions = 16,
  kMaxCaptureChannels = 2,
  kButlerWakeWatermarkFrames = 2048,
  kTakePrefetchFrames = 16384,
  kMutationQueueCapacity = 256,
  kEventQueueCapacity = 4096,
  kCaptureRingCapacityFrames = 65536,
  kTakePlaybackRingCapacityFrames = 65536,
  kTelemetryQueueCapacity = 512
};
#endif
```

---

### 3. Layer-by-Layer APIs & Interfaces (Bottom-Up, Zero Dead Code)

#### Layer 1 — Platform Audio HAL (`packages/muse_audio_engine/{native,web}/`)
**Called exclusively by:** Layer 3 (`AudioEngineCore` lifecycle) and the OS/Browser audio thread.
* **Platform Lifecycle Rules:** On Web, `IPlatformAudioHal.init()` / `start()` must be called inside an explicit user gesture (`AudioContext.resume()` and `getUserMedia()`). On Android, `RECORD_AUDIO` runtime permission is checked before enabling duplex input.

```c
// packages/muse_audio_engine/engine_core/hal_contract.h (C11/C++17 ABI-compatible for ffigen)
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t MuseStatus;
enum {
  MUSE_OK = 0,
  MUSE_ERR_DEVICE_INIT = -1,
  MUSE_ERR_PERMISSION_DENIED = -2,
  MUSE_ERR_SF_LOAD_FAILED = -3,
  MUSE_ERR_SF_TOO_LARGE = -4,
  MUSE_ERR_TRANSPORT_NOT_STOPPED = -5,
  MUSE_ERR_QUEUE_FULL = -6,
  MUSE_ERR_CAPTURE_OVERFLOW = -7,
  MUSE_ERR_STORAGE_IO = -8,
  MUSE_ERR_BUFFER_TOO_SMALL = -9,
  MUSE_ERR_TAKE_LOAD_FAILED = -10
};

typedef struct MuseHardwareConfig {
  uint32_t sample_rate;
  uint32_t input_channels;
  uint32_t output_channels;
  uint32_t input_buffer_frames;
  uint32_t output_buffer_frames;
  char device_fingerprint[128]; // Zero-initialized fixed buffer
} MuseHardwareConfig;

// Callback invoked by miniaudio duplex callback (Native) or AudioWorkletProcessor.process() (Web)
typedef void (*MuseAudioProcessCallback)(
    void* user_data,
    const float* input_interleaved,
    float* output_interleaved,
    uint32_t frame_count);

typedef struct IPlatformAudioHal {
  MuseStatus (*init)(void* engine_ctx, MuseAudioProcessCallback cb, MuseHardwareConfig* out_cfg);
  MuseStatus (*start)(void* hal_handle);
  MuseStatus (*stop)(void* hal_handle);
  void       (*dispose)(void* hal_handle);
} IPlatformAudioHal;

#ifdef __cplusplus
}
#endif
```

---

#### Layer 2 — Core Real-Time Infrastructure (`packages/muse_audio_engine/engine_core/infra/`)
**Called exclusively by:** Layer 3 (`AudioEngineCore`, `ButlerWorker`) and Middle Bridge FFI/Wasm bindings.
All types are trivially copyable, zero-initialized POD structs with explicit padding and `static_assert` size checks in C++ (`std::is_trivially_copyable_v<T>`), using fixed-width C11 typedefs for `ffigen` compatibility.

```c
// packages/muse_audio_engine/engine_core/infra/rt_pods.h (C11/C++17 ABI-compatible for ffigen)
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#include <type_traits>
extern "C" {
#endif

typedef uint8_t MutationType;
enum {
  MUT_SET_PLAYING = 1,
  MUT_SEEK_SAMPLE = 2,
  MUT_SET_LOOP_REGION = 3,
  MUT_FLUSH_AND_ADVANCE_EPOCH = 4,
  MUT_ASSIGN_CHANNEL_PATCH = 5, // uses channel, int_param_a (sf_handle), int_param_b (bank_num), int_param_c (program_num)
  MUT_SET_CHANNEL_MIX = 6,      // uses channel, float_param_a (gain_db), float_param_b (pan)
  MUT_ALL_NOTES_OFF_CHANNEL = 7,
  MUT_SET_MONITOR_GAIN = 8,
  MUT_SET_CAPTURE_STATE = 9,
  MUT_SET_SYNTH_SUSPENDED = 10,     // flag_a: 1 = suspend FluidSynth rendering for SF2 load/unload, 0 = resume
  MUT_SET_SCHEDULED_WATERMARK = 11  // target_epoch + sample_frame_a: lookahead scheduled-up-to frame
};

typedef struct MutationCommand {
  MutationType type;
  uint8_t channel;          // 0..15
  uint8_t flag_a;           // bool: is_playing / loop_enabled / capture_active
  uint8_t reserved;
  int32_t int_param_a;      // sfont_handle
  int32_t int_param_b;      // bank_num (0..16383)
  int32_t int_param_c;      // program_num (0..127)
  float float_param_a;      // gain_db / monitor_gain
  float float_param_b;      // pan (-1.0f .. 1.0f)
  uint64_t target_epoch;    // used by MUT_FLUSH_AND_ADVANCE_EPOCH / MUT_SEEK_SAMPLE
  int64_t sample_frame_a;   // seek frame / loop_start_frame
  int64_t sample_frame_b;   // loop_end_frame
} MutationCommand;

typedef uint8_t SynthEventType;
enum {
  EVT_NOTE_ON = 1,
  EVT_NOTE_OFF = 2,
  EVT_CONTROL_CHANGE = 3,
  EVT_PITCH_BEND = 4
};

typedef struct SynthNoteEvent {
  uint64_t epoch;
  int64_t target_sample_frame;
  SynthEventType type;
  uint8_t channel;          // 0..15
  uint8_t key_or_cc;        // 0..127
  uint8_t velocity_or_val;  // 0..127
  int16_t pitch_bend;       // -8192..8191
  uint16_t reserved;
} SynthNoteEvent;

// Pre-mixed stereo f32 frame pushed by Butler / Web OPFS Worker into TakePlaybackRingBuffer
typedef struct TakePlaybackStereoFrame {
  uint64_t epoch;
  int64_t target_sample_frame;
  float left;
  float right;
} TakePlaybackStereoFrame;

typedef struct TelemetryFrame {
  int64_t playhead_sample_frame;
  uint64_t active_epoch;
  float output_peak_l;
  float output_peak_r;
  float output_rms_l;
  float output_rms_r;
  float input_peak;
  float input_rms;
  uint8_t is_playing;
  uint8_t is_capturing;
  uint8_t event_queue_underrun;
  uint8_t capture_buffer_overflow;
  uint8_t take_playback_underrun;
  uint8_t reserved[3];
} TelemetryFrame;

typedef struct FinalizedCaptureReceipt {
  MuseStatus status;               // int32_t
  int32_t reserved_pad0;           // Explicit 8-byte alignment padding before int64_t
  int64_t captured_sample_clock;   // Hardware sampleClock at first captured frame
  int64_t captured_playhead_frame; // Timeline playhead frame at first captured frame
  int64_t duration_frames;
  uint32_t sample_rate;
  uint16_t channel_count;
  uint16_t reserved;
  uint32_t output_buffer_frames;   // Latched at capture start
  uint32_t input_buffer_frames;    // Latched at capture start
  char staging_path[512];
  char sha256_hex[65];             // 64 lowercase hex chars + null terminator
  char reserved_pad1[7];           // Explicit trailing padding to 8-byte boundary
} FinalizedCaptureReceipt;

#ifdef __cplusplus
} // extern "C"

static_assert(std::is_trivially_copyable_v<MutationCommand>);
static_assert(sizeof(MutationCommand) == 48);
static_assert(std::is_trivially_copyable_v<SynthNoteEvent>);
static_assert(sizeof(SynthNoteEvent) == 24);
static_assert(std::is_trivially_copyable_v<TakePlaybackStereoFrame>);
static_assert(sizeof(TakePlaybackStereoFrame) == 24);
static_assert(std::is_trivially_copyable_v<TelemetryFrame>);
static_assert(sizeof(TelemetryFrame) == 48);
static_assert(std::is_trivially_copyable_v<FinalizedCaptureReceipt>);
static_assert(sizeof(FinalizedCaptureReceipt) == 632);
#endif
```

```cpp
// packages/muse_audio_engine/engine_core/infra/spsc_queue.h
template <typename T, size_t Capacity>
class SpscRingBuffer {
 public:
  bool tryPush(const T& item) noexcept;                   // Producer only
  bool tryPop(T& out_item) noexcept;                      // Consumer only
  const T* peek() const noexcept;                         // Consumer zero-copy inspect
  void consumeOne() noexcept;                             // Consumer advance after peek
  size_t writeAvailable() const noexcept;
  size_t readAvailable() const noexcept;
};

// Pre-allocated L2 queue instances owned by AudioEngineCore:
// - MutationQueue:          SpscRingBuffer<MutationCommand, kMutationQueueCapacity>
// - EventQueue:             SpscRingBuffer<SynthNoteEvent, kEventQueueCapacity>
// - CaptureRingBuffer:      SpscRingBuffer<float, kCaptureRingCapacityFrames * kMaxCaptureChannels> (+ latched clocks)
// - TakePlaybackRingBuffer: SpscRingBuffer<TakePlaybackStereoFrame, kTakePlaybackRingCapacityFrames>
// - TelemetryQueue:         SpscRingBuffer<TelemetryFrame, kTelemetryQueueCapacity>
```

---

#### Layer 3 — Core Audio & Synthesis Engine (`packages/muse_audio_engine/engine_core/`)
**Called by:**
1. L1 Audio Callback (`startCycle`, `processAudio`, `endCycle` — RT-safe).
2. Middle Bridge (`lib/bridge/native/` via `dart:ffi` & `lib/bridge/web/` via Wasm exports / `MessagePort`).

* **Take Playback Streaming Behavior (Native & Web):**
  * **Native:** Butler `std::thread` opens `cas/<aa>/<sha256>.wav`, resamples/channel-converts via `ma_data_converter` to `MuseHardwareConfig.sample_rate` stereo `f32`, applies each take's `gain_db`/`pan`, sums overlapping active takes, and pushes `TakePlaybackStereoFrame` blocks tagged with `active_epoch` into `TakePlaybackRingBuffer`.
  * **Web:** The OPFS Web Worker reads/decodes/resamples active `cas/` `.wav` takes and feeds `muse_engine_push_take_playback_pcm()` (via `MessagePort` or SAB) into `TakePlaybackRingBuffer`.
  * **RT Thread (`processAudio`):** Reads `TakePlaybackRingBuffer` frames matching `[sampleClock, sampleClock + frameCount)` and `epoch == active_epoch` (discarding stale epochs on seek/loop) and sums them with `FluidSynth` + optional monitor gain prior to the master soft limiter.

```c
// packages/muse_audio_engine/engine_core/muse_engine_c_api.h
// Exact C11/C++17 ABI exposed to dart:ffi (Native, ffigen) and Emscripten Wasm (Web)
#pragma once
#include "engine_constants.h"
#include "hal_contract.h"
#include "infra/rt_pods.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MuseEngineOpaque* MuseEngineHandle;

typedef struct MuseSoundFontPresetPod {
  int32_t bank_num;
  int32_t program_num;
  char preset_name[64];
} MuseSoundFontPresetPod;

// 1. Lifecycle & SoundFont Management (Called by IAudioLifecycleBridge)
MuseStatus muse_engine_create(MuseEngineHandle* out_handle, MuseHardwareConfig* out_cfg);
// Headless / Web AudioWorklet creation using caller-supplied sample_rate & buffer configuration.
MuseStatus muse_engine_create_with_config(
    MuseEngineHandle* out_handle,
    const MuseHardwareConfig* explicit_cfg);
void       muse_engine_destroy(MuseEngineHandle handle);

// Fails closed with MUSE_ERR_BUFFER_TOO_SMALL and writes required count to *out_preset_count if > max_presets.
// On Native, executes under the atomic synth_suspended handshake so it never races with RT rendering.
MuseStatus muse_engine_load_sf2_file(
    MuseEngineHandle handle,
    const char* posix_path,
    int32_t* out_sf_handle,
    MuseSoundFontPresetPod* out_presets,
    uint32_t max_presets,
    uint32_t* out_preset_count);
// Used on Web AudioWorklet when transport is stopped; enforces byte_length <= kMaxWebSoundFontBytes.
MuseStatus muse_engine_load_sf2_bytes(
    MuseEngineHandle handle,
    const uint8_t* bytes,
    uint32_t byte_length,
    int32_t* out_sf_handle,
    MuseSoundFontPresetPod* out_presets,
    uint32_t max_presets,
    uint32_t* out_preset_count);
MuseStatus muse_engine_unload_sf2(MuseEngineHandle handle, int32_t sf_handle);

// 2. Mutation & Event Queues (Called by ITransportBridge, ISynthEventBridge)
MuseStatus muse_engine_push_mutation(MuseEngineHandle handle, const MutationCommand* cmd);
MuseStatus muse_engine_push_events(
    MuseEngineHandle handle,
    const SynthNoteEvent* events,
    uint32_t count,
    uint32_t* out_pushed_count);

// 3. Active Audio Take Streaming Playback (Called by ITransportBridge / Butler / Web OPFS Worker)
// Native: Butler opens cas_wav_posix_path, resamples to device rate, and feeds TakePlaybackRingBuffer.
MuseStatus muse_engine_register_active_take(
    MuseEngineHandle handle,
    const char* take_id_utf8,
    const char* cas_wav_posix_path,
    int64_t start_sample_frame,
    int64_t duration_frames,
    float gain_db,
    float pan);
// Web: OPFS Worker decodes/resamples cas/*.wav and pushes stereo f32 blocks into TakePlaybackRingBuffer.
MuseStatus muse_engine_push_take_playback_pcm(
    MuseEngineHandle handle,
    uint64_t epoch,
    int64_t start_sample_frame,
    const float* interleaved_stereo_f32,
    uint32_t frame_count,
    uint32_t* out_pushed_frames);
MuseStatus muse_engine_clear_active_takes(MuseEngineHandle handle);

// 4. Recording Control via Butler Worker (Called by IRecordingBridge; start/stop-only capture)
MuseStatus muse_engine_prepare_capture(MuseEngineHandle handle, const char* staging_wav_path);
MuseStatus muse_engine_start_capture(MuseEngineHandle handle);
MuseStatus muse_engine_stop_and_finalize_capture(
    MuseEngineHandle handle,
    FinalizedCaptureReceipt* out_receipt); // Blocks caller worker/isolate (never RT or UI thread) until WAV header + SHA-256 finish

// 5. Telemetry Drain (Called by ITelemetryBridge at 30-60Hz)
uint32_t   muse_engine_drain_telemetry(
    MuseEngineHandle handle,
    TelemetryFrame* out_frames,
    uint32_t max_frames);

// 6. AudioWorklet & Offline Test Processing Entrypoints (Web Wasm / Catch2)
// Runs the 3-phase cycle (startCycle -> processAudio -> endCycle) for [frame_count] frames.
MuseStatus muse_engine_process_block(
    MuseEngineHandle handle,
    const float* input_interleaved,
    float* output_interleaved,
    uint32_t frame_count);
// Drains captured mic frames in Web non-SAB batch mode (and Catch2 tests) with first frame's sampleClock.
uint32_t   muse_engine_drain_capture_frames(
    MuseEngineHandle handle,
    float* out_interleaved_frames,
    uint32_t max_frames,
    int64_t* out_first_sample_clock);

#ifdef __cplusplus
}
#endif
```

---

#### Middle Bridge Contracts (`lib/bridge/contracts/`)
**Implemented by:** `lib/bridge/native/native_audio_bridge.dart` and `lib/bridge/web/web_audio_worklet_bridge.dart` (wired in `lib/app/`).
**Called by:** Layer 4 (`lib/domain/`) and Layer 5 (`lib/presentation/`).

```dart
// lib/bridge/contracts/audio_bridge_contracts.dart

/// Pure-Dart storage-to-bridge resolver implemented by lib/storage/{native,web}/ and
/// injected into platform audio bridges by lib/app/ so lib/bridge/ never hardcodes paths
/// or opens OPFS directly.
abstract interface class IInternalStorageLocator {
  /// Native: returns internal POSIX path ApplicationSupportDirectory/cas/<aa>/<sha256>.<ext>.
  /// Web: returns null (Web bridges stream bytes via readCasBlobBytes / OPFS Worker).
  String? resolveNativeCasPosixPath(Sha256Digest sha256, {required String ext});

  /// Native: returns ApplicationSupportDirectory/staging/rec_<take_id>.wav.part.
  /// Web: returns OPFS-relative staging path /staging/rec_<take_id>.wav.part.
  String resolveRecordingStagingPath(TakeId takeId);

  /// Reads an immutable CAS asset as bytes (used on Web to transfer .sf2 / .wav into Worker/Worklet).
  Future<Result<List<int>>> readCasBlobBytes(Sha256Digest sha256, {required String ext});
}

final class AudioHardwareInfo {
  final int sampleRate;
  final int inputChannels;
  final int outputChannels;
  final int inputBufferFrames;
  final int outputBufferFrames;
  final String deviceFingerprint;
  const AudioHardwareInfo({
    required this.sampleRate,
    required this.inputChannels,
    required this.outputChannels,
    required this.inputBufferFrames,
    required this.outputBufferFrames,
    required this.deviceFingerprint,
  });
}

final class SoundFontPresetInfo {
  final int bankNum;
  final int programNum;
  final String presetName;
  const SoundFontPresetInfo({
    required this.bankNum,
    required this.programNum,
    required this.presetName,
  });
}

final class LoadedSoundFontDescriptor {
  final SoundFontHandle handle;
  final List<SoundFontPresetInfo> presets;
  const LoadedSoundFontDescriptor({required this.handle, required this.presets});
}

abstract interface class IAudioLifecycleBridge {
  /// On Web, must be invoked inside a user gesture (resumes AudioContext).
  Future<Result<AudioHardwareInfo>> initialize();
  AudioHardwareInfo get currentHardwareInfo;
  Future<Result<LoadedSoundFontDescriptor>> loadSoundFontFromCas({
    required Sha256Digest sha256,
  });
  Future<Result<void>> unloadSoundFont(SoundFontHandle handle);
  Future<void> dispose();
}

final class ActiveTakePlaybackRegion {
  final TakeId takeId;
  final PartId partId;
  final Sha256Digest wavSha256;
  final SampleFrame startSampleFrame;
  final int durationFrames;
  final double gainDb;
  final double pan;
  const ActiveTakePlaybackRegion({
    required this.takeId,
    required this.partId,
    required this.wavSha256,
    required this.startSampleFrame,
    required this.durationFrames,
    required this.gainDb,
    required this.pan,
  });
}

abstract interface class ITransportBridge {
  Result<void> play();
  Result<void> pause();
  Result<void> stop();
  /// Advances the bridge's shared EpochCounter (also visible via ISynthEventBridge.currentEpoch)
  /// and pushes MUT_SEEK_SAMPLE so MIDI events and Butler take playback seek atomically.
  Result<EpochId> seekToSample(SampleFrame targetFrame);
  Result<void> setLoopRegion({required bool enabled, required SampleFrame startFrame, required SampleFrame endFrame});
  /// L4 passes only active, audible (unmuted / solo-passing) takes with part gain/pan applied.
  Future<Result<void>> syncActiveTakeRegions(List<ActiveTakePlaybackRegion> regions);
}

final class ScheduledMidiEvent {
  final EpochId epoch;
  final SampleFrame targetSampleFrame; // Timeline frame, or SampleFrame(MuseConstants.immediateDispatchFrame) for live audition
  final int type; // 1=noteOn, 2=noteOff, 3=cc, 4=pitchBend
  final int channel; // 0..15
  final int data1;
  final int data2;
  final int pitchBend;
  const ScheduledMidiEvent({
    required this.epoch,
    required this.targetSampleFrame,
    required this.type,
    required this.channel,
    required this.data1,
    required this.data2,
    this.pitchBend = 0,
  });
}

abstract interface class ISynthEventBridge {
  /// Shares the same underlying authoritative epoch counter as ITransportBridge.seekToSample().
  EpochId get currentEpoch;
  Result<EpochId> flushAndAdvanceEpoch();
  Result<int> scheduleEvents(List<ScheduledMidiEvent> events);
  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  });
  Result<void> setChannelMix({
    required int midiChannel,
    required double gainDb,
    required double pan,
  });
  Result<void> silenceChannel(int midiChannel);
  Result<void> triggerLiveAuditionNote({
    required int midiChannel,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  });
}

final class RecordingCaptureReceipt {
  final TakeId takeId;
  final String stagingPath;
  final Sha256Digest sha256;
  final SampleFrame capturedSampleClock;
  final SampleFrame capturedPlayheadFrame;
  final int durationFrames;
  final int sampleRate;
  final int channelCount;
  final int outputBufferFrames;
  final int inputBufferFrames;
  const RecordingCaptureReceipt({
    required this.takeId,
    required this.stagingPath,
    required this.sha256,
    required this.capturedSampleClock,
    required this.capturedPlayheadFrame,
    required this.durationFrames,
    required this.sampleRate,
    required this.channelCount,
    required this.outputBufferFrames,
    required this.inputBufferFrames,
  });
}

abstract interface class IRecordingBridge {
  Result<void> setMonitorGain(double gainLinear);
  /// Verifies runtime RECORD_AUDIO (Android) / getUserMedia (Web user gesture) permission before opening capture.
  Future<Result<void>> prepareAndStartCapture(TakeId takeId);
  Future<Result<RecordingCaptureReceipt>> stopAndFinalizeCapture(TakeId takeId);
}

final class TelemetrySnapshot {
  final SampleFrame playheadSampleFrame;
  final EpochId activeEpoch;
  final double outputPeakL;
  final double outputPeakR;
  final double outputRmsL;
  final double outputRmsR;
  final double inputPeak;
  final double inputRms;
  final bool isPlaying;
  final bool isCapturing;
  final bool hasEventQueueUnderrun;
  final bool hasCaptureBufferOverflow;
  final bool hasTakePlaybackUnderrun;
  const TelemetrySnapshot({
    required this.playheadSampleFrame,
    required this.activeEpoch,
    required this.outputPeakL,
    required this.outputPeakR,
    required this.outputRmsL,
    required this.outputRmsR,
    required this.inputPeak,
    required this.inputRms,
    required this.isPlaying,
    required this.isCapturing,
    required this.hasEventQueueUnderrun,
    required this.hasCaptureBufferOverflow,
    required this.hasTakePlaybackUnderrun,
  });
}

abstract interface class ITelemetryBridge {
  /// Non-destructive latest snapshot cached whenever drainTelemetry() runs (read by L4 lookahead feeder).
  TelemetrySnapshot? get latestSnapshot;

  /// Drains up to [maxFrames] queued TelemetrySnapshot blocks in chronological order.
  /// L5 TransportAndTelemetryController is the single drainer so SPSC frames are never split across consumers.
  List<TelemetrySnapshot> drainTelemetry({int maxFrames = MuseConstants.maxTelemetryDrainFrames});
}
```

---

#### Storage & Domain Data Contracts (`lib/domain/models/` & `lib/domain/repositories/`)
**Implemented by:** `lib/storage/{native,web}/` (repositories & `IInternalStorageLocator`).
**Called by:** Layer 4 (`lib/domain/`) and Composition Root (`lib/app/`).
Covers all 13 tables in [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md#L92-L335), atomic CAS promotion, Mark-and-Sweep GC, and orphan sweeps without leaking SQLite or filesystem types into L4.

```dart
// lib/domain/models/score_models.dart (Pure Dart — WasmGC-ready)

enum PlaybackTimingMode { quantized, raw }

enum EnharmonicStep { C, D, E, F, G, A, B }

enum KeyMode { major, minor, dorian, phrygian, lydian, mixolydian, aeolian, locrian, none }

enum ClefSign { G, F, C, percussion, tab, none }

enum SpannerType { tie, slur, beam }

enum SpannerPlacement { auto, above, below }

enum CalibrationPlatform { ios, android, macos, windows, linux, web }

final class ProjectSummary {
  final ProjectId projectId;
  final String title;
  final int ppqn; // Always 960
  final int gridSnapTicks;
  final int pickupTicks;
  final PlaybackTimingMode playbackTimingMode;
  final int revision;
  final int createdAtMs;
  final int updatedAtMs;
  const ProjectSummary({
    required this.projectId,
    required this.title,
    required this.ppqn,
    required this.gridSnapTicks,
    required this.pickupTicks,
    required this.playbackTimingMode,
    required this.revision,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
}

final class CreateProjectInput {
  final ProjectId projectId;
  final String title;
  final int gridSnapTicks;
  final int pickupTicks;
  final PlaybackTimingMode playbackTimingMode;
  final int initialUsPerQuarter;
  final int initialTimeSigNumerator;
  final int initialTimeSigDenominator;
  const CreateProjectInput({
    required this.projectId,
    required this.title,
    required this.gridSnapTicks,
    this.pickupTicks = 0,
    this.playbackTimingMode = PlaybackTimingMode.quantized,
    required this.initialUsPerQuarter,
    required this.initialTimeSigNumerator,
    required this.initialTimeSigDenominator,
  });
}

final class UpdateProjectMetadataInput {
  final ProjectId projectId;
  final int expectedRevision;
  final String? title;
  final int? gridSnapTicks;
  final int? pickupTicks;
  final PlaybackTimingMode? playbackTimingMode;
  const UpdateProjectMetadataInput({
    required this.projectId,
    required this.expectedRevision,
    this.title,
    this.gridSnapTicks,
    this.pickupTicks,
    this.playbackTimingMode,
  });
}

final class ProjectPartEntity {
  final PartId partId;
  final ProjectId projectId;
  final String musicXmlPartId;
  final int sortOrder;
  final String name;
  final int stavesCount; // 1 or 2
  final int midiChannel; // 0..15
  final SoundFontId? sfId;
  final int bankNum;
  final int programNum;
  final double gainDb;
  final double pan; // -1.0 .. 1.0
  final bool isMuted;
  final bool isSolo;
  final int updatedAtMs;
  const ProjectPartEntity({
    required this.partId,
    required this.projectId,
    required this.musicXmlPartId,
    required this.sortOrder,
    required this.name,
    required this.stavesCount,
    required this.midiChannel,
    required this.sfId,
    required this.bankNum,
    required this.programNum,
    required this.gainDb,
    required this.pan,
    required this.isMuted,
    required this.isSolo,
    required this.updatedAtMs,
  });
}

final class TempoEventEntity {
  final TempoEventId tempoEventId;
  final ProjectId projectId;
  final Tick tick; // tick 0 = initial tempo (protected from deletion)
  final int usPerQuarter;
  final int updatedAtMs;
  const TempoEventEntity({
    required this.tempoEventId,
    required this.projectId,
    required this.tick,
    required this.usPerQuarter,
    required this.updatedAtMs,
  });
}

final class TimeSignatureEventEntity {
  final TimeSigEventId tsEventId;
  final ProjectId projectId;
  final Tick tick; // tick 0 = initial time signature (protected from deletion)
  final int numerator;
  final int denominator; // 1, 2, 4, 8, 16, 32, 64
  final int updatedAtMs;
  const TimeSignatureEventEntity({
    required this.tsEventId,
    required this.projectId,
    required this.tick,
    required this.numerator,
    required this.denominator,
    required this.updatedAtMs,
  });
}

final class KeySignatureEventEntity {
  final KeySigEventId keyEventId;
  final ProjectId projectId;
  final PartId? partId; // null = project-wide key
  final int staffNumber; // 0 = all staves, 1 or 2
  final Tick tick;
  final int fifths; // -7 .. 7
  final KeyMode mode;
  final int updatedAtMs;
  const KeySignatureEventEntity({
    required this.keyEventId,
    required this.projectId,
    required this.partId,
    required this.staffNumber,
    required this.tick,
    required this.fifths,
    required this.mode,
    required this.updatedAtMs,
  });
}

final class ClefEventEntity {
  final ClefEventId clefEventId;
  final ProjectId projectId;
  final PartId partId;
  final int staffNumber; // 1 or 2
  final Tick tick;
  final ClefSign sign;
  final int line; // 1..5
  final int octaveChange; // -2..2
  final int updatedAtMs;
  const ClefEventEntity({
    required this.clefEventId,
    required this.projectId,
    required this.partId,
    required this.staffNumber,
    required this.tick,
    required this.sign,
    required this.line,
    required this.octaveChange,
    required this.updatedAtMs,
  });
}

final class TimelineNote {
  final NoteId noteId;
  final ProjectId projectId;
  final PartId partId;
  final int staffNumber; // 1 or 2
  final int voiceNumber; // 1..4
  final int pitchMidi; // 0..127
  final EnharmonicStep enharmonicStep;
  final int enharmonicAlter; // -2..2
  final Tick rawStartTick;
  final int rawDurationTicks;
  final Tick quantizedStartTick;
  final int quantizedDurationTicks;
  final int velocity; // 1..127
  final int updatedAtMs;
  const TimelineNote({
    required this.noteId,
    required this.projectId,
    required this.partId,
    required this.staffNumber,
    required this.voiceNumber,
    required this.pitchMidi,
    required this.enharmonicStep,
    required this.enharmonicAlter,
    required this.rawStartTick,
    required this.rawDurationTicks,
    required this.quantizedStartTick,
    required this.quantizedDurationTicks,
    required this.velocity,
    required this.updatedAtMs,
  });
}

final class NoteSpannerEntity {
  final SpannerId spannerId;
  final ProjectId projectId;
  final PartId partId;
  final SpannerType spannerType;
  final NoteId startNoteId;
  final NoteId endNoteId;
  final int spannerLevel; // 1..6
  final SpannerPlacement placement;
  final int updatedAtMs;
  const NoteSpannerEntity({
    required this.spannerId,
    required this.projectId,
    required this.partId,
    required this.spannerType,
    required this.startNoteId,
    required this.endNoteId,
    required this.spannerLevel,
    required this.placement,
    required this.updatedAtMs,
  });
}

final class AudioTakeEntity {
  final TakeId takeId;
  final ProjectId projectId;
  final PartId partId;
  final Sha256Digest blobSha256;
  final Tick startTick;
  final int sampleRate;
  final int channelCount; // 1 or 2
  final int durationFrames;
  final SampleFrame capturedPlayheadFrame;
  final SampleFrame capturedSampleClock;
  final int outputBufferFrames;
  final int inputBufferFrames;
  final int calibrationOffsetFrames;
  final int createdAtMs;
  final int updatedAtMs;
  const AudioTakeEntity({
    required this.takeId,
    required this.projectId,
    required this.partId,
    required this.blobSha256,
    required this.startTick,
    required this.sampleRate,
    required this.channelCount,
    required this.durationFrames,
    required this.capturedPlayheadFrame,
    required this.capturedSampleClock,
    required this.outputBufferFrames,
    required this.inputBufferFrames,
    required this.calibrationOffsetFrames,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
}

final class SoundFontCatalogEntry {
  final SoundFontId sfId;
  final String name;
  final Sha256Digest blobSha256;
  final int byteSize;
  final List<SoundFontPresetInfo> presets;
  final int createdAtMs;
  final int updatedAtMs;
  const SoundFontCatalogEntry({
    required this.sfId,
    required this.name,
    required this.blobSha256,
    required this.byteSize,
    required this.presets,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
}

final class LatencyCalibrationProfile {
  final CalibrationProfileId profileId;
  final CalibrationPlatform platform;
  final String deviceFingerprint;
  final int sampleRate;
  final int bufferSizeFrames;
  final int calibrationOffsetFrames;
  final int updatedAtMs;
  const LatencyCalibrationProfile({
    required this.profileId,
    required this.platform,
    required this.deviceFingerprint,
    required this.sampleRate,
    required this.bufferSizeFrames,
    required this.calibrationOffsetFrames,
    required this.updatedAtMs,
  });
}

final class UpsertCalibrationProfileInput {
  final CalibrationPlatform platform;
  final String deviceFingerprint;
  final int sampleRate;
  final int bufferSizeFrames;
  final int calibrationOffsetFrames;
  const UpsertCalibrationProfileInput({
    required this.platform,
    required this.deviceFingerprint,
    required this.sampleRate,
    required this.bufferSizeFrames,
    required this.calibrationOffsetFrames,
  });
}

final class PickedExternalFile {
  final String fileName;
  final String extension; // e.g. 'sf2', 'musicxml', 'mxl', 'xml'
  final int byteLength;
  final Stream<List<int>> byteStream;
  const PickedExternalFile({
    required this.fileName,
    required this.extension,
    required this.byteLength,
    required this.byteStream,
  });
}

final class AudioTakeRealignmentUpdate {
  final TakeId takeId;
  final Tick newStartTick;
  final int newCalibrationOffsetFrames;
  const AudioTakeRealignmentUpdate({
    required this.takeId,
    required this.newStartTick,
    required this.newCalibrationOffsetFrames,
  });
}

final class ProjectWorkspaceAggregate {
  final ProjectSummary project;
  final List<ProjectPartEntity> parts;
  final List<TempoEventEntity> tempoEvents;
  final List<TimeSignatureEventEntity> timeSignatureEvents;
  final List<KeySignatureEventEntity> keySignatureEvents;
  final List<ClefEventEntity> clefEvents;
  final List<TimelineNote> notes;
  final List<NoteSpannerEntity> spanners;
  final List<AudioTakeEntity> audioTakes;
  const ProjectWorkspaceAggregate({
    required this.project,
    required this.parts,
    required this.tempoEvents,
    required this.timeSignatureEvents,
    required this.keySignatureEvents,
    required this.clefEvents,
    required this.notes,
    required this.spanners,
    required this.audioTakes,
  });
}

final class ScoreMutationBatch {
  final ProjectId projectId;
  final int expectedRevision;
  final UpdateProjectMetadataInput? projectMetadataUpdate;
  final List<ProjectPartEntity> upsertParts;
  final List<PartId> deletePartIds;
  final List<TempoEventEntity> upsertTempoEvents;
  final List<TempoEventId> deleteTempoEventIds;
  final List<TimeSignatureEventEntity> upsertTimeSignatureEvents;
  final List<TimeSigEventId> deleteTimeSignatureEventIds;
  final List<KeySignatureEventEntity> upsertKeySignatureEvents;
  final List<KeySigEventId> deleteKeySignatureEventIds;
  final List<ClefEventEntity> upsertClefEvents;
  final List<ClefEventId> deleteClefEventIds;
  final List<TimelineNote> upsertNotes;
  final List<NoteId> deleteNoteIds;
  final List<NoteSpannerEntity> upsertSpanners;
  final List<SpannerId> deleteSpannerIds;
  final List<AudioTakeEntity> upsertAudioTakes;
  final List<PartId> deleteAudioTakePartIds;
  const ScoreMutationBatch({
    required this.projectId,
    required this.expectedRevision,
    this.projectMetadataUpdate,
    this.upsertParts = const [],
    this.deletePartIds = const [],
    this.upsertTempoEvents = const [],
    this.deleteTempoEventIds = const [],
    this.upsertTimeSignatureEvents = const [],
    this.deleteTimeSignatureEventIds = const [],
    this.upsertKeySignatureEvents = const [],
    this.deleteKeySignatureEventIds = const [],
    this.upsertClefEvents = const [],
    this.deleteClefEventIds = const [],
    this.upsertNotes = const [],
    this.deleteNoteIds = const [],
    this.upsertSpanners = const [],
    this.deleteSpannerIds = const [],
    this.upsertAudioTakes = const [],
    this.deleteAudioTakePartIds = const [],
  });
}
```

```dart
// lib/domain/repositories/storage_contracts.dart

// 1. Storage Lifecycle & Maintenance (Called by lib/app/ at startup & background)
abstract interface class IStorageMaintenanceRepository {
  /// Opens SQLite, enforces PRAGMA foreign_keys = ON, verifies platform journal_mode
  /// (WAL on Native, DELETE/TRUNCATE on Web), runs schema_migrations, and sweeps staging/*.part orphans.
  Future<Result<void>> initializeAndVerifyStorage();

  /// Checks Web OPFS / Native free disk quota before recording or importing SoundFonts.
  /// Returns available free bytes if >= [requiredBytes]; fails closed with insufficientStorageQuota otherwise.
  Future<Result<int>> verifyAvailableQuotaBytes({required int requiredBytes});

  /// Purges soft-deleted rows older than [olderThanEpochMs] and runs Mark-and-Sweep CAS GC
  /// (DELETE FROM content_blobs WHERE NOT EXISTS ... RETURNING sha256, ext -> unlink cas file).
  Future<Result<int>> runGarbageCollection({required int olderThanEpochMs});

  Future<void> close();
}

// 2. Project & Score Repository (Covers projects, project_parts, tempo_events,
//    time_signature_events, key_signature_events, clef_events, timeline_notes,
//    note_spanners, audio_takes, content_blobs)
abstract interface class IProjectRepository {
  Future<Result<List<ProjectSummary>>> listActiveProjects({required int limit, required int offset});
  Future<Result<ProjectWorkspaceAggregate>> loadProjectAggregate(ProjectId projectId);
  Future<Result<ProjectSummary>> createProject(CreateProjectInput input);
  Future<Result<void>> updateProjectMetadata(UpdateProjectMetadataInput input);
  Future<Result<void>> softDeleteProject(ProjectId projectId, {required int deletedAtMs});

  /// Commits an atomic batch of score edits (notes, spanners, tempo/time/key/clef maps, part settings)
  /// and increments projects.revision in a single BEGIN IMMEDIATE transaction.
  Future<Result<int>> commitScoreMutationBatch(ScoreMutationBatch batch);

  /// Promotes staging/rec_<take_id>.wav.part -> cas/<aa>/<sha256>.wav and inserts
  /// content_blobs + UPSERTs audio_takes on (project_id, part_id) (one overwrite recording per part).
  Future<Result<AudioTakeEntity>> promoteAndCommitRecordedTake({
    required RecordingCaptureReceipt receipt,
    required ProjectId projectId,
    required PartId partId,
    required Tick alignedStartTick,
    required int calibrationOffsetFrames,
  });

  /// Updates start_tick and calibration_offset_frames for existing takes when latency calibration changes.
  Future<Result<List<AudioTakeEntity>>> realignAudioTakesCalibration({
    required ProjectId projectId,
    required List<AudioTakeRealignmentUpdate> updates,
  });

  Future<Result<void>> deletePartAudioTake({
    required ProjectId projectId,
    required PartId partId,
  });
}

// 3. SoundFont Asset Library & Calibration Repository
//    (Covers soundfonts, soundfont_presets, content_blobs, latency_calibration_profiles)
abstract interface class IAssetLibraryRepository {
  Future<Result<List<SoundFontCatalogEntry>>> listActiveSoundFonts();
  Future<Result<SoundFontCatalogEntry>> importSoundFontBytes({
    required String displayName,
    required Stream<List<int>> byteStream,
    required int byteLength,
    required List<SoundFontPresetInfo> extractedPresets,
  });
  Future<Result<void>> softDeleteSoundFont(SoundFontId sfId, {required int deletedAtMs});

  Future<Result<LatencyCalibrationProfile?>> getCalibrationProfile({
    required CalibrationPlatform platform,
    required String deviceFingerprint,
    required int sampleRate,
    required int bufferSizeFrames,
  });
  Future<Result<LatencyCalibrationProfile>> upsertCalibrationProfile(
    UpsertCalibrationProfileInput input,
  );
}

// 4. Platform Import / Export Exchange (Copy-on-Import / Stage-on-Export / Web File Picker)
abstract interface class IExternalFileExchange {
  Future<Result<PickedExternalFile?>> pickImportFile({required List<String> allowedExtensions});
  Future<Result<void>> exportFileToUser({
    required String suggestedFileName,
    required String mimeType,
    required List<int> bytes,
  });
  Future<Result<void>> exportCasWavTakeToUser({
    required Sha256Digest wavSha256,
    required String suggestedFileName,
  });
}
```

---

#### Layer 4 — Musical & Notation Domain (`lib/domain/`)
**Pure Dart (`WasmGC`-ready). Depends only on:** `lib/bridge/contracts/`, `lib/domain/repositories/`, and `crisp_notation_core`.
**Called exclusively by:** Layer 5 (`lib/presentation/`) and Composition Root (`lib/app/`).

To keep L4 modular and free of dead code, it is structured into six domain services/coordinators:

##### 4.1 `TempoTimelineCalculator` (`lib/domain/timeline/tempo_timeline_calculator.dart`)
* **Responsibility:** Owns the immutable sorted `List<TempoEventEntity>` and `List<TimeSignatureEventEntity>` + `pickupTicks`. Implements the exact 64-bit segment-wise integer formula from [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md#L86-L88) and the latency compensation formula from [ARCHITECTURE.md](file:///Users/goldenfung/Documents/muse_grid/ARCHITECTURE.md#L279).
* **APIs for L4 & L5:**
  ```dart
  final class BarBeatGridLine {
    final Tick tick;
    final int measureNumber; // 0 for pickup (anacrusis), 1+ for full measures
    final int beatIndex;
    final bool isBarline;
    final bool isBeatLine;
    const BarBeatGridLine({
      required this.tick,
      required this.measureNumber,
      required this.beatIndex,
      required this.isBarline,
      required this.isBeatLine,
    });
  }

  abstract interface class ITempoTimelineCalculator {
    SampleFrame tickToSampleFrame(Tick tick, {required int sampleRate});
    Tick sampleFrameToTick(SampleFrame frame, {required int sampleRate});
    Tick quantizeTick(Tick rawTick, {required Tick snapSubdivisionTicks});
    Tick computeLatencyCompensatedStartTick({
      required SampleFrame capturedPlayheadFrame,
      required int outputBufferFrames,
      required int inputBufferFrames,
      required int calibrationOffsetFrames,
      required int sampleRate,
    });
    List<BarBeatGridLine> queryVisibleGridLines({
      required Tick startTick,
      required Tick endTick,
      required Tick subdivisionTicks,
    });
  }
  ```

##### 4.2 `SoundFontPresetParser` (`lib/domain/assets/soundfont_preset_parser.dart`)
* **Responsibility:** Parses SF2 `RIFF/sfbk/pdta/phdr` preset header chunks in Pure Dart during import so `IAssetLibraryRepository.importSoundFontBytes()` receives `extractedPresets` on both Native and Web without loading the `.sf2` into a running `AudioWorklet`.
* **APIs for L5 (`ProjectCatalogController`):**
  ```dart
  abstract interface class ISoundFontPresetParser {
    Future<Result<List<SoundFontPresetInfo>>> parsePresetsFromSf2Stream({
      required Stream<List<int>> byteStream,
      required int byteLength,
    });
  }
  ```

##### 4.3 `DualModelScoreService` (`lib/domain/notation/dual_model_score_service.dart`)
* **Responsibility:** Synchronizes the in-memory `960 PPQN` `TimelineNote` + `NoteSpannerEntity` spatial index with `crisp_notation_core`'s `StaffSystem` (composed of `Score` staves) via shared `NoteId`, and handles bidirectional MusicXML (`.xml` / `.musicxml` / `.mxl`) import/export.
* **APIs for L4 & L5:**
  ```dart
  import 'package:crisp_notation_core/crisp_notation_core.dart' show StaffSystem;

  final class ScoreRenderSnapshot {
    /// Deterministic engraved crisp_notation_core StaffSystem consumed directly by L5 StaffSystemView.
    final StaffSystem crispScoreModel;
    final int revision;
    const ScoreRenderSnapshot({required this.crispScoreModel, required this.revision});
  }

  final class ScoreWorkspaceState {
    final ProjectWorkspaceAggregate aggregate;
    final ScoreRenderSnapshot renderSnapshot;
    const ScoreWorkspaceState({required this.aggregate, required this.renderSnapshot});
  }

  abstract interface class IDualModelScoreService {
    /// Builds initial ScoreWorkspaceState (spatial note index + crisp_notation_core Score) from SQLite aggregate.
    Result<ScoreWorkspaceState> buildWorkspaceState(ProjectWorkspaceAggregate aggregate);

    /// Parses MusicXML (.xml/.musicxml/.mxl) into a new ProjectWorkspaceAggregate with UUIDv7 noteIds.
    Result<ProjectWorkspaceAggregate> importFromMusicXmlBytes({
      required List<int> bytes,
      required bool isCompressedMxl,
      required String fallbackTitle,
      SoundFontId? defaultSoundFontId,
    });

    /// Serializes the current authoritative score state to .musicxml or .mxl bytes.
    Result<List<int>> exportToMusicXmlBytes({
      required ProjectWorkspaceAggregate aggregate,
      required bool compressAsMxl,
    });

    /// Applies a validated ScoreMutationBatch in-place to both the 960 PPQN spatial index
    /// and the crisp_notation_core Score AST without losing enharmonic/spanner metadata.
    Result<ScoreWorkspaceState> applyMutationToDualModel(
      ScoreWorkspaceState currentState,
      ScoreMutationBatch mutation,
    );

    /// Fast spatial query over [state] for Piano Roll viewport culling (O(log N + K) in-memory).
    List<TimelineNote> queryNotesInViewport({
      required ScoreWorkspaceState state,
      required PartId partId,
      required Tick startTick,
      required Tick endTick,
      required int minPitchMidi,
      required int maxPitchMidi,
      required PlaybackTimingMode timingMode,
    });
  }
  ```

##### 4.4 `ScoreEditingCommandBus` (`lib/domain/commands/score_editing_command_bus.dart`)
* **Responsibility:** Executes reversible `ScoreCommand` mutations (Undo/Redo stack), persists deltas via `IProjectRepository.commitScoreMutationBatch`, updates `IDualModelScoreService`, and notifies `ILookaheadPlaybackCoordinator` when an edit intersects the active playback lookahead horizon. Rejects invalid deletions (e.g., deleting `tempo_events` or `time_signature_events` at `tick == 0`) fail-closed with `protectedInitialMapEvent`.
* **APIs for L5:**
  ```dart
  sealed class ScoreCommand {
    const ScoreCommand();
  }

  final class InsertNotesCommand extends ScoreCommand {
    final List<TimelineNote> notes;
    const InsertNotesCommand(this.notes);
  }
  final class UpdateNotesCommand extends ScoreCommand {
    final List<TimelineNote> updatedNotes;
    const UpdateNotesCommand(this.updatedNotes);
  }
  final class DeleteNotesCommand extends ScoreCommand {
    final List<NoteId> noteIds;
    const DeleteNotesCommand(this.noteIds);
  }
  final class UpsertNoteSpannerCommand extends ScoreCommand {
    final NoteSpannerEntity spanner;
    const UpsertNoteSpannerCommand(this.spanner);
  }
  final class DeleteNoteSpannerCommand extends ScoreCommand {
    final SpannerId spannerId;
    const DeleteNoteSpannerCommand(this.spannerId);
  }
  final class UpsertTempoEventCommand extends ScoreCommand {
    final TempoEventEntity event;
    const UpsertTempoEventCommand(this.event);
  }
  final class DeleteTempoEventCommand extends ScoreCommand {
    final TempoEventId tempoEventId; // Fails closed if tick == 0
    const DeleteTempoEventCommand(this.tempoEventId);
  }
  final class UpsertTimeSignatureCommand extends ScoreCommand {
    final TimeSignatureEventEntity event;
    const UpsertTimeSignatureCommand(this.event);
  }
  final class DeleteTimeSignatureCommand extends ScoreCommand {
    final TimeSigEventId tsEventId; // Fails closed if tick == 0
    const DeleteTimeSignatureCommand(this.tsEventId);
  }
  final class UpsertKeySignatureCommand extends ScoreCommand {
    final KeySignatureEventEntity event;
    const UpsertKeySignatureCommand(this.event);
  }
  final class DeleteKeySignatureCommand extends ScoreCommand {
    final KeySigEventId keyEventId;
    const DeleteKeySignatureCommand(this.keyEventId);
  }
  final class UpsertClefEventCommand extends ScoreCommand {
    final ClefEventEntity event;
    const UpsertClefEventCommand(this.event);
  }
  final class DeleteClefEventCommand extends ScoreCommand {
    final ClefEventId clefEventId;
    const DeleteClefEventCommand(this.clefEventId);
  }
  final class AddProjectPartCommand extends ScoreCommand {
    final ProjectPartEntity part;
    final List<ClefEventEntity> initialClefs;
    const AddProjectPartCommand({required this.part, required this.initialClefs});
  }
  final class UpdatePartMixerOrPatchCommand extends ScoreCommand {
    final ProjectPartEntity updatedPart; // sfId, bankNum, programNum, gainDb, pan, isMuted, isSolo, name
    const UpdatePartMixerOrPatchCommand(this.updatedPart);
  }
  final class ReorderProjectPartsCommand extends ScoreCommand {
    final List<PartId> orderedPartIds; // Updates project_parts.sort_order
    const ReorderProjectPartsCommand(this.orderedPartIds);
  }
  final class RemoveProjectPartCommand extends ScoreCommand {
    final PartId partId;
    const RemoveProjectPartCommand(this.partId);
  }
  final class ClearPartAudioCommand extends ScoreCommand {
    final PartId partId;
    const ClearPartAudioCommand(this.partId);
  }
  final class UpdateProjectSettingsCommand extends ScoreCommand {
    final String? title;
    final int? gridSnapTicks;
    final int? pickupTicks;
    final PlaybackTimingMode? playbackTimingMode;
    const UpdateProjectSettingsCommand({
      this.title,
      this.gridSnapTicks,
      this.pickupTicks,
      this.playbackTimingMode,
    });
  }

  abstract interface class IScoreEditingCommandBus {
    ScoreWorkspaceState get currentState;
    Stream<ScoreWorkspaceState> get stateStream;
    bool get canUndo;
    bool get canRedo;

    Future<Result<ScoreWorkspaceState>> execute(ScoreCommand command);
    Future<Result<ScoreWorkspaceState>> undo();
    Future<Result<ScoreWorkspaceState>> redo();
  }
  ```

##### 4.5 `LookaheadPlaybackCoordinator` (`lib/domain/playback/lookahead_playback_coordinator.dart`)
* **Responsibility:** Owns workspace audio session lifecycle (`attachProject` loads SoundFonts + active take regions; `detachProject` calls `IAudioLifecycleBridge.unloadSoundFont()` for unused SoundFonts and clears active takes), transport state (`play`, `pause`, `stop`, `seekToTick`, `setLoopTickRange`), runs the non-paint lookahead feeder (`kLookaheadRefillIntervalMs = 25ms` filling `kLookaheadWindowMs = 200ms`), resolves `sf_id` → `SoundFontHandle`, enforces fail-closed `missingSoundFontForPart`, and issues `ISynthEventBridge.flushAndAdvanceEpoch()` on seek or live edit within the lookahead window.
* **APIs for L5:**
  ```dart
  abstract interface class ILookaheadPlaybackCoordinator {
    Future<Result<void>> attachProject(ScoreWorkspaceState workspace);
    Future<void> detachProject();
    Future<Result<void>> unloadUnusedSoundFont(SoundFontId sfId);

    Future<Result<void>> play();
    Result<void> pause();
    Result<void> stop();
    Result<void> seekToTick(Tick targetTick);
    Result<void> setLoopTickRange({required bool enabled, required Tick startTick, required Tick endTick});
    Result<void> auditionNote({required PartId partId, required int pitchMidi, required int velocity, required bool isNoteOn});

    /// Called by ScoreEditingCommandBus when notes/tempo/mixer/active takes change during playback.
    void notifyScoreMutatedInRange({required Tick affectedStartTick, required Tick affectedEndTick});
  }
  ```

##### 4.6 `RecordingSessionCoordinator` (`lib/domain/recording/recording_session_coordinator.dart`)
* **Responsibility:** Orchestrates pre-flight quota checks (`IStorageMaintenanceRepository.verifyAvailableQuotaBytes`), count-in metronome scheduling via `ISynthEventBridge`, duplex playback + start/stop capture via `IRecordingBridge` (suppressing the armed part's previous WAV while playing other unmuted parts), latency-compensated `start_tick` calculation via `ITempoTimelineCalculator.computeLatencyCompensatedStartTick()` + `IAssetLibraryRepository.getCalibrationProfile()`, atomic CAS promotion + SQLite overwrite `UPSERT` via `IProjectRepository.promoteAndCommitRecordedTake()`, and take re-alignment via `IProjectRepository.realignAudioTakesCalibration()` when calibration profiles change.
* **APIs for L5:**
  ```dart
  abstract interface class IRecordingSessionCoordinator {
    Result<void> setInputMonitorGain(double gainLinear);
    Future<Result<TakeId>> startRecordingOnPart({
      required PartId partId,
      required Tick countInStartTick,
    });
    Future<Result<AudioTakeEntity>> stopAndCommitRecording();
    Future<Result<List<AudioTakeEntity>>> realignProjectTakesForCalibration({
      required ProjectId projectId,
      required int newCalibrationOffsetFrames,
    });
  }
  ```

---

#### Layer 5 — Presentation (`lib/presentation/`)
**Depends only on:** Layer 4 (`lib/domain/`) interfaces, `lib/bridge/contracts/ITelemetryBridge`, Flutter, and `crisp_notation`.
**Structured into 5 focused UI Controllers / ViewModels so every L4 API is consumed directly:**

| L5 Controller / Widget | Consumed L4 / Bridge Interfaces | UI Responsibility |
| :--- | :--- | :--- |
| `ProjectCatalogController` | `IProjectRepository`, `IAssetLibraryRepository`, `IExternalFileExchange`, `IDualModelScoreService`, `ISoundFontPresetParser`, `ILookaheadPlaybackCoordinator` | Project list pagination, create/delete project, import/export `.musicxml`/`.mxl`/`.sf2`/`.wav`, SoundFont manager (parses `phdr` presets on import; calls `unloadUnusedSoundFont` on delete), latency calibration dialog (upserts profile & calls `realignProjectTakesForCalibration`) |
| `WorkspaceShellController` | `IScoreEditingCommandBus`, `ITempoTimelineCalculator`, `ILookaheadPlaybackCoordinator` | Attaches/detaches workspace (`attachProject`/`detachProject`), holds active `ScoreWorkspaceState`, Undo/Redo toolbar, project settings (`title`, `pickupTicks`, `gridSnapTicks`, `playbackTimingMode`), part reordering & mixer/patch edits |
| `StaffNotationViewController` | `IScoreEditingCommandBus`, `ILookaheadPlaybackCoordinator` | Feeds `crisp_notation`'s `StaffSystemView` (`gridAlign: true`) from `ScoreRenderSnapshot.crispScoreModel`; dispatches staff note/clef/key/time-sig/spanner `ScoreCommand`s and live note audition |
| `PianoRollViewportController` | `IDualModelScoreService.queryNotesInViewport`, `ITempoTimelineCalculator.queryVisibleGridLines`, `IScoreEditingCommandBus`, `ILookaheadPlaybackCoordinator.auditionNote` | Drives viewport-culled `CustomPainter` (static grid + notes layer, velocity lane, edge-drag resize, marquee selection, pinch/wheel zoom) |
| `TransportAndTelemetryController` | `ILookaheadPlaybackCoordinator`, `IRecordingSessionCoordinator`, `ITelemetryBridge`, `ITempoTimelineCalculator.sampleFrameToTick` | Single 60 Hz `Ticker` drainer calling `ITelemetryBridge.drainTelemetry()` (updating `latestSnapshot` for L4) to drive the isolated playhead overlay (`ValueListenable<Tick>`), L/R output & mic input peak/RMS meters, gapless live recording waveform peak/RMS blocks, and overflow/underrun error banners |

---

### 4. End-to-End Traceability Matrix (Zero-Dead-Code Verification)

Every database table in [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md) and every C/C++ / Bridge function maps to an explicit caller in the layer immediately above it:

| Lower-Layer Resource / Table / Queue | Exposed Contract Method | Upper-Layer Caller |
| :--- | :--- | :--- |
| `schema_migrations`, `PRAGMA journal_mode`, `staging/*.part` | `IStorageMaintenanceRepository.initializeAndVerifyStorage()` | `lib/app/MuseGridAppBootstrap` on startup |
| `content_blobs` (GC) | `IStorageMaintenanceRepository.runGarbageCollection()` | `lib/app/MuseGridAppBootstrap` after project/SF2 purge or overwrite |
| `cas/` & `staging/` locator | `IInternalStorageLocator.{resolveNativeCasPosixPath, resolveRecordingStagingPath, readCasBlobBytes}` | `NativeAudioBridge` & `WebAudioWorkletBridge` (injected by `lib/app/`) |
| `projects` | `IProjectRepository.{listActiveProjects, loadProjectAggregate, createProject, updateProjectMetadata, softDeleteProject}` | `L5 ProjectCatalogController` & `L4 ScoreEditingCommandBus` |
| `project_parts` | `IProjectRepository.commitScoreMutationBatch()` + `ISynthEventBridge.{assignChannelPatch, setChannelMix, silenceChannel}` | `L4 ScoreEditingCommandBus` (`UpdatePartMixerOrPatchCommand`, `ReorderProjectPartsCommand`) & `L4 LookaheadPlaybackCoordinator` |
| `tempo_events`, `time_signature_events` | `IProjectRepository.commitScoreMutationBatch()` + `ITempoTimelineCalculator` | `L4 ScoreEditingCommandBus`, `L4 LookaheadPlaybackCoordinator`, `L5 PianoRollViewportController` |
| `key_signature_events`, `clef_events` | `IProjectRepository.commitScoreMutationBatch()` + `IDualModelScoreService` | `L5 StaffNotationViewController` → `L4 ScoreEditingCommandBus` |
| `timeline_notes`, `note_spanners` | `IProjectRepository.commitScoreMutationBatch()` + `IDualModelScoreService.queryNotesInViewport()` | `L5 PianoRollViewportController` & `L5 StaffNotationViewController` → `L4 ScoreEditingCommandBus` |
| `audio_takes` + `CaptureRingBuffer` + `TakePlaybackRingBuffer` | `IRecordingBridge.*` → `IProjectRepository.{promoteAndCommitRecordedTake, realignAudioTakesCalibration, deletePartAudioTake, commitScoreMutationBatch}` + `ITransportBridge.syncActiveTakeRegions()` → `muse_engine_register_active_take()` / `muse_engine_push_take_playback_pcm()` / `muse_engine_drain_capture_frames()` | `L5 TransportAndTelemetryController` → `L4 RecordingSessionCoordinator` & `L4 LookaheadPlaybackCoordinator` (and Web `AudioWorklet` / Catch2 via `muse_engine_process_block()`) |
| `soundfonts`, `soundfont_presets` | `ISoundFontPresetParser.parsePresetsFromSf2Stream()` + `IAudioLifecycleBridge.{loadSoundFontFromCas, unloadSoundFont}` + `IAssetLibraryRepository.{listActiveSoundFonts, importSoundFontBytes, softDeleteSoundFont}` | `L5 ProjectCatalogController`, `L5 WorkspaceShellController` → `L4 LookaheadPlaybackCoordinator` |
| `latency_calibration_profiles` | `IAssetLibraryRepository.{getCalibrationProfile, upsertCalibrationProfile}` + `IRecordingSessionCoordinator.realignProjectTakesForCalibration()` | `L5 ProjectCatalogController` & `L4 RecordingSessionCoordinator` |
| `MutationQueue`, `EventQueue` (L2) | `ITransportBridge.*`, `ISynthEventBridge.*` → `muse_engine_push_mutation()`, `muse_engine_push_events()` | `L4 LookaheadPlaybackCoordinator` & `L4 RecordingSessionCoordinator` (count-in) |
| `TelemetryQueue` (L2) | `ITelemetryBridge.drainTelemetry()` (single drainer) + `ITelemetryBridge.latestSnapshot` | `L5 TransportAndTelemetryController` (60 Hz UI `Ticker` drainer) & `L4 LookaheadPlaybackCoordinator` (25 ms feeder reading `latestSnapshot`) |

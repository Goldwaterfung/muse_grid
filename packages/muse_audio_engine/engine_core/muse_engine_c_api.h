#ifndef MUSE_ENGINE_C_API_H
#define MUSE_ENGINE_C_API_H

#include <stdint.h>

#include "engine_constants.h"
#include "hal_contract.h"
#include "infra/rt_pods.h"

#if defined(_WIN32)
#if defined(MUSE_ENGINE_BUILD_SHARED)
#define MUSE_ENGINE_API __declspec(dllexport)
#else
#define MUSE_ENGINE_API
#endif
#elif defined(__GNUC__) || defined(__clang__)
#define MUSE_ENGINE_API __attribute__((visibility("default")))
#else
#define MUSE_ENGINE_API
#endif

#ifdef __cplusplus
#include <type_traits>
extern "C" {
#endif

/// Opaque engine handle allocated cleanly behind the C11 FFI/Wasm ABI.
typedef struct MuseEngineOpaque* MuseEngineHandle;

/// Preset metadata POD extracted after SoundFont loading (72 bytes).
typedef struct MuseSoundFontPresetPod {
  int32_t bank_num;
  int32_t program_num;
  char preset_name[kPresetNameBufferSize];
} MuseSoundFontPresetPod;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Creates an engine initialized against the registered Layer 1 HAL.
MUSE_ENGINE_API MuseStatus muse_engine_create(
    MuseEngineHandle* out_engine,
    MuseHardwareConfig* out_hardware_config);

/// Creates an engine with an explicit config (Web AudioWorklet & tests).
MUSE_ENGINE_API MuseStatus muse_engine_create_with_config(
    MuseEngineHandle* out_engine,
    const MuseHardwareConfig* explicit_config);

/// Tears down the HAL, Butler worker, and FluidSynth instance cleanly.
MUSE_ENGINE_API void muse_engine_destroy(MuseEngineHandle engine);

// ---------------------------------------------------------------------------
// SoundFont Management
// ---------------------------------------------------------------------------

/// Loads a SoundFont from a POSIX file path and populates up to max_presets.
MUSE_ENGINE_API MuseStatus muse_engine_load_sf2_file(
    MuseEngineHandle engine,
    const char* posix_path,
    int32_t* out_sf_handle,
    MuseSoundFontPresetPod* out_presets,
    uint32_t max_presets,
    uint32_t* out_preset_count);

/// Loads an in-memory SoundFont buffer and populates up to max_presets.
MUSE_ENGINE_API MuseStatus muse_engine_load_sf2_bytes(
    MuseEngineHandle engine,
    const uint8_t* bytes,
    uint32_t byte_length,
    int32_t* out_sf_handle,
    MuseSoundFontPresetPod* out_presets,
    uint32_t max_presets,
    uint32_t* out_preset_count);

/// Unloads a loaded SoundFont handle safely while synth rendering is suspended.
MUSE_ENGINE_API MuseStatus muse_engine_unload_sf2(
    MuseEngineHandle engine,
    int32_t sf_handle);

// ---------------------------------------------------------------------------
// Lock-Free Command, Note & Active Take Queues
// ---------------------------------------------------------------------------

/// Enqueues a single non-RT MutationCommand into MutationQueue.
MUSE_ENGINE_API MuseStatus muse_engine_push_mutation(
    MuseEngineHandle engine,
    const MutationCommand* cmd);

/// Enqueues a batch of SynthNoteEvents (queued playback vs immediate audition).
MUSE_ENGINE_API MuseStatus muse_engine_push_events(
    MuseEngineHandle engine,
    const SynthNoteEvent* events,
    uint32_t count,
    uint32_t* out_pushed_count);

/// Registers an active audio take region and starts Native Butler prefetch.
MUSE_ENGINE_API MuseStatus muse_engine_register_active_take(
    MuseEngineHandle engine,
    const char* take_id_utf8,
    const char* cas_wav_posix_path,
    int64_t start_sample_frame,
    int64_t duration_frames,
    float gain_db,
    float pan);

/// Pushes pre-decoded stereo float32 take frames into TakePlaybackRingBuffer.
MUSE_ENGINE_API MuseStatus muse_engine_push_take_playback_pcm(
    MuseEngineHandle engine,
    uint64_t epoch,
    int64_t start_sample_frame,
    const float* interleaved_stereo_f32,
    uint32_t frame_count,
    uint32_t* out_pushed_frames);

/// Unregisters and closes all active take decoders cleanly.
MUSE_ENGINE_API MuseStatus muse_engine_clear_active_takes(
    MuseEngineHandle engine);

// ---------------------------------------------------------------------------
// Capture & Recording
// ---------------------------------------------------------------------------

/// Pre-allocates/opens the staging WAV encoder on the Butler worker thread.
MUSE_ENGINE_API MuseStatus muse_engine_prepare_capture(
    MuseEngineHandle engine,
    const char* staging_wav_path);

/// Arms real-time CaptureRingBuffer ingestion.
MUSE_ENGINE_API MuseStatus muse_engine_start_capture(
    MuseEngineHandle engine);

/// Stops capture, joins/drains remaining frames, hashes WAV, emits receipt.
MUSE_ENGINE_API MuseStatus muse_engine_stop_and_finalize_capture(
    MuseEngineHandle engine,
    FinalizedCaptureReceipt* out_receipt);

// ---------------------------------------------------------------------------
// Telemetry & Web / Offline Render Pull
// ---------------------------------------------------------------------------

/// Drains up to max_frames TelemetryFrame snapshots from TelemetryQueue.
MUSE_ENGINE_API uint32_t muse_engine_drain_telemetry(
    MuseEngineHandle engine,
    TelemetryFrame* out_frames,
    uint32_t max_frames);

/// Executes the deterministic 3-phase cycle for host/Wasm/test-driven blocks.
MUSE_ENGINE_API MuseStatus muse_engine_process_block(
    MuseEngineHandle engine,
    const float* input_interleaved,
    float* output_interleaved,
    uint32_t frame_count);

/// Drains captured input frames directly when Butler disk writing is absent.
MUSE_ENGINE_API uint32_t muse_engine_drain_capture_frames(
    MuseEngineHandle engine,
    float* out_interleaved_frames,
    uint32_t max_frames,
    int64_t* out_first_sample_clock);

#ifdef __cplusplus
} // extern "C"

static_assert(std::is_trivially_copyable_v<MuseSoundFontPresetPod>);
static_assert(sizeof(MuseSoundFontPresetPod) == 72,
              "MuseSoundFontPresetPod must remain 72 bytes across C11/C++ ABI");
#endif

#endif // MUSE_ENGINE_C_API_H

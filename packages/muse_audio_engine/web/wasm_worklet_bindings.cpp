#if defined(__EMSCRIPTEN__)

#include <emscripten/emscripten.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "engine_constants.h"
#include "muse_engine_c_api.h"
#include "muse_engine_opaque.h"

namespace {

// Total capture batch scratch capacity in floats across channels.
constexpr uint32_t kMaxCaptureBatchFrames =
    kWebCaptureBatchQuanta * kWebRenderQuantumFrames;
constexpr uint32_t kInitialOutCountZero = 0u;

// Telemetry meter field indices consumed by JS without C struct offset math.
constexpr uint32_t kTelemetryMeterOutputPeakL = 0u;
constexpr uint32_t kTelemetryMeterOutputPeakR = 1u;
constexpr uint32_t kTelemetryMeterOutputRmsL = 2u;
constexpr uint32_t kTelemetryMeterOutputRmsR = 3u;
constexpr uint32_t kTelemetryMeterInputPeak = 4u;
constexpr uint32_t kTelemetryMeterInputRms = 5u;

// Telemetry bitflag positions exposed by muse_wasm_telemetry_flags_u32.
constexpr uint32_t kTelemetryFlagIsPlayingBit = 0u;
constexpr uint32_t kTelemetryFlagIsCapturingBit = 1u;
constexpr uint32_t kTelemetryFlagEventQueueUnderrunBit = 2u;
constexpr uint32_t kTelemetryFlagCaptureBufferOverflowBit = 3u;
constexpr uint32_t kTelemetryFlagTakePlaybackUnderrunBit = 4u;
constexpr uint32_t kTelemetryLoopPassShiftBits = 16u;
constexpr uint32_t kTelemetryByteShiftBits = 8u;

alignas(16) float g_in_scratch[kMaxRenderBlockFrames * kMaxCaptureChannels] = {};
alignas(16) float g_out_scratch[kMaxRenderBlockFrames * kStereoChannelCount] = {};
alignas(16) float
    g_capture_scratch[kMaxCaptureBatchFrames * kMaxCaptureChannels] = {};
int64_t g_capture_clock_out = 0;
TelemetryFrame g_telemetry_scratch[kTelemetryQueueCapacity] = {};
MuseSoundFontPresetPod g_preset_scratch[kMaxSoundFontPresets] = {};
SynthNoteEvent g_event_scratch[kEventQueueCapacity] = {};
alignas(16) float
    g_take_pcm_scratch[kTakePrefetchFrames * kStereoChannelCount] = {};

uint32_t g_last_preset_count = 0u;
uint32_t g_last_telemetry_count = 0u;

} // namespace

extern "C" {

EMSCRIPTEN_KEEPALIVE
MuseEngineHandle muse_wasm_create(
    uint32_t sample_rate,
    uint32_t input_channels,
    uint32_t output_channels,
    uint32_t input_buffer_frames,
    uint32_t output_buffer_frames,
    const char* device_fingerprint_utf8) {
  MuseHardwareConfig cfg = {};
  cfg.sample_rate = sample_rate;
  cfg.input_channels = input_channels;
  cfg.output_channels = output_channels;
  cfg.input_buffer_frames = input_buffer_frames;
  cfg.output_buffer_frames = output_buffer_frames;

  if (device_fingerprint_utf8 != nullptr && device_fingerprint_utf8[0] != '\0') {
    std::snprintf(cfg.device_fingerprint, sizeof(cfg.device_fingerprint), "%s",
                  device_fingerprint_utf8);
  }

  MuseEngineHandle engine = nullptr;
  if (muse_engine_create_with_config(&engine, &cfg) != MUSE_OK) {
    return nullptr;
  }
  return engine;
}

EMSCRIPTEN_KEEPALIVE
void muse_wasm_destroy(MuseEngineHandle engine) {
  muse_engine_destroy(engine);
}

EMSCRIPTEN_KEEPALIVE
float* muse_wasm_input_scratch_ptr() {
  return g_in_scratch;
}

EMSCRIPTEN_KEEPALIVE
float* muse_wasm_output_scratch_ptr() {
  return g_out_scratch;
}

EMSCRIPTEN_KEEPALIVE
float* muse_wasm_capture_drain_scratch_ptr() {
  return g_capture_scratch;
}

EMSCRIPTEN_KEEPALIVE
int64_t* muse_wasm_capture_clock_ptr() {
  return &g_capture_clock_out;
}

EMSCRIPTEN_KEEPALIVE
SynthNoteEvent* muse_wasm_event_scratch_ptr() {
  return g_event_scratch;
}

EMSCRIPTEN_KEEPALIVE
float* muse_wasm_take_pcm_scratch_ptr() {
  return g_take_pcm_scratch;
}

EMSCRIPTEN_KEEPALIVE
uint8_t* muse_wasm_alloc_bytes(uint32_t len) {
  if (len == 0u) {
    return nullptr;
  }
  return static_cast<uint8_t*>(std::malloc(static_cast<size_t>(len)));
}

EMSCRIPTEN_KEEPALIVE
void muse_wasm_free_bytes(void* ptr) {
  std::free(ptr);
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_process_quantum(
    MuseEngineHandle engine,
    uint32_t frame_count) {
  if (frame_count > kMaxRenderBlockFrames) {
    return MUSE_ERR_BUFFER_TOO_SMALL;
  }
  return muse_engine_process_block(
      engine, g_in_scratch, g_out_scratch, frame_count);
}

EMSCRIPTEN_KEEPALIVE
uint32_t muse_wasm_drain_capture(
    MuseEngineHandle engine,
    uint32_t max_frames) {
  const uint32_t clamped =
      std::min(max_frames, static_cast<uint32_t>(kMaxCaptureBatchFrames));
  g_capture_clock_out = 0;
  return muse_engine_drain_capture_frames(
      engine, g_capture_scratch, clamped, &g_capture_clock_out);
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_push_mutation(
    MuseEngineHandle engine,
    uint8_t type,
    uint8_t channel,
    uint8_t flag_a,
    int32_t int_param_a,
    int32_t int_param_b,
    int32_t int_param_c,
    float float_param_a,
    float float_param_b,
    uint64_t target_epoch,
    int64_t sample_frame_a,
    int64_t sample_frame_b) {
  MutationCommand cmd = {};
  cmd.type = type;
  cmd.channel = channel;
  cmd.flag_a = flag_a;
  cmd.int_param_a = int_param_a;
  cmd.int_param_b = int_param_b;
  cmd.int_param_c = int_param_c;
  cmd.float_param_a = float_param_a;
  cmd.float_param_b = float_param_b;
  cmd.target_epoch = target_epoch;
  cmd.sample_frame_a = sample_frame_a;
  cmd.sample_frame_b = sample_frame_b;
  return muse_engine_push_mutation(engine, &cmd);
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_push_single_event(
    MuseEngineHandle engine,
    uint64_t epoch,
    int64_t target_sample_frame,
    uint8_t type,
    uint8_t channel,
    uint8_t key_or_cc,
    uint8_t velocity_or_val,
    int16_t pitch_bend,
    uint16_t loop_pass) {
  SynthNoteEvent evt = {};
  evt.epoch = epoch;
  evt.target_sample_frame = target_sample_frame;
  evt.type = type;
  evt.channel = channel;
  evt.key_or_cc = key_or_cc;
  evt.velocity_or_val = velocity_or_val;
  evt.pitch_bend = pitch_bend;
  evt.reserved = loop_pass;
  uint32_t pushed = kInitialOutCountZero;
  return muse_engine_push_events(engine, &evt, 1u, &pushed);
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_load_sf2_bytes(
    MuseEngineHandle engine,
    const uint8_t* bytes,
    uint32_t byte_length,
    int32_t* out_sf_handle,
    uint32_t* out_preset_count) {
  g_last_preset_count = 0u;
  uint32_t count = 0u;
  const MuseStatus status = muse_engine_load_sf2_bytes(
      engine,
      bytes,
      byte_length,
      out_sf_handle,
      g_preset_scratch,
      static_cast<uint32_t>(kMaxSoundFontPresets),
      &count);
  g_last_preset_count =
      std::min(count, static_cast<uint32_t>(kMaxSoundFontPresets));
  if (out_preset_count != nullptr) {
    *out_preset_count = count;
  }
  return status;
}

EMSCRIPTEN_KEEPALIVE
int32_t muse_wasm_preset_bank(uint32_t idx) {
  if (idx >= g_last_preset_count) {
    return 0;
  }
  return g_preset_scratch[idx].bank_num;
}

EMSCRIPTEN_KEEPALIVE
int32_t muse_wasm_preset_program(uint32_t idx) {
  if (idx >= g_last_preset_count) {
    return 0;
  }
  return g_preset_scratch[idx].program_num;
}

EMSCRIPTEN_KEEPALIVE
const char* muse_wasm_preset_name(uint32_t idx) {
  if (idx >= g_last_preset_count) {
    return "";
  }
  return g_preset_scratch[idx].preset_name;
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_unload_sf2(MuseEngineHandle engine, int32_t sf_handle) {
  return muse_engine_unload_sf2(engine, sf_handle);
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_register_active_take(
    MuseEngineHandle engine,
    const char* take_id_utf8,
    const char* cas_wav_posix_path,
    int64_t start_sample_frame,
    int64_t duration_frames,
    float gain_db,
    float pan) {
  if (take_id_utf8 == nullptr || take_id_utf8[0] == '\0' ||
      cas_wav_posix_path == nullptr || cas_wav_posix_path[0] == '\0') {
    return MUSE_ERR_TAKE_LOAD_FAILED;
  }
  return muse_engine_register_active_take(
      engine,
      take_id_utf8,
      cas_wav_posix_path,
      start_sample_frame,
      duration_frames,
      gain_db,
      pan);
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_push_take_pcm(
    MuseEngineHandle engine,
    uint64_t epoch,
    int64_t start_sample_frame,
    uint32_t frame_count,
    uint32_t* out_pushed_frames) {
  if (frame_count > static_cast<uint32_t>(kTakePrefetchFrames)) {
    if (out_pushed_frames != nullptr) {
      *out_pushed_frames = 0u;
    }
    return MUSE_ERR_BUFFER_TOO_SMALL;
  }
  return muse_engine_push_take_playback_pcm(
      engine,
      epoch,
      start_sample_frame,
      g_take_pcm_scratch,
      frame_count,
      out_pushed_frames);
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_clear_active_takes(MuseEngineHandle engine) {
  return muse_engine_clear_active_takes(engine);
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_prepare_capture(
    MuseEngineHandle engine,
    const char* staging_wav_path) {
  if (staging_wav_path == nullptr || staging_wav_path[0] == '\0') {
    return MUSE_ERR_DEVICE_INIT;
  }
  return muse_engine_prepare_capture(engine, staging_wav_path);
}

EMSCRIPTEN_KEEPALIVE
MuseStatus muse_wasm_start_capture(MuseEngineHandle engine) {
  return muse_engine_start_capture(engine);
}

EMSCRIPTEN_KEEPALIVE
double muse_wasm_captured_playhead_frame_f64(MuseEngineHandle engine) {
  if (engine == nullptr) {
    return 0.0;
  }
  const auto& latch = engine->core.captureLatch();
  if (latch.clock_latched.load(std::memory_order_acquire)) {
    return static_cast<double>(latch.captured_playhead_frame);
  }
  return static_cast<double>(engine->core.playheadAtomic());
}

EMSCRIPTEN_KEEPALIVE
uint32_t muse_wasm_did_capture_overflow(MuseEngineHandle engine) {
  if (engine == nullptr) {
    return 0u;
  }
  return engine->core.didCaptureOverflow() ? 1u : 0u;
}

EMSCRIPTEN_KEEPALIVE
uint32_t muse_wasm_drain_telemetry(
    MuseEngineHandle engine,
    uint32_t max_frames) {
  const uint32_t clamped =
      std::min(max_frames, static_cast<uint32_t>(kTelemetryQueueCapacity));
  g_last_telemetry_count = muse_engine_drain_telemetry(
      engine, g_telemetry_scratch, clamped);
  return g_last_telemetry_count;
}

EMSCRIPTEN_KEEPALIVE
double muse_wasm_telemetry_playhead_f64(uint32_t idx) {
  if (idx >= g_last_telemetry_count) {
    return 0.0;
  }
  return static_cast<double>(g_telemetry_scratch[idx].playhead_sample_frame);
}

EMSCRIPTEN_KEEPALIVE
double muse_wasm_telemetry_epoch_f64(uint32_t idx) {
  if (idx >= g_last_telemetry_count) {
    return 0.0;
  }
  return static_cast<double>(g_telemetry_scratch[idx].active_epoch);
}

EMSCRIPTEN_KEEPALIVE
float muse_wasm_telemetry_meter_f32(uint32_t idx, uint32_t field_idx) {
  if (idx >= g_last_telemetry_count) {
    return 0.0f;
  }
  const TelemetryFrame& tf = g_telemetry_scratch[idx];
  switch (field_idx) {
    case kTelemetryMeterOutputPeakL:
      return tf.output_peak_l;
    case kTelemetryMeterOutputPeakR:
      return tf.output_peak_r;
    case kTelemetryMeterOutputRmsL:
      return tf.output_rms_l;
    case kTelemetryMeterOutputRmsR:
      return tf.output_rms_r;
    case kTelemetryMeterInputPeak:
      return tf.input_peak;
    case kTelemetryMeterInputRms:
      return tf.input_rms;
    default:
      return 0.0f;
  }
}

EMSCRIPTEN_KEEPALIVE
uint32_t muse_wasm_telemetry_flags_u32(uint32_t idx) {
  if (idx >= g_last_telemetry_count) {
    return 0u;
  }
  const TelemetryFrame& tf = g_telemetry_scratch[idx];
  uint32_t flags = 0u;
  if (tf.is_playing != 0u) {
    flags |= (1u << kTelemetryFlagIsPlayingBit);
  }
  if (tf.is_capturing != 0u) {
    flags |= (1u << kTelemetryFlagIsCapturingBit);
  }
  if (tf.event_queue_underrun != 0u) {
    flags |= (1u << kTelemetryFlagEventQueueUnderrunBit);
  }
  if (tf.capture_buffer_overflow != 0u) {
    flags |= (1u << kTelemetryFlagCaptureBufferOverflowBit);
  }
  if (tf.take_playback_underrun != 0u) {
    flags |= (1u << kTelemetryFlagTakePlaybackUnderrunBit);
  }
  const uint32_t loop_pass =
      static_cast<uint32_t>(tf.reserved[0]) |
      (static_cast<uint32_t>(tf.reserved[1]) << kTelemetryByteShiftBits);
  flags |= (loop_pass << kTelemetryLoopPassShiftBits);
  return flags;
}

} // extern "C"

#endif // defined(__EMSCRIPTEN__)

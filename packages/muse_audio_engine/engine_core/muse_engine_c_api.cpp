#include "muse_engine_c_api.h"

#include <mutex>
#include <new>

#include "audio_engine_core.h"
#include "hal_registry.h"
#include "muse_engine_opaque.h"

namespace {

struct HalRegistryState {
  std::mutex mutex;
  const IPlatformAudioHal* hal = nullptr;
  void* hal_handle = nullptr;
};

HalRegistryState& halRegistryState() noexcept {
  static HalRegistryState state;
  return state;
}

muse::engine::AudioEngineCore* unwrap(MuseEngineHandle handle) noexcept {
  return (handle != nullptr) ? &handle->core : nullptr;
}

} // namespace

void muse_engine_register_platform_hal(
    const IPlatformAudioHal* hal,
    void* hal_handle) {
  auto& state = halRegistryState();
  std::lock_guard<std::mutex> lock(state.mutex);
  state.hal = hal;
  state.hal_handle = hal_handle;
}

const IPlatformAudioHal* muse_engine_get_registered_platform_hal(
    void** out_hal_handle) {
  auto& state = halRegistryState();
  std::lock_guard<std::mutex> lock(state.mutex);
  if (out_hal_handle != nullptr) {
    *out_hal_handle = state.hal_handle;
  }
  return state.hal;
}

extern "C" {

MuseStatus muse_engine_create(
    MuseEngineHandle* out_engine,
    MuseHardwareConfig* out_hardware_config) {
  if (out_engine == nullptr || out_hardware_config == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  *out_engine = nullptr;

  void* hal_handle = nullptr;
  const IPlatformAudioHal* hal =
      muse_engine_get_registered_platform_hal(&hal_handle);
  if (hal == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }

  auto* wrapper = new (std::nothrow) MuseEngineOpaque();
  if (wrapper == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }

  const MuseStatus status =
      wrapper->core.initializeWithHal(*hal, hal_handle, out_hardware_config);
  if (status != MUSE_OK) {
    delete wrapper;
    return status;
  }

  *out_engine = wrapper;
  return MUSE_OK;
}

MuseStatus muse_engine_create_with_config(
    MuseEngineHandle* out_engine,
    const MuseHardwareConfig* explicit_config) {
  if (out_engine == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  *out_engine = nullptr;
  if (explicit_config == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }

  auto* wrapper = new (std::nothrow) MuseEngineOpaque();
  if (wrapper == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }

  const MuseStatus status =
      wrapper->core.initializeWithConfig(*explicit_config);
  if (status != MUSE_OK) {
    delete wrapper;
    return status;
  }

  *out_engine = wrapper;
  return MUSE_OK;
}

void muse_engine_destroy(MuseEngineHandle engine) {
  if (engine == nullptr) {
    return;
  }
  engine->core.dispose();
  delete engine;
}

MuseStatus muse_engine_load_sf2_file(
    MuseEngineHandle engine,
    const char* posix_path,
    int32_t* out_sf_handle,
    MuseSoundFontPresetPod* out_presets,
    uint32_t max_presets,
    uint32_t* out_preset_count) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    if (out_sf_handle != nullptr) {
      *out_sf_handle = kFluidSynthSfFailed;
    }
    if (out_preset_count != nullptr) {
      *out_preset_count = 0;
    }
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->loadSoundFontFile(
      posix_path, out_sf_handle, out_presets, max_presets, out_preset_count);
}

MuseStatus muse_engine_load_sf2_bytes(
    MuseEngineHandle engine,
    const uint8_t* bytes,
    uint32_t byte_length,
    int32_t* out_sf_handle,
    MuseSoundFontPresetPod* out_presets,
    uint32_t max_presets,
    uint32_t* out_preset_count) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    if (out_sf_handle != nullptr) {
      *out_sf_handle = kFluidSynthSfFailed;
    }
    if (out_preset_count != nullptr) {
      *out_preset_count = 0;
    }
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->loadSoundFontBytes(
      bytes, byte_length, out_sf_handle, out_presets, max_presets,
      out_preset_count);
}

MuseStatus muse_engine_unload_sf2(
    MuseEngineHandle engine,
    int32_t sf_handle) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->unloadSoundFont(sf_handle);
}

MuseStatus muse_engine_push_mutation(
    MuseEngineHandle engine,
    const MutationCommand* cmd) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr || cmd == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->pushMutation(*cmd);
}

MuseStatus muse_engine_push_events(
    MuseEngineHandle engine,
    const SynthNoteEvent* events,
    uint32_t count,
    uint32_t* out_pushed_count) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    if (out_pushed_count != nullptr) {
      *out_pushed_count = 0;
    }
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->pushEvents(events, count, out_pushed_count);
}

MuseStatus muse_engine_register_active_take(
    MuseEngineHandle engine,
    const char* take_id_utf8,
    const char* cas_wav_posix_path,
    int64_t start_sample_frame,
    int64_t duration_frames,
    float gain_db,
    float pan) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->registerActiveTake(
      take_id_utf8, cas_wav_posix_path, start_sample_frame, duration_frames,
      gain_db, pan);
}

MuseStatus muse_engine_push_take_playback_pcm(
    MuseEngineHandle engine,
    uint64_t epoch,
    int64_t start_sample_frame,
    const float* interleaved_stereo_f32,
    uint32_t frame_count,
    uint32_t* out_pushed_frames) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    if (out_pushed_frames != nullptr) {
      *out_pushed_frames = 0;
    }
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->pushTakePlaybackPcm(
      epoch, start_sample_frame, interleaved_stereo_f32, frame_count,
      out_pushed_frames);
}

MuseStatus muse_engine_clear_active_takes(MuseEngineHandle engine) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->clearActiveTakes();
}

MuseStatus muse_engine_prepare_capture(
    MuseEngineHandle engine,
    const char* staging_wav_path) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->prepareCapture(staging_wav_path);
}

MuseStatus muse_engine_start_capture(MuseEngineHandle engine) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->startCapture();
}

MuseStatus muse_engine_stop_and_finalize_capture(
    MuseEngineHandle engine,
    FinalizedCaptureReceipt* out_receipt) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    if (out_receipt != nullptr) {
      *out_receipt = FinalizedCaptureReceipt{};
      out_receipt->status = MUSE_ERR_DEVICE_INIT;
    }
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->stopAndFinalizeCapture(out_receipt);
}

uint32_t muse_engine_drain_telemetry(
    MuseEngineHandle engine,
    TelemetryFrame* out_frames,
    uint32_t max_frames) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    return 0u;
  }
  return core->drainTelemetry(out_frames, max_frames);
}

MuseStatus muse_engine_process_block(
    MuseEngineHandle engine,
    const float* input_interleaved,
    float* output_interleaved,
    uint32_t frame_count) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  return core->processBlock(input_interleaved, output_interleaved, frame_count);
}

uint32_t muse_engine_drain_capture_frames(
    MuseEngineHandle engine,
    float* out_interleaved_frames,
    uint32_t max_frames,
    int64_t* out_first_sample_clock) {
  muse::engine::AudioEngineCore* core = unwrap(engine);
  if (core == nullptr) {
    if (out_first_sample_clock != nullptr) {
      *out_first_sample_clock = 0;
    }
    return 0u;
  }
  return core->drainCaptureFrames(
      out_interleaved_frames, max_frames, out_first_sample_clock);
}

} // extern "C"

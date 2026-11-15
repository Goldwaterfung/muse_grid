#pragma once

#include <stdint.h>

#include "engine_constants.h"

#ifdef __cplusplus
#include <type_traits>
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
  char device_fingerprint[kDeviceFingerprintBufferSize];
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
} // extern "C"

static_assert(std::is_trivially_copyable_v<MuseHardwareConfig>);
static_assert(sizeof(MuseHardwareConfig) == 148);
#endif

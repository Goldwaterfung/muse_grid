#if !defined(__EMSCRIPTEN__)

#include "miniaudio_duplex_hal.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__ANDROID__)
#include <android/log.h>
#endif

#include "engine_constants.h"
#include "hal_registry.h"

namespace muse::hal {

namespace {

std::mutex& defaultHalMutex() noexcept {
  static std::mutex mutex;
  return mutex;
}

MiniaudioHalContext& defaultHalContext() noexcept {
  static MiniaudioHalContext ctx;
  return ctx;
}

MiniaudioHalContext* resolveContext(void* hal_handle) noexcept {
  if (hal_handle != nullptr) {
    return static_cast<MiniaudioHalContext*>(hal_handle);
  }
  return &defaultHalContext();
}

bool isHeadlessModeEnabled() noexcept {
  const char* env_val = std::getenv(kHeadlessAudioEnvVar);
  return env_val != nullptr &&
         std::strcmp(env_val, kHeadlessAudioEnabledValue) == 0;
}

uint32_t extractMaxNativeChannels(const ma_device_info& info) noexcept {
  uint32_t max_ch = 0;
  for (ma_uint32 i = 0; i < info.nativeDataFormatCount; ++i) {
    max_ch = std::max<uint32_t>(max_ch, info.nativeDataFormats[i].channels);
  }
  return max_ch;
}

const ma_device_info* findDefaultDeviceInfo(
    const ma_device_info* infos,
    ma_uint32 count) noexcept {
  if (infos == nullptr || count == 0) {
    return nullptr;
  }
  for (ma_uint32 i = 0; i < count; ++i) {
    if (infos[i].isDefault) {
      return &infos[i];
    }
  }
  return &infos[0];
}

void miniaudioDataCallback(
    ma_device* pDevice,
    void* pOutput,
    const void* pInput,
    ma_uint32 frameCount) {
  if (pDevice == nullptr) {
    return;
  }
  auto* ctx = static_cast<MiniaudioHalContext*>(pDevice->pUserData);
  if (ctx == nullptr || ctx->process_cb == nullptr || pOutput == nullptr) {
    if (pOutput != nullptr) {
      const uint32_t out_ch = (pDevice->playback.channels > 0)
                                  ? pDevice->playback.channels
                                  : kStereoChannelCount;
      std::memset(pOutput, 0,
                  static_cast<size_t>(frameCount) * out_ch * sizeof(float));
    }
    return;
  }
  ctx->process_cb(
      ctx->engine_ctx,
      static_cast<const float*>(pInput),
      static_cast<float*>(pOutput),
      static_cast<uint32_t>(frameCount));
}

void cleanupContextResources(MiniaudioHalContext* ctx) noexcept {
  if (ctx == nullptr) {
    return;
  }
  if (ctx->device_initialized) {
    if (ctx->running.exchange(false, std::memory_order_acq_rel)) {
      (void)ma_device_stop(&ctx->device);
    }
    ma_device_uninit(&ctx->device);
    ctx->device_initialized = false;
  }
  if (ctx->context_initialized) {
    ma_context_uninit(&ctx->context);
    ctx->context_initialized = false;
  }
  ctx->process_cb = nullptr;
  ctx->engine_ctx = nullptr;
  ctx->negotiated_input_channels = 0;
  ctx->negotiated_output_channels = 0;
  ctx->initialized.store(false, std::memory_order_release);
}

MuseStatus halInitDefault(
    void* engine_ctx,
    MuseAudioProcessCallback cb,
    MuseHardwareConfig* out_cfg) {
  std::lock_guard<std::mutex> lock(defaultHalMutex());
  return halInitWithContext(&defaultHalContext(), engine_ctx, cb, out_cfg);
}

MuseStatus halStartUnlocked(MiniaudioHalContext* ctx) {
  if (ctx == nullptr || !ctx->initialized.load(std::memory_order_acquire) ||
      !ctx->device_initialized) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (ctx->running.load(std::memory_order_acquire)) {
    return MUSE_OK;
  }
  if (ma_device_start(&ctx->device) != MA_SUCCESS) {
    return MUSE_ERR_DEVICE_INIT;
  }
  ctx->running.store(true, std::memory_order_release);
  return MUSE_OK;
}

MuseStatus halStopUnlocked(MiniaudioHalContext* ctx) {
  if (ctx == nullptr || !ctx->initialized.load(std::memory_order_acquire) ||
      !ctx->device_initialized) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (ctx->running.load(std::memory_order_acquire)) {
    if (ma_device_stop(&ctx->device) != MA_SUCCESS) {
      return MUSE_ERR_DEVICE_INIT;
    }
    ctx->running.store(false, std::memory_order_release);
  }
  return MUSE_OK;
}

ma_result initDuplexDevice(
    MiniaudioHalContext* ctx,
    ma_device_config* dev_cfg) noexcept {
#if defined(__ANDROID__)
  dev_cfg->aaudio.usage = ma_aaudio_usage_media;
  dev_cfg->playback.shareMode = ma_share_mode_exclusive;
  dev_cfg->capture.shareMode = ma_share_mode_exclusive;
  ma_result dev_rc = ma_device_init(&ctx->context, dev_cfg, &ctx->device);
  if (dev_rc != MA_SUCCESS) {
    __android_log_print(
        ANDROID_LOG_WARN,
        "MuseHal",
        "AAudio exclusive duplex init failed (ma_result=%d); falling back to shared mode",
        static_cast<int>(dev_rc));
    dev_cfg->playback.shareMode = ma_share_mode_shared;
    dev_cfg->capture.shareMode = ma_share_mode_shared;
    dev_rc = ma_device_init(&ctx->context, dev_cfg, &ctx->device);
  }
  return dev_rc;
#else
  return ma_device_init(&ctx->context, dev_cfg, &ctx->device);
#endif
}

struct DefaultMiniaudioHalRegistrar {
  DefaultMiniaudioHalRegistrar() noexcept {
    registerDefaultMiniaudioHal();
  }
};

const DefaultMiniaudioHalRegistrar kDefaultMiniaudioHalRegistrar;

} // namespace

const IPlatformAudioHal& miniaudioDuplexHal() noexcept {
  static const IPlatformAudioHal kHal{
      &halInitDefault,
      &halStart,
      &halStop,
      &halDispose,
  };
  return kHal;
}

void registerDefaultMiniaudioHal() noexcept {
  muse_engine_register_platform_hal(&miniaudioDuplexHal(), nullptr);
}

MuseStatus halInitWithContext(
    MiniaudioHalContext* ctx,
    void* engine_ctx,
    MuseAudioProcessCallback cb,
    MuseHardwareConfig* out_cfg) {
  if (ctx == nullptr || engine_ctx == nullptr || cb == nullptr ||
      out_cfg == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  *out_cfg = {};

  if (ctx->initialized.load(std::memory_order_acquire)) {
    return MUSE_ERR_DEVICE_INIT;
  }

  const bool is_headless = isHeadlessModeEnabled();
  ma_context_config ctx_cfg = ma_context_config_init();

  if (is_headless) {
    ma_backend backends[] = {ma_backend_null};
    if (ma_context_init(backends, 1, &ctx_cfg, &ctx->context) != MA_SUCCESS) {
      return MUSE_ERR_DEVICE_INIT;
    }
  } else {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    ctx_cfg.coreaudio.sessionCategory = ma_ios_session_category_play_and_record;
    ctx_cfg.coreaudio.sessionCategoryOptions =
        ma_ios_session_category_option_default_to_speaker |
        ma_ios_session_category_option_allow_bluetooth |
        ma_ios_session_category_option_allow_bluetooth_a2dp |
        ma_ios_session_category_option_allow_air_play;
#endif
    if (ma_context_init(nullptr, 0, &ctx_cfg, &ctx->context) != MA_SUCCESS) {
      return MUSE_ERR_DEVICE_INIT;
    }
  }
  ctx->context_initialized = true;

  ma_device_config dev_cfg = ma_device_config_init(ma_device_type_duplex);
  dev_cfg.sampleRate = 0; // Negotiate native device sample rate
  dev_cfg.periodSizeInFrames = 0; // Negotiate native period size
  dev_cfg.performanceProfile = ma_performance_profile_low_latency;
  dev_cfg.playback.format = ma_format_f32;
  dev_cfg.capture.format = ma_format_f32;
  dev_cfg.pUserData = ctx;
  dev_cfg.dataCallback = &miniaudioDataCallback;

  bool allow_capture_clamp_retry = false;
  if (is_headless) {
    dev_cfg.playback.channels = kStereoChannelCount;
    dev_cfg.capture.channels = kMonoChannelCount;
  } else {
    ma_device_info* pb_infos = nullptr;
    ma_uint32 pb_count = 0;
    ma_device_info* cap_infos = nullptr;
    ma_uint32 cap_count = 0;
    if (ma_context_get_devices(&ctx->context, &pb_infos, &pb_count, &cap_infos,
                               &cap_count) != MA_SUCCESS ||
        pb_count == 0 || cap_count == 0) {
      cleanupContextResources(ctx);
      return MUSE_ERR_DEVICE_INIT;
    }

    const ma_device_info* default_pb = findDefaultDeviceInfo(pb_infos, pb_count);
    const ma_device_info* default_cap =
        findDefaultDeviceInfo(cap_infos, cap_count);
    if (default_pb == nullptr || default_cap == nullptr) {
      cleanupContextResources(ctx);
      return MUSE_ERR_DEVICE_INIT;
    }

    ma_device_info full_pb{};
    if (ma_context_get_device_info(&ctx->context, ma_device_type_playback,
                                   &default_pb->id, &full_pb) != MA_SUCCESS ||
        full_pb.nativeDataFormatCount == 0) {
      cleanupContextResources(ctx);
      return MUSE_ERR_DEVICE_INIT;
    }
    const uint32_t native_pb_channels = extractMaxNativeChannels(full_pb);
    dev_cfg.playback.channels =
        (native_pb_channels == 0 || native_pb_channels > kStereoChannelCount)
            ? kStereoChannelCount
            : native_pb_channels;

    ma_device_info full_cap{};
    if (ma_context_get_device_info(&ctx->context, ma_device_type_capture,
                                   &default_cap->id, &full_cap) != MA_SUCCESS ||
        full_cap.nativeDataFormatCount == 0) {
      cleanupContextResources(ctx);
      return MUSE_ERR_DEVICE_INIT;
    }
    const uint32_t native_cap_channels = extractMaxNativeChannels(full_cap);
    if (native_cap_channels > kMaxCaptureChannels) {
      dev_cfg.capture.channels = kMaxCaptureChannels;
    } else if (native_cap_channels >= kMonoChannelCount) {
      dev_cfg.capture.channels = native_cap_channels;
    } else {
      // Backend reported channels == 0 ("any channel count supported"); let
      // miniaudio negotiate native capture channels and clamp if needed.
      dev_cfg.capture.channels = 0;
      allow_capture_clamp_retry = true;
    }
  }

  ma_result dev_rc = initDuplexDevice(ctx, &dev_cfg);
  if (dev_rc == MA_SUCCESS && allow_capture_clamp_retry &&
      ctx->device.capture.channels > kMaxCaptureChannels) {
    ma_device_uninit(&ctx->device);
    dev_cfg.capture.channels = kMaxCaptureChannels;
    dev_rc = initDuplexDevice(ctx, &dev_cfg);
  }

  if (dev_rc != MA_SUCCESS) {
    cleanupContextResources(ctx);
    return MUSE_ERR_DEVICE_INIT;
  }
  ctx->device_initialized = true;

  if (ctx->device.sampleRate == 0 || ctx->device.playback.channels == 0 ||
      ctx->device.capture.channels == 0 ||
      ctx->device.capture.channels > kMaxCaptureChannels ||
      ctx->device.playback.internalPeriodSizeInFrames == 0) {
    cleanupContextResources(ctx);
    return MUSE_ERR_DEVICE_INIT;
  }

  out_cfg->sample_rate = ctx->device.sampleRate;
  out_cfg->input_channels = ctx->device.capture.channels;
  out_cfg->output_channels = ctx->device.playback.channels;
  out_cfg->input_buffer_frames =
      (ctx->device.capture.internalPeriodSizeInFrames > 0)
          ? ctx->device.capture.internalPeriodSizeInFrames
          : ctx->device.playback.internalPeriodSizeInFrames;
  out_cfg->output_buffer_frames =
      ctx->device.playback.internalPeriodSizeInFrames;

  if (is_headless) {
    std::snprintf(out_cfg->device_fingerprint,
                  sizeof(out_cfg->device_fingerprint), "%s",
                  kHeadlessDeviceFingerprint);
  } else {
    ma_device_info pb_info{};
    if (ma_device_get_info(&ctx->device, ma_device_type_playback, &pb_info) ==
            MA_SUCCESS &&
        pb_info.name[0] != '\0') {
      std::snprintf(out_cfg->device_fingerprint,
                    sizeof(out_cfg->device_fingerprint), "%s", pb_info.name);
    } else {
      std::snprintf(out_cfg->device_fingerprint,
                    sizeof(out_cfg->device_fingerprint), "%s",
                    kUnknownDeviceFingerprint);
    }
  }

  ctx->negotiated_input_channels = ctx->device.capture.channels;
  ctx->negotiated_output_channels = ctx->device.playback.channels;
  ctx->process_cb = cb;
  ctx->engine_ctx = engine_ctx;
  ctx->running.store(false, std::memory_order_release);
  ctx->initialized.store(true, std::memory_order_release);
  return MUSE_OK;
}

MuseStatus halStart(void* hal_handle) {
  if (hal_handle == nullptr) {
    std::lock_guard<std::mutex> lock(defaultHalMutex());
    return halStartUnlocked(resolveContext(nullptr));
  }
  return halStartUnlocked(resolveContext(hal_handle));
}

MuseStatus halStop(void* hal_handle) {
  if (hal_handle == nullptr) {
    std::lock_guard<std::mutex> lock(defaultHalMutex());
    return halStopUnlocked(resolveContext(nullptr));
  }
  return halStopUnlocked(resolveContext(hal_handle));
}

void halDispose(void* hal_handle) {
  if (hal_handle == nullptr) {
    std::lock_guard<std::mutex> lock(defaultHalMutex());
    cleanupContextResources(resolveContext(nullptr));
    return;
  }
  cleanupContextResources(resolveContext(hal_handle));
}

} // namespace muse::hal

#endif // !defined(__EMSCRIPTEN__)

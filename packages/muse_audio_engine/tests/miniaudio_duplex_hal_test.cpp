#include <catch2/catch_test_macros.hpp>

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#include "engine_constants.h"
#include "hal_registry.h"
#include "miniaudio_duplex_hal.h"
#include "muse_engine_c_api.h"

namespace {

class ScopedEnvVar {
 public:
  ScopedEnvVar(const char* name, const char* value) : name_(name) {
    const char* existing = std::getenv(name);
    if (existing != nullptr) {
      had_previous_ = true;
      previous_ = existing;
    }
    setEnv(name_.c_str(), value);
  }

  ~ScopedEnvVar() {
    if (had_previous_) {
      setEnv(name_.c_str(), previous_.c_str());
    } else {
      unsetEnv(name_.c_str());
    }
  }

  ScopedEnvVar(const ScopedEnvVar&) = delete;
  ScopedEnvVar& operator=(const ScopedEnvVar&) = delete;

 private:
  static void setEnv(const char* name, const char* value) {
#if defined(_WIN32)
    _putenv_s(name, value != nullptr ? value : "");
#else
    if (value != nullptr) {
      ::setenv(name, value, 1);
    } else {
      ::unsetenv(name);
    }
#endif
  }

  static void unsetEnv(const char* name) {
#if defined(_WIN32)
    _putenv_s(name, "");
#else
    ::unsetenv(name);
#endif
  }

  std::string name_;
  bool had_previous_ = false;
  std::string previous_;
};

struct EngineGuard {
  MuseEngineHandle handle = nullptr;
  ~EngineGuard() {
    if (handle != nullptr) {
      muse_engine_destroy(handle);
    }
  }
};

void noopProcessCallback(
    void* /*user_data*/,
    const float* /*input_interleaved*/,
    float* output_interleaved,
    uint32_t frame_count) {
  if (output_interleaved != nullptr) {
    std::memset(output_interleaved, 0,
                static_cast<size_t>(frame_count) * kStereoChannelCount *
                    sizeof(float));
  }
}

} // namespace

TEST_CASE(
    "MiniaudioDuplexHal auto-registers and negotiates headless duplex config",
    "[hal][miniaudio]") {
  ScopedEnvVar headless_env(kHeadlessAudioEnvVar, kHeadlessAudioEnabledValue);

  void* registered_handle = reinterpret_cast<void*>(0x1);
  const IPlatformAudioHal* hal =
      muse_engine_get_registered_platform_hal(&registered_handle);
  REQUIRE(hal != nullptr);
  REQUIRE(registered_handle == nullptr);

  EngineGuard engine;
  MuseHardwareConfig cfg{};
  REQUIRE(muse_engine_create(&engine.handle, &cfg) == MUSE_OK);
  REQUIRE(engine.handle != nullptr);
  CHECK(cfg.sample_rate > 0);
  CHECK(cfg.input_channels >= 1);
  CHECK(cfg.input_channels <= kMaxCaptureChannels);
  CHECK(cfg.output_channels == kStereoChannelCount);
  CHECK(cfg.input_buffer_frames > 0);
  CHECK(cfg.output_buffer_frames > 0);
  CHECK(std::string(cfg.device_fingerprint) == kHeadlessDeviceFingerprint);
}

TEST_CASE(
    "MiniaudioDuplexHal fails closed on double active init and allows re-init after destroy",
    "[hal][miniaudio]") {
  ScopedEnvVar headless_env(kHeadlessAudioEnvVar, kHeadlessAudioEnabledValue);

  EngineGuard first;
  MuseHardwareConfig first_cfg{};
  REQUIRE(muse_engine_create(&first.handle, &first_cfg) == MUSE_OK);

  // Double init against the single active default session slot must fail closed.
  MuseEngineHandle second = nullptr;
  MuseHardwareConfig second_cfg{};
  CHECK(muse_engine_create(&second, &second_cfg) == MUSE_ERR_DEVICE_INIT);
  CHECK(second == nullptr);

  const IPlatformAudioHal& hal = muse::hal::miniaudioDuplexHal();
  int dummy_ctx = 0;
  CHECK(hal.init(&dummy_ctx, &noopProcessCallback, &second_cfg) ==
        MUSE_ERR_DEVICE_INIT);

  muse_engine_destroy(first.handle);
  first.handle = nullptr;

  EngineGuard reinitialized;
  MuseHardwareConfig reinit_cfg{};
  REQUIRE(muse_engine_create(&reinitialized.handle, &reinit_cfg) == MUSE_OK);
  CHECK(std::string(reinit_cfg.device_fingerprint) ==
        kHeadlessDeviceFingerprint);
}

TEST_CASE(
    "MiniaudioDuplexHal drives live RT callbacks and advances playhead telemetry",
    "[hal][miniaudio]") {
  ScopedEnvVar headless_env(kHeadlessAudioEnvVar, kHeadlessAudioEnabledValue);

  EngineGuard engine;
  MuseHardwareConfig cfg{};
  REQUIRE(muse_engine_create(&engine.handle, &cfg) == MUSE_OK);

  MutationCommand play_cmd{};
  play_cmd.type = MUT_SET_PLAYING;
  play_cmd.flag_a = 1;
  REQUIRE(muse_engine_push_mutation(engine.handle, &play_cmd) == MUSE_OK);

  std::vector<TelemetryFrame> frames(kTelemetryQueueCapacity);
  int64_t latest_playhead = 0;
  bool observed_playing = false;

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < deadline) {
    const uint32_t drained = muse_engine_drain_telemetry(
        engine.handle, frames.data(), static_cast<uint32_t>(frames.size()));
    for (uint32_t i = 0; i < drained; ++i) {
      if (frames[i].is_playing != 0) {
        observed_playing = true;
      }
      if (frames[i].playhead_sample_frame > latest_playhead) {
        latest_playhead = frames[i].playhead_sample_frame;
      }
    }
    if (observed_playing && latest_playhead > 0) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }

  CHECK(observed_playing);
  CHECK(latest_playhead > 0);
}

TEST_CASE(
    "MiniaudioDuplexHal fails closed on invalid parameters and uninitialized start/stop",
    "[hal][miniaudio]") {
  ScopedEnvVar headless_env(kHeadlessAudioEnvVar, kHeadlessAudioEnabledValue);

  muse::hal::MiniaudioHalContext isolated_ctx;
  MuseHardwareConfig out_cfg{};
  int dummy_engine = 0;

  CHECK(muse::hal::halInitWithContext(nullptr, &dummy_engine,
                                      &noopProcessCallback,
                                      &out_cfg) == MUSE_ERR_DEVICE_INIT);
  CHECK(muse::hal::halInitWithContext(&isolated_ctx, nullptr,
                                      &noopProcessCallback,
                                      &out_cfg) == MUSE_ERR_DEVICE_INIT);
  CHECK(muse::hal::halInitWithContext(&isolated_ctx, &dummy_engine, nullptr,
                                      &out_cfg) == MUSE_ERR_DEVICE_INIT);
  CHECK(muse::hal::halInitWithContext(&isolated_ctx, &dummy_engine,
                                      &noopProcessCallback,
                                      nullptr) == MUSE_ERR_DEVICE_INIT);

  CHECK(muse::hal::halStart(nullptr) == MUSE_ERR_DEVICE_INIT);
  CHECK(muse::hal::halStop(nullptr) == MUSE_ERR_DEVICE_INIT);
  muse::hal::halDispose(nullptr);

  CHECK(muse::hal::halStart(&isolated_ctx) == MUSE_ERR_DEVICE_INIT);
  CHECK(muse::hal::halStop(&isolated_ctx) == MUSE_ERR_DEVICE_INIT);
  muse::hal::halDispose(&isolated_ctx);

  REQUIRE(muse::hal::halInitWithContext(&isolated_ctx, &dummy_engine,
                                        &noopProcessCallback,
                                        &out_cfg) == MUSE_OK);
  CHECK(muse::hal::halInitWithContext(&isolated_ctx, &dummy_engine,
                                      &noopProcessCallback,
                                      &out_cfg) == MUSE_ERR_DEVICE_INIT);
  REQUIRE(muse::hal::halStart(&isolated_ctx) == MUSE_OK);
  REQUIRE(muse::hal::halStop(&isolated_ctx) == MUSE_OK);
  muse::hal::halDispose(&isolated_ctx);
  // Idempotent dispose on already-disposed context.
  muse::hal::halDispose(&isolated_ctx);
}

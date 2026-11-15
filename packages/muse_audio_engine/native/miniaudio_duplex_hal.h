#pragma once

#if !defined(__EMSCRIPTEN__)

#include <atomic>
#include <cstdint>

#include <miniaudio.h>

#include "hal_contract.h"

namespace muse::hal {

/// Non-RT owner state for one `miniaudio` full-duplex audio session.
struct MiniaudioHalContext {
  MiniaudioHalContext() = default;
  ~MiniaudioHalContext() = default;

  MiniaudioHalContext(const MiniaudioHalContext&) = delete;
  MiniaudioHalContext& operator=(const MiniaudioHalContext&) = delete;
  MiniaudioHalContext(MiniaudioHalContext&&) = delete;
  MiniaudioHalContext& operator=(MiniaudioHalContext&&) = delete;

  std::atomic<bool> initialized{false};
  std::atomic<bool> running{false};
  ma_context context{};
  bool context_initialized = false;
  ma_device device{};
  bool device_initialized = false;
  MuseAudioProcessCallback process_cb = nullptr;
  void* engine_ctx = nullptr;
  uint32_t negotiated_input_channels = 0;
  uint32_t negotiated_output_channels = 0;
};

/// Returns the singleton `IPlatformAudioHal` vtable backed by `miniaudio`.
const IPlatformAudioHal& miniaudioDuplexHal() noexcept;

/// Registers `miniaudioDuplexHal()` as the default process HAL (`hal_handle = nullptr`).
void registerDefaultMiniaudioHal() noexcept;

/// Initializes an explicit or default `MiniaudioHalContext` in full-duplex mode.
MuseStatus halInitWithContext(
    MiniaudioHalContext* ctx,
    void* engine_ctx,
    MuseAudioProcessCallback cb,
    MuseHardwareConfig* out_cfg);

/// Starts the `miniaudio` duplex device for `hal_handle` (or default context when null).
MuseStatus halStart(void* hal_handle);

/// Stops the `miniaudio` duplex device for `hal_handle` (or default context when null).
MuseStatus halStop(void* hal_handle);

/// Idempotently stops and uninitializes the `miniaudio` device and context.
void halDispose(void* hal_handle);

} // namespace muse::hal

#endif // !defined(__EMSCRIPTEN__)

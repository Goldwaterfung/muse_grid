#pragma once

#include "hal_contract.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Registers the active Layer 1 platform HAL implementation and optional opaque
/// handle used by `muse_engine_create()`. Kept outside `hal_contract.h` and
/// `muse_engine_c_api.h` so `ffigen` emits only the public C ABI.
void muse_engine_register_platform_hal(
    const IPlatformAudioHal* hal,
    void* hal_handle);

/// Retrieves the currently registered Layer 1 platform HAL (or `nullptr` if
/// none is registered).
const IPlatformAudioHal* muse_engine_get_registered_platform_hal(
    void** out_hal_handle);

#ifdef __cplusplus
} // extern "C"
#endif

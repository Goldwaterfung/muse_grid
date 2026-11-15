#pragma once

#include "audio_engine_core.h"

/// Private C++ backing definition for the opaque C11 handle `MuseEngineHandle`.
struct MuseEngineOpaque final {
  muse::engine::AudioEngineCore core;
};

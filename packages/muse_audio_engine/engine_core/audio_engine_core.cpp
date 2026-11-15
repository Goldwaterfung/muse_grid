#include "audio_engine_core.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

#if !defined(__EMSCRIPTEN__)
#include "butler_worker.h"
#endif

#if defined(__SSE__) || defined(_M_X64) || defined(_M_IX86)
#include <xmmintrin.h>
#if defined(__SSE3__) || defined(_M_X64) || defined(_M_IX86)
#include <pmmintrin.h>
#endif
#endif

namespace muse::engine {

namespace {

// URI prefix identifying stack-pinned in-memory SoundFont byte slices passed to
// FluidSynth's custom sfloader during loadSoundFontBytes().
constexpr char kMemorySf2UriPrefix[] = "muse-mem://";
constexpr size_t kMemorySf2UriPrefixLen = sizeof(kMemorySf2UriPrefix) - 1;
constexpr uint32_t kMemorySf2Magic = 0x4D555345u; // 'MUSE'
constexpr size_t kMemorySf2UriBufferSize = 64;
constexpr uint32_t kTakePushBatchChunkFrames = 256;

struct MemorySf2Slice {
  uint32_t magic = 0;
  const uint8_t* data = nullptr;
  uint32_t size = 0;
};

struct MemorySf2Stream {
  const uint8_t* data = nullptr;
  size_t size = 0;
  size_t cursor = 0;
};

void* memSf2Open(const char* filename) {
  if (filename == nullptr ||
      std::strncmp(filename, kMemorySf2UriPrefix, kMemorySf2UriPrefixLen) != 0) {
    return nullptr;
  }
  const char* hex_ptr = filename + kMemorySf2UriPrefixLen;
  if (*hex_ptr == '\0') {
    return nullptr;
  }
  char* end_ptr = nullptr;
  const unsigned long long addr = std::strtoull(hex_ptr, &end_ptr, 16);
  if (end_ptr == hex_ptr || end_ptr == nullptr || *end_ptr != '\0' || addr == 0) {
    return nullptr;
  }
  const auto* slice = reinterpret_cast<const MemorySf2Slice*>(
      static_cast<uintptr_t>(addr));
  if (slice->magic != kMemorySf2Magic || slice->data == nullptr ||
      slice->size == 0) {
    return nullptr;
  }
  return new MemorySf2Stream{slice->data, static_cast<size_t>(slice->size), 0};
}

int memSf2Read(void* buf, fluid_long_long_t count, void* handle) {
  if (buf == nullptr || handle == nullptr || count < 0) {
    return FLUID_FAILED;
  }
  auto* stream = static_cast<MemorySf2Stream*>(handle);
  const size_t bytes_requested = static_cast<size_t>(count);
  if (bytes_requested > stream->size - stream->cursor) {
    return FLUID_FAILED;
  }
  if (bytes_requested > 0) {
    std::memcpy(buf, stream->data + stream->cursor, bytes_requested);
    stream->cursor += bytes_requested;
  }
  return FLUID_OK;
}

int memSf2Seek(void* handle, fluid_long_long_t offset, int origin) {
  if (handle == nullptr) {
    return FLUID_FAILED;
  }
  auto* stream = static_cast<MemorySf2Stream*>(handle);
  fluid_long_long_t new_pos = 0;
  switch (origin) {
    case SEEK_SET:
      new_pos = offset;
      break;
    case SEEK_CUR:
      new_pos = static_cast<fluid_long_long_t>(stream->cursor) + offset;
      break;
    case SEEK_END:
      new_pos = static_cast<fluid_long_long_t>(stream->size) + offset;
      break;
    default:
      return FLUID_FAILED;
  }
  if (new_pos < 0 || static_cast<size_t>(new_pos) > stream->size) {
    return FLUID_FAILED;
  }
  stream->cursor = static_cast<size_t>(new_pos);
  return FLUID_OK;
}

int memSf2Close(void* handle) {
  delete static_cast<MemorySf2Stream*>(handle);
  return FLUID_OK;
}

fluid_long_long_t memSf2Tell(void* handle) {
  if (handle == nullptr) {
    return FLUID_FAILED;
  }
  const auto* stream = static_cast<const MemorySf2Stream*>(handle);
  return static_cast<fluid_long_long_t>(stream->cursor);
}

void enableHardwareDenormalProtection() noexcept {
  thread_local bool tl_denormals_configured = false;
  if (tl_denormals_configured) {
    return;
  }
  tl_denormals_configured = true;
#if defined(__aarch64__) && (defined(__clang__) || defined(__GNUC__))
  uint64_t fpcr = 0;
  __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
  fpcr |= (uint64_t{1} << kAarch64FpcrFlushToZeroBit);
  __asm__ __volatile__("msr fpcr, %0" : : "r"(fpcr));
#elif defined(__SSE__) || defined(_M_X64) || defined(_M_IX86)
  _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
#ifdef _MM_SET_DENORMALS_ZERO_MODE
  _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
#endif
#endif
}

} // namespace

AudioEngineCore::AudioEngineCore() noexcept {
  resetAllState();
}

AudioEngineCore::~AudioEngineCore() {
  dispose();
}

void AudioEngineCore::resetAllState() noexcept {
  hardware_config_ = {};
  hal_ = nullptr;
  hal_handle_ = nullptr;
  mutation_queue_.reset();
  event_queue_.reset();
  audition_queue_.reset();
  capture_ring_buffer_.reset();
  take_playback_ring_buffer_.reset();
  take_playback_valid_from_idx_.store(0, std::memory_order_release);
  telemetry_queue_.reset();
  for (auto& ch : synth_chan_left_) {
    ch.fill(0.0f);
  }
  for (auto& ch : synth_chan_right_) {
    ch.fill(0.0f);
  }
  synth_left_.fill(0.0f);
  synth_right_.fill(0.0f);
  capture_scratch_.fill(0.0f);
  for (auto& slot_set : take_windows_) {
    for (auto& w : slot_set) {
      w = TakeWindowRange{};
    }
  }
  active_take_window_idx_.store(0, std::memory_order_release);
  resetRtState();
  resetCaptureStateForPrepare();
  transport_seq_.store(0, std::memory_order_release);
  playhead_atomic_.store(0, std::memory_order_release);
  active_epoch_atomic_.store(0, std::memory_order_release);
  seek_generation_atomic_.store(0, std::memory_order_release);
  rendered_playback_frames_atomic_.store(0, std::memory_order_release);
  is_playing_atomic_.store(false, std::memory_order_release);
  is_capturing_atomic_.store(false, std::memory_order_release);
  capture_active_atomic_.store(false, std::memory_order_release);
  capture_overflowed_atomic_.store(false, std::memory_order_release);
  loop_enabled_atomic_.store(false, std::memory_order_release);
  loop_start_atomic_.store(0, std::memory_order_release);
  loop_end_atomic_.store(0, std::memory_order_release);
  capture_owned_by_butler_.store(false, std::memory_order_release);
  capture_prepared_without_butler_.store(false, std::memory_order_release);
  butler_wake_requested_.store(false, std::memory_order_release);
  hal_running_.store(false, std::memory_order_release);
  initialized_.store(false, std::memory_order_release);
  synth_suspend_requested_.store(false, std::memory_order_release);
  synth_suspend_seq_.store(0, std::memory_order_release);
  synth_suspend_ack_seq_.store(0, std::memory_order_release);
}

void AudioEngineCore::resetRtState() noexcept {
  rt_ = RtEngineState{};
  const float unity_gain = dsp::dbToLinear(kDefaultGainDb);
  const dsp::StereoPanGains center_pan = dsp::computeConstantPowerPan(kCenterPan);
  for (auto& mix : rt_.channel_mix) {
    mix.linear_gain = unity_gain;
    mix.pan_left = center_pan.left;
    mix.pan_right = center_pan.right;
  }
}

void AudioEngineCore::resetCaptureStateForPrepare() noexcept {
  capture_ring_buffer_.reset();
  capture_latch_.clock_latched.store(false, std::memory_order_release);
  capture_latch_.captured_sample_clock = 0;
  capture_latch_.captured_playhead_frame = 0;
  capture_latch_.output_buffer_frames = hardware_config_.output_buffer_frames;
  capture_latch_.input_buffer_frames = hardware_config_.input_buffer_frames;
  capture_latch_.total_frames_drained_via_c_api = 0;
  capture_overflowed_atomic_.store(false, std::memory_order_release);
}

void AudioEngineCore::clearCaptureActiveFlagsIfOffline() noexcept {
  if (!hal_running_.load(std::memory_order_acquire)) {
    is_capturing_atomic_.store(false, std::memory_order_release);
    capture_active_atomic_.store(false, std::memory_order_release);
  }
}

bool AudioEngineCore::isValidHardwareConfig(
    const MuseHardwareConfig& cfg) noexcept {
  if (cfg.sample_rate < static_cast<uint32_t>(kMinSynthSampleRate) ||
      cfg.sample_rate > static_cast<uint32_t>(kMaxSynthSampleRate)) {
    return false;
  }
  if (cfg.output_channels == 0 || cfg.input_channels > kMaxCaptureChannels ||
      cfg.output_buffer_frames == 0) {
    return false;
  }
  return true;
}

MuseStatus AudioEngineCore::initializeWithHal(
    const IPlatformAudioHal& hal,
    void* hal_handle,
    MuseHardwareConfig* out_cfg) {
  if (out_cfg == nullptr || hal.init == nullptr || hal.start == nullptr ||
      hal.stop == nullptr || hal.dispose == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (initialized_.load(std::memory_order_acquire)) {
    return MUSE_ERR_DEVICE_INIT;
  }

  resetAllState();
  *out_cfg = {};

  MuseHardwareConfig cfg{};
  const MuseStatus init_status =
      hal.init(this, &AudioEngineCore::audioHalCallback, &cfg);
  if (init_status != MUSE_OK) {
    return init_status;
  }
  if (!isValidHardwareConfig(cfg)) {
    hal.dispose(hal_handle);
    return MUSE_ERR_DEVICE_INIT;
  }

  hardware_config_ = cfg;
  hardware_config_.device_fingerprint[kDeviceFingerprintBufferSize - 1] = '\0';

  const MuseStatus synth_status = initFluidSynth(hardware_config_.sample_rate);
  if (synth_status != MUSE_OK) {
    hal.dispose(hal_handle);
    resetAllState();
    return synth_status;
  }

  const MuseStatus butler_status = startButlerIfSupported();
  if (butler_status != MUSE_OK) {
    destroyFluidSynth();
    hal.dispose(hal_handle);
    resetAllState();
    return butler_status;
  }

  hal_ = &hal;
  hal_handle_ = hal_handle;
  initialized_.store(true, std::memory_order_release);
  hal_running_.store(true, std::memory_order_release);

  const MuseStatus start_status = hal.start(hal_handle);
  if (start_status != MUSE_OK) {
    hal_running_.store(false, std::memory_order_release);
    initialized_.store(false, std::memory_order_release);
    stopAndJoinButler();
    destroyFluidSynth();
    hal.dispose(hal_handle);
    hal_ = nullptr;
    hal_handle_ = nullptr;
    resetAllState();
    return start_status;
  }

  *out_cfg = hardware_config_;
  return MUSE_OK;
}

MuseStatus AudioEngineCore::initializeWithConfig(
    const MuseHardwareConfig& explicit_cfg) {
  if (initialized_.load(std::memory_order_acquire) ||
      !isValidHardwareConfig(explicit_cfg)) {
    return MUSE_ERR_DEVICE_INIT;
  }

  resetAllState();
  hardware_config_ = explicit_cfg;
  hardware_config_.device_fingerprint[kDeviceFingerprintBufferSize - 1] = '\0';

  const MuseStatus synth_status = initFluidSynth(hardware_config_.sample_rate);
  if (synth_status != MUSE_OK) {
    resetAllState();
    return synth_status;
  }

  const MuseStatus butler_status = startButlerIfSupported();
  if (butler_status != MUSE_OK) {
    destroyFluidSynth();
    resetAllState();
    return butler_status;
  }

  hal_ = nullptr;
  hal_handle_ = nullptr;
  hal_running_.store(false, std::memory_order_release);
  initialized_.store(true, std::memory_order_release);
  return MUSE_OK;
}

void AudioEngineCore::dispose() {
  if (hal_ != nullptr) {
    if (hal_running_.exchange(false, std::memory_order_acq_rel)) {
      if (hal_->stop != nullptr) {
        (void)hal_->stop(hal_handle_);
      }
    }
    if (hal_->dispose != nullptr) {
      hal_->dispose(hal_handle_);
    }
    hal_ = nullptr;
    hal_handle_ = nullptr;
  } else {
    hal_running_.store(false, std::memory_order_release);
  }

  stopAndJoinButler();
  {
    std::lock_guard<std::mutex> lock(synth_control_mutex_);
    destroyFluidSynth();
  }
  initialized_.store(false, std::memory_order_release);
  capture_owned_by_butler_.store(false, std::memory_order_release);
  capture_prepared_without_butler_.store(false, std::memory_order_release);
}

MuseStatus AudioEngineCore::startButlerIfSupported() {
#if !defined(__EMSCRIPTEN__)
  butler_worker_ = std::make_unique<ButlerWorker>(*this);
  const MuseStatus st = butler_worker_->start();
  if (st != MUSE_OK) {
    butler_worker_.reset();
    return st;
  }
#endif
  return MUSE_OK;
}

void AudioEngineCore::stopAndJoinButler() noexcept {
#if !defined(__EMSCRIPTEN__)
  if (butler_worker_) {
    butler_worker_->stop();
    butler_worker_.reset();
  }
#endif
}

MuseStatus AudioEngineCore::initFluidSynth(uint32_t sample_rate) {
  destroyFluidSynth();

  settings_ = new_fluid_settings();
  if (settings_ == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }

  fluid_settings_setnum(settings_, "synth.sample-rate",
                        static_cast<double>(sample_rate));
  fluid_settings_setint(settings_, "synth.threadsafe-api", 0);
  fluid_settings_setint(settings_, "synth.midi-channels",
                        static_cast<int>(kMidiChannelCount));
  fluid_settings_setint(settings_, "synth.audio-channels",
                        static_cast<int>(kMidiChannelCount));
  fluid_settings_setint(settings_, "synth.audio-groups",
                        static_cast<int>(kFluidAudioGroups));
  fluid_settings_setint(settings_, "synth.effects-channels",
                        static_cast<int>(kFluidEffectsChannelsPerGroup));
  fluid_settings_setint(settings_, "synth.effects-groups",
                        static_cast<int>(kFluidEffectsGroups));
  fluid_settings_setnum(
      settings_, "synth.gain",
      static_cast<double>(dsp::dbToLinear(kDefaultSynthHeadroomDb)));
  fluid_settings_setint(settings_, "synth.polyphony",
                        static_cast<int>(kDefaultSynthPolyphony));

  synth_ = new_fluid_synth(settings_);
  if (synth_ == nullptr) {
    destroyFluidSynth();
    return MUSE_ERR_DEVICE_INIT;
  }

  // Register custom memory SF2 loader before any SoundFont loads.
  fluid_sfloader_t* mem_loader = new_fluid_defsfloader(settings_);
  if (mem_loader == nullptr) {
    destroyFluidSynth();
    return MUSE_ERR_DEVICE_INIT;
  }
  if (fluid_sfloader_set_callbacks(mem_loader, &memSf2Open, &memSf2Read,
                                   &memSf2Seek, &memSf2Tell,
                                   &memSf2Close) != FLUID_OK) {
    delete_fluid_sfloader(mem_loader);
    destroyFluidSynth();
    return MUSE_ERR_DEVICE_INIT;
  }
  fluid_synth_add_sfloader(synth_, mem_loader);
  return MUSE_OK;
}

void AudioEngineCore::destroyFluidSynth() noexcept {
  if (synth_ != nullptr) {
    delete_fluid_synth(synth_);
    synth_ = nullptr;
  }
  if (settings_ != nullptr) {
    delete_fluid_settings(settings_);
    settings_ = nullptr;
  }
}

MuseStatus AudioEngineCore::pushMutation(const MutationCommand& cmd) {
  if (!initialized_.load(std::memory_order_acquire)) {
    return MUSE_ERR_DEVICE_INIT;
  }

  switch (cmd.type) {
    case MUT_SET_PLAYING:
    case MUT_FLUSH_AND_ADVANCE_EPOCH:
    case MUT_SET_CAPTURE_STATE:
    case MUT_SET_SYNTH_SUSPENDED:
      break;
    case MUT_SEEK_SAMPLE:
      if (cmd.sample_frame_a < 0) {
        return MUSE_ERR_DEVICE_INIT;
      }
      break;
    case MUT_SET_LOOP_REGION:
      if (cmd.sample_frame_a < 0 ||
          (cmd.flag_a != 0 && cmd.sample_frame_b <= cmd.sample_frame_a)) {
        return MUSE_ERR_DEVICE_INIT;
      }
      break;
    case MUT_ASSIGN_CHANNEL_PATCH:
      if (cmd.channel > kMaxMidiChannel || cmd.int_param_a <= 0 ||
          cmd.int_param_b < 0 ||
          cmd.int_param_b > static_cast<int32_t>(kMaxBankNum) ||
          cmd.int_param_c < 0 ||
          cmd.int_param_c > static_cast<int32_t>(kMaxProgramNum)) {
        return MUSE_ERR_DEVICE_INIT;
      }
      break;
    case MUT_SET_CHANNEL_MIX:
      if (cmd.channel > kMaxMidiChannel || !std::isfinite(cmd.float_param_a) ||
          !std::isfinite(cmd.float_param_b)) {
        return MUSE_ERR_DEVICE_INIT;
      }
      break;
    case MUT_ALL_NOTES_OFF_CHANNEL:
      if (cmd.channel > kMaxMidiChannel) {
        return MUSE_ERR_DEVICE_INIT;
      }
      break;
    case MUT_SET_MONITOR_GAIN:
      if (!std::isfinite(cmd.float_param_a) || cmd.float_param_a < 0.0f) {
        return MUSE_ERR_DEVICE_INIT;
      }
      break;
    case MUT_SET_SCHEDULED_WATERMARK:
      if (cmd.sample_frame_a < 0) {
        return MUSE_ERR_DEVICE_INIT;
      }
      break;
    default:
      return MUSE_ERR_DEVICE_INIT;
  }

  {
    std::lock_guard<std::mutex> lock(mutation_producer_mutex_);
    if (!mutation_queue_.tryPush(cmd)) {
      return MUSE_ERR_QUEUE_FULL;
    }
  }
#if !defined(__EMSCRIPTEN__)
  if (butler_worker_ &&
      (cmd.type == MUT_SET_PLAYING || cmd.type == MUT_SEEK_SAMPLE ||
       cmd.type == MUT_FLUSH_AND_ADVANCE_EPOCH ||
       cmd.type == MUT_SET_LOOP_REGION || cmd.type == MUT_SET_CAPTURE_STATE)) {
    butler_worker_->notifyWake();
  }
#else
  if (cmd.type == MUT_SET_LOOP_REGION) {
    // Web AudioWorklet runs pushMutation() and process() sequentially on one
    // thread; reset stale prefetched take audio before new loop chunks arrive.
    invalidateTakePlaybackBuffer(true);
  }
#endif
  return MUSE_OK;
}

MuseStatus AudioEngineCore::pushEvents(
    const SynthNoteEvent* events,
    uint32_t count,
    uint32_t* out_pushed_count) {
  if (out_pushed_count == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  *out_pushed_count = 0;

  if (!initialized_.load(std::memory_order_acquire)) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (count == 0) {
    return MUSE_OK;
  }
  if (events == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }

  std::lock_guard<std::mutex> lock(event_producer_mutex_);
  for (uint32_t i = 0; i < count; ++i) {
    const SynthNoteEvent& evt = events[i];
    if (evt.type < EVT_NOTE_ON || evt.type > EVT_PITCH_BEND ||
        evt.channel > kMaxMidiChannel || evt.key_or_cc > kMaxMidiKeyOrCc ||
        evt.velocity_or_val > kMaxMidiKeyOrCc ||
        evt.pitch_bend < kMinPitchBendSigned ||
        evt.pitch_bend > kMaxPitchBendSigned) {
      *out_pushed_count = i;
      return MUSE_ERR_DEVICE_INIT;
    }

    if (evt.target_sample_frame == kImmediateDispatchFrame) {
      if (!audition_queue_.tryPush(evt)) {
        *out_pushed_count = i;
        return MUSE_ERR_QUEUE_FULL;
      }
    } else {
      if (evt.target_sample_frame < 0) {
        *out_pushed_count = i;
        return MUSE_ERR_DEVICE_INIT;
      }
      if (!event_queue_.tryPush(evt)) {
        *out_pushed_count = i;
        return MUSE_ERR_QUEUE_FULL;
      }
    }
  }

  *out_pushed_count = count;
  return MUSE_OK;
}

MuseStatus AudioEngineCore::pushTakePlaybackPcm(
    uint64_t epoch,
    int64_t start_sample_frame,
    const float* interleaved_stereo_f32,
    uint32_t frame_count,
    uint32_t* out_pushed_frames) {
  if (out_pushed_frames == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  *out_pushed_frames = 0;

  if (!initialized_.load(std::memory_order_acquire) || start_sample_frame < 0) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (frame_count == 0) {
    return MUSE_OK;
  }
  if (interleaved_stereo_f32 == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }

  std::array<TakePlaybackStereoFrame, kTakePushBatchChunkFrames> batch{};
  uint32_t total_pushed = 0;
  while (total_pushed < frame_count) {
    const uint32_t chunk =
        std::min<uint32_t>(frame_count - total_pushed, kTakePushBatchChunkFrames);
    for (uint32_t i = 0; i < chunk; ++i) {
      const uint32_t idx = total_pushed + i;
      batch[i] = TakePlaybackStereoFrame{
          epoch,
          start_sample_frame + static_cast<int64_t>(idx),
          interleaved_stereo_f32[idx * kStereoChannelCount + 0],
          interleaved_stereo_f32[idx * kStereoChannelCount + 1],
      };
    }
    const size_t pushed =
        take_playback_ring_buffer_.tryPushBatch(batch.data(), chunk);
    total_pushed += static_cast<uint32_t>(pushed);
    if (pushed < chunk) {
      *out_pushed_frames = total_pushed;
      return MUSE_ERR_QUEUE_FULL;
    }
  }

  *out_pushed_frames = total_pushed;
  return MUSE_OK;
}

void AudioEngineCore::updateTakeWindows(
    const TakeWindowRange* windows,
    size_t count) {
  std::lock_guard<std::mutex> lock(take_window_writer_mutex_);
  const uint8_t current_idx =
      active_take_window_idx_.load(std::memory_order_acquire);
  const uint8_t next_idx = static_cast<uint8_t>(1u - current_idx);

  auto& next_slots = take_windows_[next_idx];
  const size_t copy_count = (windows == nullptr)
      ? 0u
      : std::min<size_t>(count, kMaxActiveTakeRegions);
  for (size_t i = 0; i < copy_count; ++i) {
    next_slots[i] = windows[i];
  }
  for (size_t i = copy_count; i < kMaxActiveTakeRegions; ++i) {
    next_slots[i] = TakeWindowRange{};
  }
  active_take_window_idx_.store(next_idx, std::memory_order_release);
}

void AudioEngineCore::clearTakeWindows() {
  updateTakeWindows(nullptr, 0);
}

uint32_t AudioEngineCore::drainTelemetry(
    TelemetryFrame* out_frames,
    uint32_t max_frames) {
  if (out_frames == nullptr || max_frames == 0) {
    return 0;
  }
  return static_cast<uint32_t>(telemetry_queue_.tryPopBatch(out_frames, max_frames));
}

uint32_t AudioEngineCore::drainCaptureFrames(
    float* out_interleaved_frames,
    uint32_t max_frames,
    int64_t* out_first_sample_clock) {
  if (out_first_sample_clock != nullptr) {
    *out_first_sample_clock = 0;
  }
  if (out_interleaved_frames == nullptr || max_frames == 0 ||
      capture_owned_by_butler_.load(std::memory_order_acquire)) {
    return 0;
  }
  const uint32_t channels = hardware_config_.input_channels;
  if (channels == 0 || channels > kMaxCaptureChannels) {
    return 0;
  }

  const size_t available_frames =
      capture_ring_buffer_.readAvailable() / static_cast<size_t>(channels);
  const uint32_t frames_to_pop =
      std::min<uint32_t>(max_frames, static_cast<uint32_t>(available_frames));
  if (frames_to_pop == 0) {
    return 0;
  }

  const size_t floats_to_pop =
      static_cast<size_t>(frames_to_pop) * static_cast<size_t>(channels);
  const size_t popped_floats =
      capture_ring_buffer_.tryPopBatch(out_interleaved_frames, floats_to_pop);
  const uint32_t popped_frames =
      static_cast<uint32_t>(popped_floats / static_cast<size_t>(channels));

  if (out_first_sample_clock != nullptr) {
    *out_first_sample_clock =
        capture_latch_.captured_sample_clock +
        static_cast<int64_t>(capture_latch_.total_frames_drained_via_c_api);
  }
  capture_latch_.total_frames_drained_via_c_api += popped_frames;
  return popped_frames;
}

template <typename Fn>
MuseStatus AudioEngineCore::executeWithSynthSuspended(Fn&& fn) {
  if (!hal_running_.load(std::memory_order_acquire)) {
    return fn();
  }

  const uint64_t seq = synth_suspend_seq_.fetch_add(1, std::memory_order_acq_rel) + 1;
  synth_suspend_requested_.store(true, std::memory_order_release);

  const auto deadline = std::chrono::steady_clock::now() +
      std::chrono::milliseconds(kSynthSuspendTimeoutMs);
  while (synth_suspend_ack_seq_.load(std::memory_order_acquire) < seq) {
    if (!hal_running_.load(std::memory_order_acquire)) {
      break;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      synth_suspend_requested_.store(false, std::memory_order_release);
      return MUSE_ERR_DEVICE_INIT;
    }
    std::this_thread::yield();
  }

  struct SuspendGuard {
    std::atomic<bool>& flag;
    ~SuspendGuard() { flag.store(false, std::memory_order_release); }
  } guard{synth_suspend_requested_};

  return fn();
}

MuseStatus AudioEngineCore::extractSoundFontPresets(
    int32_t sf_handle,
    MuseSoundFontPresetPod* out_presets,
    uint32_t max_presets,
    uint32_t* out_preset_count) {
  if (synth_ == nullptr || out_preset_count == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  *out_preset_count = 0;

  fluid_sfont_t* sfont = fluid_synth_get_sfont_by_id(synth_, sf_handle);
  if (sfont == nullptr) {
    return MUSE_ERR_SF_LOAD_FAILED;
  }

  uint32_t total = 0;
  fluid_sfont_iteration_start(sfont);
  while (fluid_preset_t* preset = fluid_sfont_iteration_next(sfont)) {
    if (total < max_presets && out_presets != nullptr) {
      MuseSoundFontPresetPod& pod = out_presets[total];
      pod = MuseSoundFontPresetPod{};
      pod.bank_num = static_cast<int32_t>(fluid_preset_get_banknum(preset));
      pod.program_num = static_cast<int32_t>(fluid_preset_get_num(preset));
      const char* name = fluid_preset_get_name(preset);
      if (name != nullptr) {
        std::snprintf(pod.preset_name, sizeof(pod.preset_name), "%s", name);
      }
    }
    ++total;
  }

  *out_preset_count = total;
  if (total > max_presets) {
    return MUSE_ERR_BUFFER_TOO_SMALL;
  }
  return MUSE_OK;
}

MuseStatus AudioEngineCore::loadSoundFontFile(
    const char* posix_path,
    int32_t* out_sf_handle,
    MuseSoundFontPresetPod* out_presets,
    uint32_t max_presets,
    uint32_t* out_preset_count) {
  if (out_sf_handle != nullptr) {
    *out_sf_handle = kFluidSynthSfFailed;
  }
  if (out_preset_count != nullptr) {
    *out_preset_count = 0;
  }
  if (out_sf_handle == nullptr || out_preset_count == nullptr ||
      (max_presets > 0 && out_presets == nullptr) ||
      !initialized_.load(std::memory_order_acquire) || synth_ == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (posix_path == nullptr || posix_path[0] == '\0' ||
      std::strncmp(posix_path, kMemorySf2UriPrefix, kMemorySf2UriPrefixLen) ==
          0) {
    return MUSE_ERR_SF_LOAD_FAILED;
  }

  std::lock_guard<std::mutex> lock(synth_control_mutex_);
  return executeWithSynthSuspended([&]() -> MuseStatus {
    const int sf_id = fluid_synth_sfload(synth_, posix_path, 0);
    if (sf_id == FLUID_FAILED || sf_id < 0) {
      *out_sf_handle = kFluidSynthSfFailed;
      return MUSE_ERR_SF_LOAD_FAILED;
    }

    const MuseStatus preset_status =
        extractSoundFontPresets(sf_id, out_presets, max_presets, out_preset_count);
    if (preset_status != MUSE_OK) {
      (void)fluid_synth_sfunload(synth_, sf_id, 0);
      *out_sf_handle = kFluidSynthSfFailed;
      return preset_status;
    }

    *out_sf_handle = static_cast<int32_t>(sf_id);
    return MUSE_OK;
  });
}

MuseStatus AudioEngineCore::loadSoundFontBytes(
    const uint8_t* bytes,
    uint32_t byte_length,
    int32_t* out_sf_handle,
    MuseSoundFontPresetPod* out_presets,
    uint32_t max_presets,
    uint32_t* out_preset_count) {
  if (out_sf_handle != nullptr) {
    *out_sf_handle = kFluidSynthSfFailed;
  }
  if (out_preset_count != nullptr) {
    *out_preset_count = 0;
  }
  if (out_sf_handle == nullptr || out_preset_count == nullptr ||
      (max_presets > 0 && out_presets == nullptr) ||
      !initialized_.load(std::memory_order_acquire) || synth_ == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (bytes == nullptr || byte_length == 0 ||
      byte_length > kMaxWebSoundFontBytes) {
    return MUSE_ERR_SF_TOO_LARGE;
  }

  std::lock_guard<std::mutex> lock(synth_control_mutex_);
  const bool offline = !hal_running_.load(std::memory_order_acquire);
  if (offline) {
    startCycle();
  }
  const bool playing = is_playing_atomic_.load(std::memory_order_acquire) ||
      (offline && rt_.is_playing);
  if (playing) {
    return MUSE_ERR_TRANSPORT_NOT_STOPPED;
  }

  return executeWithSynthSuspended([&]() -> MuseStatus {
    const MemorySf2Slice slice{kMemorySf2Magic, bytes, byte_length};
    char uri[kMemorySf2UriBufferSize]{};
    std::snprintf(
        uri, sizeof(uri), "%s%llx", kMemorySf2UriPrefix,
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&slice)));

    const int sf_id = fluid_synth_sfload(synth_, uri, 0);
    if (sf_id == FLUID_FAILED || sf_id < 0) {
      *out_sf_handle = kFluidSynthSfFailed;
      return MUSE_ERR_SF_LOAD_FAILED;
    }

    const MuseStatus preset_status =
        extractSoundFontPresets(sf_id, out_presets, max_presets, out_preset_count);
    if (preset_status != MUSE_OK) {
      (void)fluid_synth_sfunload(synth_, sf_id, 0);
      *out_sf_handle = kFluidSynthSfFailed;
      return preset_status;
    }

    *out_sf_handle = static_cast<int32_t>(sf_id);
    return MUSE_OK;
  });
}

MuseStatus AudioEngineCore::unloadSoundFont(int32_t sf_handle) {
  if (!initialized_.load(std::memory_order_acquire) || synth_ == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (sf_handle <= 0) {
    return MUSE_ERR_SF_LOAD_FAILED;
  }

  std::lock_guard<std::mutex> lock(synth_control_mutex_);
  return executeWithSynthSuspended([&]() -> MuseStatus {
    if (fluid_synth_sfunload(synth_, sf_handle, 0) != FLUID_OK) {
      return MUSE_ERR_SF_LOAD_FAILED;
    }
    return MUSE_OK;
  });
}

MuseStatus AudioEngineCore::prepareCapture(const char* staging_wav_path) {
  if (!initialized_.load(std::memory_order_acquire)) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (hardware_config_.input_channels == 0 ||
      hardware_config_.input_channels > kMaxCaptureChannels) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (staging_wav_path == nullptr || staging_wav_path[0] == '\0') {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (std::strlen(staging_wav_path) >= kStagingPathBufferSize) {
    return MUSE_ERR_STORAGE_IO;
  }
  if (capture_active_atomic_.load(std::memory_order_acquire) ||
      is_capturing_atomic_.load(std::memory_order_acquire)) {
    return MUSE_ERR_TRANSPORT_NOT_STOPPED;
  }

#if !defined(__EMSCRIPTEN__)
  if (!butler_worker_) {
    return MUSE_ERR_DEVICE_INIT;
  }
  const MuseStatus st = butler_worker_->prepareCapture(staging_wav_path);
  if (st == MUSE_OK) {
    capture_owned_by_butler_.store(true, std::memory_order_release);
    capture_prepared_without_butler_.store(false, std::memory_order_release);
  }
  return st;
#else
  resetCaptureStateForPrepare();
  capture_owned_by_butler_.store(false, std::memory_order_release);
  capture_prepared_without_butler_.store(true, std::memory_order_release);
  return MUSE_OK;
#endif
}

MuseStatus AudioEngineCore::startCapture() {
  if (!initialized_.load(std::memory_order_acquire) ||
      hardware_config_.input_channels == 0 ||
      hardware_config_.input_channels > kMaxCaptureChannels) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (!capture_owned_by_butler_.load(std::memory_order_acquire) &&
      !capture_prepared_without_butler_.load(std::memory_order_acquire)) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (capture_active_atomic_.load(std::memory_order_acquire) ||
      is_capturing_atomic_.load(std::memory_order_acquire)) {
    return MUSE_ERR_TRANSPORT_NOT_STOPPED;
  }

  capture_overflowed_atomic_.store(false, std::memory_order_release);

  MutationCommand cmd{};
  cmd.type = MUT_SET_CAPTURE_STATE;
  cmd.flag_a = 1;
  return pushMutation(cmd);
}

MuseStatus AudioEngineCore::stopAndFinalizeCapture(
    FinalizedCaptureReceipt* out_receipt) {
  if (out_receipt == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  *out_receipt = FinalizedCaptureReceipt{};
#if !defined(__EMSCRIPTEN__)
  if (!initialized_.load(std::memory_order_acquire) || !butler_worker_) {
    out_receipt->status = MUSE_ERR_DEVICE_INIT;
    return MUSE_ERR_DEVICE_INIT;
  }
  const MuseStatus st = butler_worker_->stopAndFinalizeCapture(out_receipt);
  capture_owned_by_butler_.store(false, std::memory_order_release);
  return st;
#else
  out_receipt->status = MUSE_ERR_STORAGE_IO;
  capture_prepared_without_butler_.store(false, std::memory_order_release);
  capture_owned_by_butler_.store(false, std::memory_order_release);
  return MUSE_ERR_STORAGE_IO;
#endif
}

MuseStatus AudioEngineCore::registerActiveTake(
    const char* take_id_utf8,
    const char* cas_wav_posix_path,
    int64_t start_sample_frame,
    int64_t duration_frames,
    float gain_db,
    float pan) {
  if (!initialized_.load(std::memory_order_acquire)) {
    return MUSE_ERR_DEVICE_INIT;
  }
#if !defined(__EMSCRIPTEN__)
  if (!butler_worker_) {
    return MUSE_ERR_DEVICE_INIT;
  }
  return butler_worker_->registerActiveTake(
      take_id_utf8, cas_wav_posix_path, start_sample_frame, duration_frames,
      gain_db, pan);
#else
  if (take_id_utf8 == nullptr || take_id_utf8[0] == '\0' ||
      std::strlen(take_id_utf8) >= kTakeIdBufferSize ||
      cas_wav_posix_path == nullptr || cas_wav_posix_path[0] == '\0' ||
      std::strlen(cas_wav_posix_path) >= kCasPathBufferSize ||
      start_sample_frame < 0 || duration_frames <= 0 ||
      !std::isfinite(gain_db) || !std::isfinite(pan)) {
    return MUSE_ERR_TAKE_LOAD_FAILED;
  }

  std::lock_guard<std::mutex> lock(take_window_writer_mutex_);
  const uint8_t current_idx =
      active_take_window_idx_.load(std::memory_order_acquire);
  const uint8_t next_idx = static_cast<uint8_t>(1u - current_idx);
  const auto& current_slots = take_windows_[current_idx];
  auto& next_slots = take_windows_[next_idx];
  next_slots = current_slots;

  for (size_t i = 0; i < kMaxActiveTakeRegions; ++i) {
    if (next_slots[i].active == 0) {
      next_slots[i] = TakeWindowRange{
          start_sample_frame,
          start_sample_frame + duration_frames,
          1,
      };
      active_take_window_idx_.store(next_idx, std::memory_order_release);
      return MUSE_OK;
    }
  }
  return MUSE_ERR_TAKE_LOAD_FAILED;
#endif
}

MuseStatus AudioEngineCore::clearActiveTakes() {
  if (!initialized_.load(std::memory_order_acquire)) {
    return MUSE_ERR_DEVICE_INIT;
  }
#if !defined(__EMSCRIPTEN__)
  if (!butler_worker_) {
    return MUSE_ERR_DEVICE_INIT;
  }
  return butler_worker_->clearActiveTakes();
#else
  clearTakeWindows();
  invalidateTakePlaybackBuffer(true);
  return MUSE_OK;
#endif
}

void AudioEngineCore::setCaptureDrainPaused(bool paused) noexcept {
#if !defined(__EMSCRIPTEN__)
  if (butler_worker_) {
    butler_worker_->setCaptureDrainPaused(paused);
  }
#else
  (void)paused;
#endif
}

void AudioEngineCore::audioHalCallback(
    void* user_data,
    const float* input_interleaved,
    float* output_interleaved,
    uint32_t frame_count) {
  if (user_data == nullptr) {
    return;
  }
  (void)static_cast<AudioEngineCore*>(user_data)->processBlock(
      input_interleaved, output_interleaved, frame_count);
}

MuseStatus AudioEngineCore::processBlock(
    const float* input_interleaved,
    float* output_interleaved,
    uint32_t frame_count) {
  if (!initialized_.load(std::memory_order_acquire)) {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (frame_count == 0) {
    return MUSE_OK;
  }
  if (output_interleaved == nullptr || hardware_config_.output_channels == 0) {
    return MUSE_ERR_DEVICE_INIT;
  }

  const uint32_t in_ch = hardware_config_.input_channels;
  const uint32_t out_ch = hardware_config_.output_channels;
  const float* in_ptr = input_interleaved;
  float* out_ptr = output_interleaved;
  uint32_t remaining = frame_count;

  while (remaining > 0) {
    startCycle();

    uint32_t chunk = std::min<uint32_t>(remaining, kMaxRenderBlockFrames);
    if (rt_.is_playing && rt_.loop_enabled && !rt_.is_capturing &&
        rt_.loop_end_frame > rt_.loop_start_frame &&
        rt_.playhead_sample_frame < rt_.loop_end_frame &&
        rt_.playhead_sample_frame + static_cast<int64_t>(chunk) >
            rt_.loop_end_frame) {
      chunk = static_cast<uint32_t>(rt_.loop_end_frame - rt_.playhead_sample_frame);
    }

    processAudio(in_ptr, out_ptr, chunk);
    endCycle(chunk);

    out_ptr += static_cast<size_t>(chunk) * static_cast<size_t>(out_ch);
    if (in_ptr != nullptr && in_ch > 0) {
      in_ptr += static_cast<size_t>(chunk) * static_cast<size_t>(in_ch);
    }
    remaining -= chunk;
  }

  return MUSE_OK;
}

bool AudioEngineCore::isMutationSynthMutating(MutationType type) noexcept {
  switch (type) {
    case MUT_ASSIGN_CHANNEL_PATCH:
    case MUT_SET_CHANNEL_MIX:
    case MUT_ALL_NOTES_OFF_CHANNEL:
    case MUT_SEEK_SAMPLE:
    case MUT_FLUSH_AND_ADVANCE_EPOCH:
    case MUT_SET_PLAYING:
      return true;
    default:
      return false;
  }
}

void AudioEngineCore::applyChannelMix(
    uint8_t channel,
    float gain_db,
    float pan) noexcept {
  if (channel > kMaxMidiChannel) {
    return;
  }
  RtChannelMixState& slot = rt_.channel_mix[channel];
  slot.linear_gain = dsp::dbToLinear(gain_db);
  const dsp::StereoPanGains gains = dsp::computeConstantPowerPan(pan);
  slot.pan_left = gains.left;
  slot.pan_right = gains.right;
}

void AudioEngineCore::applyMutation(const MutationCommand& cmd) noexcept {
  switch (cmd.type) {
    case MUT_SET_PLAYING: {
      const bool next_playing = (cmd.flag_a != 0);
      if (rt_.is_playing && !next_playing) {
        if (synth_ != nullptr && !rt_.synth_suspended) {
          fluid_synth_all_notes_off(synth_, kAllMidiChannels);
        }
        rt_.has_scheduled_since_play = false;
      }
      rt_.is_playing = next_playing;
      break;
    }
    case MUT_SEEK_SAMPLE: {
      rt_.playhead_sample_frame = std::max<int64_t>(0, cmd.sample_frame_a);
      if (cmd.target_epoch > rt_.active_epoch) {
        rt_.active_epoch = cmd.target_epoch;
      }
      rt_.loop_pass = 0u;
      ++rt_.seek_generation;
      if (synth_ != nullptr && !rt_.synth_suspended) {
        fluid_synth_all_notes_off(synth_, kAllMidiChannels);
      }
      rt_.scheduled_watermark_frame = rt_.playhead_sample_frame;
      rt_.has_scheduled_since_play = false;
      break;
    }
    case MUT_SET_LOOP_REGION: {
      const bool enabled = (cmd.flag_a != 0);
      rt_.loop_enabled = enabled;
      rt_.loop_start_frame = cmd.sample_frame_a;
      rt_.loop_end_frame = cmd.sample_frame_b;
      break;
    }
    case MUT_FLUSH_AND_ADVANCE_EPOCH: {
      if (cmd.target_epoch == 0) {
        ++rt_.active_epoch;
      } else if (cmd.target_epoch > rt_.active_epoch) {
        rt_.active_epoch = cmd.target_epoch;
      }
      rt_.loop_pass = 0u;
      ++rt_.seek_generation;
      if (synth_ != nullptr && !rt_.synth_suspended) {
        fluid_synth_all_notes_off(synth_, kAllMidiChannels);
      }
      rt_.scheduled_watermark_frame = rt_.playhead_sample_frame;
      rt_.has_scheduled_since_play = false;
      break;
    }
    case MUT_ASSIGN_CHANNEL_PATCH:
      if (synth_ != nullptr && !rt_.synth_suspended &&
          cmd.channel <= kMaxMidiChannel) {
        fluid_synth_program_select(
            synth_, static_cast<int>(cmd.channel), cmd.int_param_a,
            cmd.int_param_b, cmd.int_param_c);
      }
      break;
    case MUT_SET_CHANNEL_MIX:
      applyChannelMix(cmd.channel, cmd.float_param_a, cmd.float_param_b);
      break;
    case MUT_ALL_NOTES_OFF_CHANNEL:
      if (synth_ != nullptr && !rt_.synth_suspended &&
          cmd.channel <= kMaxMidiChannel) {
        fluid_synth_all_notes_off(synth_, static_cast<int>(cmd.channel));
      }
      break;
    case MUT_SET_MONITOR_GAIN:
      rt_.monitor_gain = std::max(0.0f, cmd.float_param_a);
      break;
    case MUT_SET_CAPTURE_STATE: {
      const bool next_capturing = (cmd.flag_a != 0) &&
          (hardware_config_.input_channels >= 1 &&
           hardware_config_.input_channels <= kMaxCaptureChannels);
      if (!rt_.is_capturing && next_capturing) {
        capture_latch_.clock_latched.store(false, std::memory_order_release);
        capture_latch_.total_frames_drained_via_c_api = 0;
      }
      rt_.is_capturing = next_capturing;
      if (next_capturing) {
        rt_.capture_overflowed = false;
        capture_overflowed_atomic_.store(false, std::memory_order_release);
      }
      break;
    }
    case MUT_SET_SYNTH_SUSPENDED:
      rt_.mutation_synth_suspended = (cmd.flag_a != 0);
      rt_.synth_suspended = rt_.mutation_synth_suspended ||
          synth_suspend_requested_.load(std::memory_order_acquire);
      break;
    case MUT_SET_SCHEDULED_WATERMARK:
      if (cmd.target_epoch == rt_.active_epoch) {
        rt_.scheduled_watermark_frame = cmd.sample_frame_a;
        rt_.has_scheduled_since_play = true;
      }
      break;
    default:
      break;
  }
}

void AudioEngineCore::publishTransportSnapshot() noexcept {
  const uint64_t seq = transport_seq_.load(std::memory_order_relaxed);
  transport_seq_.store(seq + 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  playhead_atomic_.store(rt_.playhead_sample_frame, std::memory_order_release);
  active_epoch_atomic_.store(rt_.active_epoch, std::memory_order_release);
  seek_generation_atomic_.store(rt_.seek_generation, std::memory_order_release);
  rendered_playback_frames_atomic_.store(rt_.rendered_playback_frames,
                                         std::memory_order_release);
  is_playing_atomic_.store(rt_.is_playing, std::memory_order_release);
  is_capturing_atomic_.store(rt_.is_capturing, std::memory_order_release);
  capture_active_atomic_.store(rt_.is_capturing, std::memory_order_release);
  loop_enabled_atomic_.store(rt_.loop_enabled, std::memory_order_release);
  loop_start_atomic_.store(rt_.loop_start_frame, std::memory_order_release);
  loop_end_atomic_.store(rt_.loop_end_frame, std::memory_order_release);
  transport_seq_.store(seq + 2u, std::memory_order_release);
}

RtTransportSnapshot AudioEngineCore::readTransportSnapshot() const noexcept {
  RtTransportSnapshot snap{};
  while (true) {
    const uint64_t s1 = transport_seq_.load(std::memory_order_acquire);
    if ((s1 & 1u) != 0u) {
      continue;
    }
    snap.playhead_sample_frame =
        playhead_atomic_.load(std::memory_order_relaxed);
    snap.active_epoch = active_epoch_atomic_.load(std::memory_order_relaxed);
    snap.seek_generation =
        seek_generation_atomic_.load(std::memory_order_relaxed);
    snap.rendered_playback_frames =
        rendered_playback_frames_atomic_.load(std::memory_order_relaxed);
    snap.is_playing = is_playing_atomic_.load(std::memory_order_relaxed);
    snap.is_capturing = is_capturing_atomic_.load(std::memory_order_relaxed);
    snap.loop_enabled = loop_enabled_atomic_.load(std::memory_order_relaxed);
    snap.loop_start_frame = loop_start_atomic_.load(std::memory_order_relaxed);
    snap.loop_end_frame = loop_end_atomic_.load(std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_acquire);
    const uint64_t s2 = transport_seq_.load(std::memory_order_acquire);
    if (s1 == s2) {
      return snap;
    }
  }
}

void AudioEngineCore::startCycle() noexcept {
  enableHardwareDenormalProtection();

  // Acquire flag before sequence so any true req sees >= seq from caller.
  const bool req = synth_suspend_requested_.load(std::memory_order_acquire);
  const uint64_t seq = synth_suspend_seq_.load(std::memory_order_acquire);
  rt_.synth_suspended = req || rt_.mutation_synth_suspended;
  if (req) {
    rt_.pending_suspend_seq = seq;
  }

  take_playback_ring_buffer_.consumeUpToIndex(
      take_playback_valid_from_idx_.load(std::memory_order_acquire));

  const uint64_t prev_seek = rt_.seek_generation;
  const uint64_t prev_epoch = rt_.active_epoch;
  const bool prev_playing = rt_.is_playing;
  const bool prev_loop = rt_.loop_enabled;
  const int64_t prev_loop_start = rt_.loop_start_frame;
  const int64_t prev_loop_end = rt_.loop_end_frame;

  bool applied_any = false;
  for (size_t i = 0; i < kMutationQueueCapacity; ++i) {
    const MutationCommand* peek_cmd = mutation_queue_.peek();
    if (peek_cmd == nullptr) {
      break;
    }
    if (rt_.synth_suspended && isMutationSynthMutating(peek_cmd->type)) {
      break;
    }
    const MutationCommand cmd = *peek_cmd;
    mutation_queue_.consumeOne();
    applyMutation(cmd);
    applied_any = true;
  }

  if (applied_any) {
    publishTransportSnapshot();
    if (rt_.seek_generation != prev_seek || rt_.active_epoch != prev_epoch ||
        rt_.is_playing != prev_playing || rt_.loop_enabled != prev_loop ||
        rt_.loop_start_frame != prev_loop_start ||
        rt_.loop_end_frame != prev_loop_end) {
      butler_wake_requested_.store(true, std::memory_order_release);
    }
  }
}

void AudioEngineCore::dispatchSynthEvent(const SynthNoteEvent& evt) noexcept {
  if (synth_ == nullptr) {
    return;
  }
  const int ch = static_cast<int>(evt.channel);
  switch (evt.type) {
    case EVT_NOTE_ON:
      fluid_synth_noteon(synth_, ch, static_cast<int>(evt.key_or_cc),
                         static_cast<int>(evt.velocity_or_val));
      break;
    case EVT_NOTE_OFF:
      fluid_synth_noteoff(synth_, ch, static_cast<int>(evt.key_or_cc));
      break;
    case EVT_CONTROL_CHANGE:
      fluid_synth_cc(synth_, ch, static_cast<int>(evt.key_or_cc),
                     static_cast<int>(evt.velocity_or_val));
      break;
    case EVT_PITCH_BEND: {
      const int32_t unsigned_bend = std::clamp<int32_t>(
          static_cast<int32_t>(evt.pitch_bend) + kPitchBendCenter,
          0, kMaxPitchBendUnsigned);
      fluid_synth_pitch_bend(synth_, ch, static_cast<int>(unsigned_bend));
      break;
    }
    default:
      break;
  }
}

MuseStatus AudioEngineCore::renderFluidMultiBusSlice(
    uint32_t offset,
    uint32_t count) noexcept {
  if (count == 0) {
    return MUSE_OK;
  }
  if (synth_ == nullptr || offset + count > kMaxRenderBlockFrames) {
    return MUSE_ERR_DEVICE_INIT;
  }

  static_assert(kFluidAudioGroups == kMidiChannelCount);
  static_assert(kFluidEffectsGroups == kMidiChannelCount);

  float* out_ptrs[kMidiChannelCount * kStereoChannelCount]{};
  for (uint32_t ch = 0; ch < kMidiChannelCount; ++ch) {
    float* left = synth_chan_left_[ch].data() + offset;
    float* right = synth_chan_right_[ch].data() + offset;
    std::fill_n(left, count, 0.0f);
    std::fill_n(right, count, 0.0f);
    out_ptrs[ch * kStereoChannelCount + 0] = left;
    out_ptrs[ch * kStereoChannelCount + 1] = right;
  }

  float* fx_ptrs[kFluidEffectsGroups * kFluidEffectsChannelsPerGroup *
                 kStereoChannelCount]{};
  for (uint32_t g = 0; g < kFluidEffectsGroups; ++g) {
    for (uint32_t fx = 0; fx < kFluidEffectsChannelsPerGroup; ++fx) {
      const uint32_t fx_base =
          (g * kFluidEffectsChannelsPerGroup + fx) * kStereoChannelCount;
      fx_ptrs[fx_base + 0] = out_ptrs[g * kStereoChannelCount + 0];
      fx_ptrs[fx_base + 1] = out_ptrs[g * kStereoChannelCount + 1];
    }
  }

  const int rc = fluid_synth_process(
      synth_, static_cast<int>(count),
      static_cast<int>(kFluidEffectsGroups * kFluidEffectsChannelsPerGroup *
                       kStereoChannelCount),
      fx_ptrs, static_cast<int>(kMidiChannelCount * kStereoChannelCount),
      out_ptrs);
  return (rc == FLUID_OK) ? MUSE_OK : MUSE_ERR_DEVICE_INIT;
}

bool AudioEngineCore::hasActiveTakeOverlap(
    int64_t target_frame,
    uint32_t span_frames) const noexcept {
  const uint8_t idx = active_take_window_idx_.load(std::memory_order_acquire);
  const auto& windows = take_windows_[idx];
  const int64_t end_frame = target_frame + static_cast<int64_t>(span_frames);
  for (size_t w = 0; w < kMaxActiveTakeRegions; ++w) {
    const TakeWindowRange& win = windows[w];
    if (win.active == 0) {
      continue;
    }
    if (win.start_sample_frame < end_frame &&
        win.end_sample_frame > target_frame) {
      return true;
    }
  }
  return false;
}

void AudioEngineCore::processAudio(
    const float* input_interleaved,
    float* output_interleaved,
    uint32_t frame_count) noexcept {
  if (frame_count == 0 || output_interleaved == nullptr) {
    return;
  }

  uint8_t event_underrun = 0;
  uint8_t take_underrun = 0;
  uint8_t capture_overflow = rt_.capture_overflowed ? 1u : 0u;

  // 1. Multi-Bus Synth Rendering
  if (rt_.synth_suspended) {
    std::fill_n(synth_left_.data(), frame_count, 0.0f);
    std::fill_n(synth_right_.data(), frame_count, 0.0f);
    synth_suspend_ack_seq_.store(rt_.pending_suspend_seq,
                                 std::memory_order_release);
  } else {
    for (size_t i = 0; i < kAuditionQueueCapacity; ++i) {
      SynthNoteEvent evt{};
      if (!audition_queue_.tryPop(evt)) {
        break;
      }
      if (evt.epoch >= rt_.active_epoch) {
        dispatchSynthEvent(evt);
      }
    }

    uint32_t rendered = 0;
    const int64_t window_start = rt_.playhead_sample_frame;
    const int64_t window_end =
        window_start + static_cast<int64_t>(frame_count);

    for (size_t i = 0; i < kEventQueueCapacity; ++i) {
      const SynthNoteEvent* nxt = event_queue_.peek();
      if (nxt == nullptr) {
        break;
      }
      if (nxt->epoch < rt_.active_epoch) {
        event_queue_.consumeOne();
        continue;
      }
      if (!rt_.is_playing) {
        break;
      }
      const int16_t pass_delta = static_cast<int16_t>(
          static_cast<uint16_t>(nxt->reserved - rt_.loop_pass));
      if (pass_delta < 0) {
        // Consume events from superseded loop passes (for example a trailing
        // note-off clipped right at loop_end_frame on the prior pass).
        event_queue_.consumeOne();
        continue;
      }
      if (pass_delta > 0) {
        // Defer queued post-wrap events until endCycle() wraps and advances
        // rt_.loop_pass so they never fire early at loopStartFrame.
        break;
      }
      if (nxt->target_sample_frame >= window_end) {
        break;
      }
      const uint32_t target_off = (nxt->target_sample_frame <= window_start)
          ? 0u
          : static_cast<uint32_t>(nxt->target_sample_frame - window_start);
      if (target_off > rendered) {
        (void)renderFluidMultiBusSlice(rendered, target_off - rendered);
        rendered = target_off;
      }
      dispatchSynthEvent(*nxt);
      event_queue_.consumeOne();
    }

    if (rendered < frame_count) {
      (void)renderFluidMultiBusSlice(rendered, frame_count - rendered);
    }

    std::fill_n(synth_left_.data(), frame_count, 0.0f);
    std::fill_n(synth_right_.data(), frame_count, 0.0f);
    for (uint32_t ch = 0; ch < kMidiChannelCount; ++ch) {
      const RtChannelMixState& mix = rt_.channel_mix[ch];
      const float gain_l = mix.linear_gain * mix.pan_left;
      const float gain_r = mix.linear_gain * mix.pan_right;
      const float* src_l = synth_chan_left_[ch].data();
      const float* src_r = synth_chan_right_[ch].data();
      for (uint32_t i = 0; i < frame_count; ++i) {
        synth_left_[i] += src_l[i] * gain_l;
        synth_right_[i] += src_r[i] * gain_r;
      }
    }

    if (rt_.is_playing && rt_.has_scheduled_since_play &&
        window_end > rt_.scheduled_watermark_frame && event_queue_.empty()) {
      event_underrun = 1;
    }
  }

  // 2. Active Take Mixing (TakePlaybackRingBuffer)
  take_playback_ring_buffer_.consumeUpToIndex(
      take_playback_valid_from_idx_.load(std::memory_order_acquire));
  if (rt_.is_playing) {
    const bool loop_region_valid = rt_.loop_enabled && !rt_.is_capturing &&
        rt_.loop_end_frame > rt_.loop_start_frame;

    for (uint32_t i = 0; i < frame_count; ++i) {
      const int64_t target_pos =
          rt_.playhead_sample_frame + static_cast<int64_t>(i);
      const bool in_loop_window = loop_region_valid &&
          target_pos >= rt_.loop_start_frame &&
          target_pos < rt_.loop_end_frame;
      bool matched = false;
      for (size_t skips = 0; skips < kTakePlaybackRingCapacityFrames; ++skips) {
        const TakePlaybackStereoFrame* f = take_playback_ring_buffer_.peek();
        if (f == nullptr) {
          break;
        }
        const bool stale_epoch = (f->epoch < rt_.active_epoch);
        // Inside an active loop, frames in [loop_start, target_pos) belong to
        // the next wrapped loop pass; only drop pre-loop/post-loop frames.
        const bool stale_frame = in_loop_window
            ? (f->target_sample_frame < rt_.loop_start_frame ||
               f->target_sample_frame >= rt_.loop_end_frame)
            : (f->target_sample_frame < target_pos);
        if (stale_epoch || stale_frame) {
          take_playback_ring_buffer_.consumeOne();
          continue;
        }
        if (f->epoch == rt_.active_epoch &&
            f->target_sample_frame == target_pos) {
          synth_left_[i] += f->left;
          synth_right_[i] += f->right;
          take_playback_ring_buffer_.consumeOne();
          matched = true;
        }
        break;
      }
      if (!matched && hasActiveTakeOverlap(target_pos, 1)) {
        take_underrun = 1;
      }
    }
  }

  // 3. Monitor Foldback, Master Soft Limiter & Post-Limiter Telemetry
  const uint32_t in_ch =
      (input_interleaved != nullptr) ? hardware_config_.input_channels : 0u;
  const uint32_t out_ch = hardware_config_.output_channels;

  float output_peak_l = 0.0f;
  float output_peak_r = 0.0f;
  float sum_sq_out_l = 0.0f;
  float sum_sq_out_r = 0.0f;
  float input_peak = 0.0f;
  float sum_sq_in = 0.0f;

  for (uint32_t i = 0; i < frame_count; ++i) {
    float in_l = 0.0f;
    float in_r = 0.0f;
    if (in_ch == 1) {
      const float s = input_interleaved[i];
      if (std::isfinite(s)) {
        in_l = s;
        in_r = s;
        input_peak = std::max(input_peak, std::fabs(s));
        sum_sq_in += s * s;
      }
    } else if (in_ch >= kStereoChannelCount) {
      const float s_l = input_interleaved[i * in_ch + 0];
      const float s_r = input_interleaved[i * in_ch + 1];
      in_l = std::isfinite(s_l) ? s_l : 0.0f;
      in_r = std::isfinite(s_r) ? s_r : 0.0f;
      input_peak =
          std::max(input_peak, std::max(std::fabs(in_l), std::fabs(in_r)));
      sum_sq_in +=
          (in_l * in_l + in_r * in_r) / static_cast<float>(kStereoChannelCount);
    }

    const float mix_l = synth_left_[i] + in_l * rt_.monitor_gain;
    const float mix_r = synth_right_[i] + in_r * rt_.monitor_gain;
    const float out_l = applySoftLimiter(mix_l);
    const float out_r = applySoftLimiter(mix_r);

    output_peak_l = std::max(output_peak_l, std::fabs(out_l));
    output_peak_r = std::max(output_peak_r, std::fabs(out_r));
    sum_sq_out_l += out_l * out_l;
    sum_sq_out_r += out_r * out_r;

    if (out_ch == 1) {
      output_interleaved[i] = dsp::foldStereoToMono(out_l, out_r);
    } else if (out_ch >= kStereoChannelCount) {
      output_interleaved[i * out_ch + 0] = out_l;
      output_interleaved[i * out_ch + 1] = out_r;
      for (uint32_t ch = kStereoChannelCount; ch < out_ch; ++ch) {
        output_interleaved[i * out_ch + ch] = 0.0f;
      }
    }
  }

  // 4. Recording Capture (CaptureRingBuffer)
  if (rt_.is_capturing && input_interleaved != nullptr && in_ch > 0 &&
      in_ch <= kMaxCaptureChannels) {
    if (!capture_latch_.clock_latched.load(std::memory_order_relaxed)) {
      capture_latch_.captured_sample_clock = rt_.sample_clock;
      capture_latch_.captured_playhead_frame = rt_.playhead_sample_frame;
      capture_latch_.output_buffer_frames = hardware_config_.output_buffer_frames;
      capture_latch_.input_buffer_frames = hardware_config_.input_buffer_frames;
      capture_latch_.clock_latched.store(true, std::memory_order_release);
    }

    const size_t sample_count =
        static_cast<size_t>(frame_count) * static_cast<size_t>(in_ch);
    for (size_t s = 0; s < sample_count; ++s) {
      capture_scratch_[s] =
          std::isfinite(input_interleaved[s]) ? input_interleaved[s] : 0.0f;
    }
    const size_t pushed =
        capture_ring_buffer_.tryPushBatch(capture_scratch_.data(), sample_count);
    if (pushed < sample_count) {
      rt_.capture_overflowed = true;
      rt_.is_capturing = false;
      capture_overflow = 1;
      capture_overflowed_atomic_.store(true, std::memory_order_release);
      capture_active_atomic_.store(false, std::memory_order_release);
      is_capturing_atomic_.store(false, std::memory_order_release);
    }
  }

  // 5. Telemetry Push (Lossy)
  const float inv_frames = 1.0f / static_cast<float>(frame_count);
  TelemetryFrame tf{};
  tf.playhead_sample_frame = rt_.playhead_sample_frame;
  tf.active_epoch = rt_.active_epoch;
  tf.output_peak_l = output_peak_l;
  tf.output_peak_r = output_peak_r;
  tf.output_rms_l = std::sqrt(sum_sq_out_l * inv_frames);
  tf.output_rms_r = std::sqrt(sum_sq_out_r * inv_frames);
  tf.input_peak = input_peak;
  tf.input_rms = std::sqrt(sum_sq_in * inv_frames);
  tf.is_playing = rt_.is_playing ? 1 : 0;
  tf.is_capturing = rt_.is_capturing ? 1 : 0;
  tf.event_queue_underrun = event_underrun;
  tf.capture_buffer_overflow = capture_overflow;
  tf.take_playback_underrun = take_underrun;
  tf.reserved[0] = static_cast<uint8_t>(rt_.loop_pass & 0xFFu);
  tf.reserved[1] = static_cast<uint8_t>((rt_.loop_pass >> 8) & 0xFFu);
  tf.reserved[2] = 0u;
  (void)telemetry_queue_.tryPush(tf);
}

void AudioEngineCore::endCycle(uint32_t frame_count) noexcept {
  rt_.sample_clock += static_cast<int64_t>(frame_count);
  if (rt_.is_playing) {
    rt_.rendered_playback_frames += static_cast<uint64_t>(frame_count);
    rt_.playhead_sample_frame += static_cast<int64_t>(frame_count);
    if (rt_.loop_enabled && !rt_.is_capturing &&
        rt_.loop_end_frame > rt_.loop_start_frame &&
        rt_.playhead_sample_frame >= rt_.loop_end_frame) {
      const int64_t loop_len = rt_.loop_end_frame - rt_.loop_start_frame;
      const int64_t overshoot = rt_.playhead_sample_frame - rt_.loop_end_frame;
      const int64_t wraps = 1 + (overshoot / loop_len);
      rt_.playhead_sample_frame =
          rt_.loop_start_frame + (overshoot % loop_len);
      rt_.loop_pass = static_cast<uint16_t>(
          rt_.loop_pass + static_cast<uint16_t>(wraps));
      if (synth_ != nullptr && !rt_.synth_suspended) {
        fluid_synth_all_notes_off(synth_, kAllMidiChannels);
      }
    }
  }

  publishTransportSnapshot();

  const uint32_t in_ch = std::max<uint32_t>(1u, hardware_config_.input_channels);
  if ((rt_.is_capturing &&
       capture_ring_buffer_.readAvailable() >=
           kButlerWakeWatermarkFrames * static_cast<size_t>(in_ch)) ||
      rt_.is_playing) {
    butler_wake_requested_.store(true, std::memory_order_release);
  }
}

} // namespace muse::engine

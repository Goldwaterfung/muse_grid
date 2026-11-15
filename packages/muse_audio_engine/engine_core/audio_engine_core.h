#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>

#include <fluidsynth.h>

#include "engine_constants.h"
#include "hal_contract.h"
#include "infra/rt_pods.h"
#include "infra/spsc_queue.h"
#include "muse_engine_c_api.h"

namespace muse::engine {

#if !defined(__EMSCRIPTEN__)
class ButlerWorker;
#endif

/// Active timeline sample-frame range of a registered audio take.
struct TakeWindowRange {
  int64_t start_sample_frame = 0;
  int64_t end_sample_frame = 0;
  uint8_t active = 0;
};

/// Real-time per-MIDI-channel dry/FX mix state applied after FluidSynth renders.
struct RtChannelMixState {
  float linear_gain = 1.0f;
  float pan_left = 0.0f;
  float pan_right = 0.0f;
};

/// State owned exclusively by the real-time audio callback thread (L3).
struct RtEngineState {
  int64_t sample_clock = 0;
  int64_t playhead_sample_frame = 0;
  uint64_t active_epoch = 0;
  uint64_t seek_generation = 0;
  uint64_t rendered_playback_frames = 0;
  int64_t scheduled_watermark_frame = 0;
  float monitor_gain = 0.0f;
  bool is_playing = false;
  bool loop_enabled = false;
  int64_t loop_start_frame = 0;
  int64_t loop_end_frame = 0;
  uint16_t loop_pass = 0;
  bool is_capturing = false;
  bool capture_overflowed = false;
  bool synth_suspended = false;
  bool mutation_synth_suspended = false;
  bool has_scheduled_since_play = false;
  uint64_t pending_suspend_seq = 0;
  std::array<RtChannelMixState, kMidiChannelCount> channel_mix{};
};

/// Tear-free cross-thread transport snapshot published by RT via seqlock.
struct RtTransportSnapshot {
  int64_t playhead_sample_frame = 0;
  uint64_t active_epoch = 0;
  uint64_t seek_generation = 0;
  uint64_t rendered_playback_frames = 0;
  int64_t loop_start_frame = 0;
  int64_t loop_end_frame = 0;
  bool is_playing = false;
  bool is_capturing = false;
  bool loop_enabled = false;
};

/// Sample-clock and playhead latch written once on the first captured RT frame.
struct CaptureLatchState {
  std::atomic<bool> clock_latched{false};
  int64_t captured_sample_clock = 0;
  int64_t captured_playhead_frame = 0;
  uint32_t output_buffer_frames = 0;
  uint32_t input_buffer_frames = 0;
  uint64_t total_frames_drained_via_c_api = 0;
};

/// Layer 3 real-time audio engine implementing the 3-phase callback cycle.
class AudioEngineCore final {
 public:
  AudioEngineCore() noexcept;
  ~AudioEngineCore();

  AudioEngineCore(const AudioEngineCore&) = delete;
  AudioEngineCore& operator=(const AudioEngineCore&) = delete;
  AudioEngineCore(AudioEngineCore&&) = delete;
  AudioEngineCore& operator=(AudioEngineCore&&) = delete;

  // Group A — Lifecycle & FluidSynth Setup
  MuseStatus initializeWithHal(
      const IPlatformAudioHal& hal,
      void* hal_handle,
      MuseHardwareConfig* out_cfg);
  MuseStatus initializeWithConfig(const MuseHardwareConfig& explicit_cfg);
  void dispose();
  const MuseHardwareConfig& hardwareConfig() const noexcept {
    return hardware_config_;
  }

  // Group B — Non-RT Command, Event, Take & Telemetry Endpoints
  MuseStatus pushMutation(const MutationCommand& cmd);
  MuseStatus pushEvents(
      const SynthNoteEvent* events,
      uint32_t count,
      uint32_t* out_pushed_count);
  MuseStatus pushTakePlaybackPcm(
      uint64_t epoch,
      int64_t start_sample_frame,
      const float* interleaved_stereo_f32,
      uint32_t frame_count,
      uint32_t* out_pushed_frames);
  void updateTakeWindows(const TakeWindowRange* windows, size_t count);
  void clearTakeWindows();
  uint32_t drainTelemetry(TelemetryFrame* out_frames, uint32_t max_frames);
  uint32_t drainCaptureFrames(
      float* out_interleaved_frames,
      uint32_t max_frames,
      int64_t* out_first_sample_clock);

  // Group C — SoundFont Management & Atomic Suspend Handshake
  MuseStatus loadSoundFontFile(
      const char* posix_path,
      int32_t* out_sf_handle,
      MuseSoundFontPresetPod* out_presets,
      uint32_t max_presets,
      uint32_t* out_preset_count);
  MuseStatus loadSoundFontBytes(
      const uint8_t* bytes,
      uint32_t byte_length,
      int32_t* out_sf_handle,
      MuseSoundFontPresetPod* out_presets,
      uint32_t max_presets,
      uint32_t* out_preset_count);
  MuseStatus unloadSoundFont(int32_t sf_handle);

  // Group D — Capture & Active Take Delegation
  MuseStatus prepareCapture(const char* staging_wav_path);
  MuseStatus startCapture();
  MuseStatus stopAndFinalizeCapture(FinalizedCaptureReceipt* out_receipt);
  MuseStatus registerActiveTake(
      const char* take_id_utf8,
      const char* cas_wav_posix_path,
      int64_t start_sample_frame,
      int64_t duration_frames,
      float gain_db,
      float pan);
  MuseStatus clearActiveTakes();

  // Group E — The 3-Phase RT Audio Callback
  static void audioHalCallback(
      void* user_data,
      const float* input_interleaved,
      float* output_interleaved,
      uint32_t frame_count);
  MuseStatus processBlock(
      const float* input_interleaved,
      float* output_interleaved,
      uint32_t frame_count);
  void startCycle() noexcept;
  void processAudio(
      const float* input_interleaved,
      float* output_interleaved,
      uint32_t frame_count) noexcept;
  void endCycle(uint32_t frame_count) noexcept;

  // Package-internal accessors for ButlerWorker and diagnostics
  int64_t playheadAtomic() const noexcept {
    return playhead_atomic_.load(std::memory_order_acquire);
  }
  uint64_t activeEpochAtomic() const noexcept {
    return active_epoch_atomic_.load(std::memory_order_acquire);
  }
  bool isPlayingAtomic() const noexcept {
    return is_playing_atomic_.load(std::memory_order_acquire);
  }
  bool isCapturingAtomic() const noexcept {
    return is_capturing_atomic_.load(std::memory_order_acquire);
  }
  bool captureActiveAtomic() const noexcept {
    return capture_active_atomic_.load(std::memory_order_acquire);
  }
  bool didCaptureOverflow() const noexcept {
    return capture_overflowed_atomic_.load(std::memory_order_acquire);
  }
  void clearCaptureOverflow() noexcept {
    capture_overflowed_atomic_.store(false, std::memory_order_release);
  }
  bool loopEnabledAtomic() const noexcept {
    return loop_enabled_atomic_.load(std::memory_order_acquire);
  }
  int64_t loopStartAtomic() const noexcept {
    return loop_start_atomic_.load(std::memory_order_acquire);
  }
  int64_t loopEndAtomic() const noexcept {
    return loop_end_atomic_.load(std::memory_order_acquire);
  }
  RtTransportSnapshot readTransportSnapshot() const noexcept;
  bool isHalRunning() const noexcept {
    return hal_running_.load(std::memory_order_acquire);
  }
  bool consumeButlerWakeRequested() noexcept {
    return butler_wake_requested_.exchange(false, std::memory_order_acq_rel);
  }
  size_t takePlaybackReadAvailable() const noexcept {
    return take_playback_ring_buffer_.readAvailable();
  }
  CaptureRingBuffer& captureRingBuffer() noexcept {
    return capture_ring_buffer_;
  }
  TakePlaybackRingBuffer& takePlaybackRingBuffer() noexcept {
    return take_playback_ring_buffer_;
  }
  void invalidateTakePlaybackBuffer(bool allow_offline_reset) noexcept {
    if (allow_offline_reset && !hal_running_.load(std::memory_order_acquire)) {
      take_playback_ring_buffer_.reset();
      take_playback_valid_from_idx_.store(0, std::memory_order_release);
      return;
    }
    take_playback_valid_from_idx_.store(
        take_playback_ring_buffer_.writeIndex(), std::memory_order_release);
  }
  CaptureLatchState& captureLatch() noexcept { return capture_latch_; }
  void resetCaptureStateForPrepare() noexcept;
  void clearCaptureActiveFlagsIfOffline() noexcept;
  void setCaptureDrainPaused(bool paused) noexcept;

 private:
#if !defined(__EMSCRIPTEN__)
  friend class ButlerWorker;
#endif

  // Group F — Private Synth & Signal Math Helpers
  MuseStatus initFluidSynth(uint32_t sample_rate);
  void destroyFluidSynth() noexcept;
  MuseStatus extractSoundFontPresets(
      int32_t sf_handle,
      MuseSoundFontPresetPod* out_presets,
      uint32_t max_presets,
      uint32_t* out_preset_count);
  void applyChannelMix(uint8_t channel, float gain_db, float pan) noexcept;
  MuseStatus renderFluidMultiBusSlice(uint32_t offset, uint32_t count) noexcept;
  void dispatchSynthEvent(const SynthNoteEvent& evt) noexcept;
  static float applySoftLimiter(float sample) noexcept {
    return dsp::applySoftLimiter(sample);
  }

  template <typename Fn>
  MuseStatus executeWithSynthSuspended(Fn&& fn);

  void resetAllState() noexcept;
  void resetRtState() noexcept;
  void publishTransportSnapshot() noexcept;
  void applyMutation(const MutationCommand& cmd) noexcept;
  bool hasActiveTakeOverlap(
      int64_t target_frame,
      uint32_t span_frames) const noexcept;
  static bool isMutationSynthMutating(MutationType type) noexcept;
  static bool isValidHardwareConfig(const MuseHardwareConfig& cfg) noexcept;
  MuseStatus startButlerIfSupported();
  void stopAndJoinButler() noexcept;

  MuseHardwareConfig hardware_config_{};
  const IPlatformAudioHal* hal_ = nullptr;
  void* hal_handle_ = nullptr;

  fluid_settings_t* settings_ = nullptr;
  fluid_synth_t* synth_ = nullptr;

#if !defined(__EMSCRIPTEN__)
  std::unique_ptr<ButlerWorker> butler_worker_;
#endif

  MutationQueue mutation_queue_{};
  EventQueue event_queue_{};
  AuditionQueue audition_queue_{};
  CaptureRingBuffer capture_ring_buffer_{};
  TakePlaybackRingBuffer take_playback_ring_buffer_{};
  std::atomic<size_t> take_playback_valid_from_idx_{0};
  TelemetryQueue telemetry_queue_{};

  std::array<std::array<float, kMaxRenderBlockFrames>, kMidiChannelCount>
      synth_chan_left_{};
  std::array<std::array<float, kMaxRenderBlockFrames>, kMidiChannelCount>
      synth_chan_right_{};
  std::array<float, kMaxRenderBlockFrames> synth_left_{};
  std::array<float, kMaxRenderBlockFrames> synth_right_{};
  std::array<float, kMaxRenderBlockFrames * kMaxCaptureChannels>
      capture_scratch_{};

  std::array<std::array<TakeWindowRange, kMaxActiveTakeRegions>, 2>
      take_windows_{};
  std::atomic<uint8_t> active_take_window_idx_{0};

  RtEngineState rt_{};
  CaptureLatchState capture_latch_{};

  std::atomic<uint64_t> transport_seq_{0};
  std::atomic<int64_t> playhead_atomic_{0};
  std::atomic<uint64_t> active_epoch_atomic_{0};
  std::atomic<uint64_t> seek_generation_atomic_{0};
  std::atomic<uint64_t> rendered_playback_frames_atomic_{0};
  std::atomic<bool> is_playing_atomic_{false};
  std::atomic<bool> is_capturing_atomic_{false};
  std::atomic<bool> capture_active_atomic_{false};
  std::atomic<bool> capture_overflowed_atomic_{false};
  std::atomic<bool> loop_enabled_atomic_{false};
  std::atomic<int64_t> loop_start_atomic_{0};
  std::atomic<int64_t> loop_end_atomic_{0};
  std::atomic<bool> capture_owned_by_butler_{false};
  std::atomic<bool> capture_prepared_without_butler_{false};
  std::atomic<bool> butler_wake_requested_{false};
  std::atomic<bool> hal_running_{false};
  std::atomic<bool> initialized_{false};

  std::atomic<bool> synth_suspend_requested_{false};
  std::atomic<uint64_t> synth_suspend_seq_{0};
  std::atomic<uint64_t> synth_suspend_ack_seq_{0};

  std::mutex mutation_producer_mutex_;
  std::mutex event_producer_mutex_;
  std::mutex take_window_writer_mutex_;
  std::mutex synth_control_mutex_;
};

} // namespace muse::engine

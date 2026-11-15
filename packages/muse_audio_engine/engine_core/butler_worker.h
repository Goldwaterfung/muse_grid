#pragma once

#if !defined(__EMSCRIPTEN__)

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>

#include <miniaudio.h>

#include "engine_constants.h"
#include "hal_contract.h"
#include "infra/rt_pods.h"

namespace muse::engine {

class AudioEngineCore;

/// Pre-opened native WAV decode slot managed exclusively by ButlerWorker.
struct ActiveTakeSlot {
  bool active = false;
  char take_id[kTakeIdBufferSize]{};
  ma_decoder decoder{};
  bool decoder_initialized = false;
  int64_t start_sample_frame = 0;
  int64_t duration_frames = 0;
  int64_t next_read_offset = 0;
  float linear_gain = 1.0f;
  float pan_left = 0.0f;
  float pan_right = 0.0f;
};

/// Synchronous command payload marshaled from non-RT callers onto ButlerWorker.
struct ButlerCommandRequest {
  enum class Kind {
    None = 0,
    PrepareCapture,
    StopAndFinalizeCapture,
    RegisterActiveTake,
    ClearActiveTakes
  };

  Kind kind = Kind::None;
  const char* path_a = nullptr;
  const char* path_b = nullptr;
  int64_t start_sample_frame = 0;
  int64_t duration_frames = 0;
  float gain_db = 0.0f;
  float pan = 0.0f;
  FinalizedCaptureReceipt* out_receipt = nullptr;
  MuseStatus result = MUSE_OK;
  bool done = false;
};

/// Dedicated non-RT disk/codec/SHA-256 worker thread for Native platforms.
class ButlerWorker final {
 public:
  explicit ButlerWorker(AudioEngineCore& core) noexcept;
  ~ButlerWorker();

  ButlerWorker(const ButlerWorker&) = delete;
  ButlerWorker& operator=(const ButlerWorker&) = delete;
  ButlerWorker(ButlerWorker&&) = delete;
  ButlerWorker& operator=(ButlerWorker&&) = delete;

  MuseStatus start();
  void stop();
  void notifyWake();

  MuseStatus prepareCapture(const char* staging_wav_path);
  MuseStatus stopAndFinalizeCapture(FinalizedCaptureReceipt* out_receipt);
  MuseStatus registerActiveTake(
      const char* take_id_utf8,
      const char* cas_wav_posix_path,
      int64_t start_sample_frame,
      int64_t duration_frames,
      float gain_db,
      float pan);
  MuseStatus clearActiveTakes();
  void setCaptureDrainPaused(bool paused) noexcept {
    capture_drain_paused_.store(paused, std::memory_order_release);
  }

  static MuseStatus computeFileSha256(
      const char* file_path,
      char* out_sha256_hex_65);

 private:
  void workerLoop();
  MuseStatus submitCommand(ButlerCommandRequest& request);

  MuseStatus handlePrepareCapture(const char* staging_wav_path);
  MuseStatus handleStopAndFinalizeCapture(FinalizedCaptureReceipt* out_receipt);
  void drainCaptureBufferToEncoder(bool drain_all);

  MuseStatus handleRegisterActiveTake(
      const char* take_id_utf8,
      const char* cas_wav_posix_path,
      int64_t start_sample_frame,
      int64_t duration_frames,
      float gain_db,
      float pan);
  void handleClearActiveTakes();
  void streamTakePlaybackPrefetch();

  void syncTakeWindowsToCore();
  void uninitEncoderIfOpen() noexcept;
  void uninitAllTakeDecoders() noexcept;

  AudioEngineCore& core_;

  std::thread worker_thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> capture_drain_paused_{false};

  std::mutex caller_mutex_;
  std::mutex cmd_mutex_;
  std::condition_variable cmd_cv_;
  std::condition_variable cmd_done_cv_;
  ButlerCommandRequest pending_cmd_{};
  bool wake_hint_ = false;
  bool worker_loop_exited_ = false;

  // Worker-thread-exclusive capture encoder state
  ma_encoder encoder_{};
  bool encoder_initialized_ = false;
  bool capture_active_ = false;
  uint32_t capture_channels_ = 0;
  int64_t encoded_frames_ = 0;
  MuseStatus butler_io_error_ = MUSE_OK;
  char staging_path_[kStagingPathBufferSize]{};

  // Worker-thread-exclusive active take decode/prefetch state
  std::array<ActiveTakeSlot, kMaxActiveTakeRegions> take_slots_{};
  size_t active_take_count_ = 0;
  bool prefetch_dirty_ = false;
  bool prefetch_incomplete_ = false;
  uint64_t prefetch_epoch_ = 0;
  uint64_t prefetch_seek_generation_ = 0;
  int64_t prefetch_cursor_frame_ = 0;
  int64_t last_seen_playhead_for_prefetch_ = 0;
  uint64_t stream_pushed_frames_ = 0;
  uint64_t stream_rendered_baseline_ = 0;
  bool last_loop_active_ = false;
  int64_t last_loop_start_ = 0;
  int64_t last_loop_end_ = 0;

  // Fixed pre-allocated worker scratch buffers
  std::array<float, kCaptureDrainChunkFrames * kMaxCaptureChannels>
      capture_chunk_buffer_{};
  std::array<float, kTakeWorkerChunkFrames * kStereoChannelCount>
      take_decode_scratch_{};
  std::array<float, kTakeWorkerChunkFrames * kStereoChannelCount>
      take_mix_scratch_{};
  std::array<TakePlaybackStereoFrame, kTakeWorkerChunkFrames>
      take_frame_batch_{};
};

} // namespace muse::engine

#endif // !defined(__EMSCRIPTEN__)

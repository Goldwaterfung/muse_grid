#if !defined(__EMSCRIPTEN__)

#include "butler_worker.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

#include <picosha2.h>

#include "audio_engine_core.h"

namespace muse::engine {

ButlerWorker::ButlerWorker(AudioEngineCore& core) noexcept : core_(core) {}

ButlerWorker::~ButlerWorker() {
  stop();
}

MuseStatus ButlerWorker::start() {
  if (running_.load(std::memory_order_acquire) || worker_thread_.joinable()) {
    return MUSE_ERR_STORAGE_IO;
  }

  stop_requested_.store(false, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lock(cmd_mutex_);
    pending_cmd_ = ButlerCommandRequest{};
    wake_hint_ = false;
    worker_loop_exited_ = false;
  }

  try {
    worker_thread_ = std::thread(&ButlerWorker::workerLoop, this);
  } catch (...) {
    stop_requested_.store(false, std::memory_order_release);
    running_.store(false, std::memory_order_release);
    return MUSE_ERR_STORAGE_IO;
  }

  running_.store(true, std::memory_order_release);
  return MUSE_OK;
}

void ButlerWorker::stop() {
  if (worker_thread_.joinable()) {
    stop_requested_.store(true, std::memory_order_release);
    {
      std::lock_guard<std::mutex> lock(cmd_mutex_);
      cmd_cv_.notify_all();
      cmd_done_cv_.notify_all();
    }
    worker_thread_.join();
  }
  running_.store(false, std::memory_order_release);
  uninitEncoderIfOpen();
  uninitAllTakeDecoders();
  capture_active_ = false;
  active_take_count_ = 0;
  prefetch_dirty_ = false;
  prefetch_incomplete_ = false;
}

void ButlerWorker::notifyWake() {
  if (!running_.load(std::memory_order_acquire)) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(cmd_mutex_);
    wake_hint_ = true;
  }
  cmd_cv_.notify_one();
}

MuseStatus ButlerWorker::submitCommand(ButlerCommandRequest& request) {
  std::lock_guard<std::mutex> caller_lock(caller_mutex_);
  if (!running_.load(std::memory_order_acquire) ||
      stop_requested_.load(std::memory_order_acquire)) {
    return MUSE_ERR_STORAGE_IO;
  }

  std::unique_lock<std::mutex> lock(cmd_mutex_);
  if (worker_loop_exited_ || stop_requested_.load(std::memory_order_acquire)) {
    return MUSE_ERR_STORAGE_IO;
  }
  pending_cmd_ = request;
  pending_cmd_.done = false;
  pending_cmd_.result = MUSE_ERR_STORAGE_IO;
  cmd_cv_.notify_one();

  cmd_done_cv_.wait(lock, [&]() {
    return pending_cmd_.done || worker_loop_exited_;
  });
  const MuseStatus status =
      pending_cmd_.done ? pending_cmd_.result : MUSE_ERR_STORAGE_IO;
  pending_cmd_ = ButlerCommandRequest{};
  return status;
}

MuseStatus ButlerWorker::prepareCapture(const char* staging_wav_path) {
  if (staging_wav_path == nullptr || staging_wav_path[0] == '\0') {
    return MUSE_ERR_DEVICE_INIT;
  }
  if (std::strlen(staging_wav_path) >= kStagingPathBufferSize) {
    return MUSE_ERR_STORAGE_IO;
  }

  ButlerCommandRequest req{};
  req.kind = ButlerCommandRequest::Kind::PrepareCapture;
  req.path_a = staging_wav_path;
  return submitCommand(req);
}

MuseStatus ButlerWorker::stopAndFinalizeCapture(
    FinalizedCaptureReceipt* out_receipt) {
  if (out_receipt == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  *out_receipt = FinalizedCaptureReceipt{};
  out_receipt->status = MUSE_ERR_STORAGE_IO;

  ButlerCommandRequest req{};
  req.kind = ButlerCommandRequest::Kind::StopAndFinalizeCapture;
  req.out_receipt = out_receipt;
  return submitCommand(req);
}

MuseStatus ButlerWorker::registerActiveTake(
    const char* take_id_utf8,
    const char* cas_wav_posix_path,
    int64_t start_sample_frame,
    int64_t duration_frames,
    float gain_db,
    float pan) {
  if (take_id_utf8 == nullptr || take_id_utf8[0] == '\0' ||
      std::strlen(take_id_utf8) >= kTakeIdBufferSize ||
      cas_wav_posix_path == nullptr || cas_wav_posix_path[0] == '\0' ||
      std::strlen(cas_wav_posix_path) >= kCasPathBufferSize ||
      start_sample_frame < 0 || duration_frames <= 0 ||
      !std::isfinite(gain_db) || !std::isfinite(pan)) {
    return MUSE_ERR_TAKE_LOAD_FAILED;
  }

  ButlerCommandRequest req{};
  req.kind = ButlerCommandRequest::Kind::RegisterActiveTake;
  req.path_a = take_id_utf8;
  req.path_b = cas_wav_posix_path;
  req.start_sample_frame = start_sample_frame;
  req.duration_frames = duration_frames;
  req.gain_db = gain_db;
  req.pan = pan;
  return submitCommand(req);
}

MuseStatus ButlerWorker::clearActiveTakes() {
  ButlerCommandRequest req{};
  req.kind = ButlerCommandRequest::Kind::ClearActiveTakes;
  return submitCommand(req);
}

void ButlerWorker::workerLoop() {
  while (!stop_requested_.load(std::memory_order_acquire)) {
    ButlerCommandRequest req{};
    bool has_cmd = false;
    {
      std::lock_guard<std::mutex> lock(cmd_mutex_);
      if (pending_cmd_.kind != ButlerCommandRequest::Kind::None &&
          !pending_cmd_.done) {
        req = pending_cmd_;
        has_cmd = true;
      }
    }

    if (has_cmd) {
      MuseStatus st = MUSE_OK;
      switch (req.kind) {
        case ButlerCommandRequest::Kind::PrepareCapture:
          st = handlePrepareCapture(req.path_a);
          break;
        case ButlerCommandRequest::Kind::StopAndFinalizeCapture:
          st = handleStopAndFinalizeCapture(req.out_receipt);
          break;
        case ButlerCommandRequest::Kind::RegisterActiveTake:
          st = handleRegisterActiveTake(req.path_a, req.path_b,
                                        req.start_sample_frame,
                                        req.duration_frames, req.gain_db,
                                        req.pan);
          break;
        case ButlerCommandRequest::Kind::ClearActiveTakes:
          handleClearActiveTakes();
          st = MUSE_OK;
          break;
        default:
          st = MUSE_OK;
          break;
      }

      {
        std::lock_guard<std::mutex> lock(cmd_mutex_);
        pending_cmd_.result = st;
        pending_cmd_.done = true;
      }
      cmd_done_cv_.notify_all();
    }

    if (capture_active_ &&
        !capture_drain_paused_.load(std::memory_order_acquire)) {
      drainCaptureBufferToEncoder(false);
    }

    const RtTransportSnapshot snap = core_.readTransportSnapshot();
    if (active_take_count_ > 0 &&
        (prefetch_dirty_ || prefetch_incomplete_ || snap.is_playing ||
         snap.active_epoch != prefetch_epoch_ ||
         snap.seek_generation != prefetch_seek_generation_ ||
         snap.playhead_sample_frame != last_seen_playhead_for_prefetch_)) {
      streamTakePlaybackPrefetch();
    }

    const bool active =
        capture_active_ ||
        (active_take_count_ > 0 && (snap.is_playing || prefetch_incomplete_));
    const auto poll_ms = std::chrono::milliseconds(
        active ? kButlerPollIntervalMs : kButlerIdlePollIntervalMs);

    std::unique_lock<std::mutex> lock(cmd_mutex_);
    cmd_cv_.wait_for(lock, poll_ms, [&]() {
      return stop_requested_.load(std::memory_order_acquire) ||
             (pending_cmd_.kind != ButlerCommandRequest::Kind::None &&
              !pending_cmd_.done) ||
             wake_hint_ || core_.consumeButlerWakeRequested();
    });
    wake_hint_ = false;
  }

  {
    std::lock_guard<std::mutex> lock(cmd_mutex_);
    if (pending_cmd_.kind != ButlerCommandRequest::Kind::None &&
        !pending_cmd_.done) {
      pending_cmd_.result = MUSE_ERR_STORAGE_IO;
      pending_cmd_.done = true;
    }
    worker_loop_exited_ = true;
  }
  cmd_done_cv_.notify_all();
}

void ButlerWorker::uninitEncoderIfOpen() noexcept {
  if (encoder_initialized_) {
    ma_encoder_uninit(&encoder_);
    encoder_initialized_ = false;
  }
}

void ButlerWorker::uninitAllTakeDecoders() noexcept {
  for (auto& slot : take_slots_) {
    if (slot.decoder_initialized) {
      ma_decoder_uninit(&slot.decoder);
      slot.decoder_initialized = false;
    }
    slot.active = false;
  }
}

void ButlerWorker::syncTakeWindowsToCore() {
  std::array<TakeWindowRange, kMaxActiveTakeRegions> windows{};
  size_t count = 0;
  for (const auto& slot : take_slots_) {
    if (slot.active) {
      windows[count++] = TakeWindowRange{
          slot.start_sample_frame,
          slot.start_sample_frame + slot.duration_frames,
          1,
      };
    }
  }
  active_take_count_ = count;
  core_.updateTakeWindows(windows.data(), count);
}

MuseStatus ButlerWorker::handlePrepareCapture(const char* staging_wav_path) {
  if (capture_active_) {
    return MUSE_ERR_TRANSPORT_NOT_STOPPED;
  }
  const uint32_t channels = core_.hardwareConfig().input_channels;
  if (channels == 0 || channels > kMaxCaptureChannels) {
    return MUSE_ERR_DEVICE_INIT;
  }

  core_.resetCaptureStateForPrepare();

  ma_encoder_config cfg = ma_encoder_config_init(
      ma_encoding_format_wav, ma_format_f32, channels,
      core_.hardwareConfig().sample_rate);
  if (ma_encoder_init_file(staging_wav_path, &cfg, &encoder_) != MA_SUCCESS) {
    return MUSE_ERR_STORAGE_IO;
  }

  encoder_initialized_ = true;
  capture_active_ = true;
  capture_drain_paused_.store(false, std::memory_order_release);
  capture_channels_ = channels;
  encoded_frames_ = 0;
  butler_io_error_ = MUSE_OK;
  std::snprintf(staging_path_, sizeof(staging_path_), "%s", staging_wav_path);
  return MUSE_OK;
}

void ButlerWorker::drainCaptureBufferToEncoder(bool drain_all) {
  const size_t ch = static_cast<size_t>(capture_channels_);
  if (!encoder_initialized_ || ch == 0 || ch > kMaxCaptureChannels) {
    return;
  }

  const size_t min_floats = drain_all ? ch : (kCaptureDrainChunkFrames * ch);
  while (true) {
    const size_t avail_floats = core_.captureRingBuffer().readAvailable();
    if (avail_floats < min_floats) {
      break;
    }

    const size_t avail_frames = avail_floats / ch;
    if (avail_frames == 0) {
      break;
    }

    const size_t chunk_frames =
        std::min<size_t>(avail_frames, kCaptureDrainChunkFrames);
    const size_t chunk_floats = chunk_frames * ch;
    const size_t popped_floats = core_.captureRingBuffer().tryPopBatch(
        capture_chunk_buffer_.data(), chunk_floats);
    const size_t popped_frames = popped_floats / ch;
    if (popped_frames == 0) {
      break;
    }

    ma_uint64 written = 0;
    const ma_result wr = ma_encoder_write_pcm_frames(
        &encoder_, capture_chunk_buffer_.data(),
        static_cast<ma_uint64>(popped_frames), &written);
    if (wr != MA_SUCCESS ||
        written != static_cast<ma_uint64>(popped_frames)) {
      butler_io_error_ = MUSE_ERR_STORAGE_IO;
      break;
    }
    encoded_frames_ += static_cast<int64_t>(written);
  }
}

MuseStatus ButlerWorker::handleStopAndFinalizeCapture(
    FinalizedCaptureReceipt* out_receipt) {
  if (!capture_active_) {
    out_receipt->status = MUSE_ERR_TRANSPORT_NOT_STOPPED;
    return MUSE_ERR_TRANSPORT_NOT_STOPPED;
  }

  MutationCommand stop_cmd{};
  stop_cmd.type = MUT_SET_CAPTURE_STATE;
  stop_cmd.flag_a = 0;

  const auto deadline = std::chrono::steady_clock::now() +
      std::chrono::milliseconds(kButlerDrainTimeoutMs);
  MuseStatus push_status = MUSE_ERR_QUEUE_FULL;
  while (true) {
    push_status = core_.pushMutation(stop_cmd);
    if (push_status != MUSE_ERR_QUEUE_FULL) {
      break;
    }
    if (std::chrono::steady_clock::now() >= deadline ||
        stop_requested_.load(std::memory_order_acquire)) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }

  bool rt_stopped = true;
  if (push_status != MUSE_OK) {
    rt_stopped = false;
  } else {
    while (core_.isHalRunning() && core_.captureActiveAtomic()) {
      if (std::chrono::steady_clock::now() >= deadline ||
          stop_requested_.load(std::memory_order_acquire)) {
        rt_stopped = false;
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }

  if (!rt_stopped) {
    uninitEncoderIfOpen();
    capture_active_ = false;
    core_.clearCaptureActiveFlagsIfOffline();
    (void)std::remove(staging_path_);
    *out_receipt = FinalizedCaptureReceipt{};
    out_receipt->status = MUSE_ERR_STORAGE_IO;
    return MUSE_ERR_STORAGE_IO;
  }

  if (!core_.didCaptureOverflow()) {
    drainCaptureBufferToEncoder(true);
  }
  uninitEncoderIfOpen();
  capture_active_ = false;
  core_.clearCaptureActiveFlagsIfOffline();

  if (butler_io_error_ != MUSE_OK) {
    (void)std::remove(staging_path_);
    *out_receipt = FinalizedCaptureReceipt{};
    out_receipt->status = butler_io_error_;
    return butler_io_error_;
  }

  if (core_.didCaptureOverflow()) {
    (void)std::remove(staging_path_);
    *out_receipt = FinalizedCaptureReceipt{};
    out_receipt->status = MUSE_ERR_CAPTURE_OVERFLOW;
    return MUSE_ERR_CAPTURE_OVERFLOW;
  }

  *out_receipt = FinalizedCaptureReceipt{};
  if (computeFileSha256(staging_path_, out_receipt->sha256_hex) != MUSE_OK) {
    (void)std::remove(staging_path_);
    *out_receipt = FinalizedCaptureReceipt{};
    out_receipt->status = MUSE_ERR_STORAGE_IO;
    return MUSE_ERR_STORAGE_IO;
  }

  const CaptureLatchState& latch = core_.captureLatch();
  if (latch.clock_latched.load(std::memory_order_acquire)) {
    out_receipt->captured_sample_clock = latch.captured_sample_clock;
    out_receipt->captured_playhead_frame = latch.captured_playhead_frame;
    out_receipt->output_buffer_frames = latch.output_buffer_frames;
    out_receipt->input_buffer_frames = latch.input_buffer_frames;
  } else {
    out_receipt->captured_sample_clock = 0;
    out_receipt->captured_playhead_frame = core_.playheadAtomic();
    out_receipt->output_buffer_frames =
        core_.hardwareConfig().output_buffer_frames;
    out_receipt->input_buffer_frames =
        core_.hardwareConfig().input_buffer_frames;
  }
  out_receipt->duration_frames = encoded_frames_;
  out_receipt->sample_rate = core_.hardwareConfig().sample_rate;
  out_receipt->channel_count = static_cast<uint16_t>(capture_channels_);
  std::snprintf(out_receipt->staging_path, sizeof(out_receipt->staging_path),
                "%s", staging_path_);
  out_receipt->status = MUSE_OK;
  return MUSE_OK;
}

MuseStatus ButlerWorker::handleRegisterActiveTake(
    const char* take_id_utf8,
    const char* cas_wav_posix_path,
    int64_t start_sample_frame,
    int64_t duration_frames,
    float gain_db,
    float pan) {
  bool replaced_existing = false;
  ActiveTakeSlot* free_slot = nullptr;
  for (auto& slot : take_slots_) {
    if (slot.active && std::strcmp(slot.take_id, take_id_utf8) == 0) {
      if (slot.decoder_initialized) {
        ma_decoder_uninit(&slot.decoder);
        slot.decoder_initialized = false;
      }
      slot.active = false;
      slot.take_id[0] = '\0';
      free_slot = &slot;
      replaced_existing = true;
      break;
    }
  }
  if (free_slot == nullptr) {
    for (auto& slot : take_slots_) {
      if (!slot.active) {
        free_slot = &slot;
        break;
      }
    }
  }
  if (free_slot == nullptr) {
    return MUSE_ERR_TAKE_LOAD_FAILED;
  }

  ma_decoder_config dec_cfg = ma_decoder_config_init(
      ma_format_f32, kStereoChannelCount, core_.hardwareConfig().sample_rate);
  if (ma_decoder_init_file(cas_wav_posix_path, &dec_cfg, &free_slot->decoder) !=
      MA_SUCCESS) {
    free_slot->decoder_initialized = false;
    if (replaced_existing) {
      syncTakeWindowsToCore();
      core_.invalidateTakePlaybackBuffer(true);
    }
    return MUSE_ERR_TAKE_LOAD_FAILED;
  }
  free_slot->decoder_initialized = true;

  ma_uint64 decoded_length = 0;
  if (ma_decoder_get_length_in_pcm_frames(&free_slot->decoder,
                                          &decoded_length) != MA_SUCCESS ||
      decoded_length == 0 || duration_frames <= 0) {
    ma_decoder_uninit(&free_slot->decoder);
    free_slot->decoder_initialized = false;
    if (replaced_existing) {
      syncTakeWindowsToCore();
      core_.invalidateTakePlaybackBuffer(true);
    }
    return MUSE_ERR_TAKE_LOAD_FAILED;
  }

  free_slot->active = true;
  std::snprintf(free_slot->take_id, sizeof(free_slot->take_id), "%s",
                take_id_utf8);
  free_slot->start_sample_frame = start_sample_frame;
  free_slot->duration_frames =
      std::min<int64_t>(duration_frames, static_cast<int64_t>(decoded_length));
  free_slot->next_read_offset = 0;
  free_slot->linear_gain = dsp::dbToLinear(gain_db);
  const dsp::StereoPanGains pan_gains = dsp::computeConstantPowerPan(pan);
  free_slot->pan_left = pan_gains.left;
  free_slot->pan_right = pan_gains.right;

  syncTakeWindowsToCore();
  core_.invalidateTakePlaybackBuffer(true);
  prefetch_dirty_ = true;
  // Force prefetch alignment cleanly from the current transport snapshot.
  const RtTransportSnapshot snap = core_.readTransportSnapshot();
  prefetch_epoch_ = snap.active_epoch;
  prefetch_seek_generation_ = snap.seek_generation;
  prefetch_cursor_frame_ =
      (snap.loop_enabled && !snap.is_capturing &&
       snap.loop_end_frame > snap.loop_start_frame &&
       snap.playhead_sample_frame >= snap.loop_end_frame)
          ? snap.loop_start_frame
          : snap.playhead_sample_frame;
  last_seen_playhead_for_prefetch_ = snap.playhead_sample_frame;
  stream_rendered_baseline_ = snap.rendered_playback_frames;
  stream_pushed_frames_ = 0;
  return MUSE_OK;
}

void ButlerWorker::handleClearActiveTakes() {
  uninitAllTakeDecoders();
  syncTakeWindowsToCore();
  core_.invalidateTakePlaybackBuffer(true);
  prefetch_dirty_ = false;
  prefetch_incomplete_ = false;
  const RtTransportSnapshot snap = core_.readTransportSnapshot();
  prefetch_epoch_ = snap.active_epoch;
  prefetch_seek_generation_ = snap.seek_generation;
  prefetch_cursor_frame_ = snap.playhead_sample_frame;
  last_seen_playhead_for_prefetch_ = snap.playhead_sample_frame;
  stream_rendered_baseline_ = snap.rendered_playback_frames;
  stream_pushed_frames_ = 0;
}

void ButlerWorker::streamTakePlaybackPrefetch() {
  if (active_take_count_ == 0) {
    return;
  }
  prefetch_incomplete_ = false;

  const RtTransportSnapshot snap = core_.readTransportSnapshot();
  const uint64_t epoch = snap.active_epoch;
  const uint64_t seek_gen = snap.seek_generation;
  const int64_t playhead = snap.playhead_sample_frame;
  const int64_t loop_start = snap.loop_start_frame;
  const int64_t loop_end = snap.loop_end_frame;
  const bool loop_active =
      snap.loop_enabled && !snap.is_capturing && loop_end > loop_start;

  const bool loop_changed =
      (loop_active != last_loop_active_) ||
      (loop_active &&
       (loop_start != last_loop_start_ || loop_end != last_loop_end_));

  const bool backward_seek_same_epoch =
      (!loop_active && playhead < last_seen_playhead_for_prefetch_);

  const bool cursor_invalid_for_loop = loop_active &&
      (prefetch_cursor_frame_ >= loop_end ||
       (playhead >= loop_start && prefetch_cursor_frame_ < loop_start) ||
       (playhead < loop_start && prefetch_cursor_frame_ < playhead));

  const uint64_t initial_rendered_since_reset =
      (snap.rendered_playback_frames >= stream_rendered_baseline_)
          ? (snap.rendered_playback_frames - stream_rendered_baseline_)
          : 0u;
  const bool loop_underrun =
      loop_active && !prefetch_dirty_ &&
      (initial_rendered_since_reset > stream_pushed_frames_);

  if (prefetch_dirty_ || epoch != prefetch_epoch_ ||
      seek_gen != prefetch_seek_generation_ || loop_changed ||
      backward_seek_same_epoch ||
      (!loop_active && prefetch_cursor_frame_ < playhead) ||
      cursor_invalid_for_loop || loop_underrun) {
    prefetch_dirty_ = false;
    prefetch_epoch_ = epoch;
    prefetch_seek_generation_ = seek_gen;
    prefetch_cursor_frame_ =
        (loop_active && playhead >= loop_end) ? loop_start : playhead;
    last_loop_active_ = loop_active;
    last_loop_start_ = loop_start;
    last_loop_end_ = loop_end;
    stream_pushed_frames_ = 0;
    stream_rendered_baseline_ = snap.rendered_playback_frames;
    core_.invalidateTakePlaybackBuffer(false);
  }
  last_seen_playhead_for_prefetch_ = playhead;

  while (true) {
    const RtTransportSnapshot cur = core_.readTransportSnapshot();
    const bool cur_loop_active =
        cur.loop_enabled && !cur.is_capturing &&
        cur.loop_end_frame > cur.loop_start_frame;
    if (cur.active_epoch != prefetch_epoch_ ||
        cur.seek_generation != prefetch_seek_generation_ ||
        cur_loop_active != loop_active ||
        (loop_active && (cur.loop_start_frame != loop_start ||
                         cur.loop_end_frame != loop_end))) {
      break;
    }

    int64_t stream_ahead = 0;
    if (loop_active) {
      const uint64_t rendered_since_reset =
          (cur.rendered_playback_frames >= stream_rendered_baseline_)
              ? (cur.rendered_playback_frames - stream_rendered_baseline_)
              : 0u;
      if (rendered_since_reset > stream_pushed_frames_) {
        break;
      }
      stream_ahead =
          static_cast<int64_t>(stream_pushed_frames_ - rendered_since_reset);
    } else {
      stream_ahead = std::max<int64_t>(
          0, prefetch_cursor_frame_ - cur.playhead_sample_frame);
    }

    if (stream_ahead >= kTakePrefetchFrames) {
      break;
    }

    const int64_t remaining_budget = kTakePrefetchFrames - stream_ahead;
    if (remaining_budget <= 0) {
      break;
    }

    int64_t chunk64 = std::min<int64_t>(
        remaining_budget, static_cast<int64_t>(kTakeWorkerChunkFrames));
    if (loop_active) {
      chunk64 = std::min<int64_t>(chunk64, loop_end - prefetch_cursor_frame_);
    }
    if (chunk64 <= 0) {
      break;
    }

    const uint32_t chunk = static_cast<uint32_t>(chunk64);
    if (core_.takePlaybackRingBuffer().writeAvailable() < chunk) {
      prefetch_incomplete_ = true;
      break;
    }

    std::fill_n(take_mix_scratch_.data(),
                static_cast<size_t>(chunk) * kStereoChannelCount, 0.0f);

    const int64_t chunk_start = prefetch_cursor_frame_;
    const int64_t chunk_end = chunk_start + chunk64;

    for (size_t s = 0; s < kMaxActiveTakeRegions; ++s) {
      ActiveTakeSlot& slot = take_slots_[s];
      if (!slot.active || !slot.decoder_initialized) {
        continue;
      }
      const int64_t slot_end = slot.start_sample_frame + slot.duration_frames;
      const int64_t ov_start = std::max(chunk_start, slot.start_sample_frame);
      const int64_t ov_end = std::min(chunk_end, slot_end);
      if (ov_start >= ov_end) {
        continue;
      }

      const int64_t desired_decoder_offset = ov_start - slot.start_sample_frame;
      if (slot.next_read_offset != desired_decoder_offset) {
        if (ma_decoder_seek_to_pcm_frame(
                &slot.decoder,
                static_cast<ma_uint64>(desired_decoder_offset)) != MA_SUCCESS) {
          continue;
        }
        slot.next_read_offset = desired_decoder_offset;
      }

      const ma_uint64 to_read = static_cast<ma_uint64>(ov_end - ov_start);
      ma_uint64 frames_read = 0;
      const ma_result r = ma_decoder_read_pcm_frames(
          &slot.decoder, take_decode_scratch_.data(), to_read, &frames_read);
      if (r != MA_SUCCESS && r != MA_AT_END) {
        continue;
      }
      slot.next_read_offset += static_cast<int64_t>(frames_read);

      const uint32_t dst_offset =
          static_cast<uint32_t>(ov_start - chunk_start);
      const float gain_l = slot.linear_gain * slot.pan_left;
      const float gain_r = slot.linear_gain * slot.pan_right;
      for (ma_uint64 f = 0; f < frames_read; ++f) {
        const size_t src_idx = static_cast<size_t>(f) * kStereoChannelCount;
        const size_t dst_idx =
            (static_cast<size_t>(dst_offset) + static_cast<size_t>(f)) *
            kStereoChannelCount;
        take_mix_scratch_[dst_idx + 0] +=
            take_decode_scratch_[src_idx + 0] * gain_l;
        take_mix_scratch_[dst_idx + 1] +=
            take_decode_scratch_[src_idx + 1] * gain_r;
      }
    }

    for (uint32_t i = 0; i < chunk; ++i) {
      const size_t idx = static_cast<size_t>(i) * kStereoChannelCount;
      take_frame_batch_[i] = TakePlaybackStereoFrame{
          epoch,
          chunk_start + static_cast<int64_t>(i),
          take_mix_scratch_[idx + 0],
          take_mix_scratch_[idx + 1],
      };
    }

    const size_t pushed = core_.takePlaybackRingBuffer().tryPushBatch(
        take_frame_batch_.data(), chunk);
    if (pushed < chunk) {
      break;
    }

    stream_pushed_frames_ += static_cast<uint64_t>(chunk);
    prefetch_cursor_frame_ += chunk64;
    if (loop_active && prefetch_cursor_frame_ >= loop_end) {
      prefetch_cursor_frame_ = loop_start;
    }
  }
}

MuseStatus ButlerWorker::computeFileSha256(
    const char* file_path,
    char* out_sha256_hex_65) {
  if (file_path == nullptr || out_sha256_hex_65 == nullptr) {
    return MUSE_ERR_STORAGE_IO;
  }

  std::ifstream ifs(file_path, std::ios::binary);
  if (!ifs.is_open()) {
    return MUSE_ERR_STORAGE_IO;
  }

  std::vector<uint8_t> buf(kSha256FileChunkBytes);
  picosha2::hash256_one_by_one hasher;
  while (ifs.good()) {
    ifs.read(reinterpret_cast<char*>(buf.data()),
             static_cast<std::streamsize>(buf.size()));
    const std::streamsize got = ifs.gcount();
    if (got > 0) {
      hasher.process(buf.begin(), buf.begin() + got);
    }
  }
  if (ifs.bad() || !ifs.eof()) {
    return MUSE_ERR_STORAGE_IO;
  }

  hasher.finish();
  const std::string hex = picosha2::get_hash_hex_string(hasher);
  if (hex.size() != kSha256HexLength) {
    return MUSE_ERR_STORAGE_IO;
  }

  std::memcpy(out_sha256_hex_65, hex.data(), kSha256HexLength);
  out_sha256_hex_65[kSha256HexLength] = '\0';
  return MUSE_OK;
}

} // namespace muse::engine

#endif // !defined(__EMSCRIPTEN__)

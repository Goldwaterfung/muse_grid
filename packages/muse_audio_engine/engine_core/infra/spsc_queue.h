#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <type_traits>

#include "../engine_constants.h"
#include "rt_pods.h"

namespace muse::engine {

/// Lock-free, wait-free single-producer single-consumer circular ring buffer.
/// Free-running monotonic indices with power-of-two masking allow all
/// `Capacity` slots to be filled without sacrificing a sentinel slot or
/// performing any heap allocations.
template <typename T, size_t Capacity>
class SpscRingBuffer {
  static_assert(std::is_trivially_copyable_v<T>,
                "SpscRingBuffer element type must be trivially copyable");
  static_assert(Capacity >= 2 && (Capacity & (Capacity - 1)) == 0,
                "SpscRingBuffer Capacity must be a power of two >= 2");

 public:
  SpscRingBuffer() noexcept = default;
  SpscRingBuffer(const SpscRingBuffer&) = delete;
  SpscRingBuffer& operator=(const SpscRingBuffer&) = delete;

  /// Producer-only single-item push. Returns `false` if the ring is full.
  bool tryPush(const T& item) noexcept {
    const size_t w = write_idx_.load(std::memory_order_relaxed);
    const size_t r = read_idx_.load(std::memory_order_acquire);
    if ((w - r) >= Capacity) {
      return false;
    }
    buffer_[w & kMask] = item;
    write_idx_.store(w + 1, std::memory_order_release);
    return true;
  }

  /// Producer-only batch push. Copies up to `count` items across up to two
  /// wrap-around slices and publishes the updated write cursor once.
  size_t tryPushBatch(const T* items, size_t count) noexcept {
    if (items == nullptr || count == 0) {
      return 0;
    }
    const size_t w = write_idx_.load(std::memory_order_relaxed);
    const size_t r = read_idx_.load(std::memory_order_acquire);
    const size_t used = w - r;
    if (used >= Capacity) {
      return 0;
    }
    const size_t avail = Capacity - used;
    const size_t n = std::min(count, avail);
    const size_t start = w & kMask;
    const size_t first_chunk = std::min(n, Capacity - start);
    std::memcpy(&buffer_[start], items, first_chunk * sizeof(T));
    const size_t second_chunk = n - first_chunk;
    if (second_chunk > 0) {
      std::memcpy(&buffer_[0], items + first_chunk, second_chunk * sizeof(T));
    }
    write_idx_.store(w + n, std::memory_order_release);
    return n;
  }

  /// Consumer-only single-item pop. Returns `false` if the ring is empty.
  bool tryPop(T& out_item) noexcept {
    const size_t r = read_idx_.load(std::memory_order_relaxed);
    const size_t w = write_idx_.load(std::memory_order_acquire);
    if (r == w) {
      return false;
    }
    out_item = buffer_[r & kMask];
    read_idx_.store(r + 1, std::memory_order_release);
    return true;
  }

  /// Consumer-only batch pop. Returns the number of elements popped.
  size_t tryPopBatch(T* out_items, size_t max_count) noexcept {
    if (out_items == nullptr || max_count == 0) {
      return 0;
    }
    const size_t r = read_idx_.load(std::memory_order_relaxed);
    const size_t w = write_idx_.load(std::memory_order_acquire);
    const size_t avail = w - r;
    if (avail == 0) {
      return 0;
    }
    const size_t n = std::min(max_count, avail);
    const size_t start = r & kMask;
    const size_t first_chunk = std::min(n, Capacity - start);
    std::memcpy(out_items, &buffer_[start], first_chunk * sizeof(T));
    const size_t second_chunk = n - first_chunk;
    if (second_chunk > 0) {
      std::memcpy(out_items + first_chunk, &buffer_[0], second_chunk * sizeof(T));
    }
    read_idx_.store(r + n, std::memory_order_release);
    return n;
  }

  /// Consumer-only zero-copy inspection of the oldest queued item.
  const T* peek() const noexcept {
    const size_t r = read_idx_.load(std::memory_order_relaxed);
    const size_t w = write_idx_.load(std::memory_order_acquire);
    if (r == w) {
      return nullptr;
    }
    return &buffer_[r & kMask];
  }

  /// Consumer-only cursor advance paired with `peek()`.
  void consumeOne() noexcept {
    const size_t r = read_idx_.load(std::memory_order_relaxed);
    const size_t w = write_idx_.load(std::memory_order_acquire);
    if (r != w) {
      read_idx_.store(r + 1, std::memory_order_release);
    }
  }

  size_t readAvailable() const noexcept {
    // Load consumer cursor before producer cursor so `w - r` cannot underflow.
    const size_t r = read_idx_.load(std::memory_order_acquire);
    const size_t w = write_idx_.load(std::memory_order_acquire);
    return std::min(w - r, Capacity);
  }

  size_t writeAvailable() const noexcept {
    return Capacity - readAvailable();
  }

  size_t writeIndex() const noexcept {
    return write_idx_.load(std::memory_order_acquire);
  }

  /// Consumer-only O(1) discard up to `min_read_idx` (clamped by write cursor).
  void consumeUpToIndex(size_t min_read_idx) noexcept {
    const size_t r = read_idx_.load(std::memory_order_relaxed);
    const size_t w = write_idx_.load(std::memory_order_acquire);
    const size_t target = std::min(min_read_idx, w);
    if (target > r) {
      read_idx_.store(target, std::memory_order_release);
    }
  }

  bool empty() const noexcept { return readAvailable() == 0; }
  bool full() const noexcept { return readAvailable() >= Capacity; }
  static constexpr size_t capacity() noexcept { return Capacity; }

  /// Non-concurrent reset: call only when neither producer nor consumer runs.
  void reset() noexcept {
    write_idx_.store(0, std::memory_order_release);
    read_idx_.store(0, std::memory_order_release);
  }

 private:
  static constexpr size_t kMask = Capacity - 1;

  std::array<T, Capacity> buffer_{};
  alignas(kCacheLineBytes) std::atomic<size_t> write_idx_{0};
  alignas(kCacheLineBytes) std::atomic<size_t> read_idx_{0};
};

// Pre-allocated L2 queue types owned by AudioEngineCore.
using MutationQueue = SpscRingBuffer<MutationCommand, kMutationQueueCapacity>;
using EventQueue = SpscRingBuffer<SynthNoteEvent, kEventQueueCapacity>;
using AuditionQueue = SpscRingBuffer<SynthNoteEvent, kAuditionQueueCapacity>;
using CaptureRingBuffer =
    SpscRingBuffer<float, kCaptureRingCapacityFrames * kMaxCaptureChannels>;
using TakePlaybackRingBuffer =
    SpscRingBuffer<TakePlaybackStereoFrame, kTakePlaybackRingCapacityFrames>;
using TelemetryQueue = SpscRingBuffer<TelemetryFrame, kTelemetryQueueCapacity>;

} // namespace muse::engine

// Internals shared by the engine's sources.
#pragma once

#include <inkling/inkling.hpp>

#include <atomic>
#include <bit>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace inkling
{
  [[noreturn]] inline void fail(std::string const &what)
  {
    throw std::runtime_error{ "inkling: " + what };
  }

  inline float bf16_to_f32(uint16_t const h)
  {
    return std::bit_cast<float>(static_cast<uint32_t>(h) << 16);
  }

  // Round to nearest even, as MLX and PyTorch do.
  inline uint16_t f32_to_bf16(float const f)
  {
    uint32_t const u{ std::bit_cast<uint32_t>(f) };
    if((u & 0x7fffffffu) > 0x7f800000u)
    {
      return static_cast<uint16_t>((u >> 16) | 0x40);
    }
    return static_cast<uint16_t>((u + 0x7fffu + ((u >> 16) & 1u)) >> 16);
  }

  inline float round_bf16(float const f)
  {
    return bf16_to_f32(f32_to_bf16(f));
  }

  // The caches' element: an IEEE half.
  inline uint16_t f32_to_half(float const f)
  {
    return std::bit_cast<uint16_t>(static_cast<_Float16>(f));
  }

  inline float half_to_f32(uint16_t const h)
  {
    return static_cast<float>(std::bit_cast<_Float16>(h));
  }

  // Fork-join workers. run(n, grain, fn) calls fn(begin, end) on chunks of
  // [0, n) of at most `grain` items, on the workers and the calling thread,
  // and returns when all are done.
  struct pool
  {
    explicit pool(int32_t n);
    ~pool();

    void run(int64_t n, int64_t grain, std::function<void(int64_t, int64_t)> const &fn);
    int32_t size() const { return static_cast<int32_t>(threads.size()) + 1; }

    // A job lives on the caller's stack; `current` points to it while it runs.
    struct job
    {
      std::function<void(int64_t, int64_t)> const *task{};
      int64_t total{};
      int64_t chunk{};
      std::atomic<int64_t> next{ 0 };
      std::atomic<int64_t> remaining{ 0 };
    };

    std::vector<std::thread> threads;
    std::mutex mutex;
    std::condition_variable wake;
    std::atomic<uint64_t> generation{ 0 };
    std::atomic<job *> current{ nullptr };
    // Workers that may be reading `current`. A worker announces itself
    // (active) and then reads current; run clears current and then waits for
    // active to be 0. Each side stores and then loads the other's variable,
    // so all four operations are sequentially consistent: with weaker
    // orders both loads may miss the other's store, and a worker would run a
    // job whose run() has returned (specs/models/Pool.lean).
    std::atomic<int32_t> active{ 0 };
    std::atomic<bool> stopping{ false };

    static void work(job &j);
    // `seen` is the generation when the pool made the thread: a worker that
    // starts after a job or the shutdown was announced still notices it.
    void worker_loop(uint64_t seen);
  };

  int32_t default_threads();

  struct scratch;
  void forward(session &s, int32_t const *ids, int32_t n);

  // The Metal backend (metal.mm). metal_open gives null when it can't run
  // this model. metal_new_session allocates the session's caches (s.caches
  // must have their sizes). metal_forward with `force` overwrites the GPU's
  // values with force's after every stage (see check.cpp).
  metal_backend *metal_open(model &m);
  void metal_close(metal_backend *b);
  metal_session *metal_new_session(session &s);
  // The CPU path's y[t] = W x[t] (W [rows, in]) and RMS norm, for the draft model.
  void cpu_linear(model const &m, tensor const *w, float const *x, int32_t tokens, float *y);
  void cpu_rmsnorm(float const *x, float const *w, int64_t n, float eps, float *out);
  // A drafter's depth.
  int32_t draft_depth(drafter const &d);
  // The session's ring of taps for a draft model, of n BF16 values, in memory
  // the GPU writes and the CPU reads.
  uint16_t *metal_tap_ring(session &s, size_t n);
  void metal_free_session(metal_session *g);
  void metal_forward(session &s, int32_t const *ids, int32_t n, capture const *force = nullptr);

  // NVFP4 decoding tables.
  inline constexpr float e2m1_values[16]{ 0.0f,  0.5f,  1.0f,  1.5f,  2.0f,  3.0f,  4.0f,  6.0f,
                                          -0.0f, -0.5f, -1.0f, -1.5f, -2.0f, -3.0f, -4.0f, -6.0f };

  inline float e4m3_to_f32(uint8_t const b)
  {
    int const sign{ (b & 0x80) ? -1 : 1 };
    int const e{ (b >> 3) & 0xf };
    int const m{ b & 7 };
    if(e == 0xf && m == 7)
    {
      return NAN;
    }
    if(e == 0)
    {
      return static_cast<float>(sign) * std::ldexp(static_cast<float>(m) / 8.0f, -6);
    }
    return static_cast<float>(sign) * std::ldexp(1.0f + static_cast<float>(m) / 8.0f, e - 7);
  }
}

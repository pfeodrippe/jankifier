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
  // The draft model (draft.cpp, docs/drafting.md).
  struct metal_drafter;
  struct drafter
  {
    struct layer_weights
    {
      tensor const *mix_norm{}, *ctx_k{}, *ctx_v{}, *ctx_k_norm{}, *input_norm{}, *q{}, *k{}, *v{}, *q_norm{}, *k_norm{},
        *o{}, *post_norm{}, *gate{}, *up{}, *down{};
    };

    model *m{};
    int32_t layers{}, heads{}, kv_heads{}, head_dim{}, block{}, rank{}, window{}, slots{};
    float eps{}, theta{};
    // The target visits whose partial sums the drafter reads, then the final
    // norm's output: session::tap_visits.
    std::vector<int32_t> visits;
    // Softmax of the fuse weights, rounded: [layers + 1][taps].
    std::vector<std::vector<float>> alpha;
    std::vector<layer_weights> lw;
    tensor const *mask_embed{}, *final_norm{}, *markov_norm{}, *markov_embed{}, *rnn{}, *rnn_bias{}, *hidden_out{},
      *hidden_bias{};
    // The context ring: each layer's keys (normed, rotated) and values,
    // [kv_heads][slots][head_dim] (on the CPU; on the GPU in `gpu`), and each
    // slot's position (-1: empty). Positions before `fed` are in the ring (or
    // were dropped).
    std::vector<std::vector<float>> ring_k, ring_v;
    std::vector<int64_t> ring_pos;
    int64_t fed{};
    // The most drafts a check takes (set_draft_depth), and the depth chosen for
    // the next check (choose_depth): oMLX's adaptive depth, from each depth's
    // measured time and the acceptance at each position.
    // The CPU version (the reference), even for a GPU session.
    bool cpu{};
    int32_t depth{ 7 };
    // Off: every check drafts `depth` tokens (for measuring acceptance).
    bool adaptive{ true };
    struct control
    {
      // Acceptance of draft j + 1 when the drafts before it were accepted (-1:
      // not measured yet, the one before is used).
      float accept[8]{ 0.6f, -1, -1, -1, -1, -1, -1, -1 };
      // Milliseconds of a check with d drafts (0: not measured yet).
      double ms[8]{};
      int32_t cur{};
      // Checks so far; the first ones measure each depth once.
      int64_t checks{};
      // Checks and drafts kept by depth (stats_of).
      int64_t at_depth[8]{}, kept_at[8]{};
      // Milliseconds in all, by depth: of the checks, of their drafts.
      double total_ms[8]{}, draft_ms[8]{};
    } ctl;
    metal_drafter *gpu{};

    ~drafter();
  };
  // The drafts for the next check, and what it gave: `drafted` drafts,
  // `accepted` of them, in `ms` milliseconds.
  int32_t choose_depth(drafter &d);
  void observe_check(drafter &d, int32_t drafted, int32_t accepted, double ms, double draft_ms);
  // The draft on the GPU: the context rows [from, s.pos) into the ring (whose
  // positions d.ring_pos already has), then `count` proposals after `anchor`.
  std::vector<int32_t> metal_draft(drafter &d, session const &s, int64_t from, int32_t anchor, int32_t count);
  void metal_free_drafter(metal_drafter *g);
  // The drafter's GPU buffers, and the model's fold of the output head for
  // the Markov head (made once, about 0.3 s).
  void metal_prepare_drafter(drafter &d, session const &s);
  // The drafter forgets its context (the session was reset or replaced): it is
  // read again from the session's hidden states at the next draft.
  void forget_context(drafter &d);
  // The session's ring of taps for a draft model, of n BF16 values, in memory
  // the GPU writes and the CPU reads.
  uint16_t *metal_tap_ring(session &s, size_t n);
  void metal_free_session(metal_session *g);
  void metal_forward(session &s, int32_t const *ids, int32_t n, capture const *force = nullptr);
  // One token for each of `sessions` (ids[i] is sessions[i]'s), in one forward: each
  // session ends as after its own metal_forward of that token.
  void metal_forward_batch(std::vector<session *> const &sessions, int32_t const *ids);

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

#pragma once

// The conformance tests' C++: what they read from the engine (libinkling) that inkling.core
// doesn't give as data, done here so that megabytes of cache rows aren't turned into jank values.
// Everything goes through the engine's public header, except the thread pool (native/internal.hpp).

#include <inkling/jank.hpp>

#include <internal.hpp>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace inkling_specs
{
  namespace rt = ::jank::runtime;
  using rt::object_ref;
  using namespace inkling::jank_layer;

  inline object_ref sh(object_ref const cmd)
  {
    std::string const command{ "( " + to_std(cmd) + " ) 2>&1" };
    FILE *const p{ popen(command.c_str(), "r") };
    if(!p)
    {
      return str("(couldn't start it)");
    }
    std::string out;
    char buf[4096];
    size_t n{};
    while((n = std::fread(buf, 1, sizeof buf, p)) > 0)
    {
      out.append(buf, n);
    }
    pclose(p);
    return str(out);
  }

  inline object_ref set_capturing(object_ref const s, object_ref const on)
  {
    session_of(s)->capturing = rt::truthy(on);
    return rt::jank_nil;
  }

  inline object_ref set_record(object_ref const s, object_ref const on)
  {
    session_of(s)->record = rt::truthy(on);
    return rt::jank_nil;
  }

  /* The Metal forward's stream bookkeeping of the last chunk: [kind visit slot]. */
  inline object_ref events(object_ref const s)
  {
    static char const *const kinds[]{ "take", "push", "restart", "release", "read", "write" };
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(auto const &e : session_of(s)->events)
    {
      object_ref row{ rt::obj::persistent_vector::empty() };
      row = rt::conj(row, kw(kinds[static_cast<int32_t>(e.k)]));
      row = rt::conj(row, num(e.visit));
      row = rt::conj(row, num(e.slot));
      v = rt::conj(v, row);
    }
    return v;
  }

  /* The sizes of each visit's cache. */
  inline object_ref cache_shapes(object_ref const s)
  {
    auto const ses{ session_of(s) };
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(size_t i{}; i < ses->caches.size(); ++i)
    {
      auto const &c{ ses->caches[i] };
      v = rt::conj(v,
                   map_builder{}("visit", num(static_cast<int64_t>(i)))("slots", num(c.slots))(
                     "local",
                     boolean(ses->model->plan[i].local))("width", num(c.kv_heads * c.head_dim))
                     .m);
    }
    return v;
  }

  /* The keys and values each position was given when it was written, per visit, from the
   * engine's captures: what the ring's slots are compared with later. */
  struct row_log
  {
    size_t positions{};
    std::vector<std::vector<uint16_t>> k, v;
  };

  inline std::vector<std::unique_ptr<row_log>> &logs()
  {
    static std::vector<std::unique_ptr<row_log>> all;
    return all;
  }

  inline object_ref log_new(object_ref const s)
  {
    auto const ses{ session_of(s) };
    auto log{ std::make_unique<row_log>() };
    log->k.resize(ses->caches.size());
    log->v.resize(ses->caches.size());
    logs().push_back(std::move(log));
    return num(static_cast<int64_t>(logs().size() - 1));
  }

  /* Appends the rows of the chunk the session just evaluated (with capturing on). */
  inline object_ref log_append(object_ref const handle, object_ref const s)
  {
    return guarded([&] {
      auto const ses{ session_of(s) };
      auto &log{ *logs().at(static_cast<size_t>(to_int(handle))) };
      auto const &cap{ ses->captured };
      if(static_cast<size_t>(cap.pos) != log.positions)
      {
        throw std::runtime_error{ "inkling-specs: the capture is of position " + std::to_string(cap.pos)
                                  + ", and the log has " + std::to_string(log.positions) + " positions" };
      }
      if(cap.visits.size() != ses->caches.size())
      {
        throw std::runtime_error{ "inkling-specs: the capture has " + std::to_string(cap.visits.size()) + " visits" };
      }
      for(size_t vi{}; vi < cap.visits.size(); ++vi)
      {
        auto const &c{ ses->caches[vi] };
        auto const width{ static_cast<size_t>(c.kv_heads) * c.head_dim };
        auto const &vc{ cap.visits[vi] };
        if(vc.k.size() != width * cap.tokens || vc.v.size() != width * cap.tokens)
        {
          throw std::runtime_error{ "inkling-specs: visit " + std::to_string(vi) + "'s captured rows have the wrong size" };
        }
        log.k[vi].insert(log.k[vi].end(), vc.k.begin(), vc.k.end());
        log.v[vi].insert(log.v[vi].end(), vc.v.begin(), vc.v.end());
      }
      log.positions += static_cast<size_t>(cap.tokens);
      return num(static_cast<int64_t>(log.positions));
    });
  }

  /* For every visit: the positions the token at `pos - 1` attends to (its window in a local
   * visit, every position in a global one), each looked up in the ring at slot
   * `position % slots` (the model's slotOf) and compared with the row logged for it. */
  inline object_ref ring_check(object_ref const handle, object_ref const s)
  {
    return guarded([&] {
      auto const ses{ session_of(s) };
      auto const &log{ *logs().at(static_cast<size_t>(to_int(handle))) };
      auto const window{ ses->model->cfg.window };
      object_ref out{ rt::obj::persistent_vector::empty() };
      int64_t const p{ ses->pos - 1 };
      for(size_t vi{}; vi < ses->caches.size(); ++vi)
      {
        auto const &c{ ses->caches[vi] };
        bool const local{ ses->model->plan[vi].local };
        auto const width{ static_cast<size_t>(c.kv_heads) * c.head_dim };
        int64_t const first{ local ? std::max<int64_t>(0, p - window + 1) : 0 };
        int64_t checked{}, wrong{}, first_wrong{ -1 };
        for(int64_t j{ first }; j <= p; ++j)
        {
          auto const slot{ static_cast<size_t>(j % c.slots) };
          bool const same{ std::memcmp(c.k + slot * width, log.k[vi].data() + static_cast<size_t>(j) * width, width * 2) == 0
                           && std::memcmp(c.v + slot * width, log.v[vi].data() + static_cast<size_t>(j) * width, width * 2) == 0 };
          ++checked;
          if(!same)
          {
            ++wrong;
            if(first_wrong < 0)
            {
              first_wrong = j;
            }
          }
        }
        out = rt::conj(out,
                       map_builder{}("visit", num(static_cast<int64_t>(vi)))("local", boolean(local))(
                         "slots",
                         num(c.slots))("checked", num(checked))("wrong", num(wrong))("first-wrong", num(first_wrong))
                         .m);
      }
      return out;
    });
  }

  /* How many of a row's elements differ, bit for bit, between a visit's cache in two
   * sessions (keys: which = 0, values: 1). The rows are compared as stored (16-bit floats),
   * whatever their encoding. */
  inline object_ref row_diff(object_ref const a, object_ref const slot_a, object_ref const b, object_ref const slot_b,
                             object_ref const visit, object_ref const which)
  {
    return guarded([&] {
      auto const &ca{ session_of(a)->caches.at(static_cast<size_t>(to_int(visit))) };
      auto const &cb{ session_of(b)->caches.at(static_cast<size_t>(to_int(visit))) };
      auto const width{ static_cast<size_t>(ca.kv_heads) * ca.head_dim };
      auto const *ra{ (to_int(which) == 0 ? ca.k : ca.v) + static_cast<size_t>(to_int(slot_a)) * width };
      auto const *rb{ (to_int(which) == 0 ? cb.k : cb.v) + static_cast<size_t>(to_int(slot_b)) * width };
      int64_t differing{};
      for(size_t i{}; i < width; ++i)
      {
        differing += ra[i] != rb[i];
      }
      return num(differing);
    });
  }

  inline uint64_t fnv(uint64_t h, void const *data, size_t n)
  {
    auto const *p{ static_cast<unsigned char const *>(data) };
    for(size_t i{}; i < n; ++i)
    {
      h = (h ^ p[i]) * 1099511628211ull;
    }
    return h;
  }

  inline object_ref hex(uint64_t const h)
  {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%016llx", static_cast<unsigned long long>(h));
    return str(buf);
  }

  /* Digests of a session's state: the keys and values of the positions each visit still
   * holds (by position, so that two sessions compare whatever their slots), the convolution
   * histories, the logits and the tokens. */
  inline object_ref digest(object_ref const s)
  {
    auto const ses{ session_of(s) };
    uint64_t kv{ 1469598103934665603ull }, conv{ kv }, logits{ kv }, tokens{ kv };
    auto const tail{ static_cast<size_t>(ses->model->cfg.conv_taps - 1) };
    auto const window{ ses->model->cfg.window };
    int64_t const p{ ses->pos - 1 };
    for(size_t vi{}; vi < ses->caches.size(); ++vi)
    {
      auto const &c{ ses->caches[vi] };
      auto const width{ static_cast<size_t>(c.kv_heads) * c.head_dim };
      bool const local{ ses->model->plan[vi].local };
      for(int64_t j{ local ? std::max<int64_t>(0, p - window + 1) : 0 }; j <= p; ++j)
      {
        auto const slot{ static_cast<size_t>(j % c.slots) };
        kv = fnv(kv, c.k + slot * width, width * 2);
        kv = fnv(kv, c.v + slot * width, width * 2);
      }
      for(size_t i{}; i < 4; ++i)
      {
        conv = fnv(conv, c.conv[i], tail * static_cast<size_t>(c.conv_width[i]) * sizeof(float));
      }
    }
    logits = fnv(logits, ses->logits.data(), ses->logits.size() * sizeof(float));
    tokens = fnv(tokens, ses->tokens.data(), ses->tokens.size() * sizeof(int32_t));
    return map_builder{}("pos", num(ses->pos))("kv", hex(kv))("conv", hex(conv))("logits", hex(logits))("tokens",
                                                                                                         hex(tokens))
      .m;
  }

  /* How far two sessions' states are: the largest difference of the convolution histories
   * relative to the history's largest value (visit 0's key and value histories, which are
   * projections of the embeddings; all of visit 0's; and over all visits), of the logits,
   * and whether the most likely next token is the same. */
  inline object_ref distance(object_ref const a, object_ref const b)
  {
    return guarded([&] {
      auto const sa{ session_of(a) };
      auto const sb{ session_of(b) };
      auto const tail{ static_cast<size_t>(sa->model->cfg.conv_taps - 1) };
      double first{}, first_kv{}, all{};
      for(size_t vi{}; vi < sa->caches.size(); ++vi)
      {
        for(size_t i{}; i < 4; ++i)
        {
          auto const n{ tail * static_cast<size_t>(sa->caches[vi].conv_width[i]) };
          double worst{}, scale{};
          for(size_t x{}; x < n; ++x)
          {
            auto const fa{ sa->caches[vi].conv[i][x] };
            auto const fb{ sb->caches[vi].conv[i][x] };
            worst = std::max(worst, static_cast<double>(std::abs(fa - fb)));
            scale = std::max(scale, static_cast<double>(std::abs(fa)));
          }
          double const rel{ scale > 0 ? worst / scale : worst };
          all = std::max(all, rel);
          if(vi == 0)
          {
            first = std::max(first, rel);
            if(i < 2)
            {
              first_kv = std::max(first_kv, rel);
            }
          }
        }
      }
      double logit{};
      size_t arg_a{}, arg_b{};
      for(size_t i{}; i < sa->logits.size() && i < sb->logits.size(); ++i)
      {
        logit = std::max(logit, static_cast<double>(std::abs(sa->logits[i] - sb->logits[i])));
        if(sa->logits[i] > sa->logits[arg_a])
        {
          arg_a = i;
        }
        if(sb->logits[i] > sb->logits[arg_b])
        {
          arg_b = i;
        }
      }
      return map_builder{}("kv-conv-visit-0", real(first_kv))("conv-visit-0", real(first))("conv", real(all))(
               "logits",
               real(logit))(
               "same-top",
               boolean(arg_a == arg_b))
        .m;
    });
  }

  /* A digest of a field of a visit's capture, for the chunk's last token: "attended". */
  inline object_ref captured_attended(object_ref const s, object_ref const visit)
  {
    return guarded([&] {
      auto const ses{ session_of(s) };
      auto const &vc{ ses->captured.visits.at(static_cast<size_t>(to_int(visit))) };
      auto const tokens{ static_cast<size_t>(ses->captured.tokens) };
      if(tokens == 0 || vc.attended.empty())
      {
        throw std::runtime_error{ "inkling-specs: nothing captured" };
      }
      auto const width{ vc.attended.size() / tokens };
      return hex(fnv(1469598103934665603ull, vc.attended.data() + (tokens - 1) * width, width * sizeof(float)));
    });
  }

  /* The engine's two checks of a plan, copied here so that they can be given any shape:
   * parse_config's (native/model.cpp: "unsupported loop") and metal_open's count of sources,
   * message sources and live slots (native/metal.mm), over the visits in execution_plan's
   * order. Returns :config (parse_config fails), :cpu-only (metal_open gives null) or :gpu. */
  inline object_ref plan_verdict(object_ref const layers_, object_ref const block_, object_ref const has_loop,
                                 object_ref const start_, object_ref const end_, object_ref const passes_,
                                 object_ref const slots_)
  {
    auto const layers{ to_int(layers_) }, block{ to_int(block_) }, start{ to_int(start_) }, end{ to_int(end_) },
      passes{ to_int(passes_) };
    auto const stream_slots{ static_cast<size_t>(to_int(slots_)) };
    bool const loop{ rt::truthy(has_loop) };
    if(loop && (start % block != 0 || end % block != 0 || start < 0 || end > layers || start >= end || passes < 2))
    {
      return kw("config");
    }
    struct visit
    {
      int64_t layer, pass;
    };
    std::vector<visit> plan;
    int64_t const loop_end{ loop ? end : layers };
    for(int64_t l{}; l < loop_end; ++l)
    {
      plan.push_back({ l, 0 });
    }
    if(loop)
    {
      for(int64_t p{ 1 }; p < passes; ++p)
      {
        for(int64_t l{ start }; l < end; ++l)
        {
          plan.push_back({ l, p });
        }
      }
    }
    for(int64_t l{ loop_end }; l < layers; ++l)
    {
      plan.push_back({ l, 0 });
    }
    size_t blocks{}, previous{}, prelude{}, live{ 1 };
    for(auto const &v : plan)
    {
      bool const looped{ loop && v.layer == start };
      if(looped && v.pass == 0)
      {
        prelude = blocks;
      }
      else if(looped)
      {
        if(blocks < prelude + 1)
        {
          return kw("cpu-only");
        }
        live -= previous;
        previous = blocks - prelude;
        blocks = prelude;
      }
      if(v.layer % block == 0)
      {
        ++blocks;
        ++live;
      }
      if(blocks + 1 > 6 || previous > 2 || live > stream_slots)
      {
        return kw("cpu-only");
      }
    }
    return kw("gpu");
  }

  /* The thread pool: `rounds` jobs of random sizes and grains; counts the jobs after which
   * some index wasn't processed exactly once. */
  inline object_ref pool_stress(object_ref const workers, object_ref const rounds, object_ref const seed)
  {
    inkling::pool p{ static_cast<int32_t>(to_int(workers)) };
    constexpr int64_t max_n{ 4096 };
    std::vector<std::atomic<int32_t>> hits(static_cast<size_t>(max_n));
    uint64_t rng{ static_cast<uint64_t>(to_int(seed)) * 2654435761u + 1 };
    auto const next{ [&] {
      rng ^= rng << 13;
      rng ^= rng >> 7;
      rng ^= rng << 17;
      return rng;
    } };
    int64_t wrong{};
    auto const n_rounds{ to_int(rounds) };
    for(int64_t r{}; r < n_rounds; ++r)
    {
      auto const n{ static_cast<int64_t>(1 + next() % max_n) };
      auto const grain{ static_cast<int64_t>(1 + next() % 64) };
      for(int64_t i{}; i < n; ++i)
      {
        hits[static_cast<size_t>(i)].store(0, std::memory_order_relaxed);
      }
      p.run(n, grain, [&](int64_t a, int64_t b) {
        for(int64_t i{ a }; i < b; ++i)
        {
          hits[static_cast<size_t>(i)].fetch_add(1, std::memory_order_relaxed);
        }
      });
      for(int64_t i{}; i < n; ++i)
      {
        if(hits[static_cast<size_t>(i)].load() != 1)
        {
          ++wrong;
          break;
        }
      }
    }
    return map_builder{}("rounds", num(n_rounds))("wrong", num(wrong)).m;
  }

  /* Creates and destroys pools, `rounds` times, with `run_first` jobs in between, on another
   * thread; if that takes longer than `timeout_ms` the destructor is stuck (the thread is
   * left behind: end the process with _exit). */
  inline object_ref pool_churn(object_ref const workers, object_ref const rounds, object_ref const run_first,
                               object_ref const timeout_ms)
  {
    struct shared
    {
      std::atomic<int64_t> completed{ 0 };
      std::atomic<bool> done{ false };
    };
    auto const st{ std::make_shared<shared>() };
    auto const n_workers{ static_cast<int32_t>(to_int(workers)) };
    auto const n_rounds{ to_int(rounds) };
    auto const jobs{ to_int(run_first) };
    std::thread{ [st, n_workers, n_rounds, jobs] {
      for(int64_t r{}; r < n_rounds; ++r)
      {
        {
          inkling::pool p{ n_workers };
          std::atomic<int64_t> sum{ 0 };
          for(int64_t j{}; j < jobs; ++j)
          {
            p.run(64, 1, [&](int64_t a, int64_t b) { sum.fetch_add(b - a); });
          }
        }
        st->completed.fetch_add(1);
      }
      st->done.store(true);
    } }.detach();
    auto const deadline{ std::chrono::steady_clock::now() + std::chrono::milliseconds{ to_int(timeout_ms) } };
    while(!st->done.load() && std::chrono::steady_clock::now() < deadline)
    {
      std::this_thread::sleep_for(std::chrono::milliseconds{ 5 });
    }
    return map_builder{}("rounds", num(n_rounds))("completed", num(st->completed.load()))("hung",
                                                                                           boolean(!st->done.load()))
      .m;
  }
}

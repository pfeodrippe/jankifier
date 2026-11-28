#pragma once

// The part of bomsom that has to be C++: the functions SuperCollider's server calls on its own
// threads (one for each reply, one for each printout), and the queues and the wait for /synced
// that they share with jank. No jank code runs on those threads: jank's GC doesn't know them.
// Everything else (starting the server, OSC, SynthDefs) is jank, in bomsom.core.

#include <SC_WorldOptions.h>

#include <jank/runtime/core.hpp>
#include <jank/runtime/core/make_box.hpp>

#include <bit>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace bomsom
{
  inline char const *plugin_dir{ SUPERCOLLIDER_SYS_PLUGIN_DIR };

  inline std::mutex lock;
  inline std::condition_variable changed;
  inline std::deque<std::vector<char>> replies;
  inline std::deque<std::string> log;
  inline int64_t last_synced{ -1 };

  // A reply, kept as its OSC bytes for jank to decode; a /synced's id is read here, for
  // wait_synced. It comes on one of the server's threads.
  inline void on_reply(ReplyAddress *, char *data, int size)
  {
    std::lock_guard<std::mutex> const l{ lock };
    // "/synced" padded to 8 bytes, ",i" to 4, then the id as a big-endian int32.
    if(size >= 16 && std::memcmp(data, "/synced\0,i\0\0", 12) == 0)
    {
      auto const *u{ reinterpret_cast<unsigned char const *>(data + 12) };
      last_synced = static_cast<int32_t>((uint32_t{ u[0] } << 24) | (uint32_t{ u[1] } << 16)
                                         | (uint32_t{ u[2] } << 8) | uint32_t{ u[3] });
    }
    replies.emplace_back(data, data + size);
    if(replies.size() > 1000) { replies.pop_front(); }
    changed.notify_all();
  }

  // What the server prints: kept, and also written on stdout.
  inline int on_print(char const *format, va_list ap)
  {
    char buf[4096];
    va_list copy;
    va_copy(copy, ap);
    int const n{ std::vsnprintf(buf, sizeof buf, format, copy) };
    va_end(copy);
    std::fputs(buf, stdout);
    std::fflush(stdout);
    std::lock_guard<std::mutex> const l{ lock };
    if(log.empty() || (!log.back().empty() && log.back().back() == '\n')) { log.emplace_back(buf); }
    else { log.back() += buf; }
    if(log.size() > 1000) { log.pop_front(); }
    return n;
  }

  // Waits for the /synced of the /sync with this id. False after the timeout.
  inline bool wait_synced(int64_t id, int64_t timeout_ms)
  {
    std::unique_lock<std::mutex> l{ lock };
    return changed.wait_for(l, std::chrono::milliseconds{ timeout_ms }, [&] { return last_synced == id; });
  }

  // Moves the oldest reply not yet taken into `out`; false when there's none.
  inline bool next_reply(std::vector<char> &out)
  {
    std::lock_guard<std::mutex> const l{ lock };
    if(replies.empty()) { return false; }
    out = std::move(replies.front());
    replies.pop_front();
    return true;
  }

  // The oldest printout not yet taken, or "" when there's none.
  inline jank::runtime::object_ref next_log()
  {
    std::lock_guard<std::mutex> const l{ lock };
    std::string s;
    if(!log.empty())
    {
      s = std::move(log.front());
      log.pop_front();
    }
    return jank::runtime::make_box<jank::runtime::obj::persistent_string>(
      jtl::immutable_string{ s.data(), s.size() });
  }

  inline void sleep_ms(int64_t ms) { std::this_thread::sleep_for(std::chrono::milliseconds{ ms }); }

  // IEEE 754 bits, for OSC's and SynthDefs' float32 and OSC's float64.
  inline int64_t float_bits(double x) { return std::bit_cast<uint32_t>(static_cast<float>(x)); }
  inline double float_from_bits(int64_t b) { return std::bit_cast<float>(static_cast<uint32_t>(b)); }
  inline double double_from_bits(int64_t hi, int64_t lo)
  {
    return std::bit_cast<double>((uint64_t{ static_cast<uint32_t>(hi) } << 32) | static_cast<uint32_t>(lo));
  }
}

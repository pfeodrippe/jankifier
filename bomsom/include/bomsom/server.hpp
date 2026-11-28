#pragma once

// bomsom's C++: SuperCollider's server (libscsynth, from supercollider-sys) running in this
// process with the audio device, OSC messages built and sent to it, and its replies and
// printouts kept until jank asks for them.

#include <SC_WorldOptions.h>

#include <jank/runtime/core.hpp>
#include <jank/runtime/core/make_box.hpp>

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
  inline std::string to_std(jank::runtime::object_ref const o)
  {
    auto const s{ o.to_string() };
    return std::string{ s.data(), s.size() };
  }

  inline jank::runtime::object_ref to_jank(std::string const &s)
  {
    return jank::runtime::make_box<jank::runtime::obj::persistent_string>(
      jtl::immutable_string{ s.data(), s.size() });
  }

  // Big-endian bytes: OSC (strings and blobs padded to 4 bytes) and SynthDef files (strings
  // prefixed by their length).
  struct bytes
  {
    std::vector<char> b;

    void i8(int v) { b.push_back(static_cast<char>(v & 0xff)); }
    void i16(int v) { i8(v >> 8); i8(v); }
    void i32(int64_t v) { for(int s{ 24 }; s >= 0; s -= 8) { i8(static_cast<int>(v >> s)); } }
    void f32(float v) { uint32_t u; std::memcpy(&u, &v, 4); i32(u); }
    void pad() { while(b.size() % 4) { i8(0); } }
    void osc_string(std::string const &s) { b.insert(b.end(), s.begin(), s.end()); i8(0); pad(); }
    void osc_blob(std::vector<char> const &d) { i32(static_cast<int64_t>(d.size())); b.insert(b.end(), d.begin(), d.end()); pad(); }
    void pstring(std::string const &s) { i8(static_cast<int>(s.size())); b.insert(b.end(), s.begin(), s.end()); }
  };

  // Replies (each decoded to one line: the address and its arguments) and the server's
  // printouts, kept until jank takes them. A reply comes on one of the server's threads.
  inline std::mutex lock;
  inline std::condition_variable changed;
  inline std::deque<std::string> replies, log;
  inline int64_t last_synced{ -1 };
  inline World *world{};

  inline std::string osc_string_at(char const *&p, char const *end)
  {
    std::string s;
    while(p < end && *p) { s += *p++; }
    p += 4 - (s.size() % 4);
    return s;
  }

  inline int32_t osc_i32_at(char const *&p)
  {
    uint32_t u{};
    for(int i{}; i < 4; ++i) { u = (u << 8) | static_cast<uint8_t>(p[i]); }
    p += 4;
    return static_cast<int32_t>(u);
  }

  inline std::string decode(char const *data, int size)
  {
    char const *p{ data }, *end{ data + size };
    auto out{ osc_string_at(p, end) };
    if(p >= end || *p != ',') { return out; }
    auto const tags{ osc_string_at(p, end) };
    for(size_t i{ 1 }; i < tags.size() && p < end; ++i)
    {
      out += ' ';
      switch(tags[i])
      {
        case 'i': out += std::to_string(osc_i32_at(p)); break;
        case 'f':
        {
          auto const u{ static_cast<uint32_t>(osc_i32_at(p)) };
          float f;
          std::memcpy(&f, &u, 4);
          out += std::to_string(f);
          break;
        }
        case 'd':
        {
          uint64_t const u{ (static_cast<uint64_t>(static_cast<uint32_t>(osc_i32_at(p))) << 32)
                            | static_cast<uint32_t>(osc_i32_at(p)) };
          double d;
          std::memcpy(&d, &u, 8);
          out += std::to_string(d);
          break;
        }
        case 's': out += osc_string_at(p, end); break;
        case 'b':
        {
          auto const n{ osc_i32_at(p) };
          out += "<" + std::to_string(n) + " bytes>";
          p += (n + 3) / 4 * 4;
          break;
        }
        default: out += std::string{ "<" } + tags[i] + ">"; break;
      }
    }
    return out;
  }

  inline void on_reply(ReplyAddress *, char *data, int size)
  {
    auto line{ decode(data, size) };
    std::lock_guard<std::mutex> const l{ lock };
    if(line.rfind("/synced ", 0) == 0)
    {
      last_synced = std::stoll(line.substr(8));
    }
    replies.push_back(std::move(line));
    if(replies.size() > 1000) { replies.pop_front(); }
    changed.notify_all();
  }

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
    if(log.empty() || !log.back().empty() && log.back().back() == '\n') { log.emplace_back(buf); }
    else { log.back() += buf; }
    if(log.size() > 1000) { log.pop_front(); }
    return n;
  }

  // Starts the server on the default audio device: 2 outputs, no inputs (so macOS doesn't ask
  // for the microphone), the plugins of supercollider-sys. A UDP port above 0 also lets OSC
  // clients (sclang, the IDE) talk to it. 0 when it started.
  inline int start(int udp_port)
  {
    if(world) { return 1; }
    SetPrintFunc(on_print);
    WorldOptions options;
    options.mUGensPluginPath = SUPERCOLLIDER_SYS_PLUGIN_DIR;
    options.mLoadGraphDefs = 0;
    options.mNumInputBusChannels = 0;
    options.mNumOutputBusChannels = 2;
    world = World_New(&options);
    if(!world) { return 2; }
    if(udp_port > 0 && !World_OpenUDP(world, "127.0.0.1", udp_port)) { return 3; }
    return 0;
  }

  inline void stop()
  {
    if(world)
    {
      World_Cleanup(world, true);
      world = nullptr;
    }
  }

  inline bool running() { return world != nullptr; }

  inline void sleep_ms(int64_t ms) { std::this_thread::sleep_for(std::chrono::milliseconds{ ms }); }

  // One message at a time: begun with its address, given its arguments, then sent.
  inline std::string address, tags;
  inline bytes args;

  inline void begin(jank::runtime::object_ref const addr)
  {
    address = to_std(addr);
    tags = ",";
    args = {};
  }

  inline void add_int(int64_t v) { tags += 'i'; args.i32(v); }
  inline void add_float(double v) { tags += 'f'; args.f32(static_cast<float>(v)); }
  inline void add_string(jank::runtime::object_ref const v) { tags += 's'; args.osc_string(to_std(v)); }
  inline void add_blob(std::vector<char> const &v) { tags += 'b'; args.osc_blob(v); }

  inline bool send()
  {
    if(!world) { return false; }
    bytes m;
    m.osc_string(address);
    m.osc_string(tags);
    m.b.insert(m.b.end(), args.b.begin(), args.b.end());
    return World_SendPacket(world, static_cast<int>(m.b.size()), m.b.data(), on_reply);
  }

  // Sends /sync and waits for its /synced: every command sent before it (a SynthDef loading)
  // has finished. False after the timeout. The ids count here, so reloading the jank
  // namespace doesn't start them again.
  inline int64_t sync_ids{};

  inline bool sync(int64_t timeout_ms)
  {
    int64_t const id{ ++sync_ids };
    begin(to_jank("/sync"));
    add_int(id);
    if(!send()) { return false; }
    std::unique_lock<std::mutex> l{ lock };
    return changed.wait_for(l, std::chrono::milliseconds{ timeout_ms }, [&] { return last_synced == id; });
  }

  // The oldest reply or printout not yet taken, or "" when there's none.
  inline jank::runtime::object_ref next_reply()
  {
    std::lock_guard<std::mutex> const l{ lock };
    if(replies.empty()) { return to_jank(""); }
    auto s{ std::move(replies.front()) };
    replies.pop_front();
    return to_jank(s);
  }

  inline jank::runtime::object_ref next_log()
  {
    std::lock_guard<std::mutex> const l{ lock };
    if(log.empty()) { return to_jank(""); }
    auto s{ std::move(log.front()) };
    log.pop_front();
    return to_jank(s);
  }

  // The SynthDef "bomsom-sine", written byte by byte (SynthDef file format version 2):
  // Out.ar(0, [s, s]) with s = SinOsc.ar(freq) * amp, controls freq = 440 and amp = 0.1.
  inline std::vector<char> sine_def()
  {
    bytes d;
    d.b = { 'S', 'C', 'g', 'f' };
    d.i32(2);
    d.i16(1);
    d.pstring("bomsom-sine");
    d.i32(1); d.f32(0.0f);                          // constants: 0 (SinOsc's phase, Out's bus)
    d.i32(2); d.f32(440.0f); d.f32(0.1f);           // controls' initial values
    d.i32(2); d.pstring("freq"); d.i32(0); d.pstring("amp"); d.i32(1);
    d.i32(4);                                       // UGens: name, rate, inputs, outputs, special index
    d.pstring("Control"); d.i8(1); d.i32(0); d.i32(2); d.i16(0);
    d.i8(1); d.i8(1);
    d.pstring("SinOsc"); d.i8(2); d.i32(2); d.i32(1); d.i16(0);
    d.i32(0); d.i32(0);                             // freq: Control's output 0
    d.i32(-1); d.i32(0);                            // phase: constant 0
    d.i8(2);
    d.pstring("BinaryOpUGen"); d.i8(2); d.i32(2); d.i32(1); d.i16(2);   // 2 is *
    d.i32(1); d.i32(0);                             // SinOsc's output
    d.i32(0); d.i32(1);                             // amp: Control's output 1
    d.i8(2);
    d.pstring("Out"); d.i8(2); d.i32(3); d.i32(0); d.i16(0);
    d.i32(-1); d.i32(0);                            // bus: constant 0
    d.i32(2); d.i32(0);                             // left
    d.i32(2); d.i32(0);                             // right
    d.i16(0);                                       // variants
    return d.b;
  }

  inline bool send_sine_def()
  {
    begin(to_jank("/d_recv"));
    add_blob(sine_def());
    return send();
  }
}

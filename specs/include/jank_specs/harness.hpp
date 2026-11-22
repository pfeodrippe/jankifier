#pragma once

/* What the conformance harnesses (src/jank_specs/harness.jank) need from C++: processes with
 * their output captured, nREPL connections (TCP and bencode), file times, and temporary
 * directories. Values cross to jank as jank objects (lean_sys/jank.hpp's helpers). */

#include <lean_sys/jank.hpp>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <mutex>
#include <string>
#include <thread>


extern char **environ;

namespace jank_specs::harness
{
  namespace rt = ::jank::runtime;
  using rt::object_ref;
  using lean_sys::jank_layer::guarded;
  using lean_sys::jank_layer::istr;
  using lean_sys::jank_layer::kw;
  using lean_sys::jank_layer::str;
  using lean_sys::jank_layer::to_std;

  inline constexpr char const *process_box{ "jank_specs::process" };
  inline constexpr char const *connection_box{ "jank_specs::connection" };

  template <typename T>
  T *unbox(object_ref const o, char const *type)
  {
    auto const b{ lean_sys::jank_layer::as_box(o, type) };
    if(!b.is_some())
    {
      throw std::runtime_error{ std::string{ "not a " } + type };
    }
    return static_cast<T *>(b->data.data);
  }

  /* A child process: `/bin/sh -c command`, in `dir`, its stdout and stderr captured by a thread,
   * its stdin a pipe kept open (a `jank repl` exits when its stdin closes). */
  struct process
  {
    pid_t pid{};
    int out_fd{ -1 };
    int in_fd{ -1 };
    std::mutex m;
    std::string output;
    std::thread reader;
    bool reaped{};
    int exit_code{ -1 };
  };

  inline object_ref spawn(object_ref const command, object_ref const dir)
  {
    return guarded([&] {
      int out[2], in[2];
      if(pipe(out) != 0 || pipe(in) != 0)
      {
        throw std::runtime_error{ "pipe failed" };
      }
      posix_spawn_file_actions_t fa;
      posix_spawn_file_actions_init(&fa);
      posix_spawn_file_actions_adddup2(&fa, in[0], 0);
      posix_spawn_file_actions_adddup2(&fa, out[1], 1);
      posix_spawn_file_actions_adddup2(&fa, out[1], 2);
      posix_spawnattr_t attr;
      posix_spawnattr_init(&attr);
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
      /* Only the three descriptors above: not this process's sockets. */
      posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
#endif
      std::string const script{ "cd '" + to_std(dir) + "' && exec " + to_std(command) };
      char const *argv[]{ "/bin/sh", "-c", script.c_str(), nullptr };
      auto const p{ new process{} };
      if(posix_spawn(&p->pid, "/bin/sh", &fa, &attr, const_cast<char **>(argv), environ) != 0)
      {
        delete p;
        throw std::runtime_error{ "posix_spawn failed" };
      }
      posix_spawn_file_actions_destroy(&fa);
      posix_spawnattr_destroy(&attr);
      close(out[1]);
      close(in[0]);
      p->out_fd = out[0];
      p->in_fd = in[1];
      p->reader = std::thread{ [p] {
        char buf[8192];
        for(;;)
        {
          auto const n{ ::read(p->out_fd, buf, sizeof buf) };
          if(n <= 0)
          {
            break;
          }
          std::lock_guard<std::mutex> const lock{ p->m };
          p->output.append(buf, static_cast<size_t>(n));
        }
      } };
      return object_ref{ rt::make_box<rt::obj::opaque_box>(jtl::ptr<void>{ p }, istr(process_box)) };
    });
  }

  inline object_ref output(object_ref const o)
  {
    auto const p{ unbox<process>(o, process_box) };
    std::lock_guard<std::mutex> const lock{ p->m };
    return str(p->output);
  }

  inline void reap(process *p, bool const block)
  {
    if(p->reaped)
    {
      return;
    }
    int status{};
    if(waitpid(p->pid, &status, block ? 0 : WNOHANG) == p->pid)
    {
      p->reaped = true;
      p->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
      if(p->reader.joinable())
      {
        p->reader.join();
      }
      close(p->out_fd);
      close(p->in_fd);
    }
  }

  /* The exit code, after waiting up to `timeout_ms` for the process to end; nil if it hasn't. */
  inline object_ref wait(object_ref const o, int64_t const timeout_ms)
  {
    auto const p{ unbox<process>(o, process_box) };
    auto const deadline{ std::chrono::steady_clock::now() + std::chrono::milliseconds{ timeout_ms } };
    for(;;)
    {
      reap(p, false);
      if(p->reaped)
      {
        return rt::make_box(static_cast<int64_t>(p->exit_code));
      }
      if(std::chrono::steady_clock::now() >= deadline)
      {
        return rt::jank_nil;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds{ 5 });
    }
  }

  inline object_ref kill(object_ref const o)
  {
    auto const p{ unbox<process>(o, process_box) };
    if(!p->reaped)
    {
      ::kill(p->pid, SIGKILL);
      reap(p, true);
    }
    return rt::jank_nil;
  }

  /* Bencode. Strings and keywords encode as strings, integers as integers, sequential
   * collections as lists, maps as dicts (keys sorted). Dicts decode to maps with keyword keys. */
  inline void encode(object_ref const v, std::string &out)
  {
    if(rt::is_integer(v))
    {
      out += "i" + std::to_string(v.to_integer()) + "e";
    }
    else if(rt::is_map(v))
    {
      std::vector<std::pair<std::string, object_ref>> entries;
      for(auto s{ rt::seq(v) }; !rt::is_nil(s); s = rt::next(s))
      {
        auto const e{ rt::first(s) };
        auto const k{ rt::nth(e, rt::make_box(static_cast<int64_t>(0))) };
        entries.emplace_back(rt::is_keyword(k) ? lean_sys::jank_layer::source{}.text(k) : to_std(k),
                             rt::nth(e, rt::make_box(static_cast<int64_t>(1))));
      }
      std::sort(entries.begin(), entries.end(), [](auto const &a, auto const &b) {
        return a.first < b.first;
      });
      out += "d";
      for(auto const &[k, x] : entries)
      {
        out += std::to_string(k.size()) + ":" + k;
        encode(x, out);
      }
      out += "e";
    }
    else if(rt::is_string(v) || rt::is_keyword(v) || rt::is_symbol(v))
    {
      auto const s{ rt::is_string(v) ? to_std(v) : lean_sys::jank_layer::source{}.text(v) };
      out += std::to_string(s.size()) + ":" + s;
    }
    else if(rt::is_seqable(v))
    {
      out += "l";
      for(auto s{ rt::seq(v) }; !rt::is_nil(s); s = rt::next(s))
      {
        encode(rt::first(s), out);
      }
      out += "e";
    }
    else
    {
      throw std::runtime_error{ "can't bencode " + to_std(v) };
    }
  }

  /* Decodes one value at `i`; false (with `i` unchanged) if `b` holds an incomplete one. */
  inline bool decode(std::string const &b, size_t &i, object_ref &out)
  {
    if(i >= b.size())
    {
      return false;
    }
    auto j{ i };
    auto const c{ b[j] };
    if(c == 'i')
    {
      auto const e{ b.find('e', j) };
      if(e == std::string::npos)
      {
        return false;
      }
      out = rt::make_box(static_cast<int64_t>(std::stoll(b.substr(j + 1, e - j - 1))));
      i = e + 1;
      return true;
    }
    if(c == 'l' || c == 'd')
    {
      ++j;
      object_ref coll{ c == 'l' ? object_ref{ rt::obj::persistent_vector::empty() }
                                : object_ref{ rt::obj::persistent_array_map::empty() } };
      while(j < b.size() && b[j] != 'e')
      {
        object_ref k, v;
        if(!decode(b, j, k))
        {
          return false;
        }
        if(c == 'l')
        {
          coll = rt::conj(coll, k);
          continue;
        }
        if(!decode(b, j, v))
        {
          return false;
        }
        coll = rt::assoc(coll, kw(to_std(k)), v);
      }
      if(j >= b.size())
      {
        return false;
      }
      out = coll;
      i = j + 1;
      return true;
    }
    auto const colon{ b.find(':', j) };
    if(colon == std::string::npos)
    {
      return false;
    }
    auto const n{ std::stoull(b.substr(j, colon - j)) };
    if(colon + 1 + n > b.size())
    {
      return false;
    }
    out = str(std::string_view{ b }.substr(colon + 1, n));
    i = colon + 1 + n;
    return true;
  }

  /* An nREPL connection to 127.0.0.1:port. */
  struct connection
  {
    int fd{ -1 };
    std::string buf;
  };

  inline object_ref connect(int64_t const port)
  {
    return guarded([&] {
      auto const fd{ socket(AF_INET, SOCK_STREAM, 0) };
      sockaddr_in addr{};
      addr.sin_family = AF_INET;
      addr.sin_port = htons(static_cast<uint16_t>(port));
      addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      if(::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0)
      {
        ::close(fd);
        throw std::runtime_error{ "can't connect to port " + std::to_string(port) };
      }
      auto const c{ new connection{ fd, {} } };
      return object_ref{ rt::make_box<rt::obj::opaque_box>(jtl::ptr<void>{ c },
                                                           istr(connection_box)) };
    });
  }

  inline object_ref send(object_ref const o, object_ref const msg)
  {
    return guarded([&] {
      auto const c{ unbox<connection>(o, connection_box) };
      std::string data;
      encode(msg, data);
      size_t sent{};
      while(sent < data.size())
      {
        auto const n{ ::send(c->fd, data.data() + sent, data.size() - sent, 0) };
        if(n <= 0)
        {
          throw std::runtime_error{ "send failed" };
        }
        sent += static_cast<size_t>(n);
      }
      return object_ref{ rt::jank_nil };
    });
  }

  /* One message, or nil after `timeout_ms` (or when the connection closed). */
  inline object_ref read(object_ref const o, int64_t const timeout_ms)
  {
    return guarded([&] {
      auto const c{ unbox<connection>(o, connection_box) };
      auto const deadline{ std::chrono::steady_clock::now()
                           + std::chrono::milliseconds{ timeout_ms } };
      for(;;)
      {
        size_t i{};
        object_ref v;
        if(decode(c->buf, i, v))
        {
          c->buf.erase(0, i);
          return v;
        }
        auto const left{ std::chrono::duration_cast<std::chrono::milliseconds>(
                           deadline - std::chrono::steady_clock::now())
                           .count() };
        if(left <= 0)
        {
          return object_ref{ rt::jank_nil };
        }
        pollfd p{ c->fd, POLLIN, 0 };
        if(poll(&p, 1, static_cast<int>(left)) <= 0)
        {
          return object_ref{ rt::jank_nil };
        }
        char buf[65536];
        auto const n{ ::recv(c->fd, buf, sizeof buf, 0) };
        if(n <= 0)
        {
          return object_ref{ rt::jank_nil };
        }
        c->buf.append(buf, static_cast<size_t>(n));
      }
    });
  }

  inline object_ref close(object_ref const o)
  {
    auto const c{ unbox<connection>(o, connection_box) };
    ::close(c->fd);
    return rt::jank_nil;
  }

  /* Files. */

  inline object_ref make_temp_dir(object_ref const prefix)
  {
    return guarded([&] {
      std::string templ{ to_std(prefix) + "XXXXXX" };
      if(!mkdtemp(templ.data()))
      {
        throw std::runtime_error{ "mkdtemp failed for " + templ };
      }
      return str(templ);
    });
  }

  inline object_ref make_dirs(object_ref const path)
  {
    std::filesystem::create_directories(to_std(path));
    return rt::jank_nil;
  }

  inline object_ref exists(object_ref const path)
  {
    return std::filesystem::exists(to_std(path)) ? object_ref{ rt::jank_true }
                                                 : object_ref{ rt::jank_false };
  }

  inline object_ref remove_file(object_ref const path)
  {
    std::filesystem::remove(to_std(path));
    return rt::jank_nil;
  }

  /* Sets a file's modification (and access) time, in nanoseconds since the epoch. */
  inline object_ref set_mtime_ns(object_ref const path, int64_t const ns)
  {
    return guarded([&] {
      timespec ts[2];
      ts[0].tv_sec = ts[1].tv_sec = ns / 1000000000;
      ts[0].tv_nsec = ts[1].tv_nsec = ns % 1000000000;
      if(utimensat(AT_FDCWD, to_std(path).c_str(), ts, 0) != 0)
      {
        throw std::runtime_error{ "utimensat failed for " + to_std(path) };
      }
      return object_ref{ rt::jank_nil };
    });
  }

  /* The jank the harnesses run: `$JANK` if it's set, else `jank` on the PATH. */
  inline object_ref jank_binary()
  {
    auto const env{ std::getenv("JANK") };
    return str(std::string{ env && *env ? env : "jank" });
  }

  /* Sets a file's access and modification times to `s` seconds. */
  inline object_ref set_mtime_s(object_ref const path, int64_t const s)
  {
    return set_mtime_ns(path, s * 1000000000);
  }

  /* The next value of the harness's random generator, an LCG modulo 2^31, in
   * 64-bit arithmetic (jank's arithmetic on small integers wraps at 32 bits,
   * RESULTS S10). */
  inline int64_t lcg_next(int64_t const x)
  {
    return (x * 1103515245 + 12345) % 2147483648;
  }

  /* [mtime-ns size inode], or nil when the file doesn't exist. */
  inline object_ref stamp(object_ref const path)
  {
    struct stat st{};
    if(::stat(to_std(path).c_str(), &st) != 0)
    {
      return rt::jank_nil;
    }
#ifdef __APPLE__
    auto const mt{ st.st_mtimespec };
#else
    auto const mt{ st.st_mtim };
#endif
    object_ref v{ rt::obj::persistent_vector::empty() };
    v = rt::conj(v, rt::make_box(static_cast<int64_t>(mt.tv_sec) * 1000000000 + mt.tv_nsec));
    v = rt::conj(v, rt::make_box(static_cast<int64_t>(st.st_size)));
    v = rt::conj(v, rt::make_box(static_cast<int64_t>(st.st_ino)));
    return v;
  }
}

// SPDX-License-Identifier: MIT
// The harness's native part, included by jank: JSON read into jank values (a tool call's
// arguments), a JSON string written (a tool's declaration), and what the default tools need
// of the system (a command run, a directory listed).
#pragma once

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <string_view>
#include <fcntl.h>
#include <mutex>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

#include <jank/runtime/context.hpp>
#include <jank/runtime/core.hpp>
#include <jank/runtime/core/make_box.hpp>
#include <jank/runtime/core/seq.hpp>
#include <jank/runtime/obj/keyword.hpp>
#include <jank/runtime/obj/persistent_array_map.hpp>
#include <jank/runtime/obj/persistent_string.hpp>
#include <jank/runtime/obj/persistent_vector.hpp>

namespace harness
{
  namespace rt = ::jank::runtime;
  using rt::object_ref;

  inline jtl::immutable_string istr(std::string_view const s)
  {
    return { s.data(), s.size() };
  }

  inline std::string to_std(object_ref const o)
  {
    auto const s{ rt::to_string(o) };
    return { s.data(), s.size() };
  }

  inline object_ref str(std::string_view const s)
  {
    return rt::make_box<rt::obj::persistent_string>(istr(s));
  }

  inline object_ref kw(std::string_view const s)
  {
    return rt::__rt_ctx->intern_keyword(istr(s)).expect_ok();
  }

  [[noreturn]] inline void fail(std::string const &what)
  {
    throw static_cast<object_ref>(rt::ex_info(istr(what), rt::obj::persistent_array_map::empty()));
  }

  /* JSON, read: objects as maps with keyword keys, arrays as vectors, null as nil, numbers
   * as integers when they are written as integers. */
  struct json_reader
  {
    std::string_view text;
    size_t at{};

    [[noreturn]] void wrong(std::string const &what) const
    {
      fail("JSON: " + what + " at character " + std::to_string(at));
    }

    void space()
    {
      while(at < text.size() && (text[at] == ' ' || text[at] == '\n' || text[at] == '\t' || text[at] == '\r'))
      {
        ++at;
      }
    }

    static void utf8(std::string &out, unsigned const code)
    {
      if(code < 0x80)
      {
        out += static_cast<char>(code);
      }
      else if(code < 0x800)
      {
        out += static_cast<char>(0xC0 | (code >> 6));
        out += static_cast<char>(0x80 | (code & 0x3F));
      }
      else if(code < 0x10000)
      {
        out += static_cast<char>(0xE0 | (code >> 12));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
      }
      else
      {
        out += static_cast<char>(0xF0 | (code >> 18));
        out += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
      }
    }

    unsigned hex4()
    {
      if(at + 4 > text.size())
      {
        wrong("a \\u escape cut short");
      }
      unsigned code{};
      for(int i{}; i < 4; ++i)
      {
        char const c{ text[at++] };
        code <<= 4;
        if(c >= '0' && c <= '9') { code |= static_cast<unsigned>(c - '0'); }
        else if(c >= 'a' && c <= 'f') { code |= static_cast<unsigned>(c - 'a' + 10); }
        else if(c >= 'A' && c <= 'F') { code |= static_cast<unsigned>(c - 'A' + 10); }
        else { wrong("a \\u escape that is not hexadecimal"); }
      }
      return code;
    }

    std::string string()
    {
      ++at; /* the opening quote */
      std::string out;
      while(true)
      {
        if(at >= text.size())
        {
          wrong("a string without its end");
        }
        char const c{ text[at++] };
        if(c == '"')
        {
          return out;
        }
        if(c != '\\')
        {
          out += c;
          continue;
        }
        if(at >= text.size())
        {
          wrong("an escape cut short");
        }
        char const e{ text[at++] };
        switch(e)
        {
          case '"': out += '"'; break;
          case '\\': out += '\\'; break;
          case '/': out += '/'; break;
          case 'b': out += '\b'; break;
          case 'f': out += '\f'; break;
          case 'n': out += '\n'; break;
          case 'r': out += '\r'; break;
          case 't': out += '\t'; break;
          case 'u':
          {
            unsigned code{ hex4() };
            /* Two escapes for a character beyond the first 65,536. */
            if(code >= 0xD800 && code < 0xDC00 && at + 1 < text.size() && text[at] == '\\' && text[at + 1] == 'u')
            {
              at += 2;
              unsigned const low{ hex4() };
              if(low >= 0xDC00 && low < 0xE000)
              {
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
              }
              else
              {
                utf8(out, 0xFFFD);
                code = low;
              }
            }
            utf8(out, code);
            break;
          }
          default: wrong(std::string{ "an unknown escape \\" } + e);
        }
      }
    }

    object_ref number()
    {
      size_t const from{ at };
      bool whole{ true };
      if(at < text.size() && text[at] == '-')
      {
        ++at;
      }
      while(at < text.size())
      {
        char const c{ text[at] };
        if(c >= '0' && c <= '9')
        {
          ++at;
        }
        else if(c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-')
        {
          whole = false;
          ++at;
        }
        else
        {
          break;
        }
      }
      std::string const digits{ text.substr(from, at - from) };
      if(digits.empty() || digits == "-")
      {
        wrong("a value expected");
      }
      if(whole && digits.size() < 19)
      {
        return rt::make_box(static_cast<int64_t>(std::strtoll(digits.c_str(), nullptr, 10)));
      }
      return rt::make_box(std::strtod(digits.c_str(), nullptr));
    }

    bool word(std::string_view const w)
    {
      if(text.substr(at, w.size()) == w)
      {
        at += w.size();
        return true;
      }
      return false;
    }

    object_ref value(int const depth)
    {
      if(depth > 200)
      {
        wrong("nested too deep");
      }
      space();
      if(at >= text.size())
      {
        wrong("a value expected");
      }
      char const c{ text[at] };
      if(c == '{')
      {
        ++at;
        object_ref m{ rt::obj::persistent_array_map::empty() };
        space();
        if(at < text.size() && text[at] == '}')
        {
          ++at;
          return m;
        }
        while(true)
        {
          space();
          if(at >= text.size() || text[at] != '"')
          {
            wrong("a key expected");
          }
          auto const key{ string() };
          space();
          if(at >= text.size() || text[at] != ':')
          {
            wrong("a colon expected");
          }
          ++at;
          m = rt::assoc(m, kw(key), value(depth + 1));
          space();
          if(at < text.size() && text[at] == ',')
          {
            ++at;
            continue;
          }
          if(at < text.size() && text[at] == '}')
          {
            ++at;
            return m;
          }
          wrong("a comma or the object's end expected");
        }
      }
      if(c == '[')
      {
        ++at;
        object_ref v{ rt::obj::persistent_vector::empty() };
        space();
        if(at < text.size() && text[at] == ']')
        {
          ++at;
          return v;
        }
        while(true)
        {
          v = rt::conj(v, value(depth + 1));
          space();
          if(at < text.size() && text[at] == ',')
          {
            ++at;
            continue;
          }
          if(at < text.size() && text[at] == ']')
          {
            ++at;
            return v;
          }
          wrong("a comma or the array's end expected");
        }
      }
      if(c == '"')
      {
        return str(string());
      }
      if(word("true"))
      {
        return rt::jank_true;
      }
      if(word("false"))
      {
        return rt::jank_false;
      }
      if(word("null"))
      {
        return object_ref{ rt::jank_nil };
      }
      return number();
    }
  };

  inline object_ref json_read(object_ref const text)
  {
    auto const s{ to_std(text) };
    json_reader r{ s };
    auto const v{ r.value(0) };
    r.space();
    if(r.at != s.size())
    {
      r.wrong("something after the value");
    }
    return v;
  }

  /* A string as JSON writes it: quotes, backslashes and control characters escaped, every
   * other character as it is. */
  inline object_ref json_quote(object_ref const text)
  {
    auto const s{ to_std(text) };
    std::string out{ "\"" };
    for(unsigned char const c : s)
    {
      switch(c)
      {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
          if(c < 0x20)
          {
            char buffer[8];
            std::snprintf(buffer, sizeof(buffer), "\\u%04x", static_cast<unsigned>(c));
            out += buffer;
          }
          else
          {
            out += static_cast<char>(c);
          }
      }
    }
    out += '"';
    return str(out);
  }

  /* A command run by the shell (sh -c), its output and its error output together:
   * {:exit :out :bytes :timed-out}. `limit` bytes of output are kept. The command has
   * `seconds` to end; at that, it and what it started are killed. What it leaves running
   * in the background (cmd &) is not waited for: the command is over when the shell is. */
  inline object_ref run(object_ref const command, object_ref const limit, object_ref const seconds)
  {
    auto const line{ to_std(command) };
    auto const keep{ static_cast<size_t>(rt::to_int(limit)) };
    auto const allowed{ rt::to_real(seconds) };
    int ends[2];
    if(pipe(ends) != 0)
    {
      fail("the command could not be started");
    }
    pid_t const child{ fork() };
    if(child < 0)
    {
      ::close(ends[0]);
      ::close(ends[1]);
      fail("the command could not be started");
    }
    if(child == 0)
    {
      /* A group of its own, so that all of it can be killed. */
      setpgid(0, 0);
      dup2(ends[1], 1);
      dup2(ends[1], 2);
      ::close(ends[0]);
      ::close(ends[1]);
      execl("/bin/sh", "sh", "-c", line.c_str(), static_cast<char *>(nullptr));
      _exit(127);
    }
    ::close(ends[1]);
    fcntl(ends[0], F_SETFL, fcntl(ends[0], F_GETFL) | O_NONBLOCK);
    std::string out;
    size_t total{};
    std::array<char, 65536> buffer{};
    auto const began{ std::chrono::steady_clock::now() };
    int status{};
    bool over{};
    bool timed_out{};
    auto const drain{ [&]() {
      while(true)
      {
        ssize_t const n{ ::read(ends[0], buffer.data(), buffer.size()) };
        if(n <= 0)
        {
          return n == 0;
        }
        total += static_cast<size_t>(n);
        if(out.size() < keep)
        {
          out.append(buffer.data(), std::min(static_cast<size_t>(n), keep - out.size()));
        }
      }
    } };
    while(!over)
    {
      pollfd waiting{ ends[0], POLLIN, 0 };
      poll(&waiting, 1, 50);
      bool const closed{ drain() };
      if(waitpid(child, &status, WNOHANG) == child)
      {
        over = true;
        drain();
      }
      else if(closed)
      {
        waitpid(child, &status, 0);
        over = true;
      }
      else if(std::chrono::duration<double>(std::chrono::steady_clock::now() - began).count() > allowed)
      {
        timed_out = true;
        killpg(child, SIGKILL);
        waitpid(child, &status, 0);
        over = true;
        drain();
      }
    }
    ::close(ends[0]);
    int const code{ WIFEXITED(status) ? WEXITSTATUS(status) : -1 };
    object_ref m{ rt::obj::persistent_array_map::empty() };
    m = rt::assoc(m, kw("exit"), rt::make_box(static_cast<int64_t>(code)));
    m = rt::assoc(m, kw("out"), str(out));
    m = rt::assoc(m, kw("bytes"), rt::make_box(static_cast<int64_t>(total)));
    m = rt::assoc(m, kw("timed-out"), timed_out ? object_ref{ rt::jank_true } : object_ref{ rt::jank_false });
    return m;
  }

  /* A directory's entries, sorted: [{:name :dir :bytes} ...]. */
  inline object_ref list_dir(object_ref const path)
  {
    namespace fs = std::filesystem;
    std::error_code error;
    std::vector<fs::directory_entry> entries;
    for(auto const &entry : fs::directory_iterator{ fs::path{ to_std(path) }, error })
    {
      entries.push_back(entry);
    }
    if(error)
    {
      fail("the directory could not be read: " + error.message());
    }
    std::sort(entries.begin(), entries.end(), [](auto const &a, auto const &b) { return a.path().filename() < b.path().filename(); });
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(auto const &entry : entries)
    {
      std::error_code ignored;
      bool const dir{ entry.is_directory(ignored) };
      object_ref m{ rt::obj::persistent_array_map::empty() };
      m = rt::assoc(m, kw("name"), str(entry.path().filename().string()));
      m = rt::assoc(m, kw("dir"), dir ? object_ref{ rt::jank_true } : object_ref{ rt::jank_false });
      m = rt::assoc(m, kw("bytes"), rt::make_box(static_cast<int64_t>(dir ? 0 : entry.file_size(ignored))));
      v = rt::conj(v, m);
    }
    return v;
  }

  inline object_ref is_file(object_ref const path)
  {
    std::error_code ignored;
    return std::filesystem::is_regular_file(std::filesystem::path{ to_std(path) }, ignored)
      ? object_ref{ rt::jank_true }
      : object_ref{ rt::jank_false };
  }

  /* A file written whole. Says why when it can't be (jank's spit doesn't: a file the
   * system refuses to write looked written). */
  inline void write_file(object_ref const path, object_ref const text)
  {
    auto const name{ to_std(path) };
    auto const data{ to_std(text) };
    FILE *const f{ std::fopen(name.c_str(), "wb") };
    if(f == nullptr)
    {
      fail("the file " + name + " could not be written: " + std::strerror(errno));
    }
    size_t const wrote{ std::fwrite(data.data(), 1, data.size(), f) };
    int const closed{ std::fclose(f) };
    if(wrote != data.size() || closed != 0)
    {
      fail("the file " + name + " could not be written whole: " + std::strerror(errno));
    }
  }

  /* The directories a file's path needs, made. */
  inline void make_parents(object_ref const path)
  {
    std::error_code ignored;
    auto const parent{ std::filesystem::path{ to_std(path) }.parent_path() };
    if(!parent.empty())
    {
      std::filesystem::create_directories(parent, ignored);
    }
  }

  /* The first `bytes` of a text, less what would cut a character in two. */
  inline object_ref prefix(object_ref const text, object_ref const bytes)
  {
    auto const s{ to_std(text) };
    auto n{ static_cast<size_t>(std::max<int64_t>(0, rt::to_int(bytes))) };
    if(n >= s.size())
    {
      return str(s);
    }
    while(n > 0 && (static_cast<unsigned char>(s[n]) & 0xC0) == 0x80)
    {
      --n;
    }
    return str(std::string_view{ s.data(), n });
  }

  /* A line on stdout, written at once (jank's own printing is buffered). */
  inline void say(object_ref const text)
  {
    std::printf("%s\n", to_std(text).c_str());
    std::fflush(stdout);
  }

  /* The process ended with a code, at once: nothing is torn down under threads still at
   * work. */
  [[noreturn]] inline void leave(object_ref const code)
  {
    std::fflush(stdout);
    std::fflush(stderr);
    std::_Exit(static_cast<int>(rt::to_int(code)));
  }

  inline double seconds()
  {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
  }
}

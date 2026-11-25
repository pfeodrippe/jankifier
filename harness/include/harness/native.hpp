// SPDX-License-Identifier: MIT
// The harness's native part, included by jank: JSON read into jank values (a tool call's
// arguments), a JSON string written (a tool's declaration), and what the default tools need
// of the system (a command run, a directory listed).
#pragma once
#include <sandbox.h>
#include <climits>
#include <cxxabi.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <thread>
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
#include <jank/util/clang.hpp>
#include <jank/util/cli.hpp>
#include <jank/util/environment.hpp>
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

  /* A text with each byte that isn't part of a whole UTF-8 character (a string cut inside
   * one: jank's strings are bytes) replaced by U+FFFD, so that the text is UTF-8 throughout. */
  inline object_ref utf8_clean(object_ref const text)
  {
    auto const s{ to_std(text) };
    std::string out;
    out.reserve(s.size());
    size_t i{};
    while(i < s.size())
    {
      auto const c{ static_cast<unsigned char>(s[i]) };
      size_t const n{ c < 0x80 ? 1u : (c >> 5) == 0x6 ? 2u : (c >> 4) == 0xE ? 3u : (c >> 3) == 0x1E ? 4u : 0u };
      bool whole{ n > 0 && i + n <= s.size() };
      for(size_t k{ 1 }; whole && k < n; ++k)
      {
        whole = (static_cast<unsigned char>(s[i + k]) & 0xC0) == 0x80;
      }
      if(whole)
      {
        out.append(s, i, n);
        i += n;
      }
      else
      {
        out += "\xEF\xBF\xBD";
        ++i;
      }
    }
    return str(out);
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
  /* Where the top-level forms of jank code are: "ok" then a line "start end" (byte offsets)
   * a form, or "error" then what doesn't read, with its line: a bracket that closes nothing,
   * one that closes another kind, one left open, a string left open. Strings, comments and
   * character literals are skipped; a form of other things (a symbol, 'quoted, #"regex")
   * ends at white space. */
  inline object_ref top_forms(object_ref const text)
  {
    auto const s(to_std(text));
    std::string out{ "ok\n" };
    struct opened
    {
      char c;
      size_t line;
    };
    std::vector<opened> stack;
    size_t line{ 1 }, i{}, n{ s.size() }, start_line{};
    /* The last top-level form closed: where it started and where its last bracket closed it
       (a ')' that closes nothing is often one too many in it). */
    size_t closed_from{}, closed_at{};
    long start{ -1 };
    bool atom{};
    auto const closer([](char const o) { return o == '(' ? ')' : (o == '[' ? ']' : '}'); });
    auto const finish([&](size_t const end) {
      out += std::to_string(start) + " " + std::to_string(end) + "\n";
      start = -1;
      atom = false;
    });
    auto const fail([](std::string const &said) { return str("error\n" + said); });
    auto const begin([&](size_t const at) {
      if(start < 0)
      {
        start = static_cast<long>(at);
        start_line = line;
      }
    });
    while(i < n)
    {
      char const c{ s[i] };
      if(c == '"')
      {
        begin(i);
        atom = false;
        size_t const from{ line };
        ++i;
        while(i < n && s[i] != '"')
        {
          if(s[i] == '\\')
          {
            ++i;
          }
          else if(s[i] == '\n')
          {
            ++line;
          }
          ++i;
        }
        if(i >= n)
        {
          return fail("a string that starts at line " + std::to_string(from) + " isn't closed");
        }
        ++i;
        if(stack.empty())
        {
          finish(i);
        }
        continue;
      }
      if(c == ';')
      {
        if(atom && stack.empty())
        {
          finish(i);
        }
        while(i < n && s[i] != '\n')
        {
          ++i;
        }
        continue;
      }
      if(c == '\\')
      {
        begin(i);
        if(stack.empty())
        {
          atom = true;
        }
        i += 2;
        continue;
      }
      if(c == '(' || c == '[' || c == '{')
      {
        begin(i);
        atom = false;
        stack.push_back({ c, line });
        ++i;
        continue;
      }
      if(c == ')' || c == ']' || c == '}')
      {
        if(stack.empty())
        {
          /* A form with one ')' too many closes early, and the error lands on a later line: say
             where the form before it was closed (kv agents counted brackets by hand for dozens
             of steps). */
          return fail("line " + std::to_string(line) + ": a '" + std::string(1, c) + "' that closes nothing"
                      + (closed_at
                           ? "; the form before it, from line " + std::to_string(closed_from) + ", was closed at line "
                               + std::to_string(closed_at)
                               + ": if that is too early, a closing bracket there is one too many"
                           : std::string{}));
        }
        auto const o(stack.back());
        if(closer(o.c) != c)
        {
          return fail("line " + std::to_string(line) + ": a '" + std::string(1, c) + "' closes the '"
                      + std::string(1, o.c) + "' opened at line " + std::to_string(o.line));
        }
        stack.pop_back();
        ++i;
        if(stack.empty())
        {
          closed_from = start_line;
          closed_at = line;
          finish(i);
        }
        continue;
      }
      bool const space{ c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == ',' };
      if(c == '\n')
      {
        ++line;
      }
      if(stack.empty())
      {
        if(space)
        {
          if(atom)
          {
            finish(i);
          }
        }
        else
        {
          if(start < 0)
          {
            atom = true;
          }
          begin(i);
        }
      }
      ++i;
    }
    if(!stack.empty())
    {
      return fail("the form that starts at line " + std::to_string(start_line) + " isn't closed: the '"
                  + std::string(1, stack.back().c) + "' opened at line " + std::to_string(stack.back().line)
                  + " is still open");
    }
    if(atom)
    {
      finish(n);
    }
    return str(out);
  }

  /* The process's working directory changed: "" or what failed. */
  inline object_ref change_dir(object_ref const path)
  {
    auto const p(to_std(path));
    if(::chdir(p.c_str()) != 0)
    {
      return str(std::string{ "can't go to " } + p + ": " + std::strerror(errno));
    }
    return str("");
  }

  /* A path made absolute and without links or ".." (a path that isn't there yet: its
   * nearest existing directory's, with the rest added). */
  inline object_ref real_path(object_ref const path)
  {
    std::string p(to_std(path));
    std::string rest;
    while(!p.empty())
    {
      char resolved[PATH_MAX];
      if(::realpath(p.c_str(), resolved))
      {
        return str(std::string{ resolved } + rest);
      }
      auto const slash(p.find_last_of('/'));
      if(slash == std::string::npos)
      {
        char here[PATH_MAX];
        if(::getcwd(here, sizeof(here)))
        {
          return str(std::string{ here } + "/" + p + rest);
        }
        return str(p + rest);
      }
      rest = p.substr(slash) + rest;
      p = p.substr(0, slash);
      if(p.empty())
      {
        return str(rest);
      }
    }
    return str(rest);
  }

  /* This process sandboxed from now on by a profile (SBPL text): "" or what failed. macOS
   * lets a process do this once, and not when it was started inside a sandbox; what it
   * starts afterwards is sandboxed too. */
  inline object_ref sandbox_self(object_ref const profile)
  {
    char *error{};
    auto const text(to_std(profile));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int const failed{ ::sandbox_init(text.c_str(), 0, &error) };
    std::string said{ failed != 0 ? (error ? error : "sandbox_init failed") : "" };
    if(error)
    {
      ::sandbox_free_error(error);
    }
#pragma clang diagnostic pop
    return str(said);
  }

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

  // The calling thread asleep for `s` seconds.
  inline object_ref pause(object_ref const s)
  {
    std::this_thread::sleep_for(std::chrono::duration<double>(rt::to_real(s)));
    return rt::jank_nil;
  }

  // The shell command that checks a C++ file the way jank's JIT would compile it (jank's own
  // clang, its include paths and macros, the process's precompiled header), without running
  // anything: `clang++ -fsyntax-only`. Source given to the JIT that fails to compile leaves the
  // C++ library functions it used unlinkable for the rest of the process (a fault of jank's JIT:
  // "JIT session error: Symbols not found"), so the harness checks source before it goes there.
  // The source is written to the temporary directory first. "" when jank's clang or the
  // header isn't found, or the file can't be written.
  inline object_ref cpp_check_command(object_ref const source)
  {
    std::error_code ec;
    auto const file((std::filesystem::temp_directory_path(ec) / "harness-cpp-check.cpp").string());
    {
      std::FILE *const f{ std::fopen(file.c_str(), "wb") };
      if(!f)
      {
        return str("");
      }
      auto const text(to_std(source));
      std::fwrite(text.data(), 1, text.size(), f);
      std::fclose(f);
    }
    namespace u = jank::util;
    auto const clang(u::find_clang());
    auto const resources(u::find_clang_resource_dir());
    auto const pch(u::find_pch(jank::runtime::__rt_ctx->binary_version));
    if(clang.is_none() || resources.is_none() || pch.is_none())
    {
      return str("");
    }
    auto const q([](std::string const &a) {
      std::string out{ "'" };
      for(char const c : a)
      {
        if(c == '\'')
        {
          out += "'\\''";
        }
        else
        {
          out += c;
        }
      }
      return out + "'";
    });
    std::filesystem::path const clang_path{ clang.unwrap().c_str() };
    auto const dir(clang_path.parent_path());
    std::string cmd{ q(clang_path.string()) + " -fsyntax-only -x c++ -std=gnu++20 -w -fno-color-diagnostics" };
    cmd += " -nostdinc++ -I " + q((dir / "../include/c++/v1").string()) + " -I " + q((dir / "../include").string());
    cmd += " -resource-dir " + q(resources.unwrap().c_str());
    cmd += " -I " + q(std::string{ u::resource_dir().c_str() } + "/include") + " -I /opt/homebrew/include";
    for(auto const &d : u::cli::opts.include_dirs)
    {
      cmd += " -I " + q(d.c_str());
    }
    for(auto const &m : u::cli::opts.define_macros)
    {
      cmd += " -D " + q(m.c_str());
    }
    cmd += " -femulated-tls -DGC_THREADS -DPOINTER_MASK=0x0000FFFFFFFFFFFF -DIMMER_HAS_LIBGC=1"
           " -DIMMER_TAGGED_NODE=0 -DHAVE_CXX14=1 -DCPPINTEROP_USE_REPL -DFOLLY_HAVE_JEMALLOC=0"
           " -DFOLLY_HAVE_TCMALLOC=0 -DFOLLY_ASSUME_NO_JEMALLOC=1 -DFOLLY_ASSUME_NO_TCMALLOC=1 -DNDEBUG"
           " -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS -fwrapv -fPIC";
    // The system's headers (on macOS, the SDK's), as the JIT is given them.
    {
      std::vector<char const *> system;
      u::add_system_flags(system);
      for(auto const a : system)
      {
        cmd += " " + q(a);
      }
    }
    cmd += " -Xclang -fno-validate-pch -include-pch " + q(pch.unwrap().c_str()) + " " + q(file) + " 2>&1";
    return str(cmd);
  }

  // A C++ symbol's name as written (std::basic_ios<char>::operator!() const), from its linker
  // name (with macOS's extra leading underscore); the name itself when it isn't one.
  inline object_ref demangle(object_ref const symbol)
  {
    auto name(to_std(symbol));
    if(name.rfind("__Z", 0) == 0)
    {
      name = name.substr(1);
    }
    int status{};
    char *const said{ abi::__cxa_demangle(name.c_str(), nullptr, nullptr, &status) };
    if(status != 0 || !said)
    {
      return str(to_std(symbol));
    }
    std::string const out{ said };
    std::free(said);
    return str(out);
  }
}

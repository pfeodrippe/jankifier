// SPDX-License-Identifier: MIT
// The REPL's evaluation made safe for a process that does more than one thing at a time,
// included by jank (cards.repl): output captured so that evaluations at the same time don't
// lose the process's stdout, and code run on a thread with a large stack.
#pragma once

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <mutex>
#include <pthread.h>
#include <string>
#include <string_view>
#include <unistd.h>
#include <vector>

#include <gc/gc.h>

#include <jank/runtime/context.hpp>
#include <jank/runtime/core.hpp>
#include <jank/runtime/core/make_box.hpp>
#include <jank/runtime/obj/keyword.hpp>
#include <jank/runtime/obj/persistent_array_map.hpp>
#include <jank/runtime/obj/persistent_string.hpp>

namespace cards::repl
{
  namespace rt = ::jank::runtime;
  using rt::object_ref;

  inline jtl::immutable_string istr(std::string_view const s)
  {
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

  /* Output captured: what an evaluation wrote to stdout and stderr, kept apart.
   *
   * jank's nREPL captures by pointing the process's stdout and stderr at a file for the
   * evaluation's time and back afterwards, each evaluation saving and restoring by itself.
   * Two evaluations at once that are not one inside the other (a person's, from an editor,
   * and the agent's eval tool) then restore in the wrong order, and the process is left
   * writing to a file that is gone. Here the captures in progress are kept together: when
   * one ends, the streams go to the newest capture still going, or back to where they were
   * before any of them. */
  struct captures
  {
    struct capture
    {
      int id{};
      std::string path[2];
      bool ended{};
    };
    std::mutex lock;
    std::vector<capture> going;
    int before[2]{ -1, -1 };
    int next{ 1 };
  };

  inline captures &all_captures()
  {
    static captures c;
    return c;
  }

  inline int capture_file(std::string &path)
  {
    std::string name{ (std::filesystem::temp_directory_path() / "harness-capture-XXXXXX").string() };
    int const fd{ mkstemp(name.data()) };
    if(fd == -1)
    {
      fail("a file to capture output in could not be made");
    }
    path = name;
    return fd;
  }

  /* The streams pointed at the newest capture still going, or back where they were. */
  inline void capture_point(captures &c)
  {
    FILE *const streams[2]{ stdout, stderr };
    while(!c.going.empty() && c.going.back().ended)
    {
      c.going.pop_back();
    }
    for(int i{}; i < 2; ++i)
    {
      std::fflush(streams[i]);
      if(c.going.empty())
      {
        if(c.before[i] != -1)
        {
          dup2(c.before[i], fileno(streams[i]));
          ::close(c.before[i]);
          c.before[i] = -1;
        }
      }
      else
      {
        int const fd{ ::open(c.going.back().path[i].c_str(), O_WRONLY | O_APPEND) };
        if(fd != -1)
        {
          dup2(fd, fileno(streams[i]));
          ::close(fd);
        }
      }
    }
  }

  inline object_ref capture_start()
  {
    auto &c{ all_captures() };
    std::lock_guard<std::mutex> const held{ c.lock };
    FILE *const streams[2]{ stdout, stderr };
    captures::capture made;
    made.id = c.next++;
    for(int i{}; i < 2; ++i)
    {
      std::fflush(streams[i]);
      if(c.going.empty())
      {
        c.before[i] = dup(fileno(streams[i]));
      }
      int const fd{ capture_file(made.path[i]) };
      dup2(fd, fileno(streams[i]));
      ::close(fd);
    }
    c.going.push_back(made);
    return rt::make_box(static_cast<int64_t>(made.id));
  }

  /* A capture ended: {:out :err}, what was written while it was the newest one. */
  inline object_ref capture_end(object_ref const id)
  {
    auto &c{ all_captures() };
    std::lock_guard<std::mutex> const held{ c.lock };
    int const wanted{ static_cast<int>(rt::to_int(id)) };
    std::string path[2];
    for(auto &one : c.going)
    {
      if(one.id == wanted)
      {
        one.ended = true;
        path[0] = one.path[0];
        path[1] = one.path[1];
      }
    }
    std::fflush(stdout);
    std::fflush(stderr);
    capture_point(c);
    object_ref m{ rt::obj::persistent_array_map::empty() };
    char const *const keys[2]{ "out", "err" };
    for(int i{}; i < 2; ++i)
    {
      std::string text;
      if(!path[i].empty())
      {
        if(FILE *const f{ std::fopen(path[i].c_str(), "rb") })
        {
          std::array<char, 65536> buffer{};
          size_t n{};
          while((n = std::fread(buffer.data(), 1, buffer.size(), f)) > 0)
          {
            text.append(buffer.data(), n);
          }
          std::fclose(f);
        }
        unlink(path[i].c_str());
      }
      m = rt::assoc(m, kw(keys[i]), str(text));
    }
    return m;
  }

  /* A function called on a thread of its own with a stack of `megabytes`, and waited for.
   *
   * jank's nREPL evaluates on threads with the system's default stack for a thread that is
   * not the first (512 KB on macOS), and jank's compiled frames are large: a function that
   * calls itself thirty deep overflows it, and the process ends (SIGBUS). The memory of the
   * stack is only taken as it is used. The calling thread's bindings are the new thread's,
   * as with jank's own future; what the function throws is thrown here. */
  struct big_job
  {
    object_ref fn{};
    object_ref bindings{};
    object_ref result{};
    object_ref thrown{};
    std::string what;
    int failed{}; /* 0 no, 1 a jank value thrown, 2 a C++ exception, 3 something else */
  };

  inline void *big_run(void *const raw)
  {
    auto const job{ static_cast<big_job *>(raw) };
    bool pushed{};
    try
    {
      rt::__rt_ctx->push_thread_bindings(job->bindings).expect_ok();
      pushed = true;
      job->result = job->fn.call();
    }
    catch(object_ref const &e)
    {
      job->failed = 1;
      job->thrown = e;
    }
    catch(std::exception const &e)
    {
      job->failed = 2;
      job->what = e.what();
    }
    catch(...)
    {
      job->failed = 3;
    }
    /* The bindings taken off again: jank keeps a thread's bindings by its system id, which
     * a later thread can be given, and that thread would start with these. */
    if(pushed)
    {
      try
      {
        rt::__rt_ctx->pop_thread_bindings();
      }
      catch(...)
      {
      }
    }
    return nullptr;
  }

  /* An evaluation's result kept on the thread that asked for it, as jank's safe_eval keeps
   * it on the one that ran it: *1, *2 and *3, or *e. A thread that didn't bind them can't set
   * them: there they are left. */
  inline object_ref remember(object_ref const ok, object_ref const what)
  {
    static auto const one{ rt::__rt_ctx->find_var("clojure.core", "*1") };
    static auto const two{ rt::__rt_ctx->find_var("clojure.core", "*2") };
    static auto const three{ rt::__rt_ctx->find_var("clojure.core", "*3") };
    static auto const error{ rt::__rt_ctx->find_var("clojure.core", "*e") };
    if(rt::truthy(ok))
    {
      (void)three->set(two->deref());
      (void)two->set(one->deref());
      (void)one->set(what);
    }
    else
    {
      (void)error->set(what);
    }
    return object_ref{ rt::jank_nil };
  }

  inline object_ref on_big_stack(object_ref const fn, object_ref const megabytes)
  {
    /* The job is on this thread's stack, which the collector reads while this thread waits:
     * what the job holds is kept. */
    big_job job;
    job.fn = fn;
    job.bindings = rt::__rt_ctx->get_thread_bindings();
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, static_cast<size_t>(rt::to_int(megabytes)) << 20);
    pthread_t thread{};
    /* (The collector's own pthread_create: the thread is known to it.) */
    int const made{ GC_pthread_create(&thread, &attributes, big_run, &job) };
    pthread_attr_destroy(&attributes);
    if(made != 0)
    {
      fail("a thread with a large stack could not be made");
    }
    GC_pthread_join(thread, nullptr);
    switch(job.failed)
    {
      case 1:
        throw job.thrown;
      case 2:
        fail(job.what);
      case 3:
        fail("something that is not an exception was thrown");
      default:
        return job.result;
    }
  }
}

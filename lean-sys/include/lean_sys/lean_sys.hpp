#pragma once

/* lean-sys's C++ layer: Lean's runtime, Lean sessions (import modules, elaborate commands,
 * evaluate constants), and reading and building Lean values by their type.
 *
 * It doesn't depend on jank: values are read into a `Sink` and built from a `Source`, which
 * the jank layer (lean_sys/core.jank, lean_sys/elab.jank) implements with jank's runtime.
 *
 * Calls into Lean go through Lean's compiled functions, by their C symbols in libleanshared
 * (signatures from Lean 4.35's IR: an `IO` function returns an ok/error object, a `BaseIO`
 * function its value; arguments are owned unless marked borrowed). */

#include <lean/lean.h>

#include <dlfcn.h>
#include <pthread.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <lean_sys/source.hpp>

extern "C"
{
  void lean_initialize();
  void lean_initialize_thread();
  void lean_init_task_manager();
  lean_object *lean_enable_initializer_execution(lean_object *w);
  lean_object *lean_io_error_to_string(lean_object *err);
  lean_object *l_Lean_initSearchPath(lean_object *sysroot, lean_object *sp, lean_object *w);
  lean_object *l_Lean_importModules(lean_object *imports, lean_object *opts, uint32_t trust,
                                    lean_object *plugins, uint8_t leak_env, uint8_t load_exts,
                                    uint8_t level, lean_object *arts, lean_object *w);
  lean_object *l_Lean_Parser_mkInputContext(lean_object *input, lean_object *file_name,
                                            uint8_t normalize, lean_object *end_pos,
                                            lean_object *proof);
  lean_object *l_Lean_Elab_Command_mkState(lean_object *env, lean_object *messages,
                                           lean_object *opts);
  lean_object *l_Lean_Elab_IO_processCommands(lean_object *input_ctx, lean_object *parser_state,
                                              lean_object *cmd_state, lean_object *w);
  lean_object *l_Lean_MessageLog_toArray(b_lean_obj_arg log);
  lean_object *l_Lean_MessageData_toString(lean_object *data, lean_object *w);
  lean_object *l_Lean_Environment_evalConst(lean_object *type, b_lean_obj_arg env,
                                            b_lean_obj_arg opts, b_lean_obj_arg name,
                                            uint8_t check_meta);
  lean_object *l_String_toName(lean_object *s);
  lean_object *l_Lean_Name_toString(lean_object *name, uint8_t escape);
  lean_object *l_Int_repr(b_lean_obj_arg i);
  extern lean_object *l_Lean_Options_empty;
  extern lean_object *l_Lean_MessageLog_empty;
}

namespace lean_sys
{
  struct error : std::runtime_error
  {
    using std::runtime_error::runtime_error;
  };

  /* Lean objects to release, queued from any thread (a jank finalizer, when jank no longer holds
   * one) and released on Lean's thread before its next job, so that it doesn't race with Lean
   * code. */
  inline std::mutex &release_mutex()
  {
    static std::mutex m;
    return m;
  }

  inline std::vector<std::function<void()>> &release_queue()
  {
    static std::vector<std::function<void()>> q;
    return q;
  }

  inline std::atomic<size_t> &released_count()
  {
    static std::atomic<size_t> n{ 0 };
    return n;
  }

  inline void release_later(std::function<void()> f)
  {
    std::lock_guard<std::mutex> const lock{ release_mutex() };
    release_queue().push_back(std::move(f));
  }

  inline void release_object_later(lean_object *o)
  {
    release_later([o] { lean_dec(o); });
  }

  inline void drain_releases()
  {
    std::vector<std::function<void()>> q;
    {
      std::lock_guard<std::mutex> const lock{ release_mutex() };
      q.swap(release_queue());
    }
    for(auto &f : q)
    {
      f();
      ++released_count();
    }
  }

  /* Lean code runs on a thread of its own, with a large stack: elaboration recurses deeply,
   * and a thread's default stack (512 KB on macOS) is too small. Jobs run one at a time. */
  class lean_thread
  {
  public:
    static lean_thread &get()
    {
      static lean_thread t;
      return t;
    }

    bool on_it() const
    {
      return pthread_equal(pthread_self(), thread);
    }

    /* Runs `job` on Lean's thread and waits for it; its exception is rethrown here. */
    void run(std::function<void()> const &job)
    {
      if(on_it())
      {
        job();
        return;
      }
      std::lock_guard<std::mutex> const serial{ run_mutex };
      std::unique_lock<std::mutex> l{ m };
      current = &job;
      finished = false;
      failure = nullptr;
      cv.notify_all();
      cv.wait(l, [&] { return finished; });
      current = nullptr;
      if(failure)
      {
        std::rethrow_exception(failure);
      }
    }

  private:
    lean_thread()
    {
      pthread_attr_t attr;
      pthread_attr_init(&attr);
      pthread_attr_setstacksize(&attr, size_t{ 256 } << 20);
      auto const rc{ pthread_create(&thread, &attr, &lean_thread::main, this) };
      pthread_attr_destroy(&attr);
      if(rc != 0)
      {
        throw error{ "lean-sys: can't start Lean's thread" };
      }
    }

    static void *main(void *p)
    {
      auto &self{ *static_cast<lean_thread *>(p) };
      std::unique_lock<std::mutex> l{ self.m };
      for(;;)
      {
        self.cv.wait(l, [&] { return self.current && !self.finished; });
        auto const job{ self.current };
        l.unlock();
        std::exception_ptr failure;
        try
        {
          drain_releases();
          (*job)();
        }
        catch(...)
        {
          failure = std::current_exception();
        }
        l.lock();
        self.failure = failure;
        self.finished = true;
        self.cv.notify_all();
      }
      return nullptr;
    }

    pthread_t thread{};
    std::mutex run_mutex;
    std::mutex m;
    std::condition_variable cv;
    std::function<void()> const *current{};
    bool finished{};
    std::exception_ptr failure;
  };

  /* Held while Lean objects are read or released outside Lean's thread, so that it doesn't
   * run at the same time. Recursive: the jank layer holds it around a whole operation. */
  inline std::recursive_mutex &lean_lock()
  {
    static std::recursive_mutex m;
    return m;
  }

  inline bool &runtime_ready()
  {
    static bool ready{ false };
    return ready;
  }

  /* Starts Lean's runtime, with its frontend, on Lean's thread (once). */
  inline void ensure_runtime()
  {
    lean_thread::get().run([] {
      if(!runtime_ready())
      {
        lean_initialize();
        lean_init_task_manager();
        runtime_ready() = true;
      }
    });
  }

  /* A thread that allocates or releases Lean objects must be registered with Lean's runtime. */
  inline void ensure_thread()
  {
    thread_local bool ready{ false };
    if(!ready && !lean_thread::get().on_it())
    {
      ensure_runtime();
      lean_initialize_thread();
      ready = true;
    }
  }

  /* Lean values */

  inline lean_object *mk_string(std::string_view const s)
  {
    return lean_mk_string_from_bytes(s.data(), s.size());
  }

  inline std::string_view view(b_lean_obj_arg s)
  {
    return { lean_string_cstr(s), lean_string_size(s) - 1 };
  }

  inline lean_object *mk_name(std::string_view const s)
  {
    return l_String_toName(mk_string(s));
  }

  inline std::string name_string(b_lean_obj_arg name)
  {
    lean_inc(name);
    auto const s{ l_Lean_Name_toString(name, 0) };
    std::string r{ view(s) };
    lean_dec(s);
    return r;
  }

  /* `List` of owned objects. */
  inline lean_object *mk_list(std::vector<lean_object *> const &xs)
  {
    lean_object *l{ lean_box(0) };
    for(auto it{ xs.rbegin() }; it != xs.rend(); ++it)
    {
      auto const c{ lean_alloc_ctor(1, 2, 0) };
      lean_ctor_set(c, 0, *it);
      lean_ctor_set(c, 1, l);
      l = c;
    }
    return l;
  }

  inline lean_object *mk_some(lean_object *x)
  {
    auto const o{ lean_alloc_ctor(1, 1, 0) };
    lean_ctor_set(o, 0, x);
    return o;
  }

  inline lean_object *mk_pair(lean_object *a, lean_object *b)
  {
    auto const o{ lean_alloc_ctor(0, 2, 0) };
    lean_ctor_set(o, 0, a);
    lean_ctor_set(o, 1, b);
    return o;
  }

  /* The value of an `IO` result (owned), or an exception with the error's text. */
  inline lean_object *io_value(lean_object *r, std::string_view const what)
  {
    if(lean_io_result_is_error(r))
    {
      auto const e{ lean_io_result_get_error(r) };
      lean_inc(e);
      lean_dec(r);
      auto const s{ lean_io_error_to_string(e) };
      std::string msg{ what };
      msg += ": ";
      msg += view(s);
      lean_dec(s);
      throw error{ msg };
    }
    return lean_io_result_take_value(r);
  }

  /* The prefix of the Lean toolchain whose runtime is loaded, from where libleanshared is. */
  inline std::string sysroot()
  {
    Dl_info info{};
    if(!dladdr(reinterpret_cast<void *>(&lean_initialize), &info) || !info.dli_fname)
    {
      throw error{ "lean-sys: can't find where libleanshared was loaded from" };
    }
    std::string p{ info.dli_fname }; /* <prefix>/lib/lean/libleanshared.dylib */
    for(int i{}; i < 3; ++i)
    {
      p = p.substr(0, p.rfind('/'));
    }
    return p;
  }

  /* Runs `initialize_<package>_<Module_Path>(builtin)`, as a Lean program's main does. */
  inline void initialize_module(std::string const &symbol)
  {
    ensure_runtime();
    lean_thread::get().run([&] {
      auto const init{ reinterpret_cast<lean_object *(*)(uint8_t)>(
        dlsym(RTLD_DEFAULT, symbol.c_str())) };
      if(!init)
      {
        throw error{ "lean-sys: no symbol " + symbol + " in the loaded libraries" };
      }
      lean_dec(io_value(init(1), symbol));
    });
  }

  /* Shapes: how the values of a type are represented (LeanSys.Shape, in source.hpp) */

  enum class kind : uint8_t
  {
    placeholder,
    erased,
    unit,
    boolean,
    nat,
    integer,
    uint,
    real,
    real32,
    character,
    string,
    name,
    array,
    byte_array,
    list,
    option,
    prod,
    tree_map,
    tree_set,
    enumeration,
    inductive,
    opaque,
    json,
    wrap
  };

  enum class slot : uint8_t
  {
    erased,
    object,
    usize,
    scalar,
    unsupported
  };

  struct field_shape
  {
    std::string name;
    slot where{};
    size_t index{}, size{}, shape{};
  };

  struct ctor_shape
  {
    std::string name;
    size_t cidx{}, num_objs{}, num_usize{}, scalar_size{};
    std::vector<field_shape> fields;

    bool has_data() const
    {
      for(auto const &f : fields)
      {
        if(f.where != slot::erased)
        {
          return true;
        }
      }
      return false;
    }
  };

  struct shape
  {
    kind k{};
    size_t a{}, b{};
    std::string type, builder;
    std::vector<std::string> names;
    std::vector<ctor_shape> ctors;
    /* An inductive type declared with `structure`: its values are read as plain maps. */
    bool is_structure{};
    /* The builder's closure, evaluated when a value of this shape is first built. */
    lean_object *builder_fn{};

    ctor_shape const *ctor(size_t const cidx) const
    {
      for(auto const &c : ctors)
      {
        if(c.cidx == cidx)
        {
          return &c;
        }
      }
      return nullptr;
    }
  };

  inline size_t nat_field(b_lean_obj_arg o, unsigned const i)
  {
    return lean_unbox(lean_ctor_get(o, i));
  }

  inline std::string string_field(b_lean_obj_arg o, unsigned const i)
  {
    return std::string{ view(lean_ctor_get(o, i)) };
  }

  inline std::vector<shape> decode_shapes(b_lean_obj_arg arr)
  {
    std::vector<shape> r;
    for(size_t i{}; i < lean_array_size(arr); ++i)
    {
      auto const o{ lean_array_get_core(arr, i) };
      shape s;
      s.k = static_cast<kind>(lean_obj_tag(o));
      switch(s.k)
      {
        case kind::uint:
        case kind::array:
        case kind::list:
        case kind::option:
          s.a = nat_field(o, 0);
          break;
        case kind::prod:
          s.a = nat_field(o, 0);
          s.b = nat_field(o, 1);
          break;
        case kind::tree_map:
          s.a = nat_field(o, 0);
          s.b = nat_field(o, 1);
          s.builder = string_field(o, 2);
          break;
        case kind::tree_set:
          s.a = nat_field(o, 0);
          s.builder = string_field(o, 1);
          break;
        case kind::enumeration:
          {
            s.type = string_field(o, 0);
            auto const names{ lean_ctor_get(o, 1) };
            for(size_t j{}; j < lean_array_size(names); ++j)
            {
              s.names.emplace_back(view(lean_array_get_core(names, j)));
            }
            break;
          }
        case kind::inductive:
          {
            s.type = string_field(o, 0);
            auto const ctors{ lean_ctor_get(o, 1) };
            for(size_t j{}; j < lean_array_size(ctors); ++j)
            {
              auto const c{ lean_array_get_core(ctors, j) };
              ctor_shape cs{ string_field(c, 0), nat_field(c, 1), nat_field(c, 2),
                             nat_field(c, 3),    nat_field(c, 4), {} };
              auto const fields{ lean_ctor_get(c, 5) };
              for(size_t k{}; k < lean_array_size(fields); ++k)
              {
                auto const f{ lean_array_get_core(fields, k) };
                cs.fields.push_back({ string_field(f, 0), static_cast<slot>(nat_field(f, 1)),
                                      nat_field(f, 2), nat_field(f, 3), nat_field(f, 4) });
              }
              s.ctors.push_back(std::move(cs));
            }
            s.is_structure = nat_field(o, 2) != 0;
            break;
          }
        case kind::opaque:
          s.type = string_field(o, 0);
          break;
        case kind::wrap:
          s.type = string_field(o, 0); /* the field's name */
          s.a = nat_field(o, 1);
          s.builder = string_field(o, 2); /* the constructor's name, for an inductive type */
          break;
        default:
          break;
      }
      r.push_back(std::move(s));
    }
    return r;
  }

  /* The shapes of a constant's type: of its parameters, and of its result. */
  struct const_info
  {
    std::string name;
    std::vector<size_t> params;
    size_t result{};
    /* 1: the result is an `IO` action, 2: a `BaseIO` action, 3: a `CommandElabM` action. */
    unsigned io{};
    std::vector<shape> shapes;
    /* The constant's value (owned): a closure when it has parameters or is an action. */
    lean_object *value{};
    /* The number of parameters of its compiled code, and whether `value` is native code
     * (`session::compile`) rather than Lean's interpreter. */
    size_t arity{};
    bool native{};
  };

  /* A message from elaboration. Severity: 0 information, 1 warning, 2 error. */
  struct message
  {
    unsigned severity{};
    size_t line{}, column{};
    std::string text;
  };

  /* A Lean environment, built by importing modules, then elaborating commands into it, as in
   * a file: namespaces, options and sections stay open from one `elab` to the next. */
  class session
  {
  public:
    /* Imports `imports` (module names), finding them in `search_path` (the `.lake/build/lib/lean`
     * directories of a Lake project and of its packages) and in Lean's own library. */
    session(std::vector<std::string> const &search_path, std::vector<std::string> const &imports)
    {
      ensure_runtime();
      lean_thread::get().run([&] {
        enable_initializers();
        std::vector<lean_object *> sp;
        for(auto const &p : search_path)
        {
          sp.push_back(mk_string(p));
        }
        lean_dec(io_value(
          l_Lean_initSearchPath(mk_string(sysroot()), mk_list(sp), lean_io_mk_world()),
          "lean-sys: setting the search path"));

        auto all{ lean_mk_empty_array() };
        all = lean_array_push(all, mk_import("Init", false));
        all = lean_array_push(all, mk_import("Init", true));
        for(auto const &i : imports)
        {
          all = lean_array_push(all, mk_import(i, false));
        }
        all = lean_array_push(all, mk_import("Lean", false));
        lean_inc(l_Lean_Options_empty);
        env = io_value(l_Lean_importModules(all,
                                            l_Lean_Options_empty,
                                            1024,
                                            lean_mk_empty_array(),
                                            0,
                                            1,
                                            2 /* OLeanLevel.private */,
                                            lean_box(1) /* {} : NameMap _ */,
                                            lean_io_mk_world()),
                       "lean-sys: importing");
        auto const msgs{ elab_on_thread(lean_source, "<lean-sys>") };
        for(auto const &m : msgs)
        {
          if(m.severity == 2)
          {
            throw error{ "lean-sys: its Lean code doesn't elaborate: " + m.text };
          }
        }
        shapes_fn = eval_on_thread("LeanSys.constShapes");
        run_command_fn = eval_on_thread("LeanSys.runCommand");
      });
    }

    session(session const &) = delete;
    session &operator=(session const &) = delete;

    /* Releases the session's Lean objects: on Lean's thread (see `release_later`). */
    ~session()
    {
      lean_dec(env);
      if(cmd_state)
      {
        lean_dec(cmd_state);
      }
      lean_dec(shapes_fn);
      lean_dec(run_command_fn);
      for(auto const t : info_trees)
      {
        lean_dec(t);
      }
      for(auto &[_, ci] : infos)
      {
        lean_dec(ci->value);
        for(auto const &sh : ci->shapes)
        {
          if(sh.builder_fn)
          {
            lean_dec(sh.builder_fn);
          }
        }
      }
    }

    /* Elaborates `input` (commands, as in a file) into the environment. */
    std::vector<message> elab(std::string_view const input, std::string_view const file_name)
    {
      std::vector<message> r;
      lean_thread::get().run([&] { r = elab_on_thread(input, file_name); });
      return r;
    }

    /* The value of constant `name` and the shapes of its type (cached by name). */
    std::shared_ptr<const_info> info(std::string const &name)
    {
      if(auto const it{ infos.find(name) }; it != infos.end())
      {
        return it->second;
      }
      auto const ci{ std::make_shared<const_info>() };
      ci->name = name;
      lean_thread::get().run([&] {
        lean_inc(shapes_fn);
        lean_inc(env);
        auto const r{ io_value(lean_apply_3(shapes_fn, env, mk_name(name), lean_io_mk_world()),
                               "lean-sys: the shapes of " + name) };
        auto const params{ lean_ctor_get(r, 0) };
        for(size_t i{}; i < lean_array_size(params); ++i)
        {
          ci->params.push_back(lean_unbox(lean_array_get_core(params, i)));
        }
        ci->result = nat_field(r, 1);
        ci->io = static_cast<unsigned>(nat_field(r, 2));
        ci->shapes = decode_shapes(lean_ctor_get(r, 3));
        auto const new_env{ lean_ctor_get(r, 4) };
        lean_inc(new_env);
        lean_dec(env);
        env = new_env;
        ci->arity = nat_field(r, 5);
        lean_dec(r);
        ci->value = eval_on_thread(name);
      });
      infos.emplace(name, ci);
      return ci;
    }

    /* Compiles constant `name` to native code: Lean's compiler emits C for it and for the
     * definitions of the session it uses, the toolchain's clang builds that into a shared library
     * in `cache_dir` (reused when the code is the same), and the library is loaded and
     * initialized. Calls of `name` then run the native code. The library leaves Lean's and the
     * imported modules' symbols to the libraries already loaded. */
    void compile(std::string const &name, std::string const &cache_dir)
    {
      auto const ci{ info(name) };
      if(ci->native)
      {
        return;
      }
      auto const emit{ info("LeanSys.emitC") };
      auto const r{ call(*emit, { mk_name(name) }) };
      std::string const code{ view(lean_ctor_get(r, 0)) };
      auto const rest{ lean_ctor_get(r, 1) };
      std::string const symbol{ view(lean_ctor_get(rest, 0)) };
      std::string const init_name{ view(lean_ctor_get(rest, 1)) };
      lean_dec(r);

      std::string const stem{ cache_dir + "/" + std::to_string(std::hash<std::string>{}(code)) };
      std::string const c_file{ stem + ".c" };
      std::string const lib{ stem + ".so" };
      std::string const log{ stem + ".log" };
      if(!std::ifstream{ lib }.good())
      {
        std::system(("mkdir -p '" + cache_dir + "'").c_str());
        {
          std::ofstream out{ c_file };
          out << code;
        }
        /* leanc compiles with the toolchain's clang and headers; `cc` links without Lean's
         * libraries, whose symbols the loaded ones give. */
        auto const root{ sysroot() };
        std::string const obj{ stem + ".o" };
        std::string cmd{ "'" + root + "/bin/leanc' -c -fPIC -O3 -w -DLEAN_EXPORTING -o '" + obj
                         + "' '" + c_file + "' > '" + log + "' 2>&1 && cc -shared " };
#ifdef __APPLE__
        cmd += "-undefined dynamic_lookup -Wl,-w ";
#endif
        cmd += "-o '" + lib + ".tmp' '" + obj + "' >> '" + log + "' 2>&1 && mv '" + lib + ".tmp' '"
          + lib + "'";
        if(std::system(cmd.c_str()) != 0)
        {
          std::ifstream in{ log };
          std::string const out{ std::istreambuf_iterator<char>{ in }, {} };
          throw error{ "lean-sys: compiling " + name + " failed:\n" + out.substr(0, 4000) };
        }
      }
      auto const handle{ dlopen(lib.c_str(), RTLD_NOW | RTLD_LOCAL) };
      if(!handle)
      {
        auto const e{ dlerror() };
        throw error{ "lean-sys: loading the compiled " + name + ": " + (e ? e : lib) };
      }
      lean_thread::get().run([&] {
        auto const init{ reinterpret_cast<lean_object *(*)(uint8_t)>(
          dlsym(handle, init_name.c_str())) };
        if(!init)
        {
          throw error{ "lean-sys: no " + init_name + " in the compiled " + name };
        }
        lean_dec(io_value(init(1), "lean-sys: initializing the compiled " + name));
        lean_object *value{};
        if(ci->arity == 0)
        {
          auto const global{ reinterpret_cast<lean_object **>(dlsym(handle, symbol.c_str())) };
          if(!global)
          {
            throw error{ "lean-sys: no " + symbol + " in the compiled " + name };
          }
          value = *global;
          lean_inc(value);
        }
        else
        {
          auto fn{ dlsym(handle, (symbol + "___boxed").c_str()) };
          if(!fn)
          {
            fn = dlsym(handle, symbol.c_str());
          }
          if(!fn)
          {
            throw error{ "lean-sys: no " + symbol + " in the compiled " + name };
          }
          value = lean_alloc_closure(fn, static_cast<unsigned>(ci->arity), 0);
        }
        lean_dec(ci->value);
        ci->value = value;
        ci->native = true;
      });
    }

    /* The closure of a map's or set's builder. */
    lean_object *builder(shape &s)
    {
      if(!s.builder_fn)
      {
        if(s.builder.empty())
        {
          throw error{ "lean-sys: maps of this type can't be built" };
        }
        lean_thread::get().run([&] { s.builder_fn = eval_on_thread(s.builder); });
      }
      return s.builder_fn;
    }

    /* Applies `info`'s value to `args` (owned), running the action it returns, if any. The
     * result is owned. */
    lean_object *call(const_info const &ci, std::vector<lean_object *> args)
    {
      lean_object *r{};
      lean_thread::get().run([&] {
        if(ci.io == 3)
        {
          r = run_command(ci, std::move(args));
          return;
        }
        if(ci.io)
        {
          args.push_back(lean_io_mk_world());
        }
        if(args.empty())
        {
          lean_inc(ci.value);
          r = ci.value;
        }
        else
        {
          lean_inc(ci.value);
          r = lean_apply_n(ci.value, static_cast<unsigned>(args.size()), args.data());
        }
        if(ci.io == 1)
        {
          r = io_value(r, ci.name);
        }
      });
      return r;
    }

    /* Applies a closure (borrowed) to `args` (owned), on Lean's thread. */
    lean_object *apply(b_lean_obj_arg f, std::vector<lean_object *> args)
    {
      lean_object *r{};
      lean_thread::get().run([&] {
        lean_inc(f);
        r = lean_apply_n(const_cast<lean_object *>(f), static_cast<unsigned>(args.size()), args.data());
      });
      return r;
    }

    lean_object *environment() const
    {
      return env;
    }

  private:
    /* Before each import: `importModules` runs the imported modules' initializers only when
     * this is set, and turns it off again when it's done (`Lean.withImporting`). */
    static void enable_initializers()
    {
      lean_enable_initializer_execution(lean_io_mk_world()); /* BaseIO */
    }

    static lean_object *mk_import(std::string_view const mod, bool const meta)
    {
      auto const o{ lean_alloc_ctor(0, 1, 3) };
      lean_ctor_set(o, 0, mk_name(mod));
      lean_ctor_set_uint8(o, sizeof(void *) + 0, 0); /* importAll */
      lean_ctor_set_uint8(o, sizeof(void *) + 1, 1); /* isExported */
      lean_ctor_set_uint8(o, sizeof(void *) + 2, meta ? 1 : 0); /* isMeta */
      return o;
    }

    lean_object *eval_on_thread(std::string_view const name)
    {
      auto const n{ mk_name(name) };
      auto const r{ l_Lean_Environment_evalConst(lean_box(0), env, l_Lean_Options_empty, n, 0) };
      lean_dec(n);
      if(lean_obj_tag(r) == 0)
      {
        std::string msg{ "lean-sys: evaluating " };
        msg += name;
        msg += ": ";
        msg += view(lean_ctor_get(r, 0));
        lean_dec(r);
        throw error{ msg };
      }
      auto const v{ lean_ctor_get(r, 0) };
      lean_inc(v);
      lean_dec(r);
      return v;
    }

    std::vector<message> elab_on_thread(std::string_view const input, std::string_view const file_name)
    {
      auto const ictx{ l_Lean_Parser_mkInputContext(mk_string(input),
                                                    mk_string(file_name),
                                                    1,
                                                    lean_usize_to_nat(input.size()),
                                                    lean_box(0)) };
      auto const parser_state{ lean_alloc_ctor(0, 1, 2) };
      lean_ctor_set(parser_state, 0, lean_box(0));
      lean_ctor_set_uint8(parser_state, sizeof(void *) + 0, 0);
      lean_ctor_set_uint8(parser_state, sizeof(void *) + 1, 0);

      auto const st{ io_value(
        l_Lean_Elab_IO_processCommands(ictx, parser_state, fresh_state(), lean_io_mk_world()),
        "lean-sys: elaborating") };
      auto const cs{ lean_ctor_get(st, 0) };
      lean_inc(cs);
      lean_dec(st);
      return update_state(cs);
    }

    /* A command state for the next command: the session's environment, no messages, and the
     * scopes (namespaces, options, sections) and name generators of the last one (Command.State's
     * fields 2 to 7). */
    lean_object *fresh_state()
    {
      lean_inc(env);
      lean_inc(l_Lean_MessageLog_empty);
      lean_inc(l_Lean_Options_empty);
      auto fresh{ l_Lean_Elab_Command_mkState(env, l_Lean_MessageLog_empty, l_Lean_Options_empty) };
      if(cmd_state && lean_is_exclusive(fresh))
      {
        for(unsigned i{ 2 }; i <= 7; ++i)
        {
          auto const v{ lean_ctor_get(cmd_state, i) };
          lean_inc(v);
          lean_dec(lean_ctor_get(fresh, i));
          lean_ctor_set(fresh, i, v);
        }
      }
      return fresh;
    }

    /* Runs the `CommandElabM` action that `ci` returns, in the session's command state. Throws
     * when it logs errors. */
    lean_object *run_command(const_info const &ci, std::vector<lean_object *> args)
    {
      lean_object *x{};
      lean_inc(ci.value);
      x = args.empty() ? ci.value
                       : lean_apply_n(ci.value, static_cast<unsigned>(args.size()), args.data());
      lean_inc(run_command_fn);
      auto const r{ io_value(lean_apply_4(run_command_fn, lean_box(0), fresh_state(), x,
                                          lean_io_mk_world()),
                             ci.name) };
      auto const a{ lean_ctor_get(r, 0) };
      auto const cs{ lean_ctor_get(r, 1) };
      lean_inc(a);
      lean_inc(cs);
      lean_dec(r);
      auto const msgs{ update_state(cs) };
      std::string errors;
      for(auto const &m : msgs)
      {
        if(m.severity == 2)
        {
          errors += (errors.empty() ? "" : "\n") + m.text;
        }
      }
      if(!errors.empty())
      {
        lean_dec(a);
        throw error{ ci.name + ": " + errors };
      }
      return a;
    }

    /* Makes command state `cs` (owned) the session's, and returns its messages. */
    std::vector<message> update_state(lean_object *cs)
    {
      std::vector<message> r;
      auto const msgs{ l_Lean_MessageLog_toArray(lean_ctor_get(cs, 1)) };
      for(size_t i{}; i < lean_array_size(msgs); ++i)
      {
        auto const m{ lean_array_get_core(msgs, i) };
        auto const scalars{ sizeof(void *) * 5 };
        if(lean_ctor_get_uint8(m, scalars + 2)) /* isSilent */
        {
          continue;
        }
        auto const pos{ lean_ctor_get(m, 1) };
        auto const data{ lean_ctor_get(m, 4) };
        lean_inc(data);
        auto const text{ l_Lean_MessageData_toString(data, lean_io_mk_world()) }; /* BaseIO */
        r.push_back({ lean_ctor_get_uint8(m, scalars + 1),
                      lean_unbox(lean_ctor_get(pos, 0)),
                      lean_unbox(lean_ctor_get(pos, 1)),
                      std::string{ view(text) } });
        lean_dec(text);
      }
      lean_dec(msgs);

      auto const new_env{ lean_ctor_get(cs, 0) };
      lean_inc(new_env);
      lean_dec(env);
      env = new_env;
      /* Keep the earlier commands' info trees alive, as an open file does: some elaborators tie
       * the lifetime of what they started to them (Veil's verification manager). */
      if(cmd_state)
      {
        auto const info{ lean_ctor_get(cmd_state, 8) };
        lean_inc(info);
        info_trees.push_back(info);
        lean_dec(cmd_state);
      }
      cmd_state = cs;
      return r;
    }

    lean_object *env{};
    lean_object *cmd_state{};
    lean_object *shapes_fn{};
    lean_object *run_command_fn{};
    std::vector<lean_object *> info_trees;
    std::map<std::string, std::shared_ptr<const_info>> infos;
  };

  /* Reading values: a `Sink` builds the reader's values (see the jank layer):
   *   value nil(), boolean(bool), integer(int64_t), unsigned_integer(uint64_t),
   *     big_integer(std::string_view digits), real(double), string(std::string_view),
   *     character(uint32_t), keyword(std::string_view), symbol(std::string_view),
   *     opaque(b_lean_obj_arg, shape const &)
   *   builder vector_begin(), void vector_push(builder &, value), value vector_end(builder &)
   *   builder map_begin(), void map_assoc(builder &, value, value), value map_end(builder &)
   *   builder set_begin(), void set_conj(builder &, value), value set_end(builder &) */
  template <typename Sink>
  struct reader
  {
    using value = typename Sink::value;

    std::vector<shape> const &shapes;
    Sink &sink;

    /* `o` is in an object slot: scalars are boxed. */
    value read(size_t const s, b_lean_obj_arg o)
    {
      auto const &sh{ shapes[s] };
      switch(sh.k)
      {
        case kind::placeholder:
        case kind::erased:
        case kind::unit:
          return sink.nil();
        case kind::boolean:
          return sink.boolean(lean_unbox(o) != 0);
        case kind::nat:
          if(lean_is_scalar(o))
          {
            return sink.unsigned_integer(lean_unbox(o));
          }
          return big(o, true);
        case kind::integer:
          if(lean_is_scalar(o))
          {
            return sink.integer(lean_scalar_to_int64(o));
          }
          return big(o, false);
        case kind::uint:
          switch(sh.a)
          {
            case 8:
            case 16:
              return sink.unsigned_integer(lean_unbox(o));
            case 32:
              return sink.unsigned_integer(lean_unbox_uint32(o));
            case 64:
              return sink.unsigned_integer(lean_unbox_uint64(o));
            default:
              return sink.unsigned_integer(lean_unbox_usize(o));
          }
        case kind::real:
          return sink.real(lean_unbox_float(o));
        case kind::real32:
          return sink.real(lean_unbox_float32(o));
        case kind::character:
          return sink.character(lean_unbox_uint32(o));
        case kind::string:
          return sink.string(view(o));
        case kind::name:
          return sink.symbol(name_string(o));
        case kind::array:
          {
            auto b{ sink.vector_begin() };
            for(size_t i{}; i < lean_array_size(o); ++i)
            {
              sink.vector_push(b, read(sh.a, lean_array_get_core(o, i)));
            }
            return sink.vector_end(b);
          }
        case kind::byte_array:
          {
            auto b{ sink.vector_begin() };
            auto const p{ lean_sarray_cptr(const_cast<lean_object *>(o)) };
            for(size_t i{}; i < lean_sarray_size(o); ++i)
            {
              sink.vector_push(b, sink.unsigned_integer(p[i]));
            }
            return sink.vector_end(b);
          }
        case kind::list:
          {
            auto b{ sink.vector_begin() };
            for(auto c{ o }; !lean_is_scalar(c); c = lean_ctor_get(c, 1))
            {
              sink.vector_push(b, read(sh.a, lean_ctor_get(c, 0)));
            }
            return sink.vector_end(b);
          }
        case kind::option:
          return lean_is_scalar(o) ? sink.nil() : read(sh.a, lean_ctor_get(o, 0));
        case kind::prod:
          {
            auto b{ sink.vector_begin() };
            sink.vector_push(b, read(sh.a, lean_ctor_get(o, 0)));
            sink.vector_push(b, read(sh.b, lean_ctor_get(o, 1)));
            return sink.vector_end(b);
          }
        case kind::tree_map:
          {
            auto b{ sink.map_begin() };
            tree(o, [&](b_lean_obj_arg k, b_lean_obj_arg v) {
              sink.map_assoc(b, read(sh.a, k), read(sh.b, v));
            });
            return sink.map_end(b);
          }
        case kind::tree_set:
          {
            auto b{ sink.set_begin() };
            tree(o, [&](b_lean_obj_arg k, b_lean_obj_arg) { sink.set_conj(b, read(sh.a, k)); });
            return sink.set_end(b);
          }
        case kind::enumeration:
          return sink.keyword(sh.names.at(lean_unbox(o)));
        case kind::inductive:
          return inductive(sh, o);
        case kind::opaque:
          return sink.opaque(o, sh);
        case kind::json:
          return json(o);
        case kind::wrap:
          {
            auto b{ sink.map_begin() };
            if(!sh.builder.empty())
            {
              sink.map_assoc(b, sink.keyword("lean/ctor"), sink.keyword(sh.builder));
            }
            sink.map_assoc(b, sink.keyword(sh.type), read(sh.a, o));
            return sink.map_end(b);
          }
      }
      return sink.nil();
    }

  private:
    /* `Lean.Json`: null, bool, num (mantissa × 10^-exponent), str, arr, obj (keys as keywords). */
    value json(b_lean_obj_arg o)
    {
      switch(lean_obj_tag(o))
      {
        case 1:
          return sink.boolean(lean_ctor_get_uint8(o, 0) != 0);
        case 2:
          {
            auto const n{ lean_ctor_get(o, 0) };
            auto const m{ lean_ctor_get(n, 0) };
            auto const e{ lean_unbox(lean_ctor_get(n, 1)) };
            if(e == 0)
            {
              return lean_is_scalar(m) ? sink.integer(lean_scalar_to_int64(m)) : big(m, false);
            }
            double x{};
            if(lean_is_scalar(m))
            {
              x = static_cast<double>(lean_scalar_to_int64(m));
            }
            else
            {
              auto const s{ l_Int_repr(m) };
              x = std::stod(std::string{ view(s) });
              lean_dec(s);
            }
            for(size_t i{}; i < e; ++i)
            {
              x /= 10;
            }
            return sink.real(x);
          }
        case 3:
          return sink.string(view(lean_ctor_get(o, 0)));
        case 4:
          {
            auto const a{ lean_ctor_get(o, 0) };
            auto b{ sink.vector_begin() };
            for(size_t i{}; i < lean_array_size(a); ++i)
            {
              sink.vector_push(b, json(lean_array_get_core(a, i)));
            }
            return sink.vector_end(b);
          }
        case 5:
          {
            auto b{ sink.map_begin() };
            tree(lean_ctor_get(o, 0), [&](b_lean_obj_arg k, b_lean_obj_arg v) {
              sink.map_assoc(b, sink.keyword(view(k)), json(v));
            });
            return sink.map_end(b);
          }
        default:
          return sink.nil();
      }
    }

    value big(b_lean_obj_arg o, bool const nat)
    {
      /* A big `Nat` and a big `Int` are both GMP numbers. */
      auto const s{ l_Int_repr(o) };
      auto const v{ sink.big_integer(view(s)) };
      lean_dec(s);
      (void)nat;
      return v;
    }

    /* `Std.DTreeMap.Internal.Impl`: `inner size k v l r` (0) or `leaf` (1), in key order. */
    template <typename F>
    static void tree(b_lean_obj_arg o, F &&f)
    {
      if(lean_is_scalar(o))
      {
        return;
      }
      tree(lean_ctor_get(o, 3), f);
      f(lean_ctor_get(o, 1), lean_ctor_get(o, 2));
      tree(lean_ctor_get(o, 4), f);
    }

    value inductive(shape const &sh, b_lean_obj_arg o)
    {
      auto const c{ sh.ctor(lean_obj_tag(o)) };
      if(!c)
      {
        throw error{ "lean-sys: a value of " + sh.type + " with an unknown constructor" };
      }
      bool const structure{ sh.is_structure };
      if(!structure && !c->has_data())
      {
        return sink.keyword(c->name);
      }
      auto b{ sink.map_begin() };
      if(!structure)
      {
        sink.map_assoc(b, sink.keyword("lean/ctor"), sink.keyword(c->name));
      }
      for(auto const &f : c->fields)
      {
        if(f.where == slot::erased)
        {
          continue;
        }
        sink.map_assoc(b, sink.keyword(f.name), field(*c, f, o));
      }
      return sink.map_end(b);
    }

    value field(ctor_shape const &c, field_shape const &f, b_lean_obj_arg o)
    {
      auto const &fs{ shapes[f.shape] };
      auto const scalars{ sizeof(void *) * (c.num_objs + c.num_usize) + f.index };
      switch(f.where)
      {
        case slot::object:
          return read(f.shape, lean_ctor_get(o, static_cast<unsigned>(f.index)));
        case slot::usize:
          return sink.unsigned_integer(
            lean_ctor_get_usize(o, static_cast<unsigned>(c.num_objs + f.index)));
        case slot::scalar:
          switch(f.size)
          {
            case 1:
              {
                auto const x{ lean_ctor_get_uint8(o, scalars) };
                if(fs.k == kind::boolean)
                {
                  return sink.boolean(x != 0);
                }
                if(fs.k == kind::enumeration)
                {
                  return sink.keyword(fs.names.at(x));
                }
                return sink.unsigned_integer(x);
              }
            case 2:
              {
                auto const x{ lean_ctor_get_uint16(o, scalars) };
                if(fs.k == kind::enumeration)
                {
                  return sink.keyword(fs.names.at(x));
                }
                return sink.unsigned_integer(x);
              }
            case 4:
              if(fs.k == kind::real32)
              {
                return sink.real(lean_ctor_get_float32(o, scalars));
              }
              if(fs.k == kind::character)
              {
                return sink.character(lean_ctor_get_uint32(o, scalars));
              }
              return sink.unsigned_integer(lean_ctor_get_uint32(o, scalars));
            case 8:
              if(fs.k == kind::real)
              {
                return sink.real(lean_ctor_get_float(o, scalars));
              }
              return sink.unsigned_integer(lean_ctor_get_uint64(o, scalars));
            default:
              break;
          }
          break;
        default:
          break;
      }
      return sink.nil();
    }
  };

  /* Building values: a `Source` reads the values given (see the jank layer):
   *   bool is_nil(value), truthy(value), is_map(value), is_keyword(value)
   *   int64_t to_int64(value), uint64_t to_uint64(value), double to_double(value)
   *   std::string integer_digits(value) (for big integers: "" if it fits in 64 bits)
   *   std::string text(value) (a string's text, a keyword's or symbol's name)
   *   uint32_t to_char(value)
   *   size_t count(value), value nth(value, size_t)
   *   void for_each(value, F(value)) (a collection's items), for_each_entry(value, F(value, value))
   *   bool get(value map, std::string_view key, value &out) (by keyword)
   *   lean_object *lean_handle(value) (a Lean value held by the jank layer, borrowed, or nullptr)
   *   std::string describe(value) (for errors) */
  template <typename Source>
  struct writer
  {
    using value = typename Source::value;

    session &s;
    std::vector<shape> &shapes;
    Source &src;

    /* For an object slot: scalars are boxed. The result is owned. */
    lean_object *write(size_t const i, value v)
    {
      auto &sh{ shapes[i] };
      switch(sh.k)
      {
        case kind::placeholder:
        case kind::erased:
        case kind::unit:
          return lean_box(0);
        case kind::boolean:
          return lean_box(src.truthy(v) ? 1 : 0);
        case kind::nat:
          {
            auto const digits{ src.integer_digits(v) };
            if(!digits.empty())
            {
              if(digits[0] == '-')
              {
                throw error{ "lean-sys: a negative number for a Nat: " + digits };
              }
              return lean_cstr_to_nat(digits.c_str());
            }
            auto const x{ src.to_int64(v) };
            if(x < 0)
            {
              throw error{ "lean-sys: a negative number for a Nat: " + src.describe(v) };
            }
            return lean_uint64_to_nat(static_cast<uint64_t>(x));
          }
        case kind::integer:
          {
            auto const digits{ src.integer_digits(v) };
            if(!digits.empty())
            {
              return lean_cstr_to_int(digits.c_str());
            }
            return lean_int64_to_int(src.to_int64(v));
          }
        case kind::uint:
          switch(sh.a)
          {
            case 8:
            case 16:
              return lean_box(static_cast<size_t>(src.to_uint64(v)));
            case 32:
              return lean_box_uint32(static_cast<uint32_t>(src.to_uint64(v)));
            case 64:
              return lean_box_uint64(src.to_uint64(v));
            default:
              return lean_box_usize(static_cast<size_t>(src.to_uint64(v)));
          }
        case kind::real:
          return lean_box_float(src.to_double(v));
        case kind::real32:
          return lean_box_float32(static_cast<float>(src.to_double(v)));
        case kind::character:
          return lean_box_uint32(src.to_char(v));
        case kind::string:
          return mk_string(src.text(v));
        case kind::name:
          return mk_name(src.text(v));
        case kind::array:
          {
            auto const n{ src.count(v) };
            auto const a{ lean_alloc_array(n, n) };
            size_t j{};
            src.for_each(v, [&](value x) { lean_array_set_core(a, j++, write(sh.a, x)); });
            return a;
          }
        case kind::byte_array:
          {
            auto const n{ src.count(v) };
            auto const a{ lean_alloc_sarray(1, n, n) };
            size_t j{};
            src.for_each(v, [&](value x) {
              lean_sarray_cptr(a)[j++] = static_cast<uint8_t>(src.to_uint64(x));
            });
            return a;
          }
        case kind::list:
          {
            std::vector<lean_object *> xs;
            src.for_each(v, [&](value x) { xs.push_back(write(sh.a, x)); });
            return mk_list(xs);
          }
        case kind::option:
          return src.is_nil(v) ? lean_box(0) : mk_some(write(sh.a, v));
        case kind::prod:
          if(src.count(v) != 2)
          {
            throw error{ "lean-sys: a pair must be a vector of two values: " + src.describe(v) };
          }
          return mk_pair(write(sh.a, src.nth(v, 0)), write(sh.b, src.nth(v, 1)));
        case kind::tree_map:
          {
            std::vector<lean_object *> xs;
            src.for_each_entry(v, [&](value k, value x) {
              xs.push_back(mk_pair(write(sh.a, k), write(sh.b, x)));
            });
            return s.apply(s.builder(sh), { mk_list(xs) });
          }
        case kind::tree_set:
          {
            std::vector<lean_object *> xs;
            src.for_each(v, [&](value k) { xs.push_back(write(sh.a, k)); });
            return s.apply(s.builder(sh), { mk_list(xs) });
          }
        case kind::enumeration:
          return lean_box(enum_index(sh, v));
        case kind::inductive:
          return inductive(sh, v);
        case kind::opaque:
          if(auto const h{ src.lean_handle(v) })
          {
            lean_inc(h);
            return h;
          }
          throw error{ "lean-sys: a value of " + sh.type + " can't be built from "
                       + src.describe(v) };
        case kind::json:
          throw error{ "lean-sys: Lean.Json values can't be built from jank values" };
        case kind::wrap:
          {
            value x{};
            if(!src.get(v, sh.type, x))
            {
              throw error{ "lean-sys: no :" + sh.type + " in " + src.describe(v) };
            }
            return write(sh.a, x);
          }
      }
      return lean_box(0);
    }

  private:
    size_t enum_index(shape const &sh, value v)
    {
      auto const name{ src.text(v) };
      for(size_t j{}; j < sh.names.size(); ++j)
      {
        if(sh.names[j] == name)
        {
          return j;
        }
      }
      throw error{ "lean-sys: " + name + " isn't a constructor of " + sh.type };
    }

    lean_object *inductive(shape &sh, value v)
    {
      ctor_shape const *c{};
      if(sh.ctors.size() == 1)
      {
        c = &sh.ctors[0];
      }
      else
      {
        std::string name;
        value tag{};
        if(src.is_keyword(v))
        {
          name = src.text(v);
        }
        else if(src.is_map(v) && src.get(v, "lean/ctor", tag))
        {
          name = src.text(tag);
        }
        else
        {
          throw error{ "lean-sys: a value of " + sh.type
                       + " is a keyword, or a map with :lean/ctor: " + src.describe(v) };
        }
        for(auto const &x : sh.ctors)
        {
          if(x.name == name)
          {
            c = &x;
          }
        }
        if(!c)
        {
          throw error{ "lean-sys: " + name + " isn't a constructor of " + sh.type };
        }
      }
      if(c->num_objs == 0 && c->num_usize == 0 && c->scalar_size == 0)
      {
        return lean_box(c->cidx);
      }
      auto const o{ lean_alloc_ctor(static_cast<unsigned>(c->cidx),
                                    static_cast<unsigned>(c->num_objs),
                                    static_cast<unsigned>(c->num_usize * sizeof(size_t)
                                                          + c->scalar_size)) };
      for(auto const &f : c->fields)
      {
        if(f.where == slot::erased)
        {
          continue;
        }
        value x{};
        if(!src.get(v, f.name, x))
        {
          lean_free_object(o);
          throw error{ "lean-sys: no :" + f.name + " for " + sh.type + "." + c->name + " in "
                       + src.describe(v) };
        }
        set_field(*c, f, o, x);
      }
      return o;
    }

    void set_field(ctor_shape const &c, field_shape const &f, lean_object *o, value x)
    {
      auto &fs{ shapes[f.shape] };
      auto const scalars{ sizeof(void *) * (c.num_objs + c.num_usize) + f.index };
      switch(f.where)
      {
        case slot::object:
          lean_ctor_set(o, static_cast<unsigned>(f.index), write(f.shape, x));
          return;
        case slot::usize:
          lean_ctor_set_usize(o, static_cast<unsigned>(c.num_objs + f.index),
                              static_cast<size_t>(src.to_uint64(x)));
          return;
        case slot::scalar:
          switch(f.size)
          {
            case 1:
              lean_ctor_set_uint8(o, scalars,
                                  fs.k == kind::boolean ? (src.truthy(x) ? 1 : 0)
                                  : fs.k == kind::enumeration
                                    ? static_cast<uint8_t>(enum_index(fs, x))
                                    : static_cast<uint8_t>(src.to_uint64(x)));
              return;
            case 2:
              lean_ctor_set_uint16(o, scalars,
                                   fs.k == kind::enumeration
                                     ? static_cast<uint16_t>(enum_index(fs, x))
                                     : static_cast<uint16_t>(src.to_uint64(x)));
              return;
            case 4:
              if(fs.k == kind::real32)
              {
                lean_ctor_set_float32(o, scalars, static_cast<float>(src.to_double(x)));
              }
              else if(fs.k == kind::character)
              {
                lean_ctor_set_uint32(o, scalars, src.to_char(x));
              }
              else
              {
                lean_ctor_set_uint32(o, scalars, static_cast<uint32_t>(src.to_uint64(x)));
              }
              return;
            case 8:
              if(fs.k == kind::real)
              {
                lean_ctor_set_float(o, scalars, src.to_double(x));
              }
              else
              {
                lean_ctor_set_uint64(o, scalars, src.to_uint64(x));
              }
              return;
            default:
              break;
          }
          break;
        default:
          break;
      }
      throw error{ "lean-sys: field " + f.name + " of " + c.name + " can't be built" };
    }
  };
}

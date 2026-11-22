#pragma once

/* lean-sys's jank layer in C++: Lean values to jank values and back (a `Sink` and a `Source`
 * for lean_sys.hpp's reader and writer), and the functions lean_sys/session.jank calls. */

#include <lean_sys/lean_sys.hpp>

#include <cstdint>
#include <filesystem>

#include <gc/gc.h>

#include <jank/runtime/context.hpp>
#include <jank/runtime/core.hpp>
#include <jank/runtime/core/make_box.hpp>
#include <jank/runtime/core/math.hpp>
#include <jank/runtime/core/seq.hpp>
#include <jank/runtime/core/truthy.hpp>
#include <jank/runtime/obj/big_integer.hpp>
#include <jank/runtime/obj/character.hpp>
#include <jank/runtime/obj/keyword.hpp>
#include <jank/runtime/obj/opaque_box.hpp>
#include <jank/runtime/obj/persistent_array_map.hpp>
#include <jank/runtime/obj/persistent_hash_set.hpp>
#include <jank/runtime/obj/persistent_string.hpp>
#include <jank/runtime/obj/persistent_vector.hpp>
#include <jank/runtime/obj/symbol.hpp>

namespace lean_sys::jank_layer
{
  namespace rt = ::jank::runtime;
  using rt::object_ref;

  /* The canonical type of the opaque boxes holding Lean values and sessions. */
  inline constexpr char const *value_box{ "lean_sys::value" };
  inline constexpr char const *session_box{ "lean_sys::session" };

  inline jtl::immutable_string istr(std::string_view const s)
  {
    return { s.data(), s.size() };
  }

  inline std::string to_std(object_ref const o)
  {
    auto const s{ o.to_string() };
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

  inline object_ref big(std::string_view const digits)
  {
    return rt::make_box<rt::obj::big_integer>(::jank::native_big_integer{ std::string{ digits } });
  }

  inline std::string utf8(uint32_t const c)
  {
    std::string r;
    if(c < 0x80)
    {
      r += static_cast<char>(c);
    }
    else if(c < 0x800)
    {
      r += static_cast<char>(0xC0 | (c >> 6));
      r += static_cast<char>(0x80 | (c & 0x3F));
    }
    else if(c < 0x10000)
    {
      r += static_cast<char>(0xE0 | (c >> 12));
      r += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
      r += static_cast<char>(0x80 | (c & 0x3F));
    }
    else
    {
      r += static_cast<char>(0xF0 | (c >> 18));
      r += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
      r += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
      r += static_cast<char>(0x80 | (c & 0x3F));
    }
    return r;
  }

  /* A Lean value held by jank, owned by its box: when jank's GC collects the box, its finalizer
   * queues the value's release on Lean's thread. */
  inline object_ref box_value(b_lean_obj_arg o)
  {
    auto const owned{ const_cast<lean_object *>(o) };
    lean_inc(owned);
    auto const b{ rt::make_box<rt::obj::opaque_box>(jtl::ptr<void>{ owned }, istr(value_box)) };
    GC_register_finalizer_no_order(
      b.operator->(),
      [](void *, void *value) { release_object_later(static_cast<lean_object *>(value)); },
      owned,
      nullptr,
      nullptr);
    return b;
  }

  inline rt::obj::opaque_box_ref as_box(object_ref const o, char const *canonical)
  {
    if(o.get_type() != rt::object_type::opaque_box)
    {
      return {};
    }
    auto const b{ rt::expect_object<rt::obj::opaque_box>(o) };
    if(std::string_view{ b->canonical_type.data(), b->canonical_type.size() } != canonical)
    {
      return {};
    }
    return b;
  }

  struct sink
  {
    using value = object_ref;
    using builder = object_ref;

    value nil()
    {
      return rt::jank_nil;
    }

    value boolean(bool const b)
    {
      return b ? object_ref{ rt::jank_true } : object_ref{ rt::jank_false };
    }

    value integer(int64_t const i)
    {
      return rt::make_box(i);
    }

    value unsigned_integer(uint64_t const i)
    {
      if(i <= static_cast<uint64_t>(INT64_MAX))
      {
        return rt::make_box(static_cast<int64_t>(i));
      }
      return big(std::to_string(i));
    }

    value big_integer(std::string_view const digits)
    {
      return big(digits);
    }

    value real(double const d)
    {
      return rt::make_box(d);
    }

    value string(std::string_view const s)
    {
      return str(s);
    }

    value character(uint32_t const c)
    {
      return rt::make_box<rt::obj::character>(istr(utf8(c)));
    }

    value keyword(std::string_view const s)
    {
      return kw(s);
    }

    value symbol(std::string_view const s)
    {
      return rt::make_box<rt::obj::symbol>(istr(s));
    }

    value opaque(b_lean_obj_arg o, shape const &)
    {
      return box_value(o);
    }

    builder vector_begin()
    {
      return rt::obj::persistent_vector::empty();
    }

    void vector_push(builder &b, value const v)
    {
      b = rt::conj(b, v);
    }

    value vector_end(builder &b)
    {
      return b;
    }

    builder map_begin()
    {
      return rt::obj::persistent_array_map::empty();
    }

    void map_assoc(builder &b, value const k, value const v)
    {
      b = rt::assoc(b, k, v);
    }

    value map_end(builder &b)
    {
      return b;
    }

    builder set_begin()
    {
      return rt::obj::persistent_hash_set::empty();
    }

    void set_conj(builder &b, value const v)
    {
      b = rt::conj(b, v);
    }

    value set_end(builder &b)
    {
      return b;
    }
  };

  struct source
  {
    using value = object_ref;

    bool is_nil(value const v)
    {
      return rt::is_nil(v);
    }

    bool truthy(value const v)
    {
      return rt::truthy(v);
    }

    bool is_map(value const v)
    {
      return rt::is_map(v);
    }

    bool is_keyword(value const v)
    {
      return rt::is_keyword(v);
    }

    int64_t to_int64(value const v)
    {
      if(!rt::is_integer(v))
      {
        throw error{ "lean-sys: not an integer: " + describe(v) };
      }
      return v.to_integer();
    }

    uint64_t to_uint64(value const v)
    {
      auto const digits{ integer_digits(v) };
      if(!digits.empty())
      {
        return std::stoull(digits);
      }
      return static_cast<uint64_t>(to_int64(v));
    }

    double to_double(value const v)
    {
      if(!rt::is_number(v))
      {
        throw error{ "lean-sys: not a number: " + describe(v) };
      }
      return v.to_real();
    }

    /* A big integer's digits; "" for any other value. */
    std::string integer_digits(value const v)
    {
      if(!rt::is_big_integer(v))
      {
        return "";
      }
      auto s{ to_std(v) };
      if(!s.empty() && s.back() == 'N')
      {
        s.pop_back();
      }
      return s;
    }

    std::string text(value const v)
    {
      if(rt::is_keyword(v))
      {
        auto const sym{ rt::expect_object<rt::obj::keyword>(v)->sym };
        std::string r;
        if(!sym->ns.empty())
        {
          r += std::string_view{ sym->ns.data(), sym->ns.size() };
          r += '/';
        }
        r += std::string_view{ sym->name.data(), sym->name.size() };
        return r;
      }
      return to_std(v);
    }

    uint32_t to_char(value const v)
    {
      if(rt::is_integer(v))
      {
        return static_cast<uint32_t>(v.to_integer());
      }
      auto const s{ text(v) };
      auto const p{ reinterpret_cast<unsigned char const *>(s.data()) };
      if(s.empty())
      {
        throw error{ "lean-sys: not a character: " + describe(v) };
      }
      if(p[0] < 0x80)
      {
        return p[0];
      }
      if((p[0] & 0xE0) == 0xC0 && s.size() >= 2)
      {
        return ((p[0] & 0x1F) << 6) | (p[1] & 0x3F);
      }
      if((p[0] & 0xF0) == 0xE0 && s.size() >= 3)
      {
        return ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F);
      }
      if(s.size() >= 4)
      {
        return ((p[0] & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6)
          | (p[3] & 0x3F);
      }
      throw error{ "lean-sys: not a character: " + describe(v) };
    }

    size_t count(value const v)
    {
      return rt::sequence_length(v);
    }

    value nth(value const v, size_t const i)
    {
      return rt::nth(v, rt::make_box(static_cast<int64_t>(i)));
    }

    template <typename F>
    void for_each(value const v, F &&f)
    {
      for(auto s{ rt::seq(v) }; !rt::is_nil(s); s = rt::next(s))
      {
        f(rt::first(s));
      }
    }

    template <typename F>
    void for_each_entry(value const m, F &&f)
    {
      if(!rt::is_map(m))
      {
        throw error{ "lean-sys: not a map: " + describe(m) };
      }
      for(auto s{ rt::seq(m) }; !rt::is_nil(s); s = rt::next(s))
      {
        auto const e{ rt::first(s) };
        f(nth(e, 0), nth(e, 1));
      }
    }

    bool get(value const m, std::string_view const key, value &out)
    {
      if(!rt::is_map(m))
      {
        return false;
      }
      auto const k{ kw(key) };
      if(!rt::contains(m, k))
      {
        return false;
      }
      out = rt::get(m, k);
      return true;
    }

    lean_object *lean_handle(value const v)
    {
      auto const b{ as_box(v, value_box) };
      return b.is_some() ? static_cast<lean_object *>(b->data.data) : nullptr;
    }

    std::string describe(value const v)
    {
      auto const s{ v.to_code_string() };
      return { s.data(), s.size() };
    }
  };

  inline session &unbox_session(object_ref const o)
  {
    auto const b{ as_box(o, session_box) };
    if(!b.is_some())
    {
      throw error{ "lean-sys: not a Lean session" };
    }
    return *static_cast<session *>(b->data.data);
  }

  inline std::vector<std::string> strings(object_ref const coll)
  {
    std::vector<std::string> r;
    for(auto s{ rt::seq(coll) }; !rt::is_nil(s); s = rt::next(s))
    {
      r.push_back(to_std(rt::first(s)));
    }
    return r;
  }

  /* The search path of a Lake project's build: its own `.lake/build/lib/lean`, and its
   * packages' (`.lake/packages/<p>/.lake/build/lib/lean`). */
  /* Runs `f`, turning a C++ exception into a jank `ex-info`: jank throws and catches
   * `object_ref`s. */
  template <typename F>
  auto guarded(F &&f) -> decltype(f())
  {
    try
    {
      return f();
    }
    catch(std::exception const &e)
    {
      throw static_cast<object_ref>(
        rt::ex_info(istr(e.what()), rt::obj::persistent_array_map::empty()));
    }
  }

  inline object_ref lake_search_path(object_ref const project)
  {
    namespace fs = std::filesystem;
    fs::path const root{ to_std(project) };
    object_ref r{ rt::obj::persistent_vector::empty() };
    auto const add{ [&](fs::path const &p) {
      if(fs::is_directory(p))
      {
        r = rt::conj(r, str(p.string()));
      }
    } };
    add(root / ".lake" / "build" / "lib" / "lean");
    if(fs::is_directory(root / ".lake" / "packages"))
    {
      for(auto const &e : fs::directory_iterator{ root / ".lake" / "packages" })
      {
        add(e.path() / ".lake" / "build" / "lib" / "lean");
      }
    }
    return r;
  }

  /* The shared libraries of a built Lake project: its packages'
   * (`.lake/packages/<p>/.lake/build/lib/lib*.dylib`) and its own (`.lake/build/lib/lib*.dylib`). */
  inline object_ref lake_libraries(object_ref const project)
  {
    namespace fs = std::filesystem;
    fs::path const root{ to_std(project) };
    object_ref r{ rt::obj::persistent_vector::empty() };
    auto const add_dir{ [&](fs::path const &dir) {
      if(!fs::is_directory(dir))
      {
        return;
      }
      for(auto const &e : fs::directory_iterator{ dir })
      {
        auto const ext{ e.path().extension().string() };
        if(e.is_regular_file() && (ext == ".dylib" || ext == ".so")
           && e.path().filename().string().rfind("lib", 0) == 0)
        {
          r = rt::conj(r, str(e.path().string()));
        }
      }
    } };
    if(fs::is_directory(root / ".lake" / "packages"))
    {
      for(auto const &e : fs::directory_iterator{ root / ".lake" / "packages" })
      {
        add_dir(e.path() / ".lake" / "build" / "lib");
      }
    }
    add_dir(root / ".lake" / "build" / "lib");
    return r;
  }

  /* Loads shared libraries (`dlopen`, with their symbols global). Lean's libraries have no
   * rpath, so each loads only after the ones it depends on: the order is found by retrying. */
  inline object_ref load_libraries(object_ref const paths)
  {
    return guarded([&] {
      auto pending{ strings(paths) };
      std::string last_error;
      for(bool progress{ true }; progress && !pending.empty();)
      {
        progress = false;
        std::vector<std::string> next;
        for(auto const &p : pending)
        {
          if(dlopen(p.c_str(), RTLD_NOW | RTLD_GLOBAL))
          {
            progress = true;
          }
          else
          {
            auto const e{ dlerror() };
            last_error = e ? e : p;
            next.push_back(p);
          }
        }
        pending = std::move(next);
      }
      if(!pending.empty())
      {
        throw error{ "lean-sys: can't load " + pending.front() + ": " + last_error };
      }
      return object_ref{ rt::jank_nil };
    });
  }

  inline object_ref new_session(object_ref const search_path, object_ref const imports)
  {
    return guarded([&] {
      std::lock_guard<std::recursive_mutex> const lock{ lean_lock() };
      auto const s{ new session{ strings(search_path), strings(imports) } };
      auto const b{ rt::make_box<rt::obj::opaque_box>(jtl::ptr<void>{ s }, istr(session_box)) };
      /* When jank no longer holds the session, it's deleted on Lean's thread. */
      GC_register_finalizer_no_order(
        b.operator->(),
        [](void *, void *se) { release_later([se] { delete static_cast<session *>(se); }); },
        s,
        nullptr,
        nullptr);
      return object_ref{ b };
    });
  }

  /* Compiles constant `name` to native code (`session::compile`). */
  inline object_ref compile(object_ref const s, object_ref const name, object_ref const cache_dir)
  {
    return guarded([&] {
      std::lock_guard<std::recursive_mutex> const lock{ lean_lock() };
      ensure_thread();
      auto dir{ rt::is_nil(cache_dir) ? std::string{} : to_std(cache_dir) };
      if(dir.empty())
      {
        auto const tmp{ std::getenv("TMPDIR") };
        dir = std::string{ tmp ? tmp : "/tmp" } + "/lean-sys";
      }
      unbox_session(s).compile(to_std(name), dir);
      return object_ref{ rt::jank_nil };
    });
  }

  /* How many Lean objects (and sessions) jank has released so far. */
  inline int64_t released_count()
  {
    return static_cast<int64_t>(lean_sys::released_count().load());
  }

  /* Runs jank's GC, then releases what it found unreachable (for tests). */
  inline object_ref collect()
  {
    GC_gcollect();
    GC_invoke_finalizers();
    lean_thread::get().run([] {});
    return rt::jank_nil;
  }

  /* The messages of elaborating `text`, as maps. */
  inline object_ref elab(object_ref const s, object_ref const text, object_ref const file)
  {
    return guarded([&] {
      std::lock_guard<std::recursive_mutex> const lock{ lean_lock() };
      auto const msgs{ unbox_session(s).elab(to_std(text), to_std(file)) };
      static char const *const severities[]{ "info", "warning", "error" };
      object_ref r{ rt::obj::persistent_vector::empty() };
      for(auto const &m : msgs)
      {
        object_ref e{ rt::obj::persistent_array_map::empty() };
        e = rt::assoc(e, kw("severity"), kw(severities[m.severity < 3 ? m.severity : 2]));
        e = rt::assoc(e, kw("line"), rt::make_box(static_cast<int64_t>(m.line)));
        e = rt::assoc(e, kw("column"), rt::make_box(static_cast<int64_t>(m.column)));
        e = rt::assoc(e, kw("text"), str(m.text));
        r = rt::conj(r, e);
      }
      return r;
    });
  }

  /* How many arguments a call of `name` takes: its parameters that aren't erased (types, proofs). */
  inline int64_t arity(object_ref const s, object_ref const name)
  {
    return guarded([&] {
      std::lock_guard<std::recursive_mutex> const lock{ lean_lock() };
      auto const ci{ unbox_session(s).info(to_std(name)) };
      int64_t n{};
      for(auto const p : ci->params)
      {
        if(ci->shapes[p].k != kind::erased)
        {
          ++n;
        }
      }
      return n;
    });
  }

  /* Calls constant `name` (its value, when it has no parameters) with `args`, jank values built
   * into Lean values by the types of its parameters that aren't erased, and reads the result.
   * With fewer arguments than its parameters, the result is the partially applied function, as
   * an opaque Lean value. */
  inline object_ref call(object_ref const s, object_ref const name, object_ref const args)
  {
    return guarded([&] {
      std::lock_guard<std::recursive_mutex> const lock{ lean_lock() };
      ensure_thread();
      auto &se{ unbox_session(s) };
      auto const ci{ se.info(to_std(name)) };
      source src;
      writer<source> w{ se, ci->shapes, src };
      std::vector<lean_object *> lean_args;
      auto given{ rt::seq(args) };
      bool partial{ false };
      try
      {
        for(auto const p : ci->params)
        {
          if(ci->shapes[p].k == kind::erased)
          {
            lean_args.push_back(lean_box(0));
            continue;
          }
          if(rt::is_nil(given))
          {
            partial = true;
            break;
          }
          lean_args.push_back(w.write(p, rt::first(given)));
          given = rt::next(given);
        }
        if(!rt::is_nil(given))
        {
          throw error{ "lean-sys: too many arguments for " + ci->name };
        }
      }
      catch(...)
      {
        for(auto const a : lean_args)
        {
          lean_dec(a);
        }
        throw;
      }
      if(partial)
      {
        lean_object *f{};
        if(lean_args.empty())
        {
          lean_inc(ci->value);
          f = ci->value;
        }
        else
        {
          f = se.apply(ci->value, std::move(lean_args));
        }
        auto const v{ box_value(f) };
        lean_dec(f);
        return v;
      }
      auto const r{ se.call(*ci, std::move(lean_args)) };
      sink k;
      reader<sink> rd{ ci->shapes, k };
      auto const v{ rd.read(ci->result, r) };
      lean_dec(r);
      return v;
    });
  }
}

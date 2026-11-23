#pragma once

// inkling's jank layer: the functions src/inkling/core.jank calls. Models and
// sessions are held in opaque boxes; model_of and session_of give the C++
// objects (inkling::model and inkling::session, see inkling.hpp) for direct
// interop. Everything else converts to jank data.

#include <inkling/inkling.hpp>

#include <algorithm>
#include <bit>
#include <cmath>
#include <map>
#include <numeric>
#include <thread>

#include <jank/runtime/context.hpp>
#include <jank/runtime/core.hpp>
#include <jank/runtime/core/make_box.hpp>
#include <jank/runtime/core/seq.hpp>
#include <jank/runtime/core/truthy.hpp>
#include <jank/runtime/obj/keyword.hpp>
#include <jank/runtime/obj/opaque_box.hpp>
#include <jank/runtime/obj/persistent_array_map.hpp>
#include <jank/runtime/obj/persistent_string.hpp>
#include <jank/runtime/obj/persistent_vector.hpp>

namespace inkling::jank_layer
{
  namespace rt = ::jank::runtime;
  using rt::object_ref;

  inline constexpr char const *model_box{ "inkling::model" };
  inline constexpr char const *session_box{ "inkling::session" };

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

  inline object_ref num(int64_t const i)
  {
    return rt::make_box(i);
  }

  inline object_ref real(double const d)
  {
    return rt::make_box(d);
  }

  inline object_ref boolean(bool const b)
  {
    return b ? object_ref{ rt::jank_true } : object_ref{ rt::jank_false };
  }

  inline int64_t to_int(object_ref const o)
  {
    return rt::to_int(o);
  }

  inline double to_real(object_ref const o)
  {
    return rt::to_real(o);
  }

  template <typename F>
  auto guarded(F &&f) -> decltype(f())
  {
    try
    {
      return f();
    }
    catch(std::exception const &e)
    {
      throw static_cast<object_ref>(rt::ex_info(istr(e.what()), rt::obj::persistent_array_map::empty()));
    }
  }

  struct map_builder
  {
    object_ref m{ rt::obj::persistent_array_map::empty() };

    map_builder &operator()(std::string_view const k, object_ref const v)
    {
      m = rt::assoc(m, kw(k), v);
      return *this;
    }
  };

  template <typename T, typename F>
  object_ref vec_of(T const &items, F &&f)
  {
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(auto const &x : items)
    {
      v = rt::conj(v, f(x));
    }
    return v;
  }

  inline object_ref shape_of(std::vector<int64_t> const &shape)
  {
    return vec_of(shape, [](int64_t d) { return num(d); });
  }

  template <typename T>
  T *unbox(object_ref const o, char const *canonical)
  {
    if(o.get_type() != rt::object_type::opaque_box)
    {
      throw static_cast<object_ref>(rt::ex_info(istr(std::string{ "inkling: expected a " } + canonical),
                                                rt::obj::persistent_array_map::empty()));
    }
    auto const b{ rt::expect_object<rt::obj::opaque_box>(o) };
    if(std::string_view{ b->canonical_type.data(), b->canonical_type.size() } != canonical)
    {
      throw static_cast<object_ref>(rt::ex_info(istr(std::string{ "inkling: expected a " } + canonical),
                                                rt::obj::persistent_array_map::empty()));
    }
    auto const p{ static_cast<T *>(b->data.data) };
    if(!p)
    {
      throw static_cast<object_ref>(rt::ex_info(istr(std::string{ "inkling: the " } + canonical + " was freed"),
                                                rt::obj::persistent_array_map::empty()));
    }
    return p;
  }

  inline model *model_of(object_ref const o)
  {
    return unbox<model>(o, model_box);
  }

  inline session *session_of(object_ref const o)
  {
    return unbox<session>(o, session_box);
  }

  // Model.

  inline object_ref open_model(object_ref const path)
  {
    return guarded([&] {
      auto const m{ inkling::open(to_std(path)) };
      return object_ref{ rt::make_box<rt::obj::opaque_box>(jtl::ptr<void>{ m }, istr(model_box)) };
    });
  }

  inline object_ref close_model(object_ref const o)
  {
    auto const b{ rt::expect_object<rt::obj::opaque_box>(o) };
    inkling::close(static_cast<model *>(b->data.data));
    b->data = jtl::ptr<void>{ nullptr };
    return rt::jank_nil;
  }

  inline object_ref convert(object_ref const source, object_ref const out)
  {
    return guarded([&] {
      inkling::convert(to_std(source), to_std(out));
      return object_ref{ rt::jank_nil };
    });
  }

  inline object_ref config(object_ref const o)
  {
    auto const &c{ model_of(o)->cfg };
    map_builder b;
    b("layers", num(c.layers))("hidden", num(c.hidden))("vocab", num(c.vocab))("unpadded-vocab", num(c.unpadded_vocab))(
      "context",
      num(c.context))("head-dim", num(c.head_dim))("heads", num(c.heads))("kv-heads", num(c.kv_heads))(
      "local-head-dim",
      num(c.local_head_dim))("local-heads", num(c.local_heads))("local-kv-heads", num(c.local_kv_heads))(
      "rel-dim",
      num(c.rel_dim))("rel-extent", num(c.rel_extent))("window", num(c.window))("conv-taps", num(c.conv_taps))(
      "experts",
      num(c.experts))("top-k", num(c.top_k))("expert-width", num(c.expert_width))("residual-block",
                                                                                   num(c.residual_block))(
      "loop",
      c.loop ? map_builder{}("start", num(c.loop_start))("end", num(c.loop_end))("passes", num(c.loop_passes))(
                 "gate-rank",
                 num(c.gate_rank))
                 .m
             : object_ref{ rt::jank_nil })("norm-eps", real(c.norm_eps))("qk-clip", real(c.qk_clip))(
      "rel-clip",
      real(c.rel_clip))("log-floor", real(c.log_floor))("log-alpha", real(c.log_alpha))("route-scale",
                                                                                        real(c.route_scale))(
      "gate-cap",
      real(c.gate_cap))("up-cap", real(c.up_cap))("logit-cap", real(c.logit_cap))(
      "local-layers",
      vec_of(c.local_layers, [](int32_t l) { return num(l); }))("eos-token", num(c.eos_token));
    return b.m;
  }

  inline object_ref plan(object_ref const o)
  {
    auto const m{ model_of(o) };
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(size_t i{}; i < m->plan.size(); ++i)
    {
      auto const &p{ m->plan[i] };
      v = rt::conj(v,
                   map_builder{}("visit", num(static_cast<int64_t>(i)))("layer", num(p.layer))("pass", num(p.pass))(
                     "local",
                     boolean(p.local))
                     .m);
    }
    return v;
  }

  inline object_ref tensor_map(tensor const &t)
  {
    return map_builder{}("name", str(t.name))("dtype", kw(dtype_name(t.type)))("shape", shape_of(t.shape))(
             "bytes",
             num(static_cast<int64_t>(t.nbytes)))
      .m;
  }

  inline object_ref tensors(object_ref const o)
  {
    return vec_of(model_of(o)->tensors, [](tensor const &t) { return tensor_map(t); });
  }

  inline object_ref tensor_info(object_ref const o, object_ref const name)
  {
    auto const t{ model_of(o)->find(to_std(name)) };
    return t ? tensor_map(*t) : object_ref{ rt::jank_nil };
  }

  // Elements [start, start + count) of a tensor, row-major, as doubles.
  inline object_ref tensor_values(object_ref const o, object_ref const name, object_ref const start, object_ref const count)
  {
    return guarded([&] {
      auto const &t{ model_of(o)->at(to_std(name)) };
      auto const s{ to_int(start) };
      auto const n{ std::min(to_int(count), t.numel() - s) };
      object_ref v{ rt::obj::persistent_vector::empty() };
      for(int64_t i{}; i < n; ++i)
      {
        v = rt::conj(v, real(t.get(s + i)));
      }
      return v;
    });
  }

  inline object_ref tensor_name(tensor const *t)
  {
    return t ? str(t->name) : object_ref{ rt::jank_nil };
  }

  // A layer's weights, by tensor name.
  inline object_ref layer(object_ref const o, object_ref const index)
  {
    return guarded([&] {
      auto const &w{ model_of(o)->layers.at(static_cast<size_t>(to_int(index))) };
      auto const &a{ w.attn };
      auto const conv{ [](short_conv const &c) {
        return map_builder{}("weight", tensor_name(c.weight))("static", tensor_name(c.static_w))(
                 "projection",
                 tensor_name(c.weight_proj))("heads", num(c.heads))("channels", num(c.channels))
          .m;
      } };
      auto const bank{ [](expert_bank const &b) {
        return map_builder{}("format", kw(b.nvfp4 ? "nvfp4" : "mxfp8"))("weight", tensor_name(b.weight))(
                 "scales",
                 tensor_name(b.scales))("amax", tensor_name(b.amax))("rows", num(b.rows))("cols", num(b.cols))
          .m;
      } };
      return map_builder{}("index", num(w.index))("local", boolean(w.local))(
               "attention",
               map_builder{}("q", tensor_name(a.wq))("k", tensor_name(a.wk))("v", tensor_name(a.wv))(
                 "o",
                 tensor_name(a.wo))("relative", tensor_name(a.wr))("gate", tensor_name(a.gate))(
                 "sink",
                 tensor_name(a.sink))("position-projection", tensor_name(a.rel_proj))("q-scale",
                                                                                       tensor_name(a.q_scale))(
                 "relative-scale",
                 tensor_name(a.r_scale))("k-conv", conv(a.k_conv))("v-conv", conv(a.v_conv))("head-dim",
                                                                                              num(a.head_dim))(
                 "heads",
                 num(a.heads))("kv-heads", num(a.kv_heads))("window", num(a.window))("relative-extent",
                                                                                     num(a.rel_extent))
                 .m)("attention-norms", vec_of(w.attn_norm, [](tensor const *t) { return tensor_name(t); }))(
               "attention-query",
               tensor_name(w.attn_query))("attention-conv", conv(w.attn_conv))("router", tensor_name(w.router))(
               "router-bias",
               tensor_name(w.router_bias))("gate-up", bank(w.gate_up))("down", bank(w.down))(
               "mlp-norm",
               tensor_name(w.mlp_norm))("mlp-query", tensor_name(w.mlp_query))("mlp-conv", conv(w.mlp_conv))(
               "controllers",
               vec_of(w.messages,
                      [](message_gate const &g) {
                        return map_builder{}("down", tensor_name(g.down))("gain", tensor_name(g.gain))(
                                 "forget",
                                 tensor_name(g.forget))
                          .m;
                      }))
        .m;
    });
  }

  inline object_ref set_option(object_ref const o, object_ref const key, object_ref const value)
  {
    return guarded([&] {
      auto const m{ model_of(o) };
      auto const k{ to_std(key) };
      if(k == ":threads")
      {
        set_threads(*m, static_cast<int32_t>(to_int(value)));
      }
      else if(k == ":quantize-expert-inputs")
      {
        m->quantize_expert_inputs = rt::truthy(value);
      }
      else if(k == ":gpu")
      {
        m->use_gpu = rt::truthy(value);
      }
      else if(k == ":split-attention")
      {
        m->split_attention = rt::truthy(value);
      }
      else
      {
        throw std::runtime_error{ "inkling: unknown option " + k };
      }
      return object_ref{ rt::jank_nil };
    });
  }

  inline object_ref options(object_ref const o)
  {
    auto const m{ model_of(o) };
    return map_builder{}("threads", num(m->threads))("quantize-expert-inputs", boolean(m->quantize_expert_inputs))(
             "split-attention", boolean(m->split_attention))(
             "gpu",
             boolean(m->use_gpu && m->gpu))("gpu-available", boolean(m->gpu != nullptr))
      .m;
  }

  // Tokenizer.

  inline std::vector<int32_t> ids_of(object_ref const coll)
  {
    std::vector<int32_t> ids;
    for(auto s{ rt::seq(coll) }; s != rt::jank_nil; s = rt::next(s))
    {
      ids.push_back(static_cast<int32_t>(to_int(rt::first(s))));
    }
    return ids;
  }

  inline object_ref ids_vec(int32_t const *ids, size_t const n)
  {
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(size_t i{}; i < n; ++i)
    {
      v = rt::conj(v, num(ids[i]));
    }
    return v;
  }

  inline object_ref tokenize(object_ref const o, object_ref const text, object_ref const special)
  {
    auto const ids{ inkling::tokenize(*model_of(o), to_std(text), rt::truthy(special)) };
    return ids_vec(ids.data(), ids.size());
  }

  inline object_ref detokenize(object_ref const o, object_ref const ids)
  {
    return str(inkling::detokenize(*model_of(o), ids_of(ids)));
  }

  inline object_ref token_id(object_ref const o, object_ref const piece)
  {
    return num(inkling::token_id(*model_of(o), to_std(piece)));
  }

  // Sessions.

  inline object_ref new_session(object_ref const o, object_ref const context)
  {
    return guarded([&] {
      auto const s{ inkling::new_session(*model_of(o), static_cast<int32_t>(to_int(context))) };
      return object_ref{ rt::make_box<rt::obj::opaque_box>(jtl::ptr<void>{ s }, istr(session_box)) };
    });
  }

  inline object_ref free_session(object_ref const o)
  {
    auto const b{ rt::expect_object<rt::obj::opaque_box>(o) };
    inkling::free_session(static_cast<session *>(b->data.data));
    b->data = jtl::ptr<void>{ nullptr };
    return rt::jank_nil;
  }

  inline object_ref eval(object_ref const o, object_ref const ids)
  {
    return guarded([&] {
      inkling::eval(*session_of(o), ids_of(ids));
      return object_ref{ rt::jank_nil };
    });
  }

  inline object_ref eval_batch(object_ref const sessions, object_ref const ids)
  {
    return guarded([&] {
      std::vector<session *> all;
      for(auto s{ rt::seq(sessions) }; s != rt::jank_nil; s = rt::next(s))
      {
        all.push_back(session_of(rt::first(s)));
      }
      inkling::eval_batch(all, ids_of(ids));
      return object_ref{ rt::jank_nil };
    });
  }

  inline object_ref tokenize_for(object_ref const o, object_ref const text)
  {
    auto const ids{ inkling::tokenize(*session_of(o)->model, to_std(text), true) };
    return ids_vec(ids.data(), ids.size());
  }

  // Evaluates a text, tokenized with special tokens.
  inline object_ref eval_text(object_ref const o, object_ref const text)
  {
    return guarded([&] {
      auto const s{ session_of(o) };
      inkling::eval(*s, inkling::tokenize(*s->model, to_std(text), true));
      return object_ref{ rt::jank_nil };
    });
  }

  inline object_ref reset(object_ref const o)
  {
    inkling::reset(*session_of(o));
    return rt::jank_nil;
  }

  inline object_ref copy_session(object_ref const dst, object_ref const src)
  {
    return guarded([&] {
      inkling::copy(*session_of(dst), *session_of(src));
      return object_ref{ rt::jank_nil };
    });
  }

  inline object_ref position(object_ref const o)
  {
    return num(session_of(o)->pos);
  }

  /* A number for the calling thread: the same for two calls on one thread. */
  inline object_ref thread_token()
  {
    return num(static_cast<int64_t>(std::hash<std::thread::id>{}(std::this_thread::get_id()) & 0x3fffffff));
  }

  inline object_ref tokens(object_ref const o)
  {
    auto const s{ session_of(o) };
    return ids_vec(s->tokens.data(), s->tokens.size());
  }

  inline object_ref logits(object_ref const o)
  {
    auto const s{ session_of(o) };
    return vec_of(s->logits, [](float l) { return real(l); });
  }

  // The n most likely next tokens: id, piece, logit and log-probability.
  // The log-probability of token `id` next, from the session's logits (log-softmax).
  inline object_ref logprob(object_ref const o, object_ref const id)
  {
    auto const s{ session_of(o) };
    auto const &lg{ s->logits };
    auto const i{ to_int(id) };
    if(lg.empty() || i < 0 || i >= static_cast<int64_t>(lg.size()))
    {
      throw std::runtime_error{ "inkling: no logits for that id" };
    }
    double best{ lg[0] };
    for(auto const l : lg)
    {
      best = std::max(best, static_cast<double>(l));
    }
    double sum{};
    for(auto const l : lg)
    {
      sum += std::exp(l - best);
    }
    return real(lg[static_cast<size_t>(i)] - (best + std::log(sum)));
  }

  inline object_ref top(object_ref const o, object_ref const count)
  {
    auto const s{ session_of(o) };
    auto const &lg{ s->logits };
    if(lg.empty())
    {
      return rt::obj::persistent_vector::empty();
    }
    auto const n{ static_cast<size_t>(std::min<int64_t>(to_int(count), static_cast<int64_t>(lg.size()))) };
    std::vector<int32_t> idx(lg.size());
    std::iota(idx.begin(), idx.end(), 0);
    std::partial_sort(idx.begin(), idx.begin() + static_cast<ptrdiff_t>(n), idx.end(), [&](int32_t a, int32_t b) {
      return lg[static_cast<size_t>(a)] > lg[static_cast<size_t>(b)];
    });
    double const best{ lg[static_cast<size_t>(idx[0])] };
    double sum{};
    for(auto const l : lg)
    {
      sum += std::exp(l - best);
    }
    double const lse{ best + std::log(sum) };
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(size_t i{}; i < n; ++i)
    {
      auto const id{ idx[i] };
      v = rt::conj(v,
                   map_builder{}("id", num(id))("piece", str(inkling::detokenize(*s->model, &id, 1)))(
                     "logit",
                     real(lg[static_cast<size_t>(id)]))("logprob", real(lg[static_cast<size_t>(id)] - lse))(
                     "prob",
                     real(std::exp(lg[static_cast<size_t>(id)] - lse)))
                     .m);
    }
    return v;
  }

  inline object_ref sample(object_ref const o, object_ref const temperature, object_ref const top_p,
                           object_ref const top_k, object_ref const seed)
  {
    auto const s{ session_of(o) };
    uint64_t rng{ static_cast<uint64_t>(to_int(seed)) | 1u };
    return num(inkling::sample(s->logits.data(),
                               static_cast<int32_t>(s->logits.size()),
                               static_cast<float>(to_real(temperature)),
                               static_cast<float>(to_real(top_p)),
                               static_cast<int32_t>(to_int(top_k)),
                               rng));
  }

  // Drafting: up to `limit` tokens sampled and evaluated, drafted from the
  // context and checked in one forward (inkling::speculate): a vector of ids.
  inline object_ref speculate(object_ref const o, object_ref const temperature, object_ref const top_p,
                              object_ref const top_k, object_ref const seed, object_ref const limit,
                              object_ref const least, object_ref const most)
  {
    auto const s{ session_of(o) };
    auto const ids{ inkling::speculate(*s, static_cast<float>(to_real(temperature)), static_cast<float>(to_real(top_p)),
                                       static_cast<int32_t>(to_int(top_k)), static_cast<uint64_t>(to_int(seed)),
                                       static_cast<int32_t>(to_int(limit)), static_cast<int32_t>(to_int(least)),
                                       static_cast<int32_t>(to_int(most))) };
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(auto const id : ids)
    {
      v = rt::conj(v, num(id));
    }
    return v;
  }

  // The session's draft model (inkling::use_draft_model).
  inline object_ref draft_model(object_ref const o, object_ref const depth)
  {
    return guarded([&] {
      inkling::use_draft_model(*session_of(o), static_cast<int32_t>(to_int(depth)));
      return rt::jank_nil;
    });
  }

  // The session rolled back to its first `pos` tokens, within its last draft's check.
  inline object_ref truncate(object_ref const o, object_ref const pos)
  {
    inkling::truncate(*session_of(o), static_cast<int32_t>(to_int(pos)));
    return rt::jank_nil;
  }

  // Tracing.

  inline object_ref set_trace(object_ref const o, object_ref const on)
  {
    session_of(o)->trace = rt::truthy(on);
    return rt::jank_nil;
  }

  inline object_ref trace_names(object_ref const o)
  {
    return vec_of(session_of(o)->traces, [](trace_entry const &t) {
      return map_builder{}("name", str(t.name))("shape", shape_of(t.shape)).m;
    });
  }

  inline object_ref trace(object_ref const o, object_ref const name)
  {
    auto const t{ session_of(o)->find_trace(to_std(name)) };
    if(!t)
    {
      return rt::jank_nil;
    }
    return map_builder{}("name", str(t->name))("shape", shape_of(t->shape))(
             "values",
             vec_of(t->values, [](float x) { return real(x); }))
      .m;
  }

  // Whether a value is a model (one not closed).
  inline object_ref is_model(object_ref const o)
  {
    if(o.get_type() != rt::object_type::opaque_box)
    {
      return rt::jank_false;
    }
    auto const b{ rt::expect_object<rt::obj::opaque_box>(o) };
    return boolean(std::string_view{ b->canonical_type.data(), b->canonical_type.size() } == model_box
                   && b->data.data != nullptr);
  }

  inline object_ref model_path(object_ref const o)
  {
    return str(model_of(o)->path);
  }

  // Whether a value is a session (one not freed).
  inline object_ref is_session(object_ref const o)
  {
    if(o.get_type() != rt::object_type::opaque_box)
    {
      return rt::jank_false;
    }
    auto const b{ rt::expect_object<rt::obj::opaque_box>(o) };
    return boolean(std::string_view{ b->canonical_type.data(), b->canonical_type.size() } == session_box
                   && b->data.data != nullptr);
  }

  inline object_ref session_info(object_ref const o)
  {
    auto const s{ session_of(o) };
    map_builder b{};
    b("position", num(s->pos))("context", num(s->context))("logits", boolean(!s->logits.empty()))(
      "gpu",
      boolean(s->gpu && s->model->use_gpu && !s->trace && !s->model->ablated()));
    if(s->draft_model)
    {
      // The draft model's checks: [depth checks drafts-kept ms-a-check] for each
      // depth used, and the acceptance at each place.
      auto const st{ inkling::stats_of(*s->draft_model) };
      object_ref depths{ rt::obj::persistent_vector::empty() };
      object_ref accept{ rt::obj::persistent_vector::empty() };
      for(int i{}; i < 8; ++i)
      {
        if(st.at_depth[i] > 0)
        {
          object_ref row{ rt::obj::persistent_vector::empty() };
          row = rt::conj(row, num(i));
          row = rt::conj(row, num(st.at_depth[i]));
          row = rt::conj(row, num(st.kept_at[i]));
          row = rt::conj(row, real(st.ms[i]));
          row = rt::conj(row, real(st.total_ms[i] / st.at_depth[i]));
          row = rt::conj(row, real(st.draft_ms[i] / st.at_depth[i]));
          depths = rt::conj(depths, row);
        }
        accept = rt::conj(accept, real(st.accept[i]));
      }
      b("draft", map_builder{}("checks", num(st.checks))("depths", depths)("accept", accept).m);
    }
    return b.m;
  }

  // The text of the session's last `count` tokens.
  inline object_ref tail(object_ref const o, object_ref const count)
  {
    auto const s{ session_of(o) };
    auto const n{ std::min<size_t>(static_cast<size_t>(std::max<int64_t>(0, to_int(count))), s->tokens.size()) };
    return str(inkling::detokenize(*s->model, s->tokens.data() + (s->tokens.size() - n), n));
  }

  // Each id with its piece of text.
  inline object_ref pieces(object_ref const o, object_ref const ids)
  {
    auto const m{ model_of(o) };
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(auto const id : ids_of(ids))
    {
      v = rt::conj(v, map_builder{}("id", num(id))("piece", str(inkling::detokenize(*m, &id, 1))).m);
    }
    return v;
  }

  // The routes of one token of the last capture, as a matrix [visits,
  // experts]: each chosen expert's weight, 0 elsewhere.
  inline object_ref routing(object_ref const o, object_ref const token)
  {
    return guarded([&] {
      auto const s{ session_of(o) };
      auto const &cap{ s->captured };
      auto const &m{ *s->model };
      if(cap.visits.empty())
      {
        throw std::runtime_error{ "inkling: nothing captured: (capture! s true), then eval!" };
      }
      auto const tok{ to_int(token) < 0 ? cap.tokens - 1 : to_int(token) };
      auto const k{ static_cast<size_t>(m.cfg.top_k) };
      auto const ne{ static_cast<size_t>(m.cfg.experts) };
      object_ref values{ rt::obj::persistent_vector::empty() };
      object_ref labels{ rt::obj::persistent_vector::empty() };
      for(size_t vi{}; vi < cap.visits.size(); ++vi)
      {
        auto const &v{ cap.visits[vi] };
        std::vector<float> row(ne, 0.0f);
        for(size_t j{}; j < k; ++j)
        {
          auto const at{ static_cast<size_t>(tok) * k + j };
          row.at(static_cast<size_t>(v.experts.at(at))) = v.expert_weights.at(at);
        }
        for(auto const x : row)
        {
          values = rt::conj(values, real(x));
        }
        auto const &visit{ m.plan[vi] };
        labels = rt::conj(labels,
                          str("visit " + std::to_string(vi) + ": layer " + std::to_string(visit.layer)
                              + (visit.pass ? " pass " + std::to_string(visit.pass) : "")));
      }
      return map_builder{}("name", str("expert weights, token " + std::to_string(tok)))(
               "shape",
               shape_of({ static_cast<int64_t>(cap.visits.size()), static_cast<int64_t>(ne) }))("values", values)(
               "row-labels",
               labels)
        .m;
    });
  }

  // Verification, captures and experiments.

  inline object_ref check_gpu(object_ref const o, object_ref const ids)
  {
    return guarded([&] {
      auto const report{ inkling::check_gpu(*session_of(o), ids_of(ids)) };
      object_ref rows{ rt::obj::persistent_vector::empty() };
      for(auto const &r : report.rows)
      {
        rows = rt::conj(rows,
                        map_builder{}("visit", num(r.visit))("field", kw(r.field))("count", num(r.count))(
                          "different",
                          num(r.different))("beyond", num(r.beyond))("worst", real(r.worst))
                          .m);
      }
      return map_builder{}("ok", boolean(report.ok()))("compared", num(report.compared))("beyond", num(report.beyond))(
               "rows",
               rows)
        .m;
    });
  }

  inline object_ref set_capture(object_ref const o, object_ref const on)
  {
    session_of(o)->capturing = rt::truthy(on);
    return rt::jank_nil;
  }

  inline object_ref set_record(object_ref const o, object_ref const on)
  {
    session_of(o)->record = rt::truthy(on);
    return rt::jank_nil;
  }

  inline object_ref events(object_ref const o)
  {
    static char const *const kinds[]{ "take", "push", "restart", "release", "read", "write" };
    return vec_of(session_of(o)->events, [](stream_event const &e) {
      return map_builder{}("kind", kw(kinds[static_cast<int>(e.k)]))("visit", num(e.visit))("slot", num(e.slot)).m;
    });
  }

  // A field of the last capture, as [rows, values]: the rows of a token
  // (token >= 0) or of every token. visit -1 has "embed", the plan's size
  // "hidden" and "logits".
  inline object_ref captured(object_ref const o, object_ref const visit, object_ref const field, object_ref const token)
  {
    return guarded([&] {
      auto const s{ session_of(o) };
      auto const &cap{ s->captured };
      auto const vi{ to_int(visit) };
      auto const name{ to_std(field) };
      auto const tok{ to_int(token) };
      std::vector<float> owned;
      std::vector<float> const *values{};
      bool per_token{ true };
      if(vi < 0 && name == "embed")
      {
        values = &cap.embed;
      }
      else if(vi >= static_cast<int64_t>(cap.visits.size()) && (name == "hidden" || name == "logits"))
      {
        values = name == "hidden" ? &cap.hidden : &cap.logits;
        per_token = false;
      }
      else
      {
        auto const &v{ cap.visits.at(static_cast<size_t>(vi)) };
        static char const *const parts[]{ "q", "k", "v", "ffn" };
        static char const *const convs[]{ "conv.k", "conv.v", "conv.attn", "conv.ffn" };
        std::map<std::string, std::vector<float> const *> const fields{
          { "q_proj", &v.q_proj },
          { "r_proj", &v.r_proj },
          { "k_proj", &v.k_proj },
          { "v_proj", &v.v_proj },
          { "k_taps", &v.k_taps },
          { "v_taps", &v.v_taps },
          { "k_conv", &v.k_conv },
          { "v_conv", &v.v_conv },
          { "q", &v.q },
          { "r", &v.r },
          { "sink", &v.sink },
          { "gate", &v.gate },
          { "attended", &v.attended },
          { "attn_proj", &v.attn_proj },
          { "after_attention", &v.after_attention },
          { "ffn_input", &v.ffn_input },
          { "router", &v.router },
          { "expert_weights", &v.expert_weights },
          { "expert_input", &v.expert_input },
          { "expert_input_max", &v.expert_input_max },
          { "activations_raw", &v.activations_raw },
          { "activations", &v.activations },
          { "activation_max", &v.activation_max },
          { "ffn", &v.ffn },
          { "ffn_routes", &v.ffn_routes },
          { "partial", &v.partial }
        };
        if(auto const it{ fields.find(name) }; it != fields.end())
        {
          values = it->second;
        }
        for(size_t i{}; i < 4 && !values; ++i)
        {
          if(name == std::string{ "pair." } + parts[i])
          {
            values = &v.pairs[i];
          }
          else if(name == std::string{ "compressed." } + parts[i])
          {
            values = &v.compressed[i];
          }
          else if(i < 3 && name == std::string{ "input." } + parts[i])
          {
            values = &v.inputs[i];
          }
          else if(name == convs[i])
          {
            values = &v.conv[i];
            per_token = false;
          }
        }
        if(!values && (name == "k" || name == "v"))
        {
          for(auto const h : name == "k" ? v.k : v.v)
          {
            owned.push_back(static_cast<float>(std::bit_cast<_Float16>(h)));
          }
          values = &owned;
        }
        if(!values && name == "experts")
        {
          owned.assign(v.experts.begin(), v.experts.end());
          values = &owned;
        }
      }
      if(!values)
      {
        throw std::runtime_error{ "inkling: no captured field " + name + " in visit " + std::to_string(vi) };
      }
      size_t begin{}, end{ values->size() };
      if(per_token && tok >= 0 && cap.tokens > 0)
      {
        auto const row{ values->size() / static_cast<size_t>(cap.tokens) };
        begin = static_cast<size_t>(tok) * row;
        end = std::min(values->size(), begin + row);
      }
      object_ref out{ rt::obj::persistent_vector::empty() };
      for(size_t i{ begin }; i < end; ++i)
      {
        out = rt::conj(out, real((*values)[i]));
      }
      return out;
    });
  }

  inline object_ref capture_info(object_ref const o)
  {
    auto const &cap{ session_of(o)->captured };
    return map_builder{}("tokens", num(cap.tokens))("pos", num(cap.pos))(
             "visits",
             num(static_cast<int64_t>(cap.visits.size())))
      .m;
  }

  inline object_ref set_ablation(object_ref const o, object_ref const visit, object_ref const bits)
  {
    return guarded([&] {
      model_of(o)->ablate.at(static_cast<size_t>(to_int(visit))) = static_cast<uint8_t>(to_int(bits));
      return object_ref{ rt::jank_nil };
    });
  }

  inline object_ref ablations(object_ref const o)
  {
    return vec_of(model_of(o)->ablate, [](uint8_t bits) { return num(bits); });
  }

  inline object_ref ban_experts(object_ref const o, object_ref const layer, object_ref const ids)
  {
    return guarded([&] {
      auto const m{ model_of(o) };
      auto const banned{ ids_of(ids) };
      for(auto const e : banned)
      {
        if(e < 0 || e >= m->cfg.experts)
        {
          throw std::runtime_error{ "inkling: no expert " + std::to_string(e) };
        }
      }
      m->banned_experts.at(static_cast<size_t>(to_int(layer))) = banned;
      return object_ref{ rt::jank_nil };
    });
  }

  // A cache of a visit: 0 keys, 1 values, 2..5 convolution histories.
  inline object_ref cache(object_ref const o, object_ref const visit, object_ref const which)
  {
    return guarded([&] {
      auto const s{ session_of(o) };
      auto const &c{ s->caches.at(static_cast<size_t>(to_int(visit))) };
      auto const w{ to_int(which) };
      if(w < 2)
      {
        auto const rows{ std::min(s->pos, c.slots) };
        uint16_t const *data{ w == 0 ? c.k : c.v };
        object_ref vals{ rt::obj::persistent_vector::empty() };
        for(size_t i{}; i < static_cast<size_t>(rows) * c.kv_heads * c.head_dim; ++i)
        {
          vals = rt::conj(vals, real(static_cast<float>(std::bit_cast<_Float16>(data[i]))));
        }
        return map_builder{}("slots", num(c.slots))(
                 "shape",
                 shape_of({ rows, c.kv_heads, c.head_dim }))("values", vals)
          .m;
      }
      auto const i{ static_cast<size_t>(w - 2) };
      auto const width{ c.conv_width.at(i) };
      auto const tail{ s->model->cfg.conv_taps - 1 };
      object_ref vals{ rt::obj::persistent_vector::empty() };
      for(int64_t j{}; j < static_cast<int64_t>(tail) * width; ++j)
      {
        vals = rt::conj(vals, real(c.conv[i][j]));
      }
      return map_builder{}("shape", shape_of({ tail, width }))("values", vals).m;
    });
  }
}

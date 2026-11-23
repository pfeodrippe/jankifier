// SPDX-License-Identifier: MIT
// The checkpoint's draft model (a DSpark drafter, docs/drafting.md): from the
// hidden states the session keeps (keep_taps), proposals for the tokens after
// an anchor. This is the CPU version: the reference, written to follow the
// specification step by step, values rounded to BF16 where oMLX's activations
// are BF16.
#include "internal.hpp"
#include "json.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace inkling
{
  struct drafter
  {
    struct layer_weights
    {
      std::vector<float> mix_norm, ctx_k_norm, input_norm, q_norm, k_norm, post_norm;
      tensor const *ctx_k{}, *ctx_v{}, *q{}, *k{}, *v{}, *o{}, *gate{}, *up{}, *down{};
    };

    model *m{};
    int32_t layers{}, heads{}, kv_heads{}, head_dim{}, block{}, rank{}, window{}, slots{};
    float eps{}, theta{};
    // The target visits whose partial sums the drafter reads, then the final
    // norm's output: session::tap_visits.
    std::vector<int32_t> visits;
    // Softmax of the fuse weights, rounded: [layers + 1][taps].
    std::vector<std::vector<float>> alpha;
    std::vector<layer_weights> lw;
    std::vector<float> mask_embed, final_norm, markov_norm, rnn_bias, hidden_bias;
    tensor const *markov_embed{}, *rnn{}, *hidden_out{};
    // The context ring: each layer's keys (normed, rotated) and values,
    // [kv_heads][slots][head_dim], and each slot's position (-1: empty).
    std::vector<std::vector<float>> ring_k, ring_v;
    std::vector<int64_t> ring_pos;
    // Positions before `fed` are in the ring (or were dropped).
    int64_t fed{};
    int32_t depth{ 7 };
  };

  namespace
  {
    std::vector<float> vec_of(model &m, std::string const &name)
    {
      auto const *t{ m.find(name) };
      if(!t)
      {
        fail("draft model: no tensor " + name);
      }
      auto const *p{ m.f32(t) };
      return { p, p + t->numel() };
    }

    tensor const *mat_of(model &m, std::string const &name)
    {
      auto const *t{ m.find(name) };
      if(!t || t->type != dtype::bf16 || t->shape.size() != 2)
      {
        fail("draft model: no BF16 matrix " + name);
      }
      return t;
    }

    void round_vec(float *x, size_t const n)
    {
      for(size_t i{}; i < n; ++i)
      {
        x[i] = round_bf16(x[i]);
      }
    }

    // MLX's RoPE, not traditional: the two halves of a head rotated together.
    void rope(float *x, int32_t const dim, int64_t const pos, float const theta)
    {
      int32_t const half{ dim / 2 };
      for(int32_t j{}; j < half; ++j)
      {
        double const angle{ static_cast<double>(pos) * std::pow(static_cast<double>(theta), -2.0 * j / dim) };
        float const c{ static_cast<float>(std::cos(angle)) };
        float const s{ static_cast<float>(std::sin(angle)) };
        float const a{ x[j] };
        float const b{ x[j + half] };
        x[j] = a * c - b * s;
        x[j + half] = a * s + b * c;
      }
    }

    // Per head RMS norm with `w`, rounded, then rotated at `pos` and rounded.
    void head_norm_rope(float *x, int32_t const n_heads, int32_t const dim, float const *w, float const eps,
                        int64_t const pos, float const theta, bool const rotate)
    {
      for(int32_t hd{}; hd < n_heads; ++hd)
      {
        float *p{ x + static_cast<size_t>(hd) * dim };
        cpu_rmsnorm(p, w, dim, eps, p);
        round_vec(p, static_cast<size_t>(dim));
        if(rotate)
        {
          rope(p, dim, pos, theta);
          round_vec(p, static_cast<size_t>(dim));
        }
      }
    }

    // y[t] = W x[t] for `tokens` rows, rounded to BF16.
    void lin(model &m, tensor const *w, float const *x, int32_t const tokens, std::vector<float> &y)
    {
      y.assign(static_cast<size_t>(tokens) * w->dim(0), 0.0f);
      cpu_linear(m, w, x, tokens, y.data());
      round_vec(y.data(), y.size());
    }
  }

  drafter *new_drafter(session &s)
  {
    auto &m{ *s.model };
    auto const files{ m.files.find("config.json") };
    if(files == m.files.end())
    {
      fail("draft model: the model file has no config.json");
    }
    auto const root{ json::parse(files->second) };
    auto const *mtp{ root.get("mtp_config") };
    if(!mtp || !m.find("draft.mask_embed"))
    {
      fail("draft model: this model has none");
    }
    auto d{ std::make_unique<drafter>() };
    d->m = &m;
    auto const i32{ [&](char const *k) { return static_cast<int32_t>(mtp->at(k).integer()); } };
    d->layers = i32("num_hidden_layers");
    d->heads = i32("num_attention_heads");
    d->kv_heads = i32("num_key_value_heads");
    d->head_dim = i32("head_dim");
    d->block = i32("block_size");
    d->rank = i32("markov_rank");
    d->window = i32("sliding_window_size");
    d->eps = static_cast<float>(mtp->at("rms_norm_eps").num());
    d->theta = static_cast<float>(mtp->at("rope_theta").num());
    if(mtp->at("markov_head_type").str() != "rnn_hidden" || i32("hidden_size") != m.cfg.hidden)
    {
      fail("draft model: not a DSpark drafter of this model");
    }
    auto const &ids{ mtp->at("target_layer_ids").items() };
    for(size_t i{}; i < ids.size(); ++i)
    {
      auto const id{ static_cast<int32_t>(ids[i].integer()) };
      bool const last{ i + 1 == ids.size() };
      if(last != (id == static_cast<int32_t>(m.plan.size())))
      {
        fail("draft model: its last tap must be the final norm's output");
      }
      if(!last)
      {
        d->visits.push_back(id);
      }
    }
    // A slot for each of the newest window - 1 positions and a block's spare.
    d->slots = d->window - 1 + d->block;
    size_t const taps{ d->visits.size() + 1 };

    auto const fuse{ vec_of(m, "draft.fuse_weight") };
    if(fuse.size() != (static_cast<size_t>(d->layers) + 1) * taps)
    {
      fail("draft model: fuse_weight has the wrong shape");
    }
    for(int32_t l{}; l <= d->layers; ++l)
    {
      float const *row{ fuse.data() + static_cast<size_t>(l) * taps };
      float const best{ *std::max_element(row, row + taps) };
      float den{};
      std::vector<float> a(taps);
      for(size_t t{}; t < taps; ++t)
      {
        a[t] = std::exp(row[t] - best);
        den += a[t];
      }
      for(auto &x : a)
      {
        x = round_bf16(x / den);
      }
      d->alpha.push_back(a);
    }
    for(int32_t l{}; l < d->layers; ++l)
    {
      std::string const p{ "draft.layers." + std::to_string(l) + "." };
      drafter::layer_weights w;
      w.mix_norm = vec_of(m, p + "dflare_norm.weight");
      w.ctx_k = mat_of(m, p + "self_attn.k_proj_ctx.weight");
      w.ctx_v = mat_of(m, p + "self_attn.v_proj_ctx.weight");
      w.ctx_k_norm = vec_of(m, p + "self_attn.k_norm_ctx.weight");
      w.input_norm = vec_of(m, p + "input_layernorm.weight");
      w.q = mat_of(m, p + "self_attn.q_proj.weight");
      w.k = mat_of(m, p + "self_attn.k_proj.weight");
      w.v = mat_of(m, p + "self_attn.v_proj.weight");
      w.q_norm = vec_of(m, p + "self_attn.q_norm.weight");
      w.k_norm = vec_of(m, p + "self_attn.k_norm.weight");
      w.o = mat_of(m, p + "self_attn.o_proj.weight");
      w.post_norm = vec_of(m, p + "post_attention_layernorm.weight");
      w.gate = mat_of(m, p + "mlp.gate_proj.weight");
      w.up = mat_of(m, p + "mlp.up_proj.weight");
      w.down = mat_of(m, p + "mlp.down_proj.weight");
      d->lw.push_back(std::move(w));
    }
    d->mask_embed = vec_of(m, "draft.mask_embed");
    d->final_norm = vec_of(m, "draft.norm.weight");
    d->markov_norm = vec_of(m, "draft.markov_head.dflare_norm.weight");
    d->markov_embed = mat_of(m, "draft.markov_head.markov_w1.weight");
    d->rnn = mat_of(m, "draft.markov_head.rnn_proj.weight");
    d->rnn_bias = vec_of(m, "draft.markov_head.rnn_proj.bias");
    d->hidden_out = mat_of(m, "draft.markov_head.hidden_out.weight");
    d->hidden_bias = vec_of(m, "draft.markov_head.hidden_out.bias");

    size_t const ring{ static_cast<size_t>(d->kv_heads) * d->slots * d->head_dim };
    d->ring_k.assign(static_cast<size_t>(d->layers), std::vector<float>(ring));
    d->ring_v.assign(static_cast<size_t>(d->layers), std::vector<float>(ring));
    d->ring_pos.assign(static_cast<size_t>(d->slots), -1);
    keep_taps(s, d->visits);
    return d.release();
  }

  void free_drafter(drafter *d)
  {
    delete d;
  }

  void set_draft_depth(drafter &d, int32_t const depth)
  {
    d.depth = std::clamp(depth, 0, d.block - 1);
  }

  int32_t draft_depth(drafter const &d)
  {
    return d.depth;
  }

  std::vector<int32_t> draft(drafter &d, session const &s, int32_t const anchor, int32_t const count)
  {
    auto &m{ *d.m };
    int64_t const h{ m.cfg.hidden };
    size_t const taps{ d.visits.size() + 1 };
    int32_t const n_out{ std::clamp(count, 0, d.block - 1) };
    int64_t const total{ s.pos };
    if(n_out == 0 || total == 0)
    {
      return {};
    }
    if(!s.tap_ring || s.tap_visits != d.visits)
    {
      fail("draft: the session doesn't keep this drafter's hidden states");
    }
    auto const tap_row{ [&](int64_t pos) {
      return s.tap_ring + static_cast<size_t>(pos % tap_slots) * taps * static_cast<size_t>(h);
    } };
    // The mix of a position's taps by alpha, RMS-normalized with `norm`, rounded.
    auto const mixed{ [&](int64_t pos, std::vector<float> const &alpha, std::vector<float> const &norm, float *out) {
      uint16_t const *row{ tap_row(pos) };
      for(int64_t i{}; i < h; ++i)
      {
        float x{};
        for(size_t t{}; t < taps; ++t)
        {
          x += alpha[t] * bf16_to_f32(row[t * static_cast<size_t>(h) + static_cast<size_t>(i)]);
        }
        out[i] = x;
      }
      cpu_rmsnorm(out, norm.data(), h, d.eps, out);
      round_vec(out, static_cast<size_t>(h));
    } };

    // The context rows not yet in the ring (the newest window - 1 at most).
    if(d.fed > total)
    {
      d.fed = total;
    }
    int64_t const from{ std::max<int64_t>(d.fed, total - (d.window - 1)) };
    int32_t const n_new{ static_cast<int32_t>(total - from) };
    int32_t const kvw{ d.kv_heads * d.head_dim };
    if(n_new > 0)
    {
      std::vector<float> mix(static_cast<size_t>(n_new) * h), kc, vc;
      for(int32_t l{}; l < d.layers; ++l)
      {
        auto const &w{ d.lw[static_cast<size_t>(l)] };
        for(int32_t r{}; r < n_new; ++r)
        {
          mixed(from + r, d.alpha[static_cast<size_t>(l)], w.mix_norm, mix.data() + static_cast<size_t>(r) * h);
        }
        lin(m, w.ctx_k, mix.data(), n_new, kc);
        lin(m, w.ctx_v, mix.data(), n_new, vc);
        for(int32_t r{}; r < n_new; ++r)
        {
          int64_t const pos{ from + r };
          head_norm_rope(kc.data() + static_cast<size_t>(r) * kvw, d.kv_heads, d.head_dim, w.ctx_k_norm.data(), d.eps, pos,
                         d.theta, true);
          auto const slot{ static_cast<size_t>(pos % d.slots) };
          for(int32_t hd{}; hd < d.kv_heads; ++hd)
          {
            size_t const dst{ (static_cast<size_t>(hd) * d.slots + slot) * d.head_dim };
            size_t const src{ static_cast<size_t>(r) * kvw + static_cast<size_t>(hd) * d.head_dim };
            std::memcpy(d.ring_k[static_cast<size_t>(l)].data() + dst, kc.data() + src, sizeof(float) * d.head_dim);
            std::memcpy(d.ring_v[static_cast<size_t>(l)].data() + dst, vc.data() + src, sizeof(float) * d.head_dim);
          }
          d.ring_pos[slot] = pos;
        }
      }
    }
    d.fed = total;

    // The block: the anchor's normalized embedding, then mask rows.
    int32_t const rows{ d.block };
    std::vector<float> hs(static_cast<size_t>(rows) * h);
    {
      auto const *emb{ static_cast<uint16_t const *>(m.embed->data) };
      for(int64_t i{}; i < h; ++i)
      {
        hs[static_cast<size_t>(i)] = bf16_to_f32(emb[static_cast<int64_t>(anchor) * h + i]);
      }
      cpu_rmsnorm(hs.data(), m.f32(m.embed_norm), h, m.cfg.norm_eps, hs.data());
      round_vec(hs.data(), static_cast<size_t>(h));
      for(int32_t r{ 1 }; r < rows; ++r)
      {
        std::copy(d.mask_embed.begin(), d.mask_embed.end(), hs.begin() + static_cast<ptrdiff_t>(r) * h);
      }
    }
    // The ring slots attended: positions in [total - (window - 1), total).
    std::vector<size_t> valid;
    for(size_t slot{}; slot < static_cast<size_t>(d.slots); ++slot)
    {
      auto const p{ d.ring_pos[slot] };
      if(p >= 0 && p >= total - (d.window - 1) && p < total)
      {
        valid.push_back(slot);
      }
    }
    int32_t const qw{ d.heads * d.head_dim };
    int32_t const group{ d.heads / d.kv_heads };
    float const scale{ 1.0f / std::sqrt(static_cast<float>(d.head_dim)) };
    std::vector<float> x(hs.size()), q, kb, vb, att(static_cast<size_t>(rows) * qw), o, g, u, dn;
    for(int32_t l{}; l < d.layers; ++l)
    {
      auto const &w{ d.lw[static_cast<size_t>(l)] };
      for(int32_t r{}; r < rows; ++r)
      {
        cpu_rmsnorm(hs.data() + static_cast<size_t>(r) * h, w.input_norm.data(), h, d.eps, x.data() + static_cast<size_t>(r) * h);
      }
      round_vec(x.data(), x.size());
      lin(m, w.q, x.data(), rows, q);
      lin(m, w.k, x.data(), rows, kb);
      lin(m, w.v, x.data(), rows, vb);
      for(int32_t r{}; r < rows; ++r)
      {
        head_norm_rope(q.data() + static_cast<size_t>(r) * qw, d.heads, d.head_dim, w.q_norm.data(), d.eps, total + r, d.theta,
                       true);
        head_norm_rope(kb.data() + static_cast<size_t>(r) * kvw, d.kv_heads, d.head_dim, w.k_norm.data(), d.eps, total + r,
                       d.theta, true);
      }
      // Attention: every block row reads the valid ring slots and all block rows.
      auto const &rk{ d.ring_k[static_cast<size_t>(l)] };
      auto const &rv{ d.ring_v[static_cast<size_t>(l)] };
      std::vector<float> scores(valid.size() + static_cast<size_t>(rows));
      for(int32_t r{}; r < rows; ++r)
      {
        for(int32_t hd{}; hd < d.heads; ++hd)
        {
          int32_t const kvh{ hd / group };
          float const *qv{ q.data() + static_cast<size_t>(r) * qw + static_cast<size_t>(hd) * d.head_dim };
          auto const key{ [&](size_t i) {
            return i < valid.size() ? rk.data() + (static_cast<size_t>(kvh) * d.slots + valid[i]) * d.head_dim
                                    : kb.data() + (i - valid.size()) * kvw + static_cast<size_t>(kvh) * d.head_dim;
          } };
          auto const value{ [&](size_t i) {
            return i < valid.size() ? rv.data() + (static_cast<size_t>(kvh) * d.slots + valid[i]) * d.head_dim
                                    : vb.data() + (i - valid.size()) * kvw + static_cast<size_t>(kvh) * d.head_dim;
          } };
          float best{ -INFINITY };
          for(size_t i{}; i < scores.size(); ++i)
          {
            float const *k{ key(i) };
            float sdot{};
            for(int32_t j{}; j < d.head_dim; ++j)
            {
              sdot += qv[j] * k[j];
            }
            scores[i] = sdot * scale;
            best = std::max(best, scores[i]);
          }
          float den{};
          for(auto &sc : scores)
          {
            sc = std::exp(sc - best);
            den += sc;
          }
          float *out{ att.data() + static_cast<size_t>(r) * qw + static_cast<size_t>(hd) * d.head_dim };
          std::fill(out, out + d.head_dim, 0.0f);
          for(size_t i{}; i < scores.size(); ++i)
          {
            float const p{ scores[i] / den };
            float const *v{ value(i) };
            for(int32_t j{}; j < d.head_dim; ++j)
            {
              out[j] += p * v[j];
            }
          }
        }
      }
      round_vec(att.data(), att.size());
      lin(m, w.o, att.data(), rows, o);
      for(size_t i{}; i < hs.size(); ++i)
      {
        hs[i] = round_bf16(hs[i] + o[i]);
      }
      for(int32_t r{}; r < rows; ++r)
      {
        cpu_rmsnorm(hs.data() + static_cast<size_t>(r) * h, w.post_norm.data(), h, d.eps, x.data() + static_cast<size_t>(r) * h);
      }
      round_vec(x.data(), x.size());
      lin(m, w.gate, x.data(), rows, g);
      lin(m, w.up, x.data(), rows, u);
      for(size_t i{}; i < g.size(); ++i)
      {
        float const a{ g[i] };
        g[i] = round_bf16(round_bf16(a / (1.0f + std::exp(-a))) * u[i]);
      }
      lin(m, w.down, g.data(), rows, dn);
      for(size_t i{}; i < hs.size(); ++i)
      {
        hs[i] = round_bf16(hs[i] + dn[i]);
      }
    }
    // The mask rows' hidden states, normed: dh[i] proposes the token at total + 1 + i.
    std::vector<float> dh(static_cast<size_t>(n_out) * h);
    for(int32_t i{}; i < n_out; ++i)
    {
      cpu_rmsnorm(hs.data() + static_cast<size_t>(i + 1) * h, d.final_norm.data(), h, d.eps, dh.data() + static_cast<size_t>(i) * h);
    }
    round_vec(dh.data(), dh.size());

    // The Markov head: from the newest committed row's taps, a step a token.
    int32_t const rank{ d.rank };
    std::vector<float> f(static_cast<size_t>(h));
    mixed(total - 1, d.alpha[static_cast<size_t>(d.layers)], d.markov_norm, f.data());
    std::vector<float> state(static_cast<size_t>(rank), 0.0f), in(static_cast<size_t>(2 * rank + 2 * h)), proj(3 * static_cast<size_t>(rank)),
      z(static_cast<size_t>(rank)), shift(static_cast<size_t>(h)), hidden(static_cast<size_t>(h)),
      logits(static_cast<size_t>(m.unembed->dim(0)));
    auto const *memb{ static_cast<uint16_t const *>(d.markov_embed->data) };
    int32_t const v_used{ static_cast<int32_t>(m.cfg.unpadded_vocab) };
    std::vector<int32_t> out;
    int32_t prev{ anchor };
    for(int32_t i{}; i < n_out; ++i)
    {
      std::copy(state.begin(), state.end(), in.begin());
      for(int32_t j{}; j < rank; ++j)
      {
        in[static_cast<size_t>(rank + j)] = bf16_to_f32(memb[static_cast<int64_t>(prev) * rank + j]);
      }
      std::copy(dh.begin() + static_cast<ptrdiff_t>(i) * h, dh.begin() + static_cast<ptrdiff_t>(i + 1) * h,
                in.begin() + 2 * rank);
      std::copy(f.begin(), f.end(), in.begin() + 2 * rank + h);
      cpu_linear(m, d.rnn, in.data(), 1, proj.data());
      for(size_t j{}; j < proj.size(); ++j)
      {
        proj[j] += d.rnn_bias[j];
      }
      for(int32_t j{}; j < rank; ++j)
      {
        float const gate{ round_bf16(1.0f / (1.0f + std::exp(-proj[static_cast<size_t>(j)]))) };
        float const cand{ round_bf16(std::tanh(proj[static_cast<size_t>(rank + j)])) };
        auto &st{ state[static_cast<size_t>(j)] };
        st = round_bf16(round_bf16(gate * st) + round_bf16((1.0f - gate) * cand));
        z[static_cast<size_t>(j)] = round_bf16(std::tanh(proj[static_cast<size_t>(2 * rank + j)]));
      }
      // The head moves the hidden state before the shared output head (the
      // fold of oMLX, in exact arithmetic).
      cpu_linear(m, d.hidden_out, z.data(), 1, shift.data());
      for(int64_t j{}; j < h; ++j)
      {
        hidden[static_cast<size_t>(j)] = dh[static_cast<size_t>(i * h + j)] + shift[static_cast<size_t>(j)] + d.hidden_bias[static_cast<size_t>(j)];
      }
      cpu_linear(m, m.unembed, hidden.data(), 1, logits.data());
      prev = static_cast<int32_t>(std::max_element(logits.begin(), logits.begin() + v_used) - logits.begin());
      out.push_back(prev);
    }
    return out;
  }
}
